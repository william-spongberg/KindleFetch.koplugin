local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Device = require("device")
local PluginShare = require("pluginshare")
local Trapper = require("ui/trapper")
local ConfirmBox = require("ui/widget/confirmbox")
local LogUtil = require("util.logutil")
local DownloadProgress = require("ui.downloadprogress")
local DownloadPrompt = require("ui.downloadprompt")
local HttpUtil = require("util.httputil")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local HttpDownload = require("util.httpdownload")
local FileCheck = require("util.filecheck")
local ProxyUtil = require("util.proxyutil")
local Sources = require("api.sources")
local CoverCache = require("cache.covercache")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- downloads books from the site they were found on (see Sources), in the background
local Downloader = {}
Downloader.active_downloads = {}
-- how many downloads have been started this session, to list them in the order they were (see getActiveDownloads)
local downloads_started = 0

-- constants
local DOWNLOAD_POLL_INTERVAL = 0.5
-- a download that hasn't received anything for this many seconds is given up on, rather than waited on forever
local DOWNLOAD_STALL_TIME = 30
-- and once it hasn't for this many, the progress says it has stalled, as it may be a while before curl tries again
local STALL_NOTICE_TIME = 10
-- what curl gives up with when the server a book is downloaded from doesn't answer, or stops sending it, rather than
-- e.g. the device's storage being full: couldn't find it or connect to it, nothing arrived for a while, nothing came
-- back, or the connection broke
local SERVER_FAILURES = { [6] = true, [7] = true, [28] = true, [52] = true, [56] = true }
-- how often a download that's waiting for Wi-Fi checks whether it's back, as KOReader doesn't say so on every device
local RECONNECT_POLL_INTERVAL = 2

-- what a site listed a book's file as (see findDownloadLink in Sources), to check what arrives against (see checkBook):
-- its md5 (in lower case) and how many bytes it is, of those it gave that are what they should be
local function expectedFile(listed)
    listed = type(listed) == "table" and listed or {}
    local md5 = type(listed.md5) == "string" and #listed.md5 == 32 and listed.md5:match("^%x+$")
    local bytes = tonumber(listed.bytes)
    return {
        md5 = md5 and md5:lower() or nil,
        bytes = bytes and bytes > 0 and bytes or nil,
    }
end

-- keep the device from going to sleep while books are downloading, as that turns Wi-Fi off and stops them: no
-- standby between taps (where KOReader has it), and no suspending once it hasn't been used for a while, by KOReader's
-- AutoSuspend, or on a Kindle, its own screensaver. each is put back as it was once the last download is over (unless
-- something else, such as AutoTurn or Keep alive, has changed it since, which is left to it)
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

-- start curl downloading the book in the background, as transfer says (see _startDownload), or where curl can't
-- (see CurlUtil.canFetch), KOReader's own HTTP, as a device may have no curl at all, as a Kobo can (#63), which
-- failed every download. returns whether it started, and why not if it didn't
local function startCurl(transfer)
    local pid, exit_file_or_err
    if CurlUtil.canFetch() then
        pid, exit_file_or_err = CurlUtil.startDownload(transfer.download_url, transfer.part_path, nil, {
            headers_file = transfer.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            -- so that curl carries on from where a download that stalled got to, rather than starting it again
            resume = transfer.resume,
        })
    else
        -- (from the beginning, as KOReader's HTTP can't carry on from what's there)
        LogUtil.info("downloading with KOReader's own HTTP, as curl can't")
        pid, exit_file_or_err = HttpDownload.start(transfer.download_url, transfer.part_path, {
            headers_file = transfer.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            proxy = ProxyUtil.get(),
        })
    end
    if not pid then
        return false, exit_file_or_err
    end
    transfer.pid, transfer.exit_file = pid, exit_file_or_err
    return true
end

-- stop downloading the book while the device sleeps or Wi-Fi is off, rather than it failing for want of Wi-Fi as if
-- the site had, keeping what has arrived to carry on from once it's back (see resumeTransfer)
local function pauseTransfer(transfer, why)
    -- (nor once it has all arrived, and is being checked, see checkBook)
    if transfer.paused or transfer.checksum or not transfer.download_url or transfer.progress_widget.cancelled then
        return
    end
    transfer.paused = true
    -- (whose exit code isn't looked at)
    CurlUtil.killPid(transfer.pid)
    HttpDownload.collect(transfer.pid)
    transfer.pid = nil
    LogUtil.info(
        string.format(
            "pausing the download of %q at %d bytes, as %s",
            transfer.book.title,
            FileUtil.getSize(transfer.part_path),
            why
        )
    )
    transfer.progress_widget:update(transfer.progress_widget.percentage or 0, _("Waiting for Wi-Fi..."))
end

-- carry on downloading the book once the device is awake and connected again, from what had arrived, with the same
-- link (rather than asking for another, which for Z-Library can count as another download). returns false when curl
-- couldn't be started again, and the download has failed
local function resumeTransfer(transfer)
    if not transfer.paused then
        return true
    end
    LogUtil.info(string.format("carrying on with the download of %q, now Wi-Fi is back", transfer.book.title))
    transfer.paused = nil
    transfer.resume = true
    transfer.quiet_polls = 0
    FileUtil.removeFile(transfer.exit_file)
    local started, err = startCurl(transfer)
    if not started then
        LogUtil.warn("could not start curl to carry on with the download:", err)
        FileUtil.removeFile(transfer.part_path)
        transfer.on_finish(false, err)
        return false
    end
    transfer.progress_widget:update(
        transfer.progress_widget.percentage or 0,
        T(_("Waiting for %1..."), Sources[transfer.book.source].NAME)
    )
    return true
end

local pollDownload

-- check on the download again in this many seconds (see pollDownload), abandoning it once something goes wrong
local function pollIn(seconds, transfer)
    Guard.scheduleIn(seconds, "checking on a download", function()
        pollDownload(transfer)
    end, transfer.abandon)
end

-- try a download again once it has failed, or what arrived wasn't the book (bad_book, see checkBook): from the
-- beginning, where the site wouldn't carry on from where it stopped, or with another link, from a site whose links
-- each go to one of its servers, when the one it went to failed. returns whether it's being tried again
local function retry(transfer, exit_code, http_status, bad_book)
    if bad_book then
        -- (which can't be carried on from)
        FileUtil.removeFile(transfer.part_path)
    elseif exit_code == 33 and transfer.resume then
        LogUtil.info("downloading the book again from the beginning, as the site can't carry on from where it stopped")
        transfer.resume = false
        FileUtil.removeFile(transfer.part_path)
        local started, spawn_err = startCurl(transfer)
        if not started then
            LogUtil.warn("could not start curl to try again:", spawn_err)
            FileUtil.removeFile(transfer.part_path)
            transfer.on_finish(false, spawn_err or _("download failed and could not be tried again"))
            return true
        end
        pollIn(DOWNLOAD_POLL_INTERVAL, transfer)
        return true
    end

    if transfer.relink and (bad_book or http_status and http_status >= 500 or SERVER_FAILURES[exit_code]) then
        LogUtil.info(
            "asking for another download link, as the server the link went to",
            bad_book and "didn't send the book" or "failed"
        )
        transfer.relink()
        return true
    end
    return false
end

-- what arrived isn't the book (see checkBook), so try again (see retry), or fail with err
local function rejectBook(transfer, err)
    if not retry(transfer, nil, nil, true) then
        transfer.on_finish(false, err)
    end
end

-- work out the md5 of the book that has arrived, a piece at a time between whatever else KOReader is doing, as a large
-- book takes a while, and check it's the file the site listed
local function pollChecksum(transfer)
    local book, checksum = transfer.book, transfer.checksum
    if transfer.progress_widget.cancelled then
        LogUtil.info(string.format("download of %q cancelled while checking it", book.title))
        checksum:close()
        transfer.checksum = nil
        FileUtil.removeFile(transfer.part_path)
        transfer.on_finish(false, Errors.CANCELLED)
        return
    end

    local md5, err = checksum:step()
    if md5 == nil then
        Guard.nextTick("checking a downloaded book", function()
            pollChecksum(transfer)
        end, transfer.abandon)
        return
    end
    transfer.checksum = nil
    if not md5 then
        -- which isn't for this to say, as it has arrived
        LogUtil.warn(string.format("could not read %q to check it: %s", book.title, tostring(err)))
        transfer.on_finish(true)
    elseif md5 ~= transfer.expected.md5 then
        LogUtil.warn(
            string.format("%q has the md5 %s, rather than the %s listed", book.title, md5, transfer.expected.md5)
        )
        rejectBook(transfer, _("the file that downloaded doesn't match the one listed, and may be damaged"))
    else
        LogUtil.info("it has the md5 listed")
        transfer.on_finish(true)
    end
end

-- check the book that has arrived is the one the site listed, rather than e.g. a web page saying the site is busy: by
-- how it starts, then by its md5, where the site lists one (see pollChecksum). once it is, it has downloaded
local function checkBook(transfer)
    local book = transfer.book
    -- which has finished, so there's nothing for Cancel to stop meanwhile (where it was KOReader's own process that
    -- downloaded it, collecting it)
    HttpDownload.collect(transfer.pid)
    transfer.pid = nil

    local problem, start = FileCheck.problem(transfer.part_path, book.file_type)
    if problem == "web page" then
        LogUtil.warn(string.format("a web page arrived in place of %q: %s", book.title, start))
        rejectBook(
            transfer,
            T(_("%1 sent a web page rather than the book, try again later"), Sources[book.source].NAME)
        )
        return
    elseif problem then
        LogUtil.warn(string.format("what arrived of %q isn't %s: %s", book.title, book.file_type, start))
        rejectBook(transfer, T(_("the file that downloaded isn't the %1 it should be"), book.file_type:upper()))
        return
    end

    local checksum = transfer.expected.md5 and FileCheck.md5(transfer.part_path)
    if not checksum then
        transfer.on_finish(true)
        return
    end
    transfer.checksum = checksum
    transfer.progress_widget:update(1, _("Checking the book..."))
    Guard.nextTick("checking a downloaded book", function()
        pollChecksum(transfer)
    end, transfer.abandon)
end

-- check on curl downloading a book until it has finished, showing how far it has got. transfer is what's known
-- about the download (see _startDownload), and its on_finish is called with whether the book downloaded, and what
-- went wrong if it didn't
function pollDownload(transfer)
    local book, part_path, progress_widget = transfer.book, transfer.part_path, transfer.progress_widget
    if progress_widget.cancelled then
        LogUtil.info(
            string.format("download of %q cancelled at %d bytes", book.title, FileUtil.getSize(part_path) or 0)
        )
        CurlUtil.killPid(transfer.pid)
        FileUtil.removeFile(part_path)
        transfer.on_finish(false, Errors.CANCELLED)
        return
    end

    -- waiting for Wi-Fi to come back (see pauseTransfer), which is checked for here too, as KOReader doesn't say so
    -- on every device
    if transfer.paused then
        if not transfer.sleeping and NetworkMgr:isConnected() and not resumeTransfer(transfer) then
            return
        end
        pollIn(transfer.paused and RECONNECT_POLL_INTERVAL or DOWNLOAD_POLL_INTERVAL, transfer)
        return
    end

    local bytes_downloaded = FileUtil.getSize(part_path)
    -- how many checks have found nothing more of the book arrived, to tell when the download has stalled: counted,
    -- rather than timed with the clock, which can be put back, or jump forward once the time is looked up
    if bytes_downloaded ~= transfer.last_size then
        transfer.last_size = bytes_downloaded
        transfer.quiet_polls = 0
    else
        transfer.quiet_polls = (transfer.quiet_polls or 0) + 1
    end
    local stalled = bytes_downloaded > 0 and transfer.quiet_polls * DOWNLOAD_POLL_INTERVAL >= STALL_NOTICE_TIME

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
            stalled and T(_("Stalled at %1%, retrying..."), math.floor(percentage * 100))
                or string.format(
                    "%d%% · %.1f / %.1f MB",
                    math.floor(percentage * 100),
                    bytes_downloaded / (1024 * 1024),
                    total_size / (1024 * 1024)
                )
        )
    elseif bytes_downloaded > 0 then
        -- the size wasn't known, or was wrong
        local megabytes = bytes_downloaded / (1024 * 1024)
        progress_widget:update(
            progress_widget.percentage or 0,
            stalled and T(_("Stalled at %1 MB, retrying..."), string.format("%.1f", megabytes))
                or string.format("%.1f MB", megabytes)
        )
    end

    LogUtil.debug("download progress", {
        title = book.title,
        id = book.id,
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
        local download = Downloader.active_downloads[book.id]
        local seconds = download and download.started and os.time() - download.started or 0
        if exit_code == 0 and final_size and final_size > 0 then
            -- how big the site listed it as, or said it was when it last sent it (as what a retry is sent can differ
            -- from the first), as curl doesn't always notice when the site stops sending it partway
            total_size = CurlUtil.getDownloadSize(transfer.headers_file) or total_size
            local expected_size = transfer.expected.bytes or total_size
            if expected_size and final_size < expected_size then
                LogUtil.warn(
                    string.format("only %d of the %d bytes of %q arrived", final_size, expected_size, book.title)
                )
                -- as curl says when it does notice
                exit_code = 18
            else
                progress_widget:update(1, "100%")
                LogUtil.info(
                    string.format(
                        "downloaded %q: %d bytes%s in %ds",
                        book.title,
                        final_size,
                        expected_size and expected_size ~= final_size and " (expected " .. expected_size .. ")" or "",
                        seconds
                    )
                )
                checkBook(transfer)
                return
            end
        end

        -- the error the site answered with, when that's why curl gave up
        local http_status = exit_code == 22 and CurlUtil.getDownloadStatus(transfer.headers_file) or nil
        if http_status and http_status < 400 then
            http_status = nil
        end
        LogUtil.warn(
            string.format(
                "download of %q from %s failed after %ds: curl exit code %d (%s%s), %d of %s bytes",
                book.title,
                LogUtil.site(transfer.download_url),
                seconds,
                exit_code,
                exit_code == 0 and "empty file" or CurlUtil.getErrorMeaning(exit_code),
                http_status and ", HTTP " .. http_status or "",
                final_size or 0,
                tostring(total_size or "unknown")
            )
        )

        -- Wi-Fi went off, rather than the site failing (where KOReader didn't say so, see onNetworkDisconnected):
        -- carry on from what has arrived once it's back, rather than trying again now, which can't work
        if SERVER_FAILURES[exit_code] and not NetworkMgr:isConnected() then
            -- (as curl has stopped, there's nothing to stop)
            transfer.pid = nil
            pauseTransfer(transfer, "Wi-Fi is off")
            pollIn(RECONNECT_POLL_INTERVAL, transfer)
            return
        end

        if retry(transfer, exit_code, http_status) then
            return
        end

        FileUtil.removeFile(part_path)
        local err = exit_code == 0 and _("download produced empty file") or CurlUtil.explainExitCode(exit_code)
        if http_status then
            -- its servers failing, as they do while very busy, rather than e.g. the book not being there
            err = http_status >= 500
                    and T(
                        _("%1 is too busy to send books right now, try again in a few minutes"),
                        Sources[book.source].NAME
                    )
                or T(_("%1 (HTTP %2)"), err, http_status)
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
        transfer.on_finish(false, _("download process ended unexpectedly"))
        return
    end

    -- schedule download check
    pollIn(DOWNLOAD_POLL_INTERVAL, transfer)
end

-- failed_url is the link the book failed to download from, when asking for another (see transfer.relink), and hidden
-- is whether its progress was hidden, when trying again, so it stays hidden rather than showing again
function Downloader:_startDownload(book, filepath, callback, retrying, failed_url, hidden)
    local source = Sources[book.source]
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

    -- what's known about the download, as it goes along (see pollDownload). the book is downloaded next to where
    -- it's wanted and moved there once it's all arrived, so that half a book is never left looking like a whole
    -- one, and a book being downloaded over is kept until then
    local transfer = {
        book = book,
        part_path = filepath .. ".part",
        resume = true,
        expected = {},
    }
    local part_path = transfer.part_path

    -- create and show progress widget immediately
    local progress_widget = DownloadProgress.new(book.display_title or book.title, function()
        if transfer.pid then
            CurlUtil.killPid(transfer.pid)
        end
    end, hidden)
    transfer.progress_widget = progress_widget

    progress_widget:show()
    -- which can mean trying several of the site's mirrors
    progress_widget:update(0, _("Finding a download link..."))
    UIManager:forceRePaint()

    -- track this download
    Downloader:track(book.id, {
        book = book,
        filepath = filepath,
        part_path = part_path,
        progress_widget = progress_widget,
        callback = callback,
        started = os.time(),
    })

    -- look the link up without holding KOReader up (where pages are fetched with curl, see HttpUtil), as it can
    -- mean trying several mirrors, and let Cancel call it off. where it holds KOReader up, Cancel and Hide can't be
    -- tapped until it's over, as the taps would only arrive then. an error is passed on, rather than left to Trapper,
    -- which would leave the progress showing
    local can_cancel = HttpUtil.canCancel()
    if not can_cancel then
        progress_widget:setCancellable(false)
        UIManager:forceRePaint()
    end
    HttpUtil.setTrapWidget(progress_widget)
    local looked_up, download_url, lookup_err, mirror_failed, listed =
        Guard.pcall("looking up the download link", source.findDownloadLink, book, retrying, failed_url)
    HttpUtil.setTrapWidget(nil)
    progress_widget.dismiss_callback = nil
    if not can_cancel then
        progress_widget:setCancellable(true)
    end
    if not looked_up then
        download_url, lookup_err, mirror_failed, listed = nil, Errors.UNEXPECTED, false, nil
    end

    if not download_url then
        progress_widget:close()
        Downloader:untrack(book.id)

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
    transfer.download_url = download_url
    transfer.expected = expectedFile(listed)

    -- note down the headers curl is sent, which say how big the book is
    local headers_file = CurlUtil.createHeadersFile()
    transfer.headers_file = headers_file
    Downloader.active_downloads[book.id].headers_file = headers_file
    -- after a mistake in Kindle Fetch while checking on the download (see Guard), stop it, cleaning up all that can be
    transfer.abandon = function(err)
        -- other than once it has finished, when what's done with the book went wrong: it did download, and there's
        -- nothing left to stop
        if transfer.finished then
            return
        end
        if transfer.checksum then
            transfer.checksum:close()
        end
        CurlUtil.killPid(transfer.pid)
        HttpDownload.collect(transfer.pid)
        FileUtil.removeFile(part_path)
        FileUtil.removeFile(headers_file)
        progress_widget:close()
        Downloader:untrack(book.id)
        callback(false, err)
    end
    Downloader.active_downloads[book.id].transfer = transfer
    transfer.on_finish = function(ok, err)
        transfer.finished = true
        progress_widget:close()
        Downloader:untrack(book.id)
        FileUtil.removeFile(headers_file)
        -- where it was KOReader's own process that downloaded it, rather than curl
        HttpDownload.collect(transfer.pid)
        if ok and not os.rename(part_path, filepath) then
            LogUtil.warn("could not move the downloaded book from", part_path, "to", filepath)
            FileUtil.removeFile(part_path)
            ok, err = false, _("could not save the book")
        end
        UIManager:forceRePaint()
        callback(ok, err, filepath)
    end
    -- the site's links each go to one of its servers, so it can give another link once, rather than the download
    -- failing with the server it went to (see pollDownload)
    if source.NEW_LINK_WHEN_SERVER_FAILS and not retrying then
        transfer.relink = function()
            progress_widget:close()
            Downloader:untrack(book.id)
            FileUtil.removeFile(headers_file)
            FileUtil.removeFile(part_path)
            UIManager:forceRePaint()
            -- looking the link up without holding KOReader up, as when the download was started
            self:_startDownloadInBackground(
                book,
                filepath,
                callback,
                true,
                transfer.download_url,
                not progress_widget.is_visible
            )
        end
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
        Downloader:untrack(book.id)
        callback(false, spawn_err or Errors.START_FAILED)
        return
    end

    -- which takes a few seconds, and sometimes many more, before the book starts to arrive
    progress_widget:update(0, T(_("Waiting for %1..."), source.NAME))
    pollIn(DOWNLOAD_POLL_INTERVAL, transfer)
end

-- start downloading the book (see _startDownload) without holding KOReader up while its link is looked up, as that
-- can mean trying several mirrors, and saying so if something goes wrong in Kindle Fetch meanwhile (see Guard)
function Downloader:_startDownloadInBackground(book, filepath, callback, retrying, failed_url, hidden)
    Trapper:wrap(Guard.wrap("starting the download of " .. tostring(book.title), function()
        self:_startDownload(book, filepath, callback, retrying, failed_url, hidden)
    end, function(err)
        local download = Downloader.active_downloads[book.id]
        if download and download.transfer then
            download.transfer.abandon(err)
            return
        end
        if download then
            download.progress_widget:close()
            Downloader:untrack(book.id)
        end
        callback(false, err)
    end))
end

-- why a book can't be downloaded to filepath, or nil when it can: its folder can't be found (e.g. once deleted, or on
-- an SD card that has been taken out) or written to, or another book (e.g. another edition) is being downloaded to the
-- same name, which would share its .part file, and one would be saved as the other
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

-- open_existing is optionally called with the path of a book that's already there, when asked to read that one
-- rather than download over it
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

        -- ask before downloading over a book that's already there, which may be another edition with the same
        -- title, as KOReader does for the books it downloads
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
    for __, download in pairs(active_downloads) do
        if download.transfer then
            fn(download.transfer)
        end
    end
end

-- the device is going to sleep, which turns Wi-Fi off, so stop each download until it's awake again (see
-- pauseTransfer). sent by KOReader through the plugin (see main.lua), as are the events below
function Downloader:onSuspend()
    eachTransfer(self.active_downloads, function(transfer)
        transfer.sleeping = true
        pauseTransfer(transfer, "the device is going to sleep")
    end)
end

-- carry on with each download once the device is awake, as soon as it's connected again (see pollDownload)
function Downloader:onResume()
    eachTransfer(self.active_downloads, function(transfer)
        transfer.sleeping = nil
        if transfer.paused and NetworkMgr:isConnected() then
            resumeTransfer(transfer)
        end
    end)
end

function Downloader:onNetworkDisconnected()
    eachTransfer(self.active_downloads, function(transfer)
        pauseTransfer(transfer, "Wi-Fi went off")
    end)
end

function Downloader:onNetworkConnected()
    eachTransfer(self.active_downloads, function(transfer)
        if transfer.paused and not transfer.sleeping then
            resumeTransfer(transfer)
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
