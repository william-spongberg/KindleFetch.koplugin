local NotifyUtil = require("util.notifyutil")
local LogUtil = require("util.logutil")
local FileUtil = require("util.fileutil")
local StringUtil = require("util.stringutil")
local VersionUtil = require("util.versionutil")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Device = require("device")

local CurlUtil = {}

-- the oldest curl known to connect to Library Genesis from a Kindle, whose own curl is too old to
CurlUtil.MIN_VERSION = "8.17.0"

-- constants
local TMP_DIR = DataStorage:getSettingsDir() .. "/tmp/"
local CURL_ERRORS = {
    [1] = "unsupported protocol",
    [3] = "malformed URL",
    [5] = "could not resolve proxy",
    [6] = "could not resolve host",
    [7] = "failed to connect to server",
    [18] = "partial file transfer (download interrupted)",
    [19] = "HTTP range request error",
    [22] = "HTTP error response",
    [23] = "failed writing downloaded data",
    [26] = "failed reading local data",
    [27] = "out of memory",
    [28] = "request timed out",
    [35] = "TLS/SSL connection failed",
    [36] = "transfer was stopped",
    [37] = "failed to open local file",
    [47] = "too many redirects",
    [52] = "server returned an empty response",
    [55] = "failed sending network data",
    [56] = "failed receiving network data",
    [60] = "TLS certificate verification failed",
    [61] = "unsupported TLS/SSL feature",
    [67] = "authentication failed",
    [78] = "requested resource was not found",
    -- from the shell rather than from curl, when it can't run curl or can't find it
    [126] = "curl can't be run on this device",
    [127] = "curl isn't installed on this device",
}

local function ensureTmpDir()
    lfs.mkdir(TMP_DIR)
end

-- os.time() is in seconds, and downloads can start within the same second (a book's cover and the book itself),
-- so temporary files are numbered too, to keep each download's files its own
local tmp_files_created = 0
local function tmpFile(name, extension)
    ensureTmpDir()
    tmp_files_created = tmp_files_created + 1
    return string.format("%s%s_%d_%d%s", TMP_DIR, name, os.time(), tmp_files_created, extension)
end

-- remove the files left by downloads that were still running when KOReader last closed, which nothing else
-- would. only at the start of a session, while no downloads are using them
function CurlUtil.removeLeftovers()
    if lfs.attributes(TMP_DIR, "mode") ~= "directory" then
        return
    end

    local leftovers = {}
    for file in lfs.dir(TMP_DIR) do
        if file:find("^curl_download") then
            table.insert(leftovers, file)
        end
    end
    for _, file in ipairs(leftovers) do
        FileUtil.removeFile(TMP_DIR .. file)
    end
    if #leftovers > 0 then
        LogUtil.info("removed", #leftovers, "files left by earlier downloads")
    end
end

function CurlUtil.shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- where running processes are listed (changed by the tests)
CurlUtil.PROC_DIR = "/proc"

function CurlUtil.isPidRunning(pid)
    if not pid then
        return false
    end

    -- downloads are checked on twice a second, so look in /proc rather than starting a shell each time to ask kill
    local stat_file = io.open(string.format("%s/%d/stat", CurlUtil.PROC_DIR, pid), "r")
    if stat_file then
        local stat = stat_file:read("*l") or ""
        stat_file:close()
        -- a process that has finished, but hasn't been cleaned up yet, isn't running
        return stat:match(".*%)%s+(%a)") ~= "Z"
    end
    local self_stat = io.open(CurlUtil.PROC_DIR .. "/self/stat", "r")
    if self_stat then
        self_stat:close()
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

function CurlUtil.killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

-- how the installed curl describes itself, e.g. "curl 8.17.0 (arm-unknown-linux-musleabihf) libcurl/8.17.0
-- OpenSSL/3.5.4 zlib/1.3.1", or nil if curl isn't there
local function describeCurl()
    local pipe = io.popen("curl --version 2>/dev/null", "r")
    if not pipe then
        return nil
    end

    local output = pipe:read("*l")
    pipe:close()

    return output
end

-- the installed curl's version, e.g. "8.17.0", or nil if curl isn't there
function CurlUtil.getVersion()
    local description = describeCurl()
    -- "curl X.Y.Z (platform) ..."
    return description and description:match("^curl%s+([%d%.]+)")
end

-- whether curl can fetch web pages (see fetchCommand), and ask for them compressed. worked out once per session,
-- as it means running curl
local can_fetch, can_decompress
local function checkCurl()
    if can_fetch ~= nil then
        return
    end

    local description = describeCurl()
    local version = VersionUtil.parseVersion(description and description:match("^curl%s+([%d%.]+)"))
    -- on a Kindle, only once it has been updated, as the curl it comes with can't connect to Library Genesis
    can_fetch = version ~= nil
        and (
            not Device:isKindle()
            or VersionUtil.compareVersions(version, VersionUtil.parseVersion(CurlUtil.MIN_VERSION)) >= 0
        )
    can_decompress = description ~= nil and description:find("zlib", 1, true) ~= nil
    LogUtil.info(
        "fetching pages with",
        can_fetch and "curl" or "KOReader, as curl is missing or too old,",
        can_fetch and can_decompress and "compressed" or "uncompressed"
    )
end

function CurlUtil.canFetch()
    checkCurl()
    return can_fetch
end

function CurlUtil.getErrorMeaning(exit_code)
    return CURL_ERRORS[exit_code] or "(curl exit code " .. tostring(exit_code) .. ")"
end

-- the size of the file a site is sending, from the headers of its responses (one after another when redirected)
function CurlUtil.parseContentLength(headers)
    -- get content length from the last response that has one, i.e. the file's rather than a redirect's
    local file_size = nil
    for block in headers:gmatch("HTTP[/%d%.]+.-\r?\n\r?\n") do
        local size = block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if size then
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

-- how big the file being downloaded is, going by the headers curl has noted down, or nil if the site hasn't said.
-- they're complete by the time the file itself starts to arrive, so asking for the size separately first, and
-- waiting for the answer, isn't needed
function CurlUtil.getDownloadSize(headers_file)
    local f = io.open(headers_file, "r")
    if not f then
        return nil
    end
    local headers = f:read("*a")
    f:close()

    return CurlUtil.parseContentLength(headers or "")
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

function CurlUtil.getExitCode(exit_file)
    local exit_code_str = FileUtil.readFile(exit_file)
    if not exit_code_str then
        return nil -- file doesn't exist yet, process still running
    end
    FileUtil.removeFile(exit_file)
    return tonumber(exit_code_str)
end

function CurlUtil.getProxyFlag(use_proxy)
    local proxy_flag = ""
    if use_proxy then
        local proxy_url = os.getenv("PROXY_URL")
        if proxy_url and proxy_url ~= "" then
            proxy_flag = "-x " .. CurlUtil.shellQuote(proxy_url)
        end
    end

    return proxy_flag
end

function CurlUtil.spawnCurlPid(cmd)
    -- execute command
    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, "unable to launch curl"
    end

    -- read pid from terminal output
    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        return nil, "unable to determine curl pid"
    end

    return pid
end

function CurlUtil.getDownloadCMD(download_url, filepath)
    return string.format("curl -sL -f -o %s %s", CurlUtil.shellQuote(filepath), CurlUtil.shellQuote(download_url))
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
    return string.format("%s -e %s", curl_cmd, CurlUtil.shellQuote(site .. "/"))
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
    return string.format("%s -D %s", curl_cmd, CurlUtil.shellQuote(headers_file))
end

function CurlUtil.enableParallel(curl_cmd, max_parallel)
    return string.format("%s --parallel --parallel-max %d", curl_cmd, max_parallel)
end

function CurlUtil.applyProxy(curl_cmd)
    return string.format("%s %s", curl_cmd, CurlUtil.getProxyFlag(true))
end

-- a command that has curl fetch a web page into page_file, then print the HTTP status it ended with (000 when the
-- site didn't answer) and curl's own exit code, e.g. "200 0". unlike a download, a page with an error status is
-- kept, as what it says is of use. answer_timeout and page_timeout are how long, in seconds, the site can take to
-- answer and then to send the whole page
function CurlUtil.fetchCommand(url, page_file, use_proxy, answer_timeout, page_timeout)
    checkCurl()

    local cmd = string.format("curl -sL -o %s %s", CurlUtil.shellQuote(page_file), CurlUtil.shellQuote(url))
    if can_decompress then
        -- a page of search results is a tenth of the size compressed, and Library Genesis sends them slowly
        cmd = cmd .. " --compressed"
    end
    cmd = CurlUtil.pretendBrowser(cmd)
    cmd = CurlUtil.setReferer(cmd, url)
    cmd = string.format("%s --connect-timeout %d --max-time %d", cmd, answer_timeout, page_timeout)
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end

    return string.format('(%s -w %s; echo " $?") 2>/dev/null', cmd, CurlUtil.shellQuote("%{http_code}"))
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

function CurlUtil.saveExitCode(cmd, exit_file)
    -- save exit code to exit_file
    local command = string.format("(%s; echo $? > %s)", cmd, CurlUtil.shellQuote(exit_file))
    command = string.format("%s >/dev/null 2>&1", command) -- do not print errors to terminal

    return command
end

function CurlUtil.echoPid(cmd)
    return string.format("%s & echo $!", cmd)
end

function CurlUtil.getCMD(download_url, filepath, exit_file, use_proxy)
    local cmd = CurlUtil.getDownloadCMD(download_url, filepath)
    cmd = CurlUtil.enableRetry(cmd, 2, 2)
    cmd = CurlUtil.setTimeout(cmd, 15)
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    return cmd
end

-- max_time optionally limits how long each attempt (and retrying) can take, in seconds.
-- opts.headers_file optionally has curl note the headers it's sent down in that file (see getDownloadSize), and
-- opts.stall_time gives up on a download once nothing has arrived for that many seconds
function CurlUtil.download(download_url, filepath, use_proxy, background, max_time, opts)
    opts = opts or {}

    local cmd = CurlUtil.getDownloadCMD(download_url, filepath)
    cmd = CurlUtil.pretendBrowser(cmd)
    cmd = CurlUtil.setReferer(cmd, download_url)
    cmd = CurlUtil.enableRetry(cmd, 2, 2)
    cmd = CurlUtil.setTimeout(cmd, 15)
    if max_time then
        cmd = string.format("%s --max-time %d --retry-max-time %d", cmd, max_time, max_time)
    end
    if opts.headers_file then
        cmd = CurlUtil.dumpHeaders(cmd, opts.headers_file)
    end
    if opts.stall_time then
        cmd = CurlUtil.abortWhenStalled(cmd, opts.stall_time)
    end
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end

    local exit_file = CurlUtil.createExitFile()
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    LogUtil.debug("curl download command", cmd)

    if background then
        cmd = CurlUtil.echoPid(cmd)
        local pid, err = CurlUtil.spawnCurlPid(cmd, exit_file)
        if not pid or err then
            return nil, nil, err
        end

        return pid, exit_file
    end

    os.execute(cmd)

    local exit_code = CurlUtil.getExitCode(exit_file)
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
            return false, "download produced empty file"
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
        return false, CurlUtil.getErrorMeaning(exit_code)
    end
end

function CurlUtil.downloadMultiple(
    download_urls,
    filepaths,
    use_proxy,
    background,
    num_parallel_jobs,
    enable_retry,
    timeout
)
    ensureTmpDir()

    local config_file = tmpFile("curl_download_config", ".txt")
    local f = io.open(config_file, "w")

    -- backslashes and quotes mean something inside the quotes of curl's config file
    local function quote(value)
        return (value:gsub("\\", "\\\\"):gsub('"', '\\"'))
    end
    for i, download_url in ipairs(download_urls) do
        -- an address with a line break in it would add lines of its own to the config file, so leave it out
        if StringUtil.isSafeUrl(download_url) and not filepaths[i]:find("%c") then
            f:write(string.format('url = "%s"\n', quote(download_url)))
            f:write(string.format('output = "%s"\n', quote(filepaths[i])))
        else
            LogUtil.warn("left out a download whose address can't be used:", download_url)
        end
    end
    f:close()

    local results_file = CurlUtil.getResultsFile(config_file)
    local cmd = string.format('curl -sL -f --config "%s"', config_file)
    cmd = CurlUtil.pretendBrowser(cmd)
    -- covers for a page of search results all come from the same site
    cmd = CurlUtil.setReferer(cmd, download_urls[1])
    if enable_retry then
        cmd = CurlUtil.enableRetry(cmd, 2, 2)
    end
    cmd = CurlUtil.setTimeout(cmd, timeout)
    -- give up on files that stall, so they don't hold up the rest
    cmd = string.format("%s --max-time %d", cmd, timeout * 2)
    cmd = CurlUtil.enableParallel(cmd, num_parallel_jobs)
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end
    -- write each file's result, as some may download when others fail
    cmd = string.format(
        "%s -w %s > %s",
        cmd,
        CurlUtil.shellQuote("%{exitcode} %{filename_effective}\\n"),
        CurlUtil.shellQuote(results_file)
    )

    local exit_file = CurlUtil.createExitFile()
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    LogUtil.debug("curl parallel download command", cmd)

    if background then
        cmd = CurlUtil.echoPid(cmd)

        local pid, err = CurlUtil.spawnCurlPid(cmd)
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

    local exit_code = CurlUtil.getExitCode(exit_file)
    if exit_code ~= 0 then
        local reason = CurlUtil.getErrorMeaning(exit_code)
        LogUtil.warn("parallel download command failed", {
            exit_code = exit_code,
            reason = reason,
        })
        NotifyUtil.info("Download failed:" .. reason)
    end

    local results = CurlUtil.getTransferResults(results_file)
    local successful_count = 0
    for _, filepath in ipairs(filepaths) do
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
