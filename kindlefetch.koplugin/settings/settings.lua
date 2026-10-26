local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Device = require("device")
local FileUtil = require("util.fileutil")
local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")
local SavedLibrary = require("settings.savedlibrary")
local SavedZlibAccount = require("settings.savedzlibaccount")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local KindleFetchSettings = {}

-- available settings
local AVAILABLE_LANGUAGES = {
    {
        text = "English",
        code = "en",
    },
    {
        text = "Spanish",
        code = "es",
    },
    {
        text = "French",
        code = "fr",
    },
    {
        text = "German",
        code = "de",
    },
    {
        text = "Italian",
        code = "it",
    },
    {
        text = "Portuguese",
        code = "pt",
    },
    {
        text = "Russian",
        code = "ru",
    },
    {
        text = "Chinese",
        code = "zh",
    },
    {
        text = "Japanese",
        code = "ja",
    },
    {
        text = "Dutch",
        code = "nl",
    },
    {
        text = "Bulgarian",
        code = "bg",
    },
    {
        text = "Polish",
        code = "pl",
    },
    {
        text = "Arabic",
        code = "ar",
    },
    {
        text = "Latin",
        code = "la",
    },
    {
        text = "Hebrew",
        code = "he",
    },
    {
        text = "Traditional Chinese",
        code = "zh-Hant",
    },
    {
        text = "Turkish",
        code = "tr",
    },
    {
        text = "Hungarian",
        code = "hu",
    },
    {
        text = "Czech",
        code = "cs",
    },
    {
        text = "Swedish",
        code = "sv",
    },
    {
        text = "Danish",
        code = "da",
    },
    {
        text = "Korean",
        code = "ko",
    },
    {
        text = "Ukrainian",
        code = "uk",
    },
    {
        text = "Indonesian",
        code = "id",
    },
    {
        text = "Greek",
        code = "el",
    },
    {
        text = "Romanian",
        code = "ro",
    },
    {
        text = "Lithuanian",
        code = "lt",
    },
    {
        text = "Bangla",
        code = "bn",
    },
    {
        text = "Catalan",
        code = "ca",
    },
    {
        text = "Norwegian",
        code = "no",
    },
    {
        text = "Afrikaans",
        code = "af",
    },
    {
        text = "Finnish",
        code = "fi",
    },
    {
        text = "Croatian",
        code = "hr",
    },
    {
        text = "Serbian",
        code = "sr",
    },
    {
        text = "Thai",
        code = "th",
    },
    {
        text = "Hindi",
        code = "hi",
    },
    {
        text = "Irish",
        code = "ga",
    },
    {
        text = "Latvian",
        code = "lv",
    },
    {
        text = "Persian",
        code = "fa",
    },
    {
        text = "Vietnamese",
        code = "vi",
    },
    {
        text = "Slovak",
        code = "sk",
    },
    {
        text = "Kannada",
        code = "kn",
    },
    {
        text = "Tibetan",
        code = "bo",
    },
    {
        text = "Welsh",
        code = "cy",
    },
    {
        text = "Javanese",
        code = "jv",
    },
    {
        text = "Urdu",
        code = "ur",
    },
    {
        text = "Yiddish",
        code = "yi",
    },
    {
        text = "Armenian",
        code = "hy",
    },
    {
        text = "Belarusian",
        code = "be",
    },
    {
        text = "Kinyarwanda",
        code = "rw",
    },
    {
        text = "Tamil",
        code = "ta",
    },
    {
        text = "Kazakh",
        code = "kk",
    },
    {
        text = "Slovenian",
        code = "sl",
    },
    {
        text = "Malayalam",
        code = "ml",
    },
    {
        text = "Shan",
        code = "shn",
    },
    {
        text = "Mongolian",
        code = "mn",
    },
    {
        text = "Georgian",
        code = "ka",
    },
    {
        text = "Marathi",
        code = "mr",
    },
    {
        text = "Esperanto",
        code = "eo",
    },
    {
        text = "Estonian",
        code = "et",
    },
    {
        text = "Telugu",
        code = "te",
    },
    {
        text = "Filipino",
        code = "fil",
    },
    {
        text = "Gujarati",
        code = "gu",
    },
    {
        text = "Galician",
        code = "gl",
    },
    {
        text = "Kyrgyz",
        code = "ky",
    },
    {
        text = "Malay",
        code = "ms",
    },
    {
        text = "Azerbaijani",
        code = "az",
    },
    {
        text = "Swahili",
        code = "sw",
    },
    {
        text = "Quechua",
        code = "qu",
    },
    {
        text = "Punjabi",
        code = "pa",
    },
    {
        text = "Bashkir",
        code = "ba",
    },
    {
        text = "Albanian",
        code = "sq",
    },
    {
        text = "Uzbek",
        code = "uz",
    },
    {
        text = "Bosnian",
        code = "bs",
    },
    {
        text = "Basque",
        code = "eu",
    },
    {
        text = "Burmese",
        code = "my",
    },
    {
        text = "Amharic",
        code = "am",
    },
    {
        text = "Kurdish",
        code = "ku",
    },
    {
        text = "Western Frisian",
        code = "fy",
    },
    {
        text = "Zulu",
        code = "zu",
    },
    {
        text = "Pashto",
        code = "ps",
    },
    {
        text = "Nepali",
        code = "ne",
    },
    {
        text = "Somali",
        code = "so",
    },
    {
        text = "Uyghur",
        code = "ug",
    },
    {
        text = "Oromo",
        code = "om",
    },
    {
        text = "Macedonian",
        code = "mk",
    },
    {
        text = "Haitian Creole",
        code = "ht",
    },
    {
        text = "Lao",
        code = "lo",
    },
    {
        text = "Tatar",
        code = "tt",
    },
    {
        text = "Sinhala",
        code = "si",
    },
    {
        text = "Central Kurdish",
        code = "ckb",
    },
    {
        text = "Tajik",
        code = "tg",
    },
    {
        text = "Shona",
        code = "sn",
    },
    {
        text = "Sundanese",
        code = "su",
    },
    {
        text = "Norwegian Bokmål",
        code = "nb",
    },
    {
        text = "Malagasy",
        code = "mg",
    },
    {
        text = "Xhosa",
        code = "xh",
    },
    {
        text = "Hausa",
        code = "ha",
    },
    {
        text = "Sindhi",
        code = "sd",
    },
    {
        text = "Nyanja",
        code = "ny",
    },
}
-- file types KOReader can open
local EBOOK_FILE_TYPES = { "epub", "mobi", "azw", "fb2", "prc" }
local COMIC_FILE_TYPES = { "cbr", "cbz" }
local DOCUMENT_FILE_TYPES = { "pdf", "txt", "rtf", "doc", "docx", "odt", "djvu" }
local IMAGE_FILE_TYPES = { "jpg", "tif", "pdb" }
local WEB_FILE_TYPES = { "chm", "htm", "html", "htmlz" }
local AVAILABLE_FILE_TYPES = {}
for __, file_types in ipairs({
    EBOOK_FILE_TYPES,
    COMIC_FILE_TYPES,
    DOCUMENT_FILE_TYPES,
    IMAGE_FILE_TYPES,
    WEB_FILE_TYPES,
}) do
    for __, file_type in ipairs(file_types) do
        table.insert(AVAILABLE_FILE_TYPES, file_type)
    end
end
-- Library Genesis topics
local AVAILABLE_BOOK_TYPES = {
    {
        text = _("Fiction"),
        code = "fiction",
    },
    {
        text = _("Non-fiction"),
        code = "nonfiction",
    },
    {
        text = _("Comics"),
        code = "comics",
    },
    {
        text = _("Magazines"),
        code = "magazines",
    },
    {
        text = _("Scientific articles"),
        code = "articles",
    },
    {
        text = _("Standards"),
        code = "standards",
    },
}
-- the codes they're saved as
local BOOK_TYPE_CODES = {}
for __, book_type in ipairs(AVAILABLE_BOOK_TYPES) do
    table.insert(BOOK_TYPE_CODES, book_type.code)
end

-- how long searches and mirrors can be cached for
local AVAILABLE_CACHE_EXPIRY_DAYS = { 1, 3, 7, 14, 30 }
-- book types saved when searching Anna's Archive
local OLD_BOOK_TYPES = {
    book_fiction = "fiction",
    book_nonfiction = "nonfiction",
    book_comic = "comics",
    standards_document = "standards",
}

-- the settings each given a getter and setter below: the type each is saved as (a table being a list), and its default
local SCHEMA = {
    show_book_covers = { type = "boolean", default = true, fill = true },
    -- looking the sites up with DNS over HTTPS (see CurlUtil.applyEncryptedDns), for networks whose own DNS blocks them
    encrypted_dns = { type = "boolean", default = false },
    -- automatically, once per session
    check_for_updates = { type = "boolean", default = true, fill = true },
    search_cache_expiry_days = { type = "number", default = 14, fill = true },
    mirror_cache_expiry_days = { type = "number", default = 7, fill = true },
    -- the plugin version the last time KOReader was started
    last_version = { type = "string" },
    -- when the latest release was last looked up, as the time in seconds
    last_update_check = { type = "number" },
    -- the plugin version that updating to was turned down, so it isn't offered again automatically
    skipped_version = { type = "string" },
    -- the sites the search box searches (see Sites) until others are ticked: all of them, Z-Library once logged into
    search_sources = { type = "table", default = { "zlib", "libgen", "archive", "gutenberg" }, at_least_one = true },
    -- what was last searched for, most recent first (see addRecentSearch)
    recent_searches = { type = "table", default = {} },
    preferred_languages = { type = "table", default = { "en" }, fill = true },
    -- every file type KOReader can open by default, and only those still offered, dropping azw3 and the others it can't
    preferred_file_types = {
        type = "table",
        default = AVAILABLE_FILE_TYPES,
        allowed = AVAILABLE_FILE_TYPES,
        fill = true,
    },
    -- every kind of book by default, and only those still offered, with those saved searching Anna's Archive renamed
    preferred_book_types = {
        type = "table",
        default = BOOK_TYPE_CODES,
        allowed = BOOK_TYPE_CODES,
        renamed = OLD_BOOK_TYPES,
        fill = true,
    },
}

local function settingsPath()
    return DataStorage:getSettingsDir() .. "/kindlefetch_settings.lua"
end

-- opened once and kept, as reading the file from storage for every setting is slow on an e-reader
local cached_file
local function getSettingsFile()
    if not cached_file then
        cached_file = LuaSettings:open(settingsPath())
    end
    return cached_file
end

-- whether two settings are the same, tables by what's in them, such as the libraries, each a table in a list
local function sameSetting(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not sameSetting(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

-- a list of its own, so that changing a list that's handed out can't change a default
local function copy(value)
    return type(value) == "table" and { unpack(value) } or value
end

-- the strings in a list, leaving out anything else, which a list of languages or searches is never saved with
local function strings(list)
    local kept = {}
    for __, value in ipairs(list) do
        if type(value) == "string" then
            table.insert(kept, value)
        end
    end
    return kept
end

local function contains(list, value)
    for __, item in ipairs(list) do
        if item == value then
            return true
        end
    end
    return false
end

-- a setting as saved, or its default if unsaved or of the wrong type, as that could leave the plugin out of the menu
function KindleFetchSettings:getSetting(name)
    local value = getSettingsFile():readSetting(name)
    -- (nil for those read by methods of their own, such as the libraries, which are given as they were saved)
    local setting = SCHEMA[name]

    if value == nil then
        return setting and copy(setting.default)
    end

    if setting and type(value) ~= setting.type then
        LogUtil.warn("ignoring", name, "as it's saved as a", type(value), "rather than a", setting.type)
        return copy(setting.default)
    end
    -- the lists of languages, file types, book types and searches
    if setting and setting.type == "table" then
        return strings(value)
    end

    return value
end
-- save data as name, then read it back, as LuaSettings doesn't say when it can't: true, or nil and why not
local function save(name, data)
    local settings_file = getSettingsFile()
    settings_file:saveSetting(name, data)
    settings_file:flush()
    if not sameSetting(LuaSettings:open(settingsPath()):readSetting(name), data) then
        LogUtil.warn("could not save", name, "in", settingsPath())
        return nil, _("Kindle Fetch's settings couldn't be saved")
    end
    return true
end

function KindleFetchSettings:setSetting(name, data)
    local ok, err = save(name, data)
    if not ok then
        return nil, err
    end

    if type(data) ~= "table" then
        LogUtil.debug("updated", name, "to", data)
    else
        LogUtil.debug("updated", name, "to", table.concat(data, ", "))
    end

    return true
end

-- a setting in SCHEMA as it's used: as saved or its default, a list keeping only the values it can still have
local function read(name, setting)
    local value = KindleFetchSettings:getSetting(name)
    if setting.type ~= "table" then
        return value
    end
    local list = {}
    for __, item in ipairs(value) do
        -- e.g. a book type as it was saved when searching Anna's Archive
        item = setting.renamed and setting.renamed[item] or item
        if not setting.allowed or contains(setting.allowed, item) then
            table.insert(list, item)
        end
    end
    -- none of those chosen are offered any more, rather than every one being turned off, or none are where one must be
    if #list == 0 and (#value > 0 or setting.at_least_one) then
        return copy(setting.default)
    end
    return list
end

-- the end of a setting's getter and setter's names, e.g. ShowBookCovers for show_book_covers
local function accessorName(name)
    return (("_" .. name):gsub("_(%l)", string.upper))
end

-- getShowBookCovers and setShowBookCovers, and the same for each setting in SCHEMA
for name, setting in pairs(SCHEMA) do
    KindleFetchSettings["get" .. accessorName(name)] = function()
        return read(name, setting)
    end
    -- returning true, or nil and why not (see save)
    KindleFetchSettings["set" .. accessorName(name)] = function(__, value)
        return KindleFetchSettings:setSetting(name, value)
    end
end

-- fill in missing or outdated settings, writing only on change, as this runs whenever the file manager or a book opens
function KindleFetchSettings:load()
    local settings_file = getSettingsFile()
    local changed = false
    local function fill(name, value)
        if not sameSetting(settings_file:readSetting(name), value) then
            settings_file:saveSetting(name, value)
            changed = true
        end
    end

    -- (keeping one that has gone missing, as it may be back, e.g. on an SD card that has been taken out)
    if not StringUtil.assertValidString(settings_file:readSetting("download_dir")) then
        local download_dir = self:getDownloadDir()
        if FileUtil.isValidDirectory(download_dir) then
            fill("download_dir", download_dir)
        end
    end
    -- each SCHEMA says to fill, as it's used, e.g. with old book types renamed (the others are saved once changed)
    for name, setting in pairs(SCHEMA) do
        if setting.fill then
            fill(name, read(name, setting))
        end
    end

    if changed then
        settings_file:flush()
        LogUtil.debug("saved the settings that were missing or out of date")
    end
end

function KindleFetchSettings:getAvailableCacheExpiryDays()
    return AVAILABLE_CACHE_EXPIRY_DAYS
end

-- curl_update_declined (the curl version turned down, not offered again unless asked), or true from older versions
function KindleFetchSettings:getCurlUpdateDeclined()
    local declined = getSettingsFile():readSetting("curl_update_declined")
    if declined == true or type(declined) == "string" then
        return declined
    end
end
-- or nil, once it's been updated
function KindleFetchSettings:setCurlUpdateDeclined(version)
    return KindleFetchSettings:setSetting("curl_update_declined", version or nil)
end

-- the most recent searches kept (see recent_searches in SCHEMA)
local MAX_RECENT_SEARCHES = 10
-- once each, whatever its capitals, as Library Genesis finds the same books either way
function KindleFetchSettings:addRecentSearch(query)
    local searches = { query }
    for __, search in ipairs(self:getRecentSearches()) do
        if search:lower() ~= query:lower() and #searches < MAX_RECENT_SEARCHES then
            table.insert(searches, search)
        end
    end
    return KindleFetchSettings:setRecentSearches(searches)
end
function KindleFetchSettings:clearRecentSearches()
    return KindleFetchSettings:setRecentSearches({})
end

-- libraries (OPDS catalogues added, see Libraries) saved as they should be, keeping the logins they ask for each time
function KindleFetchSettings:getLibraries()
    local saved = getSettingsFile():readSetting("libraries")
    local libraries = {}
    for __, entry in ipairs(type(saved) == "table" and saved or {}) do
        local library = SavedLibrary.fromTable(entry)
        if library then
            table.insert(libraries, library:toTable())
        end
    end
    return libraries
end
-- not logged, as the passwords log into the libraries. returns true, or nil and why not
function KindleFetchSettings:setLibraries(libraries)
    local ok, err = save("libraries", libraries)
    if not ok then
        return nil, err
    end
    LogUtil.debug("saved", #libraries, "libraries")
    return true
end

-- zlib_account (the Z-Library account logged into: its email, and its user id and key, kept instead of the password)
function KindleFetchSettings:getZlibAccount()
    local account = SavedZlibAccount.fromTable(KindleFetchSettings:getSetting("zlib_account"))
    return account and account:toTable()
end
-- or nil to forget it. not logged, as the key logs into the account
function KindleFetchSettings:setZlibAccount(account)
    local saved = SavedZlibAccount.fromTable(account)
    local ok, err = save("zlib_account", saved and saved:toTable())
    if not ok then
        return nil, err
    end
    -- the settings from before (KOReader's backup), which would still log in, and be read if these ever can't be
    if not account then
        os.remove(settingsPath() .. ".old")
    end
    return true
end

-- download_dir, or the default while the folder saved can't be found, which is kept, as it may be back
function KindleFetchSettings:getDownloadDir()
    local settings_file = getSettingsFile()
    local download_dir = settings_file:readSetting("download_dir")
    if StringUtil.assertValidString(download_dir) and not FileUtil.isValidDirectory(download_dir) then
        LogUtil.warn("the download folder", download_dir, "can't be found, so downloading to the default for now")
        download_dir = nil
    end

    if not StringUtil.assertValidString(download_dir) then
        download_dir = G_reader_settings:readSetting("home_dir") or ""

        if download_dir == "" then
            download_dir = "/mnt/us/documents"
            LogUtil.warn("settings home directory not found, defaulting to", download_dir)
        end

        if not FileUtil.isValidDirectory(download_dir) then
            -- home_dir is nil on some devices, so fall back to the koreader dir
            download_dir = Device.home_dir or lfs.currentdir()
            LogUtil.warn("documents directory does not exist, defaulting to device home directory", download_dir)
        end
    end

    return download_dir
end
-- returns true, or nil and why books can't be saved in the folder (see FileUtil.checkWritableDir)
function KindleFetchSettings:setDownloadDir(path)
    local ok, err = FileUtil.checkWritableDir(path)
    if not ok then
        LogUtil.warn("not downloading to", path, "as", err)
        return nil, err
    end

    local saved, save_err = save("download_dir", path)
    if not saved then
        return nil, save_err
    end
    LogUtil.debug("download directory set to", path)
    return true
end

function KindleFetchSettings:getAvailableLanguages()
    return AVAILABLE_LANGUAGES
end

function KindleFetchSettings:getEbookFileTypes()
    return EBOOK_FILE_TYPES
end
function KindleFetchSettings:getComicFileTypes()
    return COMIC_FILE_TYPES
end
function KindleFetchSettings:getDocumentFileTypes()
    return DOCUMENT_FILE_TYPES
end
function KindleFetchSettings:getImageFileTypes()
    return IMAGE_FILE_TYPES
end
function KindleFetchSettings:getWebFileTypes()
    return WEB_FILE_TYPES
end

function KindleFetchSettings:getAvailableBookTypes()
    return AVAILABLE_BOOK_TYPES
end

return KindleFetchSettings
