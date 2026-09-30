local util = require("util")
local UIManager = require("ui/uimanager")
local LogUtil = require("util.logutil")
local DownloadProgress = require("ui.downloadprogress")
local DownloadPrompt = require("ui.downloadprompt")
local HttpUtil = require("util.httputil")
local StringUtil = require("util.stringutil")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local UrlApi = require("api.urlapi")
local UrlCache = require("cache.urlcache")
local CoverCache = require("cache.covercache")
local _ = require("gettext")

local LlgiAPI = {}
LlgiAPI.active_downloads = {}

-- constants
local DOWNLOAD_POLL_INTERVAL = 0.5

local function pollDownload(book, filepath, pid, exit_file, download_url, tried_proxy, total_size, progress_widget,
    current_pid, callback)
    if progress_widget.cancelled then
        CurlUtil.killPid(pid)
        FileUtil.removeFile(filepath)
        callback(false, "cancelled")
        return
    end

    current_pid.pid = pid
    local bytes_downloaded = FileUtil.getSize(filepath)

    -- cap at 99% while still in progress and under the total size
    if total_size and total_size > 0 and bytes_downloaded <= total_size then
        local percentage = math.min(bytes_downloaded / total_size, 0.99)
        progress_widget:update(percentage,
            string.format("%d%% · %.1f / %.1f MB", math.floor(percentage * 100), bytes_downloaded / (1024 * 1024),
                total_size / (1024 * 1024)))
    elseif bytes_downloaded > 0 then
        -- the size wasn't known, or was wrong
        progress_widget:update(progress_widget.percentage or 0,
            string.format("%.1f MB", bytes_downloaded / (1024 * 1024)))
    end

    LogUtil.debug("download progress", {
        title = book.title,
        md5 = book.md5,
        bytes_downloaded = bytes_downloaded,
        total_size = total_size
    })

    -- check exit code, again if curl has stopped, as it may have finished between the two checks
    local exit_code = CurlUtil.getExitCode(exit_file)
    if not exit_code and not CurlUtil.isPidRunning(pid) then
        exit_code = CurlUtil.getExitCode(exit_file)
    end
    if exit_code then
        local final_size = FileUtil.getSize(filepath)

        -- check if completed successfully
        if exit_code == 0 and final_size and final_size > 0 then
            progress_widget:update(1, "100%")
            LogUtil.debug("lgli download completed", {
                title = book.title,
                md5 = book.md5,
                filepath = filepath,
                bytes_downloaded = final_size
            })
            callback(true)
            return
        end

        -- download completed without reaching final size, has failed
        LogUtil.warn("curl attempt failed", {
            title = book.title,
            md5 = book.md5,
            exit_code = exit_code,
            final_size = final_size,
            tried_proxy = tried_proxy
        })

        -- use proxy as backup
        if not tried_proxy and os.getenv("PROXY_URL") and os.getenv("PROXY_URL") ~= "" then
            local new_pid, new_exit_file, spawn_err = CurlUtil.download(download_url, filepath, true, true)
            if not new_pid then
                FileUtil.removeFile(filepath)
                callback(false, spawn_err or "download failed and proxy retry could not start")
                return
            end
            UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
                pollDownload(book, filepath, new_pid, new_exit_file, download_url, true, total_size, progress_widget,
                    current_pid, callback)
            end)
            return
        end

        FileUtil.removeFile(filepath)
        callback(false, exit_code == 0 and "download produced empty file" or CurlUtil.getErrorMeaning(exit_code))
        return
    end

    -- exit early if process ends abruptly
    if not CurlUtil.isPidRunning(pid) then
        FileUtil.removeFile(filepath)
        callback(false, "download process ended unexpectedly")
        return
    end

    -- schedule download check
    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(book, filepath, pid, exit_file, download_url, tried_proxy, total_size, progress_widget,
            current_pid, callback)
    end)
end

function LlgiAPI:_startDownload(book, filepath, callback, retrying)
    LogUtil.debug("starting download", {
        title = book.title,
        md5 = book.md5,
        filepath = filepath
    })

    -- store as table to force pass by reference (so cancel callback can access it)
    local current_pid = {
        pid = nil
    }

    -- create and show progress widget immediately
    local progress_widget = DownloadProgress.new(book.title, function()
        if current_pid.pid then
            CurlUtil.killPid(current_pid.pid)
        end
    end)

    progress_widget:show()
    progress_widget:update(0, "Starting download...")
    UIManager:forceRePaint()

    -- track this download
    LlgiAPI.active_downloads[book.md5] = {
        book = book,
        filepath = filepath,
        progress_widget = progress_widget,
        callback = callback
    }

    -- get urls from cache or scrape from wikipedia
    local base_urls = UrlApi:getLibgenUrls()
    if not base_urls then
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil
        callback(false, "no Library Genesis urls available")
        return
    end

    -- try each libgen url
    local download_url
    local last_err
    for _, url in ipairs(base_urls) do
        LogUtil.debug("trying libgen url", url)

        -- load ads page (to get key for download page)
        local ads_page = string.format("%s/ads.php?md5=%s", url, book.md5)
        local html, err = HttpUtil.getBody(ads_page)

        -- find download url with key linked in ads page
        if html then
            local download_path = html:match('href="([^"]*get%.php[^"]*)"')

            if download_path and download_path ~= "" then
                download_url = url .. "/" .. download_path:gsub("^/", "")

                LogUtil.debug("resolved libgen download url", {
                    title = book.title,
                    md5 = book.md5,
                    download_url = download_url
                })

                break
            else
                LogUtil.warn("no libgen download link found on url")
                last_err = "no Library Genesis download link found"
            end
        else
            LogUtil.warn("failed to fetch libgen ads page", {
                url = url,
                error = err
            })
            last_err = err

            -- delete from url cache
            UrlApi:deleteLibgenUrl(url)
        end
    end

    if not download_url then
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil

        -- scrape new urls since all current have failed, and search again
        if not retrying then
            return LlgiAPI:_startDownload(book, filepath, callback, true)
        end

        callback(false, last_err or "all Library Genesis mirrors failed")
        return
    end

    -- get file size
    progress_widget:update(0, "Checking file size...")
    UIManager:forceRePaint()
    local total_size = CurlUtil.getRemoteFileSize(download_url)
    if total_size then
        LogUtil.debug("file size found", total_size)
    else
        LogUtil.warn("could not determine remote size")
    end

    -- start background curl downloader
    local pid, exit_file, spawn_err = CurlUtil.download(download_url, filepath, false, true)
    if not pid then
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil
        callback(false, spawn_err or "failed to spawn curl downloader")
        return
    end

    current_pid.pid = pid

    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(book, filepath, pid, exit_file, download_url, false, total_size, progress_widget, current_pid,
            function(ok, err)
                progress_widget:close()
                LlgiAPI.active_downloads[book.md5] = nil -- cleanup after download finishes
                UIManager:forceRePaint()
                callback(ok, err, filepath)
            end)
    end)
end

function LlgiAPI:downloadBook(book, filepath, callback)
    callback = callback or function()
    end

    -- show the progress of a book that is already downloading, in case it was hidden
    local active_download = LlgiAPI.active_downloads[book.md5]
    if active_download then
        if not active_download.progress_widget.is_visible then
            active_download.progress_widget:toggleVisibility()
        end
        return
    end

    -- get the book cover in the background, the prompt shows a placeholder until it arrives
    if book.image_url and not CoverCache:cacheExists(book.md5) then
        LogUtil.debug("downloading book cover", {
            title = book.title,
            md5 = book.md5
        })
        CoverCache:downloadMultiple({book}, 1)
    end

    -- show download prompt to let user choose folder and confirm
    local prompt = DownloadPrompt.new(book, filepath, function(confirmed_filepath)
        self:_startDownload(book, confirmed_filepath, callback, false)
    end)

    prompt:show()
end

function LlgiAPI:getActiveDownloads()
    local downloads = {}
    for id, download_info in pairs(self.active_downloads) do
        table.insert(downloads, {
            id = id,
            title = download_info.book.title,
            filepath = download_info.filepath,
            md5 = download_info.book.md5,
            widget = download_info.progress_widget
        })
    end
    return downloads
end

function LlgiAPI:cancelAllDownloads()
    for id, download_info in pairs(self.active_downloads) do
        -- stops curl straight away, as there may not be another poll to stop it (e.g. when exiting)
        download_info.progress_widget:cancel()
        FileUtil.removeFile(download_info.filepath)
    end
    self.active_downloads = {}
end

return LlgiAPI
