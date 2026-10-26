local Device = require("device")
local DataStorage = require("datastorage")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local KindleFetchSettings = require("settings.settings")
local UrlApi = require("api.urlapi")
local ZlibAccount = require("api.zlibaccount")
local BackgroundTask = require("ui.backgroundtask")
local CurlVersion = require("util.curlversion")
local HttpUtil = require("util.httputil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local NotifyUtil = require("util.notifyutil")
local PathUtil = require("util.pathutil")
local ProxyUtil = require("util.proxyutil")
local T = require("ffi/util").template
local _ = require("gettext")

-- what's known about Kindle Fetch, KOReader, the device and its connection, and what it logged, for whoever's helping
local Diagnostics = {}

-- the file it's saved as (see save), in KOReader's folder, to copy over USB without it showing up among the books
local REPORT_NAME = "kindlefetch-diagnostics.txt"
-- a book's entry in Project Gutenberg's catalogue, and Internet Archive's search for one book, to test connecting
local GUTENBERG_TEST_URL = "https://www.gutenberg.org/ebooks/1342.opds"
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
        "KindleFetch %s on KOReader %s, %s %s, curl %s%s",
        Diagnostics.version() or "unknown",
        ok and koreader_version or "unknown",
        deviceKind(),
        tostring(Device.model),
        CurlVersion.getVersion() or "not found",
        ProxyUtil.get() and ", through KOReader's HTTP proxy" or ""
    )
end

-- the report, with tested's results (see testConnection), in English for whoever helps, and no way into Z-Library
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
    add("Fetching with", CurlVersion.canFetch() and "curl" or "KOReader's own HTTP, as curl can't")
    local folder = KindleFetchSettings:getDownloadDir()
    local writable, err = FileUtil.checkWritableDir(folder)
    add("Download folder", folder .. (writable and "" or " (which can't be written to: " .. tostring(err) .. ")"))
    add("Library Genesis mirrors", list(UrlApi:peekLibgenUrls()))
    add(
        "Z-Library",
        (ZlibAccount:isLoggedIn() and "logged in" or "not logged in") .. ", at " .. list(UrlApi:peekZlibUrls())
    )
    -- by their names and kinds, rather than their addresses, and whether they're logged into, but never how
    local libraries = {}
    for __, library in ipairs(KindleFetchSettings:getLibraries()) do
        table.insert(
            libraries,
            string.format(
                "%s (%s, %s%s)",
                library.name,
                library.kind,
                StringUtil.isLocalUrl(library.url) and "on the local network" or "on the internet",
                library.username ~= "" and ", logged into" or ""
            )
        )
    end
    add("Libraries", list(libraries))
    add("Languages", list(KindleFetchSettings:getPreferredLanguages()))
    add("File types", list(KindleFetchSettings:getPreferredFileTypes()))
    add("Book types", list(KindleFetchSettings:getPreferredBookTypes()))
    add(
        "Encrypted DNS",
        onOff(KindleFetchSettings:getEncryptedDns())
            .. (CurlVersion.canUseEncryptedDns() and "" or " (which curl can't do)")
    )
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

-- the names of the libraries whose catalogues are tested, by their addresses (see testUrls)
local library_names = {}

-- what to test: mirrors as they are (see UrlApi.peekLibgenUrls), and Z-Library's API, which answers without a cookie
local function testUrls()
    local urls = { UrlApi.LIBGEN_PAGE }
    for __, url in ipairs(UrlApi:peekLibgenUrls()) do
        table.insert(urls, url .. "/")
    end
    table.insert(urls, ARCHIVE_TEST_URL)
    table.insert(urls, GUTENBERG_TEST_URL)
    for __, url in ipairs(UrlApi:peekZlibUrls()) do
        table.insert(urls, url .. "/eapi/info/languages")
    end
    -- and each library's catalogue, said by the library's name rather than its address (see result)
    library_names = {}
    for __, library in ipairs(KindleFetchSettings:getLibraries()) do
        table.insert(urls, library.url)
        library_names[library.url] = library.name
    end
    return urls
end

-- how asking url went, as a line of the report: whatever it answered with, it can be connected to
local function result(url, body, err, status)
    local site = library_names[url] or LogUtil.site(url)
    if status then
        return string.format("%s answered (HTTP %s)", site, tostring(status))
    elseif body then
        return site .. " answered"
    end
    return string.format("%s didn't answer: %s", site, tostring(err))
end

-- test each site (see testUrls) without holding KOReader up, then report how it went, or on Cancel how it went so far
function Diagnostics.testConnection()
    local text = _("Testing the connection to the sites Kindle Fetch uses...")
    BackgroundTask.withMessage("testing the connection", text, function()
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
        return results
    end, function(results)
        LogUtil.info("tested the connection:", table.concat(results, "; "))
        Diagnostics.show(results)
    end)
end

return Diagnostics
