local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local PluginShare = require("pluginshare")
local ConfirmBox = require("ui/widget/confirmbox")
local LogUtil = require("util.logutil")
local DownloadProgress = require("ui.downloadprogress")
local DownloadPrompt = require("ui.downloadprompt")
local Transfer = require("api.transfer")
local BackgroundTask = require("ui.backgroundtask")
local HttpUtil = require("util.httputil")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local Sites = require("api.sites")
local CoverCache = require("cache.covercache")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- downloads books from the site they were found on (see Sites), in the background
local Downloader = {}
Downloader.active_downloads = {}
-- how many downloads have been started this session, to list them in the order they were (see getActiveDownloads)
local downloads_started = 0

-- keep the device from sleeping while books download, as that turns Wi-Fi off; each is put back unless changed since
local awake
local function keepAwake()
    if awake then
        return
    end
    awake = { pause_auto_suspend = PluginShare.pause_auto_suspend }
    if UIManager.preventStandby then
        UIManager:preventStandby()
    end
    PluginShare.pause_auto_suspend = true
    if Device:isKindle() and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 1")
        awake.screensaver_prevented = true
    end
    LogUtil.info("keeping the device awake while books download")
end
local function allowSleep()
    if not awake then
        return
    end
    if UIManager.allowStandby then
        UIManager:allowStandby()
    end
    if PluginShare.pause_auto_suspend == true then
        PluginShare.pause_auto_suspend = awake.pause_auto_suspend
    end
    if awake.screensaver_prevented and not PluginShare.keepalive then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
    awake = nil
    LogUtil.info("letting the device sleep again, as no books are downloading")
end

-- follow a download from when it's started (see active_downloads), keeping the device awake while there are any
function Downloader:track(id, download)
    downloads_started = downloads_started + 1
    download.order = downloads_started
    self.active_downloads[id] = download
    keepAwake()
end

-- stop following a download once it's over, letting the device sleep again once none are left
function Downloader:untrack(id)
    self.active_downloads[id] = nil
    if next(self.active_downloads) == nil then
        allowSleep()
    end
end

-- failed_url is the link that failed, when asking for another (see Transfer.relink), and hidden keeps a retry hidden
function Downloader:_startDownload(book, filepath, callback, retrying, failed_url, hidden)
    local site = Sites[book.source]
    LogUtil.info(
        string.format(
            "downloading %q (%s, %s, id %s) to %s%s",
            book.title,
            tostring(book.file_type),
            tostring(book.file_size),
            tostring(book.id),
            filepath,
            retrying and ", after looking its link up again" or ""
        )
    )

    -- create and show progress widget immediately
    local transfer
    local progress_widget = DownloadProgress.new(book.display_title or book.title, function()
        if transfer.pid then
            CurlUtil.killPid(transfer.pid)
        end
    end, hidden)
    transfer = Transfer.new {
        book = book,
        site = site,
        filepath = filepath,
        progress_widget = progress_widget,
        callback = callback,
        on_over = function()
            Downloader:untrack(book.id)
        end,
    }

    progress_widget:show()
    -- which can mean trying several of the site's mirrors
    progress_widget:update(0, _("Finding a download link..."))
    UIManager:forceRePaint()
    Downloader:track(book.id, transfer)

    -- look the link up without blocking where it can, so Cancel works; else Cancel's off, as taps would arrive late
    local can_cancel = HttpUtil.canCancel()
    if not can_cancel then
        progress_widget:setCancellable(false)
        UIManager:forceRePaint()
    end
    HttpUtil.setTrapWidget(progress_widget)
    local looked_up, download_url, lookup_err, mirror_failed, listed =
        Guard.pcall("looking up the download link", site.findDownloadLink, site, book, retrying, failed_url)
    HttpUtil.setTrapWidget(nil)
    progress_widget.dismiss_callback = nil
    if not can_cancel then
        progress_widget:setCancellable(true)
    end
    if not looked_up then
        download_url, lookup_err, mirror_failed, listed = nil, Errors.UNEXPECTED, false, nil
    end

    if not download_url then
        transfer:close(Transfer.FAILED)

        if lookup_err == HttpUtil.CANCELLED then
            LogUtil.info(string.format("download of %q cancelled while looking up its link", book.title))
            callback(false, Errors.CANCELLED)
            return
        end
        LogUtil.warn("found no download link:", lookup_err)
        -- look the mirrors up again if any failed, in case they've moved, and try again
        if not retrying and mirror_failed then
            return Downloader:_startDownload(book, filepath, callback, true, nil, not progress_widget.is_visible)
        end

        callback(false, lookup_err)
        return
    end

    -- the site's links each go to one of its servers, so ask for another link once rather than fail with that server
    if site.NEW_LINK_WHEN_SERVER_FAILS and not retrying then
        transfer.on_relink = function(link, still_hidden)
            self:_startDownloadInBackground(book, filepath, callback, true, link, still_hidden)
        end
    end
    transfer:download(download_url, listed)
end

-- start the download without holding KOReader up while its link is looked up, saying so if it goes wrong (see Guard)
function Downloader:_startDownloadInBackground(book, filepath, callback, retrying, failed_url, hidden)
    BackgroundTask.run(
        "starting the download of " .. tostring(book.title),
        nil,
        function()
            self:_startDownload(book, filepath, callback, retrying, failed_url, hidden)
        end,
        nil,
        function(err)
            local transfer = Downloader.active_downloads[book.id]
            if transfer then
                transfer:abandon(err)
                return
            end
            callback(false, err)
        end
    )
end

-- why a book can't download to filepath, or nil: its folder is gone or read-only, or another shares its .part file
function Downloader:cantDownloadTo(filepath)
    local folder, name = filepath:match("^(.*)/([^/]*)$")
    folder = folder ~= "" and folder or "/"
    local ok, err = FileUtil.checkWritableDir(folder)
    if not ok then
        LogUtil.warn("can't download to", folder, "as", err)
        return T(_("books can't be saved in %1, as %2, so choose another folder"), folder, err)
    end
    local taken = false
    for __, download in pairs(self.active_downloads) do
        taken = taken or download.filepath == filepath
    end
    if taken then
        LogUtil.warn("another book is already downloading to", filepath)
        return T(
            _("another book is already downloading as %1, so wait for it to finish, or choose another folder"),
            name
        )
    end
end

-- open_existing, if given, is called with the path of a book already there, to read it rather than download over it
function Downloader:downloadBook(book, filepath, callback, open_existing)
    callback = callback or function() end

    -- show the progress of a book that is already downloading, in case it was hidden
    if self:showDownload(book.id) then
        return
    end

    -- get the book cover in the background, the prompt shows a placeholder until it arrives
    if book.image_url and not CoverCache:cacheExists(book.id) then
        LogUtil.debug("downloading book cover", {
            title = book.title,
            id = book.id,
        })
        CoverCache:downloadMultiple({ book }, 1)
    end

    -- show download prompt to let user choose folder and confirm
    local prompt = DownloadPrompt.new(book, filepath, function(confirmed_filepath)
        local function start()
            -- before the link is looked up, which can count as one of the few downloads Z-Library allows a day
            local err = self:cantDownloadTo(confirmed_filepath)
            if err then
                callback(false, err)
                return
            end
            -- turning on wifi first if need be, as KOReader is set up to (it says so itself if it can't connect)
            NetworkMgr:runWhenConnected(function()
                self:_startDownloadInBackground(book, confirmed_filepath, callback, false)
            end)
        end

        if not FileUtil.isValidFile(confirmed_filepath) then
            start()
            return
        end

        -- ask before downloading over a book that's there (maybe another edition of the same title), as KOReader does
        LogUtil.info("asking before downloading over", confirmed_filepath)
        UIManager:show(ConfirmBox:new {
            text = T(_("%1 already exists."), confirmed_filepath),
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

-- each download whose book has started to download, whose curl can be stopped and started again
local function eachTransfer(active_downloads, fn)
    for __, transfer in pairs(active_downloads) do
        if transfer.download_url then
            fn(transfer)
        end
    end
end

-- the device is going to sleep, turning Wi-Fi off, so pause each download (sent via main.lua, as are those below)
function Downloader:onSuspend()
    eachTransfer(self.active_downloads, function(transfer)
        transfer.sleeping = true
        transfer:pause("the device is going to sleep")
    end)
end

-- carry on with each download once the device is awake, as soon as it's connected again (see Transfer.poll)
function Downloader:onResume()
    eachTransfer(self.active_downloads, function(transfer)
        transfer.sleeping = nil
        if transfer.state == Transfer.PAUSED and NetworkMgr:isConnected() then
            transfer:resume()
        end
    end)
end

function Downloader:onNetworkDisconnected()
    eachTransfer(self.active_downloads, function(transfer)
        transfer:pause("Wi-Fi went off")
    end)
end

function Downloader:onNetworkConnected()
    eachTransfer(self.active_downloads, function(transfer)
        if transfer.state == Transfer.PAUSED and not transfer.sleeping then
            transfer:resume()
        end
    end)
end

-- show the progress of a download, if it was hidden. returns whether the book with that id is downloading
function Downloader:showDownload(id)
    local active_download = self.active_downloads[id]
    if not active_download then
        return false
    end

    if not active_download.progress_widget.is_visible then
        active_download.progress_widget:toggleVisibility()
    end
    return true
end

-- the downloads in progress, in the order they were started
function Downloader:getActiveDownloads()
    local downloads = {}
    for id, download_info in pairs(self.active_downloads) do
        table.insert(downloads, {
            id = id,
            title = download_info.book.display_title or download_info.book.title,
            filepath = download_info.filepath,
            widget = download_info.progress_widget,
            order = download_info.order or 0,
        })
    end
    table.sort(downloads, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.title < b.title
    end)
    return downloads
end

function Downloader:cancelAllDownloads()
    for id, download_info in pairs(self.active_downloads) do
        -- stops curl straight away, as there may not be another poll to stop it (e.g. when exiting)
        download_info.progress_widget:cancel()
        FileUtil.removeFile(download_info.part_path)
        FileUtil.removeFile(download_info.headers_file)
    end
    self.active_downloads = {}
    allowSleep()
end

return Downloader
