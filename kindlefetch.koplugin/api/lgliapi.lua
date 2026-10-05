local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local ConfirmBox = require("ui/widget/confirmbox")
local LogUtil = require("util.logutil")
local DownloadProgress = require("ui.downloadprogress")
local DownloadPrompt = require("ui.downloadprompt")
local HttpUtil = require("util.httputil")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local UrlApi = require("api.urlapi")
local CoverCache = require("cache.covercache")
local _ = require("gettext")

local LlgiAPI = {}
LlgiAPI.active_downloads = {}

-- constants
local DOWNLOAD_POLL_INTERVAL = 0.5
-- a download that hasn't received anything for this many seconds is given up on, rather than waited on forever
local DOWNLOAD_STALL_TIME = 30
local BUSY_ERROR = "Library Genesis is too busy to send books right now, try again in a few minutes"

-- whether a mirror's download page says its database is refusing connections, as it does while it's very busy.
-- the mirrors share the database, so they all say so at once
local function isBusy(html)
    return html:find("Could not connect to the database", 1, true) ~= nil
        or html:find("max_user_connections", 1, true) ~= nil
end

-- part_path is where curl is downloading the book to, see _startDownload
local function pollDownload(
    book,
    part_path,
    pid,
    exit_file,
    headers_file,
    download_url,
    tried_proxy,
    total_size,
    progress_widget,
    current_pid,
    callback
)
    if progress_widget.cancelled then
        LogUtil.info(
            string.format("download of %q cancelled at %d bytes", book.title, FileUtil.getSize(part_path) or 0)
        )
        CurlUtil.killPid(pid)
        FileUtil.removeFile(part_path)
        callback(false, "cancelled")
        return
    end

    current_pid.pid = pid
    local bytes_downloaded = FileUtil.getSize(part_path)

    -- curl notes down the headers it's sent, which say how big the book is, before the book starts to arrive
    if not total_size and bytes_downloaded > 0 then
        total_size = CurlUtil.getDownloadSize(headers_file)
        if total_size then
            LogUtil.info("the file is", total_size, "bytes")
        end
    end

    -- cap at 99% while still in progress and under the total size
    if total_size and total_size > 0 and bytes_downloaded <= total_size then
        local percentage = math.min(bytes_downloaded / total_size, 0.99)
        progress_widget:update(
            percentage,
            string.format(
                "%d%% · %.1f / %.1f MB",
                math.floor(percentage * 100),
                bytes_downloaded / (1024 * 1024),
                total_size / (1024 * 1024)
            )
        )
    elseif bytes_downloaded > 0 then
        -- the size wasn't known, or was wrong
        progress_widget:update(
            progress_widget.percentage or 0,
            string.format("%.1f MB", bytes_downloaded / (1024 * 1024))
        )
    end

    LogUtil.debug("download progress", {
        title = book.title,
        md5 = book.md5,
        bytes_downloaded = bytes_downloaded,
        total_size = total_size,
    })

    -- check exit code, again if curl has stopped, as it may have finished between the two checks
    local exit_code = CurlUtil.getExitCode(exit_file)
    if not exit_code and not CurlUtil.isPidRunning(pid) then
        exit_code = CurlUtil.getExitCode(exit_file)
    end
    if exit_code then
        local final_size = FileUtil.getSize(part_path)

        -- check if completed successfully
        local download = LlgiAPI.active_downloads[book.md5]
        local seconds = download and download.started and os.time() - download.started or 0
        if exit_code == 0 and final_size and final_size > 0 then
            progress_widget:update(1, "100%")
            LogUtil.info(
                string.format(
                    "downloaded %q: %d bytes%s in %ds",
                    book.title,
                    final_size,
                    total_size and total_size ~= final_size and " (expected " .. total_size .. ")" or "",
                    seconds
                )
            )
            callback(true)
            return
        end

        LogUtil.warn(
            string.format(
                "download of %q from %s%s failed after %ds: curl exit code %d (%s), %d of %s bytes",
                book.title,
                LogUtil.site(download_url),
                tried_proxy and " through the proxy" or "",
                seconds,
                exit_code,
                exit_code == 0 and "empty file" or CurlUtil.getErrorMeaning(exit_code),
                final_size or 0,
                tostring(total_size or "unknown")
            )
        )

        -- use proxy as backup
        if not tried_proxy and os.getenv("PROXY_URL") and os.getenv("PROXY_URL") ~= "" then
            LogUtil.info("retrying the download through the proxy")
            local new_pid, new_exit_file, spawn_err = CurlUtil.download(download_url, part_path, true, true, nil, {
                headers_file = headers_file,
                stall_time = DOWNLOAD_STALL_TIME,
            })
            if not new_pid then
                LogUtil.warn("could not start curl to retry through the proxy:", spawn_err)
                FileUtil.removeFile(part_path)
                callback(false, spawn_err or "download failed and proxy retry could not start")
                return
            end
            UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
                pollDownload(
                    book,
                    part_path,
                    new_pid,
                    new_exit_file,
                    headers_file,
                    download_url,
                    true,
                    total_size,
                    progress_widget,
                    current_pid,
                    callback
                )
            end)
            return
        end

        FileUtil.removeFile(part_path)
        callback(false, exit_code == 0 and "download produced empty file" or CurlUtil.getErrorMeaning(exit_code))
        return
    end

    -- exit early if process ends abruptly
    if not CurlUtil.isPidRunning(pid) then
        LogUtil.warn(
            string.format(
                "curl stopped without reporting back while downloading %q, at %d bytes",
                book.title,
                bytes_downloaded or 0
            )
        )
        FileUtil.removeFile(part_path)
        callback(false, "download process ended unexpectedly")
        return
    end

    -- schedule download check
    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(
            book,
            part_path,
            pid,
            exit_file,
            headers_file,
            download_url,
            tried_proxy,
            total_size,
            progress_widget,
            current_pid,
            callback
        )
    end)
end

function LlgiAPI:_startDownload(book, filepath, callback, retrying)
    LogUtil.info(
        string.format(
            "downloading %q (%s, %s, md5 %s) to %s%s",
            book.title,
            tostring(book.file_type),
            tostring(book.file_size),
            tostring(book.md5),
            filepath,
            retrying and ", after looking up mirrors again" or ""
        )
    )

    -- store as table to force pass by reference (so cancel callback can access it)
    local current_pid = {
        pid = nil,
    }

    -- create and show progress widget immediately
    local progress_widget = DownloadProgress.new(book.display_title or book.title, function()
        if current_pid.pid then
            CurlUtil.killPid(current_pid.pid)
        end
    end)

    progress_widget:show()
    progress_widget:update(0, "Starting download...")
    UIManager:forceRePaint()

    -- the book is downloaded next to where it's wanted and moved there once it's all arrived, so that half a book
    -- is never left looking like a whole one, and a book being downloaded over is kept until then
    local part_path = filepath .. ".part"

    -- track this download
    LlgiAPI.active_downloads[book.md5] = {
        book = book,
        filepath = filepath,
        part_path = part_path,
        progress_widget = progress_widget,
        callback = callback,
        started = os.time(),
    }

    -- get urls from cache, or scrape them from wikipedia again when retrying
    local base_urls, urls_err, wikipedia_answered = UrlApi:getLibgenUrls(retrying)
    if not base_urls then
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil
        callback(
            false,
            urls_err and not wikipedia_answered and UrlApi.NO_CONNECTION_ERROR or "no Library Genesis urls available"
        )
        return
    end

    -- try each libgen url
    local download_url
    local last_err
    -- mirrors that didn't answer at all, which may be down, or the device may be offline
    local unanswered = {}
    local answered = false
    local mirror_failed = false
    local busy = false
    for _, url in ipairs(base_urls) do
        -- load ads page (to get key for download page)
        local ads_page = string.format("%s/ads.php?md5=%s", url, book.md5)
        local html, err, status = HttpUtil.getBody(ads_page)
        answered = answered or html ~= nil or status ~= nil

        -- find download url with key linked in ads page
        if html then
            local download_path = html:match('href="([^"]*get%.php[^"]*)"')

            if download_path and download_path ~= "" then
                download_url = url .. "/" .. download_path:gsub("^/", "")

                LogUtil.info("found the download link on", LogUtil.site(url))

                break
            else
                LogUtil.warn(
                    "no download link on",
                    LogUtil.site(url) .. "'s download page (" .. #html .. " bytes):",
                    html:gsub("<[^>]+>", " "):gsub("%s+", " "):sub(1, 200)
                )
                last_err = "no Library Genesis download link found"
                busy = busy or isBusy(html)
            end
        elseif status then
            -- it answered with an error
            last_err = err
            mirror_failed = true
            UrlApi:deleteLibgenUrl(url)
        else
            table.insert(unanswered, url)
            last_err = err
            mirror_failed = true
        end
    end

    -- the internet is working if another mirror answered, or the mirrors were just looked up, so the ones that didn't
    -- are down. otherwise the device may be offline, so keep them
    if answered or retrying then
        for _, url in ipairs(unanswered) do
            UrlApi:deleteLibgenUrl(url)
        end
    end

    if not download_url then
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil

        LogUtil.warn("no mirror gave a download link:", last_err)
        -- look the mirrors up again if any failed, in case they've moved, and try again
        if not retrying and mirror_failed then
            return LlgiAPI:_startDownload(book, filepath, callback, true)
        end

        callback(false, busy and BUSY_ERROR or last_err or "all Library Genesis mirrors failed")
        return
    end

    -- start background curl downloader, noting down the headers it's sent, which say how big the book is
    local headers_file = CurlUtil.createHeadersFile()
    local pid, exit_file, spawn_err = CurlUtil.download(download_url, part_path, false, true, nil, {
        headers_file = headers_file,
        stall_time = DOWNLOAD_STALL_TIME,
    })
    if not pid then
        LogUtil.warn("could not start curl to download:", spawn_err)
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil
        callback(false, spawn_err or "failed to spawn curl downloader")
        return
    end
    LlgiAPI.active_downloads[book.md5].headers_file = headers_file

    current_pid.pid = pid

    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(
            book,
            part_path,
            pid,
            exit_file,
            headers_file,
            download_url,
            false,
            nil,
            progress_widget,
            current_pid,
            function(ok, err)
                progress_widget:close()
                LlgiAPI.active_downloads[book.md5] = nil -- cleanup after download finishes
                FileUtil.removeFile(headers_file)
                if ok and not os.rename(part_path, filepath) then
                    LogUtil.warn("could not move the downloaded book from", part_path, "to", filepath)
                    FileUtil.removeFile(part_path)
                    ok, err = false, "could not save the book"
                end
                UIManager:forceRePaint()
                callback(ok, err, filepath)
            end
        )
    end)
end

-- open_existing is optionally called with the path of a book that's already there, when asked to read that one
-- rather than download over it
function LlgiAPI:downloadBook(book, filepath, callback, open_existing)
    callback = callback or function() end

    -- show the progress of a book that is already downloading, in case it was hidden
    if self:showDownload(book.md5) then
        return
    end

    -- get the book cover in the background, the prompt shows a placeholder until it arrives
    if book.image_url and not CoverCache:cacheExists(book.md5) then
        LogUtil.debug("downloading book cover", {
            title = book.title,
            md5 = book.md5,
        })
        CoverCache:downloadMultiple({ book }, 1)
    end

    -- show download prompt to let user choose folder and confirm
    local prompt = DownloadPrompt.new(book, filepath, function(confirmed_filepath)
        local function start()
            -- turning on wifi first if need be, as KOReader is set up to (it says so itself if it can't connect)
            NetworkMgr:runWhenConnected(function()
                self:_startDownload(book, confirmed_filepath, callback, false)
            end)
        end

        if not FileUtil.isValidFile(confirmed_filepath) then
            start()
            return
        end

        -- ask before downloading over a book that's already there, which may be another edition with the same
        -- title, as KOReader does for the books it downloads
        LogUtil.info("asking before downloading over", confirmed_filepath)
        UIManager:show(ConfirmBox:new {
            text = string.format(_("%s already exists."), confirmed_filepath),
            ok_text = _("Overwrite"),
            ok_callback = start,
            other_buttons = open_existing and {
                {
                    {
                        text = _("Read existing book"),
                        callback = function()
                            open_existing(confirmed_filepath)
                        end,
                    },
                },
            },
        })
    end)

    prompt:show()
end

-- show the progress of a download, if it was hidden. returns whether the book with that md5 is downloading
function LlgiAPI:showDownload(md5)
    local active_download = self.active_downloads[md5]
    if not active_download then
        return false
    end

    if not active_download.progress_widget.is_visible then
        active_download.progress_widget:toggleVisibility()
    end
    return true
end

-- the downloads in progress, in the order they were started
function LlgiAPI:getActiveDownloads()
    local downloads = {}
    for id, download_info in pairs(self.active_downloads) do
        table.insert(downloads, {
            id = id,
            title = download_info.book.display_title or download_info.book.title,
            filepath = download_info.filepath,
            md5 = download_info.book.md5,
            widget = download_info.progress_widget,
            started = download_info.started,
        })
    end
    table.sort(downloads, function(a, b)
        if a.started ~= b.started then
            return a.started < b.started
        end
        return a.title < b.title
    end)
    return downloads
end

function LlgiAPI:cancelAllDownloads()
    for id, download_info in pairs(self.active_downloads) do
        -- stops curl straight away, as there may not be another poll to stop it (e.g. when exiting)
        download_info.progress_widget:cancel()
        FileUtil.removeFile(download_info.part_path)
        FileUtil.removeFile(download_info.headers_file)
    end
    self.active_downloads = {}
end

return LlgiAPI
