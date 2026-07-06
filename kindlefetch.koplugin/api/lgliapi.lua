local util = require("util")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local DownloadProgress = require("ui.downloadprogress")
local HttpUtil = require("util.httputil")
local StringUtil = require("util.stringutil")
local _ = require("gettext")

local LlgiAPI = {}

LlgiAPI.base_url = "https://libgen.li"
LlgiAPI.download_poll_interval = 0.5

-- shell-escape a string for safe inclusion in a shell command
local function shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- return the size in bytes of the file at path, or 0 if it doesn't exist / can't be opened yet
local function fileSize(path)
    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local size = f:seek("end")
    f:close()
    return size or 0
end

-- read a small text file and returns its trimmed contents, or nil if the file doesn't exist yet
local function readFile(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content and StringUtil.trim(content) or nil
end

local function removeFile(path)
    if path then
        os.remove(path)
    end
end

local function getRemoteFileSize(url)
    local cmd = string.format("curl -s -L -I %s", shellQuote(url))

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil
    end

    local headers = pipe:read("*a")
    pipe:close()

    if not headers then
        return nil
    end

    -- get content length from first 200 response
    local file_size = nil
    for block in headers:gmatch("HTTP[/%d%.]+.-\r?\n\r?\n") do
        local size = block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if size then
            file_size = tonumber(size)
        end
    end

    return file_size
end

local function spawnCurlDownload(download_url, filepath, use_proxy)
    local exit_file = filepath .. ".exitcode"
    removeFile(exit_file)
    removeFile(filepath)

    local proxy_flag = ""
    if use_proxy then
        local proxy_url = os.getenv("PROXY_URL")
        if proxy_url and proxy_url ~= "" then
            proxy_flag = "-x " .. shellQuote(proxy_url) .. " "
        end
    end

    local cmd = string.format(
        "(curl -sL -f %s-A 'Mozilla/5.0' --retry 2 --retry-delay 2 --connect-timeout 15 -o %s %s; echo $? > %s) >/dev/null 2>&1 & echo $!",
        proxy_flag, shellQuote(filepath), shellQuote(download_url), shellQuote(exit_file))

    logger.info("KindleFetch: curl command", cmd)

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, nil, "unable to launch curl"
    end

    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        return nil, nil, "unable to determine curl pid"
    end

    return pid, exit_file
end

local function isPidRunning(pid)
    if not pid then
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

local function killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

local function pollDownload(book, filepath, pid, exit_file, download_url, tried_proxy, total_size, progress_widget,
    current_pid, callback)
    if progress_widget.cancelled then
        killPid(pid)
        removeFile(exit_file)
        removeFile(filepath)
        callback(false, "cancelled")
        return
    end

    current_pid.pid = pid
    local bytes_downloaded = fileSize(filepath)
    local kb = math.floor(bytes_downloaded / 1024)

    -- cap at 99% while still in progress and under the total size
    if total_size and total_size > 0 then
        local percentage = math.min(bytes_downloaded / total_size, 0.99)
        progress_widget:update(percentage,
            string.format("%d%% · %.1f / %.1f MB", math.floor(percentage * 100), bytes_downloaded / (1024 * 1024),
                total_size / (1024 * 1024)))
    end

    logger.dbg("KindleFetch: download progress", {
        title = book.title,
        md5 = book.md5,
        bytes_downloaded = bytes_downloaded,
        total_size = total_size
    })

    local exit_code_str = readFile(exit_file)

    if exit_code_str then
        removeFile(exit_file)
        local exit_code = tonumber(exit_code_str)
        local final_size = fileSize(filepath)

        -- check if completed successfully
        if exit_code == 0 and final_size > 0 then
            progress_widget:update(1, "100%")
            logger.info("KindleFetch: lgli download completed", {
                title = book.title,
                md5 = book.md5,
                filepath = filepath,
                bytes_downloaded = final_size
            })
            callback(true)
            return
        end

        -- download completed without reaching final size, has failed
        logger.warn("KindleFetch: curl attempt failed", {
            title = book.title,
            md5 = book.md5,
            exit_code = exit_code,
            final_size = final_size,
            tried_proxy = tried_proxy
        })

        -- use proxy as backup
        if not tried_proxy and os.getenv("PROXY_URL") and os.getenv("PROXY_URL") ~= "" then
            local new_pid, new_exit_file, spawn_err = spawnCurlDownload(download_url, filepath, true)
            if not new_pid then
                callback(false, spawn_err or "download failed and proxy retry could not start")
                return
            end
            UIManager:scheduleIn(LlgiAPI.download_poll_interval, function()
                pollDownload(book, filepath, new_pid, new_exit_file, download_url, true, total_size, progress_widget,
                    current_pid, callback)
            end)
            return
        end

        callback(false, "download failed (curl exit code " .. tostring(exit_code) .. ")")
        return
    end

    if not isPidRunning(pid) then
        callback(false, "download process ended unexpectedly")
        return
    end

    -- schedule download check
    UIManager:scheduleIn(LlgiAPI.download_poll_interval, function()
        pollDownload(book, filepath, pid, exit_file, download_url, tried_proxy, total_size, progress_widget,
            current_pid, callback)
    end)
end

function LlgiAPI:downloadBook(book, filepath, callback)
    callback = callback or function()
    end

    logger.dbg("KindleFetch: starting download", {
        title = book.title,
        md5 = book.md5,
        filepath = filepath
    })

    -- load ads page (to get key for download page)
    local ads_page = string.format("%s/ads.php?md5=%s", self.base_url, book.md5)
    logger.dbg("KindleFetch: fetching lgli ads page", ads_page)
    local html = HttpUtil.getBody(ads_page)
    if not html then
        logger.warn("KindleFetch: failed to fetch lgli ads page", book.md5)
        callback(false, "failed to fetch lgli page")
        return
    end

    -- find download url
    local download_path = html:match('href="([^"]*get%.php[^"]*)"')
    if not download_path or download_path == "" then
        logger.warn("KindleFetch: no lgli download link found", book.md5)
        callback(false, "no lgli download link")
        return
    end
    local download_url = self.base_url .. "/" .. download_path:gsub("^/", "")
    logger.dbg("KindleFetch: resolved lgli download url", {
        title = book.title,
        md5 = book.md5,
        download_url = download_url
    })

    -- get file size
    local total_size = getRemoteFileSize(download_url)
    if total_size then
        logger.info("KindleFetch: file size found", total_size)
    else
        logger.warn("KindleFetch: could not determine remote size")
    end

    -- create curl downloader
    local pid, exit_file, spawn_err = spawnCurlDownload(download_url, filepath, false)
    if not pid then
        callback(false, spawn_err or "failed to start download")
        return
    end
    local current_pid = {
        pid = pid
    }
    local progress_widget = DownloadProgress.new(book.title, function()
        killPid(current_pid.pid)
    end)
    progress_widget:show()

    -- schedule download check
    UIManager:scheduleIn(LlgiAPI.download_poll_interval, function()
        pollDownload(book, filepath, pid, exit_file, download_url, false, total_size, progress_widget, current_pid,
            function(ok, err)
                progress_widget:close()
                UIManager:forceRePaint()
                callback(ok, err)
            end)
    end)
end

return LlgiAPI
