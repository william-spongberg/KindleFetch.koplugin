local LogUtil = require("util.logutil")
local Request = require("util.request")
local BackgroundProcess = require("util.backgroundprocess")
local ShellUtil = require("util.shellutil")
local FileUtil = require("util.fileutil")
local StringUtil = require("util.stringutil")
local VersionUtil = require("util.versionutil")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Device = require("device")

local CurlUtil = {}

-- the curl installed on Kindles, whose own is too old for Library Genesis: the latest static build, for security fixes
CurlUtil.MIN_VERSION = "8.21.0"

-- constants
local TMP_DIR = DataStorage:getSettingsDir() .. "/tmp/"
-- how long a page can send nothing before it's given up on, as Library Genesis' mirrors can connect then never answer
local FETCH_STALL_TIME = 20
local CURL_ERRORS = {
    [1] = _("unsupported protocol"),
    [3] = _("malformed URL"),
    [5] = _("could not resolve proxy"),
    [6] = _("could not resolve host"),
    [7] = _("failed to connect to server"),
    [16] = _("HTTP/2 error"),
    [18] = _("partial file transfer (download interrupted)"),
    [19] = _("HTTP range request error"),
    [22] = _("HTTP error response"),
    [23] = _("failed writing downloaded data"),
    [26] = _("failed reading local data"),
    [27] = _("out of memory"),
    [28] = _("request timed out"),
    [33] = _("the site can't carry on from where the download stopped"),
    [35] = _("TLS/SSL connection failed"),
    [36] = _("transfer was stopped"),
    [37] = _("failed to open local file"),
    [47] = _("too many redirects"),
    [51] = _("the site's TLS certificate isn't for its address"),
    [52] = _("server returned an empty response"),
    [55] = _("failed sending network data"),
    [56] = _("failed receiving network data"),
    [58] = _("problem with the TLS client certificate"),
    [59] = _("couldn't use the TLS ciphers asked for"),
    [60] = _("TLS certificate verification failed"),
    [61] = _("unsupported TLS/SSL feature"),
    [67] = _("authentication failed"),
    [77] = _("problem reading the TLS certificates to check sites' against"),
    [78] = _("requested resource was not found"),
    [83] = _("TLS certificate issuer check failed"),
    [92] = _("HTTP/2 stream error"),
    -- from the shell rather than from curl, when it can't run curl or can't find it
    [126] = _("curl can't be run on this device"),
    [127] = _("curl isn't installed on this device"),
}

local function ensureTmpDir()
    if lfs.attributes(TMP_DIR, "mode") ~= "directory" and not lfs.mkdir(TMP_DIR) then
        LogUtil.warn("could not create", TMP_DIR, "for curl's files")
    end
end

-- temporary files are numbered too, as os.time() is in seconds and a book and its cover can start in one
local tmp_files_created = 0
local function tmpFile(name, extension)
    ensureTmpDir()
    tmp_files_created = tmp_files_created + 1
    return string.format("%s%s_%d_%d%s", TMP_DIR, name, os.time(), tmp_files_created, extension)
end

-- remove the files left by downloads still running when KOReader last closed, only at the start, while none are in use
function CurlUtil.removeLeftovers()
    if lfs.attributes(TMP_DIR, "mode") ~= "directory" then
        return
    end

    local leftovers = {}
    for __, file in ipairs(FileUtil.listDir(TMP_DIR) or {}) do
        if file:find("^curl_download") then
            table.insert(leftovers, file)
        end
    end
    for __, file in ipairs(leftovers) do
        FileUtil.removeFile(TMP_DIR .. file)
    end
    if #leftovers > 0 then
        LogUtil.info("removed", #leftovers, "files left by earlier downloads")
    end
end

-- how the installed curl describes itself, or nil if it isn't there, looked up once a session as it means starting curl
local curl_description, curl_protocols
local function describeCurl()
    if curl_description == nil then
        local pipe = io.popen("curl --version 2>/dev/null", "r")
        local output = pipe and pipe:read("*a") or ""
        if pipe then
            pipe:close()
        end
        -- false when curl isn't there, so it isn't looked for again
        curl_description = output:match("^[^\n]+") or false
        -- the protocols it can use, where it says, which leave https out for a curl built without TLS
        curl_protocols = output:match("\nProtocols:%s*([^\n]*)")
    end
    return curl_description or nil
end

-- the installed curl's version, e.g. "8.17.0", or nil if curl isn't there
function CurlUtil.getVersion()
    local description = describeCurl()
    -- "curl X.Y.Z (platform) ..."
    return description and description:match("^curl%s+([%d%.]+)")
end

-- whether the installed curl is at least min_version, e.g. "7.68.0", for options older ones would fail on
local function curlIsAtLeast(min_version)
    local version = VersionUtil.parseVersion(CurlUtil.getVersion())
    return version ~= nil and VersionUtil.compareVersions(version, VersionUtil.parseVersion(min_version)) >= 0
end

-- DNS over HTTPS for curl to look sites' names up with: Cloudflare's, by its address, so the network's DNS isn't asked
local DOH_URL = "https://1.1.1.1/dns-query"
local DOH_MIN_VERSION = "7.62.0"

-- whether curl can fetch web pages and ask for them compressed, worked out once per session as it means running curl
local can_fetch, can_decompress
local function checkCurl()
    if can_fetch ~= nil then
        return
    end

    local description = describeCurl()
    local version = VersionUtil.parseVersion(description and description:match("^curl%s+([%d%.]+)"))
    -- every site is https, which a curl built without TLS can't fetch at all
    local has_tls = not curl_protocols or (" " .. curl_protocols .. " "):find(" https ", 1, true) ~= nil
    -- on a Kindle, only once it has been updated, as the curl it comes with can't connect to Library Genesis
    can_fetch = version ~= nil
        and has_tls
        and (
            not Device:isKindle()
            or VersionUtil.compareVersions(version, VersionUtil.parseVersion(CurlUtil.MIN_VERSION)) >= 0
        )
    can_decompress = description ~= nil and description:find("zlib", 1, true) ~= nil
    LogUtil.info(
        "fetching pages with",
        can_fetch and "curl"
            or version and not has_tls and "KOReader, as curl can't make secure connections,"
            or "KOReader, as curl is missing or too old,",
        can_fetch and can_decompress and "compressed" or "uncompressed"
    )
end

-- fetch pages with KOReader's own HTTP for the rest of the session, as curl has been found not to connect where it can
function CurlUtil.stopFetching(why)
    checkCurl()
    if can_fetch then
        LogUtil.warn("fetching pages with KOReader from now on, as", why)
        can_fetch = false
    end
end

function CurlUtil.canFetch()
    checkCurl()
    return can_fetch
end

-- look curl up again when it's next needed, e.g. once a newer one has been installed
function CurlUtil.forgetVersion()
    curl_description = nil
    can_fetch, can_decompress = nil, nil
end

-- what KOReader's own HTTP says went wrong, in lower case, with curl's exit code for it, so it's said the same way
local LUASOCKET_ERRORS = {
    { "host or service not provided, or not known", 6 },
    { "no address associated with hostname", 6 },
    { "name or service not known", 6 },
    { "temporary failure in name resolution", 6 },
    { "host not found", 6 },
    { "timeout", 28 },
    { "connection refused", 7 },
    { "no route to host", 7 },
    { "network is unreachable", 7 },
    { "certificate", 60 },
    { "wantread", 35 },
    { "wantwrite", 35 },
    { "handshake", 35 },
    { "ssl", 35 },
    { "tls", 35 },
    { "closed", 56 },
    { "connection reset", 56 },
}

-- the exit code curl would give for what KOReader's own HTTP says went wrong, or nil where curl has no words of its own
function CurlUtil.exitCodeFor(luasocket_err)
    local lower = tostring(luasocket_err):lower()
    for __, known in ipairs(LUASOCKET_ERRORS) do
        if lower:find(known[1], 1, true) then
            return known[2]
        end
    end
end

function CurlUtil.getErrorMeaning(exit_code)
    return CURL_ERRORS[exit_code] or T(_("(curl exit code %1)"), tostring(exit_code))
end

-- what a Kindle's own curl fails with when connecting to Library Genesis, which it's too old to
local TLS_ERRORS = { [35] = true, [51] = true, [58] = true, [59] = true, [60] = true, [77] = true, [83] = true }
CurlUtil.OUTDATED_ERROR = Errors.OUTDATED_CURL

-- whether what went wrong was connecting securely, as when the device's clock is wrong and certificates seem invalid
function CurlUtil.isTlsFailure(err)
    for exit_code in pairs(TLS_ERRORS) do
        if err == CurlUtil.getErrorMeaning(exit_code) then
            return true
        end
    end
    return false
end

-- whether this is a Kindle whose curl is older than the oldest known to connect to Library Genesis
function CurlUtil.isOutdated()
    return Device:isKindle() and CurlUtil.getVersion() ~= nil and not curlIsAtLeast(CurlUtil.MIN_VERSION)
end

-- what went wrong for curl to exit with exit_code, or on a Kindle with too old a curl, that and how to update it
function CurlUtil.explainExitCode(exit_code)
    if TLS_ERRORS[exit_code] and CurlUtil.isOutdated() then
        return CurlUtil.OUTDATED_ERROR
    end
    return CurlUtil.getErrorMeaning(exit_code)
end

-- the size of the file a site is sending, from its responses' headers (several when redirected or carried on)
function CurlUtil.parseContentLength(headers)
    -- from the file's response, the last that sent something, not a redirect's before it, or nil if it doesn't say
    local file_size = nil
    for block in headers:gmatch("HTTP[/%d%.]+.-\r?\n\r?\n") do
        if block:match("^HTTP[/%d%.]+ 2%d%d") then
            -- the whole file's size, when only the rest of it was sent
            local size = block:match("[Cc]ontent%-[Rr]ange:%s*bytes%s+%d+%-%d+/(%d+)")
                or block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
            file_size = tonumber(size)
        end
    end
    return file_size
end

-- file a download can have curl note the headers it's sent down in (see download's opts)
function CurlUtil.createHeadersFile()
    local headers_file = tmpFile("curl_download", ".headers")
    FileUtil.removeFile(headers_file)

    return headers_file
end

-- how big the download is by the headers curl noted, or nil; they're in before the file, so it needn't be asked first
function CurlUtil.getDownloadSize(headers_file)
    local f = io.open(headers_file, "r")
    if not f then
        return nil
    end
    local headers = f:read("*a")
    f:close()

    return CurlUtil.parseContentLength(headers or "")
end

-- the HTTP status the site ended up answering a download with, by the headers curl noted, or nil if it hasn't answered
function CurlUtil.getDownloadStatus(headers_file)
    local f = io.open(headers_file, "r")
    if not f then
        return nil
    end
    local headers = f:read("*a")
    f:close()

    local last_status
    for status in (headers or ""):gmatch("HTTP[/%d%.]+ (%d%d%d)") do
        last_status = tonumber(status)
    end
    return last_status
end

-- file a page is fetched into, see fetchCommand
function CurlUtil.createPageFile()
    local page_file = tmpFile("curl_download", ".page")
    FileUtil.removeFile(page_file)

    return page_file
end

function CurlUtil.createExitFile()
    local exit_file = tmpFile("curl_download", ".exitcode")
    FileUtil.removeFile(exit_file)

    return exit_file
end

function CurlUtil.getDownloadCMD(download_url, filepath)
    return string.format("curl -sL -f -o %s %s", ShellUtil.quote(filepath), ShellUtil.quote(download_url))
end

function CurlUtil.pretendBrowser(curl_cmd)
    return curl_cmd .. " -A 'Mozilla/5.0'"
end

-- send the site as the referer, like a browser, as Library Genesis sends empty covers without one
function CurlUtil.setReferer(curl_cmd, url)
    local site = tostring(url):match("^(https?://[^/]+)")
    if not site then
        return curl_cmd
    end
    return string.format("%s -e %s", curl_cmd, ShellUtil.quote(site .. "/"))
end

function CurlUtil.enableRetry(curl_cmd, count, delay)
    return string.format("%s --retry %d --retry-delay %d", curl_cmd, count, delay)
end

function CurlUtil.setTimeout(curl_cmd, seconds)
    return string.format("%s --connect-timeout %d", curl_cmd, seconds)
end

-- give up once nothing has arrived for this many seconds
function CurlUtil.abortWhenStalled(curl_cmd, seconds)
    return string.format("%s --speed-limit 1 --speed-time %d", curl_cmd, seconds)
end

function CurlUtil.dumpHeaders(curl_cmd, headers_file)
    return string.format("%s -D %s", curl_cmd, ShellUtil.quote(headers_file))
end

function CurlUtil.enableParallel(curl_cmd, max_parallel)
    -- which curl older than 7.66 doesn't have, and fails on, downloading them one after another instead
    if not curlIsAtLeast("7.66.0") then
        return curl_cmd
    end
    local cmd = string.format("%s --parallel --parallel-max %d", curl_cmd, max_parallel)
    -- a connection per file at once, as Library Genesis never lets them share: covers arrive in a third of the time
    if curlIsAtLeast("7.68.0") then
        cmd = cmd .. " --parallel-immediate"
    end
    return cmd
end

-- whether curl can look names up with encrypted DNS (see applyEncryptedDns)
function CurlUtil.canUseEncryptedDns()
    return CurlUtil.canFetch() and curlIsAtLeast(DOH_MIN_VERSION)
end

-- curl_cmd with DNS over HTTPS where the request is to go with it (see Request) and curl can
function CurlUtil.applyEncryptedDns(curl_cmd, request)
    if request.encrypted_dns and CurlUtil.canUseEncryptedDns() then
        return string.format("%s --doh-url %s", curl_cmd, DOH_URL)
    end
    return curl_cmd
end

-- curl_cmd through the request's proxy, in a config file (returned, to remove), as any program can read command lines
function CurlUtil.applyProxy(curl_cmd, request)
    local proxy = request.proxy
    if not proxy then
        return curl_cmd
    end
    local config_file = CurlUtil.createConfigFile({ { "proxy", proxy } })
    if not config_file then
        LogUtil.warn("could not give curl the proxy, so it's going without")
        return curl_cmd
    end
    return string.format("%s -K %s", curl_cmd, ShellUtil.quote(config_file)), config_file
end

-- a file of curl options (each name and value, or name) kept off its command line; nil if a value has a line break
function CurlUtil.createConfigFile(options)
    local lines = {}
    for __, option in ipairs(options) do
        local name, value = option[1], option[2]
        if value == nil then
            table.insert(lines, name)
        else
            value = tostring(value)
            if value:find("%c") then
                return nil
            end
            table.insert(lines, string.format('%s = "%s"', name, (value:gsub('[\\"]', "\\%0"))))
        end
    end

    local config_file = tmpFile("curl_download", ".config")
    local f = io.open(config_file, "w")
    if not f then
        return nil
    end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    return config_file
end

-- the options logging curl in to the request's library whichever way it asks, or nil where it needs none
function CurlUtil.loginOptions(request)
    local login = request.login
    if not login then
        return nil
    end
    return { { "user", login.username .. ":" .. login.password }, { "anyauth" } }
end

-- a command that fetches a page to page_file (kept on an error status, for what it says), printing status and exit code
function CurlUtil.fetchCommand(url, page_file, answer_timeout, page_timeout, config_file)
    checkCurl()
    local request = Request.new(url)

    local cmd = string.format("curl -sL -o %s %s", ShellUtil.quote(page_file), ShellUtil.quote(url))
    if can_decompress then
        -- a page of search results is a tenth of the size compressed, and Library Genesis sends them slowly
        cmd = cmd .. " --compressed"
    end
    cmd = CurlUtil.pretendBrowser(cmd)
    cmd = CurlUtil.setReferer(cmd, url)
    cmd = string.format(
        "%s --connect-timeout %d --max-time %d",
        cmd,
        request:connectTimeout(answer_timeout),
        page_timeout
    )
    cmd = CurlUtil.abortWhenStalled(cmd, FETCH_STALL_TIME)
    cmd = CurlUtil.applyEncryptedDns(cmd, request)
    -- each config file curl is given, removed once it has finished with them
    local config_files = {}
    local proxy_config
    cmd, proxy_config = CurlUtil.applyProxy(cmd, request)
    if proxy_config then
        table.insert(config_files, ShellUtil.quote(proxy_config))
    end
    if config_file then
        cmd = string.format("%s -K %s", cmd, ShellUtil.quote(config_file))
        table.insert(config_files, ShellUtil.quote(config_file))
    end
    if #config_files > 0 then
        return string.format(
            '(%s -w %s; exit_code=$?; rm -f %s; echo " $exit_code") 2>/dev/null',
            cmd,
            ShellUtil.quote("%{http_code}"),
            table.concat(config_files, " ")
        )
    end

    return string.format('(%s -w %s; echo " $?") 2>/dev/null', cmd, ShellUtil.quote("%{http_code}"))
end

-- file downloadMultiple has curl write each transfer's result to
function CurlUtil.getResultsFile(config_file)
    return config_file .. ".results"
end

-- exit code of each file downloaded by downloadMultiple, by path
function CurlUtil.getTransferResults(results_file)
    local results = {}
    local f = io.open(results_file, "r")
    if not f then
        return results
    end
    for line in f:lines() do
        local exit_code, path = line:match("^(%d+) (.+)$")
        if exit_code then
            results[path] = tonumber(exit_code)
        end
    end
    f:close()
    return results
end

-- whether a file from downloadMultiple downloaded, going by curl's exit code when it didn't say for each file
function CurlUtil.isTransferComplete(results, filepath, exit_code)
    if next(results) then
        return results[filepath] == 0 and FileUtil.getSize(filepath) > 0
    end
    return exit_code == 0 and FileUtil.getSize(filepath) > 0
end

-- the command downloading url to filepath and its exit file; opts.resume carries on from what's there, also on retries
local function downloadCommand(download_url, filepath, max_time, opts)
    opts = opts or {}
    local request = Request.new(download_url)

    local cmd = CurlUtil.getDownloadCMD(download_url, filepath)
    if opts.resume then
        cmd = cmd .. " -C -"
    end
    cmd = CurlUtil.pretendBrowser(cmd)
    cmd = CurlUtil.setReferer(cmd, download_url)
    cmd = CurlUtil.enableRetry(cmd, 2, 2)
    cmd = CurlUtil.setTimeout(cmd, request:connectTimeout(15))
    if max_time then
        cmd = string.format("%s --max-time %d --retry-max-time %d", cmd, max_time, max_time)
    end
    if opts.headers_file then
        cmd = CurlUtil.dumpHeaders(cmd, opts.headers_file)
    end
    if opts.stall_time then
        cmd = CurlUtil.abortWhenStalled(cmd, opts.stall_time)
    end
    cmd = CurlUtil.applyEncryptedDns(cmd, request)
    -- each config file curl is given (see applyProxy), removed once it has finished with them
    local config_files = {}
    local proxy_config
    cmd, proxy_config = CurlUtil.applyProxy(cmd, request)
    if proxy_config then
        table.insert(config_files, proxy_config)
    end
    -- and the library's login, where it's on a library's site that needs one (see loginOptions)
    local login = CurlUtil.loginOptions(request)
    if login then
        local login_config = CurlUtil.createConfigFile(login)
        if login_config then
            cmd = string.format("%s -K %s", cmd, ShellUtil.quote(login_config))
            table.insert(config_files, login_config)
        else
            LogUtil.warn("could not give curl the library's login, so it's going without")
        end
    end

    local exit_file = CurlUtil.createExitFile()
    cmd = BackgroundProcess.saveExitCode(cmd, exit_file, config_files)

    -- without the link, which can carry a temporary key
    LogUtil.debug("curl downloading from", LogUtil.site(download_url), "to", filepath)
    return cmd, exit_file
end

-- download url to filepath in the background, returning its pid and the file its exit code is saved in, or nil and why
function CurlUtil.startDownload(download_url, filepath, max_time, opts)
    local cmd, exit_file = downloadCommand(download_url, filepath, max_time, opts)
    local pid, err = BackgroundProcess.spawn(BackgroundProcess.echoPid(cmd))
    if not pid then
        return nil, err
    end
    return pid, exit_file
end

-- download url to filepath, holding KOReader up until it has: true, or nil and what went wrong, leaving nothing behind
function CurlUtil.download(download_url, filepath, max_time, opts)
    local cmd, exit_file = downloadCommand(download_url, filepath, max_time, opts)
    os.execute(cmd)

    local exit_code = BackgroundProcess.getExitCode(exit_file)
    if not exit_code then
        LogUtil.warn("could not start curl to download from", LogUtil.site(download_url))
        FileUtil.removeFile(exit_file)
        FileUtil.removeFile(filepath)
        return nil, Errors.START_FAILED
    end
    if exit_code == 0 then
        local file_size = FileUtil.getSize(filepath)
        if file_size and file_size > 0 then
            LogUtil.debug("download completed successfully", {
                filepath = filepath,
                file_size = file_size,
            })
            return true
        else
            LogUtil.warn("download from", LogUtil.site(download_url), "to", filepath, "produced an empty file")
            FileUtil.removeFile(filepath)
            return nil, _("download produced empty file")
        end
    else
        LogUtil.warn(
            "download from",
            LogUtil.site(download_url),
            "to",
            filepath,
            "failed: curl exit code",
            exit_code,
            "(" .. CurlUtil.getErrorMeaning(exit_code) .. ")"
        )
        FileUtil.removeFile(filepath)
        return nil, CurlUtil.getErrorMeaning(exit_code)
    end
end

-- opts.stall_time optionally gives up on a file once nothing of it has arrived for that many seconds
function CurlUtil.downloadMultiple(download_urls, filepaths, background, num_parallel_jobs, enable_retry, timeout, opts)
    opts = opts or {}
    ensureTmpDir()

    -- backslashes and quotes mean something inside the quotes of curl's config file
    local function quote(value)
        return (value:gsub("\\", "\\\\"):gsub('"', '\\"'))
    end
    local batch = Request.batch(download_urls)
    local lines = {}
    -- the proxy, where they go through one, with the files rather than on curl's command line (see applyProxy)
    local proxy = batch.proxy
    if proxy and not proxy:find("%c") then
        table.insert(lines, string.format('proxy = "%s"\n', quote(proxy)))
    end
    -- and the library's login, given once for all (see Request.batch)
    for __, option in ipairs(CurlUtil.loginOptions(batch) or {}) do
        if option[2] == nil then
            table.insert(lines, option[1] .. "\n")
        elseif not option[2]:find("%c") then
            table.insert(lines, string.format('%s = "%s"\n', option[1], quote(option[2])))
        end
    end
    for i, download_url in ipairs(download_urls) do
        -- an address with a line break in it would add lines of its own to the config file, so leave it out
        if StringUtil.isSafeUrl(download_url) and not filepaths[i]:find("%c") then
            table.insert(lines, string.format('url = "%s"\n', quote(download_url)))
            table.insert(lines, string.format('output = "%s"\n', quote(filepaths[i])))
        else
            LogUtil.warn("left out a download whose address can't be used:", download_url)
        end
    end

    -- which can't be written when the device's storage is full, or read-only
    local config_file = tmpFile("curl_download_config", ".txt")
    local f, open_err = io.open(config_file, "w")
    local written, write_err = false, open_err
    if f then
        written, write_err = f:write(table.concat(lines))
        local closed, close_err = f:close()
        written, write_err = written and closed, write_err or close_err
    end
    if not written then
        LogUtil.warn("could not write curl's list of files to download to", config_file .. ":", write_err)
        FileUtil.removeFile(config_file)
        if background then
            return nil, nil, nil, _("could not write the list of files for curl")
        end
        return 0
    end

    local results_file = CurlUtil.getResultsFile(config_file)
    local cmd = string.format('curl -sL -f --config "%s"', config_file)
    cmd = CurlUtil.pretendBrowser(cmd)
    -- covers for a page of search results all come from the same site
    cmd = CurlUtil.setReferer(cmd, download_urls[1])
    if enable_retry then
        cmd = CurlUtil.enableRetry(cmd, 2, 2)
    end
    cmd = CurlUtil.setTimeout(cmd, batch:connectTimeout(timeout))
    -- give up on files that take too long, so they don't hold up the rest
    cmd = string.format("%s --max-time %d", cmd, timeout * 2)
    if opts.stall_time then
        cmd = CurlUtil.abortWhenStalled(cmd, opts.stall_time)
    end
    cmd = CurlUtil.enableParallel(cmd, num_parallel_jobs)
    cmd = CurlUtil.applyEncryptedDns(cmd, batch)
    -- each file's result, as some may fail, to stderr where curl can, which is unbuffered, so each shows once done
    local write_out = "%{exitcode} %{filename_effective}\\n"
    if curlIsAtLeast("7.63.0") then
        cmd = string.format(
            "%s -w %s 2> %s",
            cmd,
            ShellUtil.quote("%{stderr}" .. write_out),
            ShellUtil.quote(results_file)
        )
    else
        cmd = string.format("%s -w %s > %s", cmd, ShellUtil.quote(write_out), ShellUtil.quote(results_file))
    end

    local exit_file = CurlUtil.createExitFile()
    cmd = BackgroundProcess.saveExitCode(cmd, exit_file)

    LogUtil.debug("curl parallel download command", cmd)

    if background then
        cmd = BackgroundProcess.echoPid(cmd)

        local pid, err = BackgroundProcess.spawn(cmd)
        if not pid then
            FileUtil.removeFile(config_file)
            FileUtil.removeFile(exit_file)
            return nil, nil, nil, err
        end

        LogUtil.debug("spawned parallel download", {
            pid = pid,
            exit_file = exit_file,
            config_file = config_file,
            file_count = #download_urls,
        })
        return pid, exit_file, config_file
    end

    os.execute(cmd)

    local exit_code = BackgroundProcess.getExitCode(exit_file)
    if exit_code ~= 0 then
        local reason = CurlUtil.getErrorMeaning(exit_code)
        LogUtil.warn("parallel download command failed", {
            exit_code = exit_code,
            reason = reason,
        })
    end

    local results = CurlUtil.getTransferResults(results_file)
    local successful_count = 0
    for __, filepath in ipairs(filepaths) do
        if CurlUtil.isTransferComplete(results, filepath, exit_code) then
            successful_count = successful_count + 1
            LogUtil.debug("file downloaded successfully", filepath)
        else
            LogUtil.warn("file download failed", filepath)
            FileUtil.removeFile(filepath)
        end
    end

    FileUtil.removeFile(config_file)
    FileUtil.removeFile(results_file)

    LogUtil.debug("parallel download completed", {
        total_requested = #download_urls,
        successful = successful_count,
    })

    return successful_count
end

return CurlUtil
