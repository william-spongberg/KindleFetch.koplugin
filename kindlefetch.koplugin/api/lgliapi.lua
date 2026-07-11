local util = require("util")
local UIManager = require("ui/uimanager")
local Notification = require("ui/widget/notification")
local logger = require("logger")
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
        FileUtil.removeFile(exit_file)
        FileUtil.removeFile(filepath)
        callback(false, "cancelled")
        return
    end

    current_pid.pid = pid
    local bytes_downloaded = FileUtil.getSize(filepath)
    local kb = math.floor(bytes_downloaded / 1024)

    -- cap at 99% while still in progress and under the total size
    if total_size and total_size > 0 then
        local percentage = math.min(bytes_downloaded / total_size, 0.99)
        progress_widget:update(percentage,
            string.format("%d%% · %.1f / %.1f MB", math.floor(percentage * 100), bytes_downloaded / (1024 * 1024),
                total_size / (1024 * 1024)))
    end

    logger.info("KindleFetch: download progress", {
        title = book.title,
        md5 = book.md5,
        bytes_downloaded = bytes_downloaded,
        total_size = total_size
    })

    -- check exit code
    local exit_code_str = FileUtil.readFile(exit_file)
    if exit_code_str then
        FileUtil.removeFile(exit_file)
        local exit_code = tonumber(exit_code_str)
        local final_size = FileUtil.getSize(filepath)

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
            local new_pid, new_exit_file, spawn_err = CurlUtil.spawnDownload(download_url, filepath, true)
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
        callback(false, "download failed (curl exit code " .. tostring(exit_code) .. ")")
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
    logger.info("KindleFetch: starting download", {
        title = book.title,
        md5 = book.md5,
        filepath = filepath
    })
    Notification:notify("Starting download...", Notification.SOURCE_ALWAYS_SHOW)

    -- get urls from cache or scrape from wikipedia
    local base_urls = UrlApi:getLibgenUrls()
    if not base_urls then
        callback(false, "no Libary Genesis urls available")
        return
    end

    -- try each libgen url
    local download_url
    local last_err
    for _, url in ipairs(base_urls) do
        logger.dbg("KindleFetch: trying libgen url", url)

        -- load ads page (to get key for download page)
        local ads_page = string.format("%s/ads.php?md5=%s", url, book.md5)
        logger.dbg("KindleFetch: fetching libgen ads page", ads_page)
        local html, err = HttpUtil.getBody(ads_page)

        -- find download url with key linked in ads page
        if html then
            local download_path = html:match('href="([^"]*get%.php[^"]*)"')

            if download_path and download_path ~= "" then
                download_url = url .. "/" .. download_path:gsub("^/", "")

                logger.dbg("KindleFetch: resolved libgen download url", {
                    title = book.title,
                    md5 = book.md5,
                    download_url = download_url
                })

                break
            else
                logger.warn("KindleFetch: no libgen download link found on url", url)
                last_err = "no Library Genesis download link found"
            end
        else
            logger.warn("KindleFetch: failed to fetch libgen ads page", {
                url = url,
                error = err
            })
            last_err = err

            -- invalidate the url cache
            UrlCache:clear()
        end
    end

    if not download_url then
        -- scrape new urls since all current have failed, and search again
        if not retrying then
            LlgiAPI:_startDownload(book, filepath, callback, true)
        end

        callback(false, last_err or "all Library Genesis mirrors failed")
        return
    end

    -- get file size
    Notification:notify("Checking file size...", Notification.SOURCE_ALWAYS_SHOW)
    local total_size = CurlUtil.getRemoteFileSize(download_url)
    if total_size then
        logger.info("KindleFetch: file size found", total_size)
    else
        logger.warn("KindleFetch: could not determine remote size")
    end

    -- create curl downloader
    local pid, exit_file, spawn_err = CurlUtil.spawnDownload(download_url, filepath, false)
    if not pid then
        callback(false, spawn_err or "failed to spawn curl downloader")
        return
    end

    -- store as table to force pass by reference
    local current_pid = {
        pid = pid
    }

    -- create download widget
    local progress_widget = DownloadProgress.new(book.title, function()
        CurlUtil.killPid(current_pid.pid)
    end)
    progress_widget:show()

    -- track this download
    LlgiAPI.active_downloads[book.md5] = {
        book = book,
        filepath = filepath,
        progress_widget = progress_widget,
        callback = callback
    }

    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(book, filepath, pid, exit_file, download_url, false, total_size, progress_widget, current_pid,
            function(ok, err)
                progress_widget:close()
                LlgiAPI.active_downloads[book.md5] = nil -- cleanup after download finishes
                UIManager:forceRePaint()
                callback(ok, err)
            end)
    end)
end

function LlgiAPI:downloadBook(book, filepath, callback)
    callback = callback or function()
    end

    if LlgiAPI.active_downloads[book.md5] then
        callback(false, "this book is already downloading")
        return
    end

    -- download book image
    self:downloadBookImage(book)

    -- show download prompt to let user choose folder and confirm
    local prompt = DownloadPrompt.new(book, filepath, function(confirmed_filepath)
        self:_startDownload(book, confirmed_filepath, callback, false)
    end)

    prompt:show()
end

function LlgiAPI:downloadBookImage(book)
    if book.image_path then
        logger.info("KindleFetch: book image already downloaded", {
            title = book.title,
            md5 = book.md5,
            image_url = book.image_url,
            image = book.image_path
        })
        return
    end

    if not book.image_url then
        logger.warn("KindleFetch: no image url available", {
            title = book.title,
            md5 = book.md5,
            image_url = book.image_url
        })
        return
    end

    -- check cache
    local tmp_path = CoverCache:get(book.md5)
    if tmp_path then
        book.image_path = tmp_path
    end

    -- fetch image data
    logger.info("KindleFetch: downloading book image", {
        title = book.title,
        md5 = book.md5,
        image_url = book.image_url
    })
    Notification:notify("Getting book cover...", Notification.SOURCE_ALWAYS_SHOW)
    local image_data, err = HttpUtil.getBody(book.image_url)
    if not image_data then
        logger.warn("KindleFetch: failed to download book image", {
            title = book.title,
            md5 = book.md5,
            error = err
        })
        return
    end
    logger.info("KindleFetch: book image downloaded successfully", {
        title = book.title,
        md5 = book.md5,
        url = book.image_url,
        size = #image_data
    })

    -- save to cache and update path
    CoverCache:set(book.md5, image_data)
    book.image_path = CoverCache:getPath(book.md5)
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
        download_info.progress_widget.cancelled = true
        download_info.progress_widget:close()
        FileUtil.removeFile(download_info.filepath)
    end
    self.active_downloads = {}
end

return LlgiAPI
