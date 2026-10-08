local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
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

local function hasProxy()
    local proxy_url = os.getenv("PROXY_URL")
    return proxy_url ~= nil and proxy_url ~= ""
end

-- start curl downloading the book in the background, as transfer says (see _startDownload), returning whether it
-- started, and why not if it didn't
local function startCurl(transfer)
    local pid, exit_file, err =
        CurlUtil.download(transfer.download_url, transfer.part_path, transfer.tried_proxy, true, nil, {
            headers_file = transfer.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            -- so that curl carries on from where a download that stalled got to, rather than starting it again
            resume = transfer.resume,
        })
    if not pid then
        return false, err
    end
    transfer.pid, transfer.exit_file = pid, exit_file
    return true
end

-- check on curl downloading a book until it has finished, showing how far it has got. transfer is what's known
-- about the download (see _startDownload), and its on_finish is called with whether the book downloaded, and what
-- went wrong if it didn't
local function pollDownload(transfer)
    local book, part_path, progress_widget = transfer.book, transfer.part_path, transfer.progress_widget
    if progress_widget.cancelled then
        LogUtil.info(
            string.format("download of %q cancelled at %d bytes", book.title, FileUtil.getSize(part_path) or 0)
        )
        CurlUtil.killPid(transfer.pid)
        FileUtil.removeFile(part_path)
        transfer.on_finish(false, "cancelled")
        return
    end

    local bytes_downloaded = FileUtil.getSize(part_path)

    -- curl notes down the headers it's sent, which say how big the book is, before the book starts to arrive
    if not transfer.total_size and bytes_downloaded > 0 then
        transfer.total_size = CurlUtil.getDownloadSize(transfer.headers_file)
        if transfer.total_size then
            LogUtil.info("the file is", transfer.total_size, "bytes")
        end
    end
    local total_size = transfer.total_size

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
    local exit_code = CurlUtil.getExitCode(transfer.exit_file)
    if not exit_code and not CurlUtil.isPidRunning(transfer.pid) then
        exit_code = CurlUtil.getExitCode(transfer.exit_file)
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
            transfer.on_finish(true)
            return
        end

        -- the error the mirror answered with, when that's why curl gave up
        local http_status = exit_code == 22 and CurlUtil.getDownloadStatus(transfer.headers_file) or nil
        if http_status and http_status < 400 then
            http_status = nil
        end
        LogUtil.warn(
            string.format(
                "download of %q from %s%s failed after %ds: curl exit code %d (%s%s), %d of %s bytes",
                book.title,
                LogUtil.site(transfer.download_url),
                transfer.tried_proxy and " through the proxy" or "",
                seconds,
                exit_code,
                exit_code == 0 and "empty file" or CurlUtil.getErrorMeaning(exit_code),
                http_status and ", HTTP " .. http_status or "",
                final_size or 0,
                tostring(total_size or "unknown")
            )
        )

        -- try again, from the beginning if the site wouldn't carry on from where the download stopped, otherwise
        -- through the proxy as a backup (carrying on from there)
        local retry
        if exit_code == 33 and transfer.resume then
            retry = "downloading the book again from the beginning, as the site can't carry on from where it stopped"
            transfer.resume = false
            FileUtil.removeFile(part_path)
        elseif not transfer.tried_proxy and hasProxy() then
            retry = "retrying the download through the proxy"
            transfer.tried_proxy = true
        end
        if retry then
            LogUtil.info(retry)
            local started, spawn_err = startCurl(transfer)
            if not started then
                LogUtil.warn("could not start curl to try again:", spawn_err)
                FileUtil.removeFile(part_path)
                transfer.on_finish(false, spawn_err or "download failed and could not be tried again")
                return
            end
            UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
                pollDownload(transfer)
            end)
            return
        end

        FileUtil.removeFile(part_path)
        local err = exit_code == 0 and "download produced empty file" or CurlUtil.getErrorMeaning(exit_code)
        if http_status then
            -- its servers failing, as they do while very busy, rather than e.g. the book not being there
            err = http_status >= 500 and BUSY_ERROR or string.format("%s (HTTP %d)", err, http_status)
        end
        transfer.on_finish(false, err)
        return
    end

    -- exit early if process ends abruptly
    if not CurlUtil.isPidRunning(transfer.pid) then
        LogUtil.warn(
            string.format(
                "curl stopped without reporting back while downloading %q, at %d bytes",
                book.title,
                bytes_downloaded or 0
            )
        )
        FileUtil.removeFile(part_path)
        transfer.on_finish(false, "download process ended unexpectedly")
        return
    end

    -- schedule download check
    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(transfer)
    end)
end

-- the book's download link, from the first mirror whose download page has one, looked up on Wikipedia again
-- when retrying. otherwise nil, and why not (HttpUtil.CANCELLED when called off), and whether a mirror failed,
-- rather than not having the book
local function findDownloadLink(book, retrying)
    -- get urls from cache, or scrape them from wikipedia again when retrying
    local base_urls, urls_err, wikipedia_answered = UrlApi:getLibgenUrls(retrying)
    if not base_urls then
        if urls_err == HttpUtil.CANCELLED then
            return nil, urls_err
        end
        return nil,
            urls_err and not wikipedia_answered and UrlApi.NO_CONNECTION_ERROR or "no Library Genesis urls available"
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
        -- called off, which says nothing about the mirrors
        if err == HttpUtil.CANCELLED then
            return nil, err
        end
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

    if download_url then
        return download_url
    end
    return nil, busy and BUSY_ERROR or last_err or "all Library Genesis mirrors failed", mirror_failed
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

    -- what's known about the download, as it goes along (see pollDownload). the book is downloaded next to where
    -- it's wanted and moved there once it's all arrived, so that half a book is never left looking like a whole
    -- one, and a book being downloaded over is kept until then
    local transfer = {
        book = book,
        part_path = filepath .. ".part",
        tried_proxy = false,
        resume = true,
    }
    local part_path = transfer.part_path

    -- create and show progress widget immediately
    local progress_widget = DownloadProgress.new(book.display_title or book.title, function()
        if transfer.pid then
            CurlUtil.killPid(transfer.pid)
        end
    end)
    transfer.progress_widget = progress_widget

    progress_widget:show()
    progress_widget:update(0, "Starting download...")
    UIManager:forceRePaint()

    -- track this download
    LlgiAPI.active_downloads[book.md5] = {
        book = book,
        filepath = filepath,
        part_path = part_path,
        progress_widget = progress_widget,
        callback = callback,
        started = os.time(),
    }

    -- look the link up without holding KOReader up (where pages are fetched with curl, see HttpUtil), as it can
    -- mean trying several mirrors, and let Cancel call it off. an error is passed on, rather than left to Trapper,
    -- which would leave the progress showing
    HttpUtil.trap_widget = progress_widget
    local looked_up, download_url, lookup_err, mirror_failed = pcall(findDownloadLink, book, retrying)
    HttpUtil.trap_widget = nil
    progress_widget.dismiss_callback = nil
    if not looked_up then
        LogUtil.err("looking up the download link went wrong:", tostring(download_url))
        download_url, lookup_err, mirror_failed = nil, "something went wrong, see crash.log", false
    end

    if not download_url then
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil

        if lookup_err == HttpUtil.CANCELLED then
            LogUtil.info(string.format("download of %q cancelled while looking up its link", book.title))
            callback(false, "cancelled")
            return
        end
        LogUtil.warn("no mirror gave a download link:", lookup_err)
        -- look the mirrors up again if any failed, in case they've moved, and try again
        if not retrying and mirror_failed then
            return LlgiAPI:_startDownload(book, filepath, callback, true)
        end

        callback(false, lookup_err)
        return
    end
    transfer.download_url = download_url

    -- note down the headers curl is sent, which say how big the book is
    local headers_file = CurlUtil.createHeadersFile()
    transfer.headers_file = headers_file
    LlgiAPI.active_downloads[book.md5].headers_file = headers_file
    transfer.on_finish = function(ok, err)
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

    -- whatever is left of an earlier download of a book of the same name, e.g. one KOReader closed during, which
    -- could be another book entirely, so curl mustn't carry on from it
    FileUtil.removeFile(part_path)

    -- start background curl downloader
    local started, spawn_err = startCurl(transfer)
    if not started then
        LogUtil.warn("could not start curl to download:", spawn_err)
        FileUtil.removeFile(headers_file)
        progress_widget:close()
        LlgiAPI.active_downloads[book.md5] = nil
        callback(false, spawn_err or "failed to spawn curl downloader")
        return
    end

    UIManager:scheduleIn(DOWNLOAD_POLL_INTERVAL, function()
        pollDownload(transfer)
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
                -- so that looking up the download link doesn't hold KOReader up (see _startDownload)
                Trapper:wrap(function()
                    self:_startDownload(book, confirmed_filepath, callback, false)
                end)
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
