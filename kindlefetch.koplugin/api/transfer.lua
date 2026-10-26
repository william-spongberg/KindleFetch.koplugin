local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local LogUtil = require("util.logutil")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local HttpDownload = require("util.httpdownload")
local BackgroundProcess = require("util.backgroundprocess")
local FileCheck = require("util.filecheck")
local ProxyUtil = require("util.proxyutil")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- a book downloading to a .part file, moved into place once whole, so half a book never looks whole or replaces one
local Transfer = {
    -- what it's doing: finding its link, downloading (paused while Wi-Fi's off), checking it, then done or failed
    FINDING_LINK = "finding link",
    DOWNLOADING = "downloading",
    PAUSED = "paused",
    CHECKING = "checking",
    DONE = "done",
    FAILED = "failed",
}
Transfer.__index = Transfer

-- constants
local DOWNLOAD_POLL_INTERVAL = 0.5
-- a download that hasn't received anything for this many seconds is given up on, rather than waited on forever
local DOWNLOAD_STALL_TIME = 30
-- and once it hasn't for this many, the progress says it has stalled, as it may be a while before curl tries again
local STALL_NOTICE_TIME = 10
-- what curl gives up with when the book's server doesn't answer or stops sending, rather than e.g. storage being full
local SERVER_FAILURES = { [6] = true, [7] = true, [28] = true, [52] = true, [56] = true }
-- how often a download that's waiting for Wi-Fi checks whether it's back, as KOReader doesn't say so on every device
local RECONNECT_POLL_INTERVAL = 2

-- what a site listed a book's file as, to check what arrives against (see check): its md5 and size, where valid
local function expectedFile(listed)
    listed = type(listed) == "table" and listed or {}
    local md5 = type(listed.md5) == "string" and #listed.md5 == 32 and listed.md5:match("^%x+$")
    local bytes = tonumber(listed.bytes)
    return {
        md5 = md5 and md5:lower() or nil,
        bytes = bytes and bytes > 0 and bytes or nil,
    }
end

-- the download of fields.book from fields.site to fields.filepath, shown by fields.progress_widget, then on_over (see
-- close) and callback(ok, err, filepath); on_relink(failed_url, hidden), where given, asks for another link
function Transfer.new(fields)
    local transfer = setmetatable(fields, Transfer)
    transfer.state = Transfer.FINDING_LINK
    transfer.part_path = fields.filepath .. ".part"
    -- so that curl carries on from where a download that stalled got to, rather than starting it again
    transfer.carry_on = true
    transfer.expected = {}
    transfer.started = os.time()
    return transfer
end

-- whether it's over, done or not
function Transfer:isOver()
    return self.state == Transfer.DONE or self.state == Transfer.FAILED
end

-- stop showing and following it (see on_over in new), as it's over in state
function Transfer:close(state)
    self.state = state
    self.progress_widget:close()
    self.on_over()
end

-- start the download in the background with curl, or KOReader's HTTP where a device has none, as a Kobo can (#63)
function Transfer:startCurl()
    local pid, exit_file_or_err
    if CurlUtil.canFetch() then
        pid, exit_file_or_err = CurlUtil.startDownload(self.download_url, self.part_path, nil, {
            headers_file = self.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            resume = self.carry_on,
        })
    else
        -- (from the beginning, as KOReader's HTTP can't carry on from what's there)
        LogUtil.info("downloading with KOReader's own HTTP, as curl can't")
        pid, exit_file_or_err = HttpDownload.start(self.download_url, self.part_path, {
            headers_file = self.headers_file,
            stall_time = DOWNLOAD_STALL_TIME,
            proxy = ProxyUtil.get(),
        })
    end
    if not pid then
        return false, exit_file_or_err
    end
    self.process = BackgroundProcess.new(pid, exit_file_or_err)
    return true
end

-- download the book from url, the link found for it, checking it against what the site listed it as (see check)
function Transfer:download(url, listed)
    self.download_url = url
    self.expected = expectedFile(listed)
    -- note down the headers curl is sent, which say how big the book is
    self.headers_file = CurlUtil.createHeadersFile()
    self.state = Transfer.DOWNLOADING

    -- what's left of an earlier download of the same name may be another book, so curl mustn't carry on from it
    FileUtil.removeFile(self.part_path)

    -- start background curl downloader
    local started, spawn_err = self:startCurl()
    if not started then
        LogUtil.warn("could not start curl to download:", spawn_err)
        FileUtil.removeFile(self.headers_file)
        self:close(Transfer.FAILED)
        self.callback(false, spawn_err or Errors.START_FAILED)
        return
    end

    -- which takes a few seconds, and sometimes many more, before the book starts to arrive
    self.progress_widget:update(0, T(_("Waiting for %1..."), self.site.NAME))
    self:pollIn(DOWNLOAD_POLL_INTERVAL)
end

-- stop the download while Wi-Fi is off, rather than fail as if the site had, keeping what arrived (see resume)
function Transfer:pause(why)
    -- (nor once it has all arrived, and is being checked, see check)
    if self.state ~= Transfer.DOWNLOADING or self.progress_widget.cancelled then
        return
    end
    self.state = Transfer.PAUSED
    -- (whose exit code isn't looked at)
    self.process:stop()
    LogUtil.info(
        string.format(
            "pausing the download of %q at %d bytes, as %s",
            self.book.title,
            FileUtil.getSize(self.part_path),
            why
        )
    )
    self.progress_widget:update(self.progress_widget.percentage or 0, _("Waiting for Wi-Fi..."))
end

-- resume from what arrived once Wi-Fi is back, with the same link (a new one can count as another Z-Library download)
function Transfer:resume()
    if self.state ~= Transfer.PAUSED then
        return true
    end
    LogUtil.info(string.format("carrying on with the download of %q, now Wi-Fi is back", self.book.title))
    self.state = Transfer.DOWNLOADING
    self.carry_on = true
    self.quiet_polls = 0
    FileUtil.removeFile(self.process.exit_file)
    local started, err = self:startCurl()
    if not started then
        LogUtil.warn("could not start curl to carry on with the download:", err)
        FileUtil.removeFile(self.part_path)
        self:finish(false, err)
        return false
    end
    self.progress_widget:update(self.progress_widget.percentage or 0, T(_("Waiting for %1..."), self.site.NAME))
    return true
end

-- check on the download again in this many seconds (see poll), abandoning it once something goes wrong
function Transfer:pollIn(seconds)
    Guard.scheduleIn(seconds, "checking on a download", function()
        self:poll()
    end, function(err)
        self:abandon(err)
    end)
end

-- ask for another link (see on_relink in new), looking it up without holding KOReader up, as when it was started
function Transfer:relink()
    self:close(Transfer.FAILED)
    FileUtil.removeFile(self.headers_file)
    FileUtil.removeFile(self.part_path)
    UIManager:forceRePaint()
    self.on_relink(self.download_url, not self.progress_widget.is_visible)
end

-- try again when a download fails or isn't the book: from the start where the site can't resume, or with another link
function Transfer:retry(exit_code, http_status, bad_book)
    if bad_book then
        -- (which can't be carried on from)
        FileUtil.removeFile(self.part_path)
    elseif exit_code == 33 and self.carry_on then
        LogUtil.info("downloading the book again from the beginning, as the site can't carry on from where it stopped")
        self.carry_on = false
        FileUtil.removeFile(self.part_path)
        local started, spawn_err = self:startCurl()
        if not started then
            LogUtil.warn("could not start curl to try again:", spawn_err)
            FileUtil.removeFile(self.part_path)
            self:finish(false, spawn_err or _("download failed and could not be tried again"))
            return true
        end
        self:pollIn(DOWNLOAD_POLL_INTERVAL)
        return true
    end

    if self.on_relink and (bad_book or http_status and http_status >= 500 or SERVER_FAILURES[exit_code]) then
        LogUtil.info(
            "asking for another download link, as the server the link went to",
            bad_book and "didn't send the book" or "failed"
        )
        self:relink()
        return true
    end
    return false
end

-- what arrived isn't the book (see check), so try again (see retry), or fail with err
function Transfer:reject(err)
    if not self:retry(nil, nil, true) then
        self:finish(false, err)
    end
end

-- work out the book's md5 a piece at a time, between whatever else KOReader is doing, as a large book takes a while
function Transfer:pollChecksum()
    local book, checksum = self.book, self.checksum
    if self.progress_widget.cancelled then
        LogUtil.info(string.format("download of %q cancelled while checking it", book.title))
        checksum:close()
        self.checksum = nil
        FileUtil.removeFile(self.part_path)
        self:finish(false, Errors.CANCELLED)
        return
    end

    local md5, err = checksum:step()
    if md5 == nil then
        Guard.nextTick("checking a downloaded book", function()
            self:pollChecksum()
        end, function(step_err)
            self:abandon(step_err)
        end)
        return
    end
    self.checksum = nil
    if not md5 then
        -- which isn't for this to say, as it has arrived
        LogUtil.warn(string.format("could not read %q to check it: %s", book.title, tostring(err)))
        self:finish(true)
    elseif md5 ~= self.expected.md5 then
        LogUtil.warn(string.format("%q has the md5 %s, rather than the %s listed", book.title, md5, self.expected.md5))
        self:reject(_("the file that downloaded doesn't match the one listed, and may be damaged"))
    else
        LogUtil.info("it has the md5 listed")
        self:finish(true)
    end
end

-- check what arrived is the book, not e.g. a web page saying the site is busy: by how it starts, then its md5
function Transfer:check()
    local book = self.book
    -- it has finished, so Cancel has nothing to stop (collecting KOReader's own process, if that downloaded it)
    self.process:collect()

    local problem, start = FileCheck.problem(self.part_path, book.file_type)
    if problem == "web page" then
        LogUtil.warn(string.format("a web page arrived in place of %q: %s", book.title, start))
        self:reject(T(_("%1 sent a web page rather than the book, try again later"), self.site.NAME))
        return
    elseif problem then
        LogUtil.warn(string.format("what arrived of %q isn't %s: %s", book.title, book.file_type, start))
        self:reject(T(_("the file that downloaded isn't the %1 it should be"), book.file_type:upper()))
        return
    end

    local checksum = self.expected.md5 and FileCheck.md5(self.part_path)
    if not checksum then
        self:finish(true)
        return
    end
    self.state = Transfer.CHECKING
    self.checksum = checksum
    self.progress_widget:update(1, _("Checking the book..."))
    Guard.nextTick("checking a downloaded book", function()
        self:pollChecksum()
    end, function(err)
        self:abandon(err)
    end)
end

-- check on the download until it's over, showing its progress, then finish with whether it worked
function Transfer:poll()
    local book, part_path, progress_widget = self.book, self.part_path, self.progress_widget
    if progress_widget.cancelled then
        LogUtil.info(
            string.format("download of %q cancelled at %d bytes", book.title, FileUtil.getSize(part_path) or 0)
        )
        self.process:kill()
        FileUtil.removeFile(part_path)
        self:finish(false, Errors.CANCELLED)
        return
    end

    -- waiting for Wi-Fi (see pause), checked for here too, as KOReader doesn't say it's back on every device
    if self.state == Transfer.PAUSED then
        if not self.sleeping and NetworkMgr:isConnected() and not self:resume() then
            return
        end
        self:pollIn(self.state == Transfer.PAUSED and RECONNECT_POLL_INTERVAL or DOWNLOAD_POLL_INTERVAL)
        return
    end

    local bytes_downloaded = FileUtil.getSize(part_path)
    -- count checks that find nothing new to tell a stall, rather than time it, as the clock can be put back or jump
    if bytes_downloaded ~= self.last_size then
        self.last_size = bytes_downloaded
        self.quiet_polls = 0
    else
        self.quiet_polls = (self.quiet_polls or 0) + 1
    end
    local stalled = bytes_downloaded > 0 and self.quiet_polls * DOWNLOAD_POLL_INTERVAL >= STALL_NOTICE_TIME

    -- curl notes down the headers it's sent, which say how big the book is, before the book starts to arrive
    if not self.total_size and bytes_downloaded > 0 then
        self.total_size = CurlUtil.getDownloadSize(self.headers_file)
        if self.total_size then
            LogUtil.info("the file is", self.total_size, "bytes")
        end
    end
    local total_size = self.total_size

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

    local exit_code, running = self.process:poll()
    if exit_code then
        local final_size = FileUtil.getSize(part_path)

        -- check if completed successfully
        local seconds = os.time() - self.started
        if exit_code == 0 and final_size and final_size > 0 then
            -- the size listed or last sent (a retry's can differ), as curl can miss the site stopping partway
            total_size = CurlUtil.getDownloadSize(self.headers_file) or total_size
            local expected_size = self.expected.bytes or total_size
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
                self:check()
                return
            end
        end

        -- the error the site answered with, when that's why curl gave up
        local http_status = exit_code == 22 and CurlUtil.getDownloadStatus(self.headers_file) or nil
        if http_status and http_status < 400 then
            http_status = nil
        end
        LogUtil.warn(
            string.format(
                "download of %q from %s failed after %ds: curl exit code %d (%s%s), %d of %s bytes",
                book.title,
                LogUtil.site(self.download_url),
                seconds,
                exit_code,
                exit_code == 0 and "empty file" or CurlUtil.getErrorMeaning(exit_code),
                http_status and ", HTTP " .. http_status or "",
                final_size or 0,
                tostring(total_size or "unknown")
            )
        )

        -- Wi-Fi went off unannounced, not the site failing: carry on once it's back, as trying again now can't work
        if SERVER_FAILURES[exit_code] and not NetworkMgr:isConnected() then
            self:pause("Wi-Fi is off")
            self:pollIn(RECONNECT_POLL_INTERVAL)
            return
        end

        if self:retry(exit_code, http_status) then
            return
        end

        FileUtil.removeFile(part_path)
        local err = exit_code == 0 and _("download produced empty file") or CurlUtil.explainExitCode(exit_code)
        if http_status == 401 and self.site.library then
            -- a library that turned its login down (see OpdsSearch)
            err = Errors.LIBRARY_LOGIN
        elseif http_status then
            -- its servers failing, as they do while very busy, rather than e.g. the book not being there
            err = http_status >= 500
                    and T(_("%1 is too busy to send books right now, try again in a few minutes"), self.site.NAME)
                or T(_("%1 (HTTP %2)"), err, http_status)
        end
        self:finish(false, err)
        return
    end

    -- exit early if process ends abruptly
    if not running then
        LogUtil.warn(
            string.format(
                "curl stopped without reporting back while downloading %q, at %d bytes",
                book.title,
                bytes_downloaded or 0
            )
        )
        FileUtil.removeFile(part_path)
        self:finish(false, _("download process ended unexpectedly"))
        return
    end

    -- schedule download check
    self:pollIn(DOWNLOAD_POLL_INTERVAL)
end

-- it's over, so move what arrived into place where it worked, and say how it went
function Transfer:finish(ok, err)
    self:close(ok and Transfer.DONE or Transfer.FAILED)
    FileUtil.removeFile(self.headers_file)
    -- where it was KOReader's own process that downloaded it, rather than curl
    if self.process then
        self.process:collect()
    end
    if ok and not os.rename(self.part_path, self.filepath) then
        LogUtil.warn("could not move the downloaded book from", self.part_path, "to", self.filepath)
        FileUtil.removeFile(self.part_path)
        ok, err = false, _("could not save the book")
        self.state = Transfer.FAILED
    end
    UIManager:forceRePaint()
    self.callback(ok, err, self.filepath)
end

-- after a mistake in Kindle Fetch while it's going (see Guard), stop it, cleaning up all that can be
function Transfer:abandon(err)
    -- other than once it has finished, as then it did download, and what went wrong was what's done with it
    if self:isOver() then
        return
    end
    if self.state ~= Transfer.FINDING_LINK then
        if self.checksum then
            self.checksum:close()
        end
        if self.process then
            self.process:stop()
        end
        FileUtil.removeFile(self.part_path)
        FileUtil.removeFile(self.headers_file)
    end
    self:close(Transfer.FAILED)
    self.callback(false, err)
end

return Transfer
