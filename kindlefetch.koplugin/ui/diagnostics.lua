local Device = require("device")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local TextViewer = require("ui/widget/textviewer")
local KindleFetchSettings = require("settings.settings")
local UrlApi = require("api.urlapi")
local ZlibAccount = require("api.zlibaccount")
local WaitingMessage = require("ui.waitingmessage")
local CurlUtil = require("util.curlutil")
local HttpUtil = require("util.httputil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local PathUtil = require("util.pathutil")
local ProxyUtil = require("util.proxyutil")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- what's known about Kindle Fetch, KOReader, the device and its connection to the sites, with what Kindle Fetch logged
-- recently, to copy or save for whoever's helping with a problem
local Diagnostics = {}

-- the file it's saved as (see save), in KOReader's own folder, where it can be copied from over USB without showing
-- up among the books
local REPORT_NAME = "kindlefetch-diagnostics.txt"
-- Internet Archive's search, asked for a single book, to test connecting to it
local ARCHIVE_TEST_URL =
    "https://archive.org/advancedsearch.php?q=identifier%3Aemma00aust&fl%5B%5D=identifier&rows=1&output=json"

-- the version of Kindle Fetch installed, or nil if it can't be read
function Diagnostics.version()
    local version = FileUtil.readFile(PathUtil.getPluginPath() .. "/version.txt")
    return version and version:match("^%s*(.-)%s*$")
end

-- which kind of device KOReader is on
local function deviceKind()
    return Device:isKindle() and "Kindle"
        or (Device.isKobo and Device:isKobo()) and "Kobo"
        or Device:isAndroid() and "Android"
        or Device:isSDL() and "computer"
        or "device"
end

-- the versions of Kindle Fetch, KOReader and curl, and the device, on a line, as logged when KOReader starts
function Diagnostics.summary()
    local ok, koreader_version = pcall(function()
        return require("version"):getCurrentRevision()
    end)
    return string.format(
        "KindleFetch %s on KOReader %s, %s %s, curl %s%s%s",
        Diagnostics.version() or "unknown",
        ok and koreader_version or "unknown",
        deviceKind(),
        tostring(Device.model),
        CurlUtil.getVersion() or "not found",
        ProxyUtil.koreader() and ", through KOReader's HTTP proxy" or "",
        ProxyUtil.backup() and ", with PROXY_URL set" or ""
    )
end

-- the report: what's known about Kindle Fetch, KOReader and the device, the results of testing the connection, where
-- it has been (tested, see testConnection), then what Kindle Fetch has logged this session. it's in English, as it's
-- for whoever helps, and has nothing in it that would let them into the Z-Library account
function Diagnostics.report(tested)
    local lines = { Diagnostics.summary() }
    local function add(label, value)
        table.insert(lines, label .. ": " .. tostring(value))
    end
    local function list(values)
        return #values > 0 and table.concat(values, ", ") or "none"
    end
    local function onOff(on)
        return on and "on" or "off"
    end

    add("Time", os.date("%Y-%m-%d %H:%M") .. " (secure connections fail when it's far off)")
    add("Fetching with", CurlUtil.canFetch() and "curl" or "KOReader's own HTTP, as curl can't")
    local folder = KindleFetchSettings:getDownloadDir()
    local writable, err = FileUtil.checkWritableDir(folder)
    add("Download folder", folder .. (writable and "" or " (which can't be written to: " .. tostring(err) .. ")"))
    add("Library Genesis mirrors", list(UrlApi:peekLibgenUrls()))
    add(
        "Z-Library",
        (ZlibAccount:isLoggedIn() and "logged in" or "not logged in") .. ", at " .. list(UrlApi:peekZlibUrls())
    )
    add("Languages", list(KindleFetchSettings:getPreferredLanguages()))
    add("File types", list(KindleFetchSettings:getPreferredFileTypes()))
    add("Book types", list(KindleFetchSettings:getPreferredBookTypes()))
    add("Covers", onOff(KindleFetchSettings:getShowBookCovers()))
    add("Update checks", onOff(KindleFetchSettings:getCheckForUpdates()))

    if tested then
        table.insert(lines, "")
        table.insert(lines, "Connection test:")
        for __, result in ipairs(tested) do
            table.insert(lines, "  " .. result)
        end
    end

    table.insert(lines, "")
    table.insert(lines, "Recent log:")
    for __, line in ipairs(LogUtil.recent()) do
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

-- save the report's text to a file (see REPORT_NAME), saying where
function Diagnostics.save(text)
    local path = DataStorage:getDataDir() .. "/" .. REPORT_NAME
    local ok, err = FileUtil.writeFile(path, text)
    if not ok then
        LogUtil.warn("could not save the diagnostics to", path, "as", err)
        NotifyUtil.error(T(_("The diagnostics couldn't be saved: %1"), err))
        return
    end
    LogUtil.info("saved the diagnostics to", path)
    NotifyUtil.info(T(_("Saved to %1"), path))
end

-- show the report (see report), to copy or save, or test the connection from
function Diagnostics.show(tested)
    local text = Diagnostics.report(tested)
    local viewer
    viewer = TextViewer:new {
        title = _("Kindle Fetch diagnostics"),
        text = text,
        text_type = "code",
        -- with KOReader's own buttons (Find and Close, and ones to go to its top and bottom) after these
        add_default_buttons = true,
        buttons_table = {
            {
                {
                    text = _("Test connection"),
                    callback = function()
                        UIManager:close(viewer)
                        Diagnostics.testConnection()
                    end,
                },
                {
                    text = _("Copy"),
                    callback = function()
                        Device.input.setClipboardText(text)
                        NotifyUtil.info(_("Copied"))
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        Diagnostics.save(text)
                    end,
                },
            },
        },
    }
    UIManager:show(viewer)
end

-- what to test connecting to: Wikipedia, where the mirrors are looked up, Library Genesis' mirrors and Z-Library's
-- addresses as they are (without looking them up again, or changing them, see UrlApi.peekLibgenUrls), and Internet
-- Archive. Z-Library's at its API, as Kindle Fetch asks it, which answers without a cookie, where its home page sends
-- what hasn't one back to it, again and again
local function testUrls()
    local urls = { UrlApi.LIBGEN_PAGE }
    for __, url in ipairs(UrlApi:peekLibgenUrls()) do
        table.insert(urls, url .. "/")
    end
    table.insert(urls, ARCHIVE_TEST_URL)
    for __, url in ipairs(UrlApi:peekZlibUrls()) do
        table.insert(urls, url .. "/eapi/info/languages")
    end
    return urls
end

-- how asking url went, as a line of the report: whatever it answered with, it can be connected to
local function result(url, body, err, status)
    local site = LogUtil.site(url)
    if status then
        return string.format("%s answered (HTTP %s)", site, tostring(status))
    elseif body then
        return site .. " answered"
    end
    return string.format("%s didn't answer: %s", site, tostring(err))
end

-- test connecting to each of the sites Kindle Fetch uses (see testUrls), one after another, without holding KOReader
-- up while they answer, where that's possible (see HttpUtil), then show the report with how it went. Cancel calls it
-- off, showing how it went with those tested by then, as each that doesn't answer is waited on for a while
function Diagnostics.testConnection()
    local message
    local function closeMessage()
        HttpUtil.setTrapWidget(nil)
        if message and not message.cancelled and not message.closed then
            message.closed = true
            UIManager:close(message)
        end
    end

    Trapper:wrap(Guard.wrap("testing the connection", function()
        message = WaitingMessage.new(_("Testing the connection to the sites Kindle Fetch uses..."))
        UIManager:show(message)
        UIManager:forceRePaint()
        HttpUtil.setTrapWidget(message)

        local results = {}
        for __, url in ipairs(testUrls()) do
            local body, err, status = HttpUtil.getBody(url)
            if err == HttpUtil.CANCELLED then
                LogUtil.info("the connection test was called off at", LogUtil.site(url))
                table.insert(results, "(called off at " .. LogUtil.site(url) .. ")")
                break
            end
            table.insert(results, result(url, body, err, status))
        end
        closeMessage()
        LogUtil.info("tested the connection:", table.concat(results, "; "))
        Diagnostics.show(results)
    end, function(err)
        closeMessage()
        Guard.say(err)
    end))
end

return Diagnostics
