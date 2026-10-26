local ffiutil = require("ffi/util")
local http = require("socket.http")
local socketutil = require("socketutil")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local Guard = require("util.guard")
local LibrarySites = require("util.librarysites")
local HttpLogin = require("util.httplogin")
local _ = require("gettext")

-- downloads with KOReader's own HTTP, where curl can't (see CurlUtil.canFetch): a device without curl, such as a Kobo
-- (#63), or a Kindle whose own is too old. each runs in a process of its own, so KOReader isn't held up, and is
-- followed and stopped as curl's are (see CurlUtil.isPidRunning and killPid): it writes what arrives to its file as it
-- arrives, notes down the headers it was sent as curl does (see CurlUtil.getDownloadSize and getDownloadStatus), and
-- saves the exit code curl would have, so that what checks on curl's downloads checks on these just the same
local HttpDownload = {}

-- how often a process that has finished is looked for again, to collect it (see collect)
local COLLECT_INTERVAL = 1

-- the exit code curl would have given up with for what KOReader's HTTP said went wrong (what it is is logged where
-- it's found out, in case curl has no words of its own for it)
local function exitCode(err)
    return CurlUtil.exitCodeFor(err) or 56
end

-- download url to path, in the process downloading it, returning the exit code curl would have. the headers it was
-- sent are noted down in headers_file, as curl does with -D (see CurlUtil.getDownloadStatus), where given
local function download(url, path, opts)
    local file, open_err = io.open(path, "wb")
    if not file then
        LogUtil.warn("could not write", path, "to download to:", open_err)
        return 23
    end
    -- giving up once nothing has arrived for stall_time, but however long it all takes, as a book can be large
    socketutil:set_timeout(opts.stall_time or 30, opts.max_time or -1)
    local site = url:match("^(https?://[^/]+)")
    local request_headers = {
        ["User-Agent"] = "Mozilla/5.0",
        -- as curl sends it, as Library Genesis sends empty covers without one
        ["Referer"] = site and site .. "/",
    }
    local requested, ok, code, headers, status_line
    if LibrarySites.isLibrary(url) then
        -- logging in to it where it asks to (see HttpLogin), into the file afresh each time it's asked, as what it
        -- says when asked without the login isn't the book
        local sinks = 0
        requested = true
        ok, code, headers, status_line = HttpLogin.request(url, request_headers, function()
            sinks = sinks + 1
            if sinks > 1 then
                if io.type(file) == "file" then
                    file:close()
                end
                file = io.open(path, "wb")
            end
            return socketutil.file_sink(file)
        end)
    else
        requested, ok, code, headers, status_line = pcall(http.request, {
            url = url,
            headers = request_headers,
            sink = socketutil.file_sink(file),
            redirect = true,
            proxy = opts.proxy,
        })
    end
    socketutil:reset_timeout()
    if io.type(file) == "file" then
        file:close()
    end

    if not requested or not ok then
        local err = requested and code or ok
        LogUtil.warn("KOReader's HTTP couldn't download from", LogUtil.site(url) .. ":", tostring(err))
        return exitCode(err)
    end
    if opts.headers_file then
        local length = type(headers) == "table" and headers["content-length"]
        FileUtil.writeFile(
            opts.headers_file,
            string.format(
                "%s\r\n%s\r\n",
                type(status_line) == "string" and status_line or "HTTP/1.1 " .. tostring(code),
                length and "content-length: " .. length .. "\r\n" or ""
            )
        )
    end
    -- what curl -f gives up with for an error
    if type(code) ~= "number" or code >= 400 then
        return 22
    end
    return 0
end

-- run fn in a process of its own (see ffiutil.runInSubProcess), returning its pid, or nil and why not. it's given
-- the file to save its exit code to, which it returns, and which is saved even when something goes wrong in it
local function start(fn)
    local exit_file = CurlUtil.createExitFile()
    local pid, err = ffiutil.runInSubProcess(function()
        local ok, exit_code = pcall(fn, exit_file)
        if not ok then
            LogUtil.err("downloading with KOReader's HTTP went wrong:", tostring(exit_code))
            exit_code = 1
        end
        FileUtil.writeFile(exit_file, tostring(exit_code) .. "\n")
    end)
    if not pid then
        LogUtil.warn("could not start a process to download with KOReader's HTTP:", tostring(err))
        return nil, _("could not start downloading")
    end
    return pid, exit_file
end

-- download url to filepath in the background, as CurlUtil.startDownload does (opts.headers_file, opts.stall_time and
-- opts.max_time as its, and opts.proxy the proxy to go through, if any), from the beginning, as KOReader's HTTP can't
-- carry on from what's there. returns the pid and the file its exit code is saved in, or nil and why not
function HttpDownload.start(download_url, filepath, opts)
    opts = opts or {}
    LogUtil.debug("KOReader's HTTP downloading from", LogUtil.site(download_url), "to", filepath)
    return start(function()
        return download(download_url, filepath, opts)
    end)
end

-- download each url to the filepath at the same place in filepaths in the background, one after another, as
-- CurlUtil.downloadMultiple does: returning the pid, the file the exit code is saved in, and a file whose results
-- file (see CurlUtil.getResultsFile) has each one's exit code as it finishes, or nil, nil, nil and why not
function HttpDownload.startMultiple(download_urls, filepaths, opts)
    opts = opts or {}
    local config_file = CurlUtil.createExitFile() .. ".config"
    local results_file = CurlUtil.getResultsFile(config_file)
    local pid, exit_file = start(function()
        local last_failure = 0
        for i, download_url in ipairs(download_urls) do
            local exit_code = download(download_url, filepaths[i], opts)
            if exit_code ~= 0 then
                last_failure = exit_code
                FileUtil.removeFile(filepaths[i])
            end
            local f = io.open(results_file, "a")
            if f then
                f:write(string.format("%d %s\n", exit_code, filepaths[i]))
                f:close()
            end
        end
        return last_failure
    end)
    if not pid then
        return nil, nil, nil, exit_file
    end
    return pid, exit_file, config_file
end

-- collect a download's process once it has finished or been stopped, which KOReader would otherwise keep as a zombie
-- until it closes. a curl download's process isn't KOReader's own to collect, which is said to be done straight away
function HttpDownload.collect(pid)
    if not pid or ffiutil.isSubProcessDone(pid) then
        return
    end
    Guard.scheduleIn(COLLECT_INTERVAL, "collecting a download's process", function()
        HttpDownload.collect(pid)
    end, Guard.quiet)
end

return HttpDownload
