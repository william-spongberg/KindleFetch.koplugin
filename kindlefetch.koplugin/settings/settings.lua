local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local Device = require("device")
local FileUtil = require("util.fileutil")
local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")
local lfs = require("libs/libkoreader-lfs")

local KindleFetchSettings = {}

-- default settings
local DEFAULTS = {
    show_book_covers = true,
    check_for_updates = true,
    search_cache_expiry_days = 14,
    mirror_cache_expiry_days = 7,
    download_dir = nil,
    preferred_languages = {"en"},
    preferred_file_types = {"epub", "pdf", "cbr", "cbz"},
    preferred_book_types = {"fiction", "comics"}
}

-- available settings
local AVAILABLE_LANGUAGES = {{
    text = "English",
    code = "en"
}, {
    text = "Spanish",
    code = "es"
}, {
    text = "French",
    code = "fr"
}, {
    text = "German",
    code = "de"
}, {
    text = "Italian",
    code = "it"
}, {
    text = "Portuguese",
    code = "pt"
}, {
    text = "Russian",
    code = "ru"
}, {
    text = "Chinese",
    code = "zh"
}, {
    text = "Japanese",
    code = "ja"
}, {
    text = "Dutch",
    code = "nl"
}, {
    text = "Bulgarian",
    code = "bg"
}, {
    text = "Polish",
    code = "pl"
}, {
    text = "Arabic",
    code = "ar"
}, {
    text = "Latin",
    code = "la"
}, {
    text = "Hebrew",
    code = "he"
}, {
    text = "Traditional Chinese",
    code = "zh-Hant"
}, {
    text = "Turkish",
    code = "tr"
}, {
    text = "Hungarian",
    code = "hu"
}, {
    text = "Czech",
    code = "cs"
}, {
    text = "Swedish",
    code = "sv"
}, {
    text = "Danish",
    code = "da"
}, {
    text = "Korean",
    code = "ko"
}, {
    text = "Ukrainian",
    code = "uk"
}, {
    text = "Indonesian",
    code = "id"
}, {
    text = "Greek",
    code = "el"
}, {
    text = "Romanian",
    code = "ro"
}, {
    text = "Lithuanian",
    code = "lt"
}, {
    text = "Bangla",
    code = "bn"
}, {
    text = "Catalan",
    code = "ca"
}, {
    text = "Norwegian",
    code = "no"
}, {
    text = "Afrikaans",
    code = "af"
}, {
    text = "Finnish",
    code = "fi"
}, {
    text = "Croatian",
    code = "hr"
}, {
    text = "Serbian",
    code = "sr"
}, {
    text = "Thai",
    code = "th"
}, {
    text = "Hindi",
    code = "hi"
}, {
    text = "Irish",
    code = "ga"
}, {
    text = "Latvian",
    code = "lv"
}, {
    text = "Persian",
    code = "fa"
}, {
    text = "Vietnamese",
    code = "vi"
}, {
    text = "Slovak",
    code = "sk"
}, {
    text = "Kannada",
    code = "kn"
}, {
    text = "Tibetan",
    code = "bo"
}, {
    text = "Welsh",
    code = "cy"
}, {
    text = "Javanese",
    code = "jv"
}, {
    text = "Urdu",
    code = "ur"
}, {
    text = "Yiddish",
    code = "yi"
}, {
    text = "Armenian",
    code = "hy"
}, {
    text = "Belarusian",
    code = "be"
}, {
    text = "Kinyarwanda",
    code = "rw"
}, {
    text = "Tamil",
    code = "ta"
}, {
    text = "Kazakh",
    code = "kk"
}, {
    text = "Slovenian",
    code = "sl"
}, {
    text = "Malayalam",
    code = "ml"
}, {
    text = "Shan",
    code = "shn"
}, {
    text = "Mongolian",
    code = "mn"
}, {
    text = "Georgian",
    code = "ka"
}, {
    text = "Marathi",
    code = "mr"
}, {
    text = "Esperanto",
    code = "eo"
}, {
    text = "Estonian",
    code = "et"
}, {
    text = "Telugu",
    code = "te"
}, {
    text = "Filipino",
    code = "fil"
}, {
    text = "Gujarati",
    code = "gu"
}, {
    text = "Galician",
    code = "gl"
}, {
    text = "Kyrgyz",
    code = "ky"
}, {
    text = "Malay",
    code = "ms"
}, {
    text = "Azerbaijani",
    code = "az"
}, {
    text = "Swahili",
    code = "sw"
}, {
    text = "Quechua",
    code = "qu"
}, {
    text = "Punjabi",
    code = "pa"
}, {
    text = "Bashkir",
    code = "ba"
}, {
    text = "Albanian",
    code = "sq"
}, {
    text = "Uzbek",
    code = "uz"
}, {
    text = "Bosnian",
    code = "bs"
}, {
    text = "Basque",
    code = "eu"
}, {
    text = "Burmese",
    code = "my"
}, {
    text = "Amharic",
    code = "am"
}, {
    text = "Kurdish",
    code = "ku"
}, {
    text = "Western Frisian",
    code = "fy"
}, {
    text = "Zulu",
    code = "zu"
}, {
    text = "Pashto",
    code = "ps"
}, {
    text = "Nepali",
    code = "ne"
}, {
    text = "Somali",
    code = "so"
}, {
    text = "Uyghur",
    code = "ug"
}, {
    text = "Oromo",
    code = "om"
}, {
    text = "Macedonian",
    code = "mk"
}, {
    text = "Haitian Creole",
    code = "ht"
}, {
    text = "Lao",
    code = "lo"
}, {
    text = "Tatar",
    code = "tt"
}, {
    text = "Sinhala",
    code = "si"
}, {
    text = "Central Kurdish",
    code = "ckb"
}, {
    text = "Tajik",
    code = "tg"
}, {
    text = "Shona",
    code = "sn"
}, {
    text = "Sundanese",
    code = "su"
}, {
    text = "Norwegian Bokmål",
    code = "nb"
}, {
    text = "Malagasy",
    code = "mg"
}, {
    text = "Xhosa",
    code = "xh"
}, {
    text = "Hausa",
    code = "ha"
}, {
    text = "Sindhi",
    code = "sd"
}, {
    text = "Nyanja",
    code = "ny"
}}
local EBOOK_FILE_TYPES = {"epub", "mobi", "azw", "azw3", "kfx", "fb2", "lit", "prc", "lrf", "snb", "updb"}
local COMIC_FILE_TYPES = {"cbr", "cbz"}
local DOCUMENT_FILE_TYPES = {"pdf", "txt", "rtf", "doc", "docx", "odt", "djvu"}
local IMAGE_FILE_TYPES = {"jpg", "tif", "pdb"}
local WEB_FILE_TYPES = {"chm", "htm", "html", "htmlz", "mht"}
-- Library Genesis topics
local AVAILABLE_BOOK_TYPES = {{
    text = "Fiction",
    code = "fiction"
}, {
    text = "Non-fiction",
    code = "nonfiction"
}, {
    text = "Comics",
    code = "comics"
}, {
    text = "Magazines",
    code = "magazines"
}, {
    text = "Scientific articles",
    code = "articles"
}, {
    text = "Standards",
    code = "standards"
}}
-- how long searches and mirrors can be cached for
local AVAILABLE_CACHE_EXPIRY_DAYS = {1, 3, 7, 14, 30}
-- book types saved when searching Anna's Archive
local OLD_BOOK_TYPES = {
    book_fiction = "fiction",
    book_nonfiction = "nonfiction",
    book_comic = "comics",
    standards_document = "standards"
}

local function getSettingsFile()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/kindlefetch_settings.lua")
end

function KindleFetchSettings:load()
    self:setDownloadDir(self:getDownloadDir())
    self:setShowBookCovers(self:getShowBookCovers())
    self:setCheckForUpdates(self:getCheckForUpdates())
    self:setSearchCacheExpiryDays(self:getSearchCacheExpiryDays())
    self:setMirrorCacheExpiryDays(self:getMirrorCacheExpiryDays())
    self:setPreferredLanguages(self:getPreferredLanguages())
    self:setPreferredFileTypes(self:getPreferredFileTypes())
    self:setPreferredBookTypes(self:getPreferredBookTypes())
end

-- util
function KindleFetchSettings:getSetting(name)
    local settings_file = getSettingsFile()
    local value = settings_file:readSetting(name)

    if value == nil then
        return DEFAULTS[name]
    end

    return value
end
function KindleFetchSettings:setSetting(name, data)
    local settings_file = getSettingsFile()
    settings_file:saveSetting(name, data)
    settings_file:flush()
    
    if type(data) ~= "table" then
        LogUtil.debug("updated", name, "to", data)
    else
        LogUtil.debug("updated", name, "to", table.concat(data, ", "))
    end
    
    return true
end

-- show_book_covers
function KindleFetchSettings:getShowBookCovers()
    return KindleFetchSettings:getSetting("show_book_covers")
end
function KindleFetchSettings:setShowBookCovers(bool)
    return KindleFetchSettings:setSetting("show_book_covers", bool)
end

-- check_for_updates (automatically, once per session)
function KindleFetchSettings:getCheckForUpdates()
    return KindleFetchSettings:getSetting("check_for_updates")
end
function KindleFetchSettings:setCheckForUpdates(bool)
    return KindleFetchSettings:setSetting("check_for_updates", bool)
end

-- search_cache_expiry_days / mirror_cache_expiry_days
function KindleFetchSettings:getSearchCacheExpiryDays()
    return KindleFetchSettings:getSetting("search_cache_expiry_days")
end
function KindleFetchSettings:setSearchCacheExpiryDays(days)
    return KindleFetchSettings:setSetting("search_cache_expiry_days", days)
end
function KindleFetchSettings:getMirrorCacheExpiryDays()
    return KindleFetchSettings:getSetting("mirror_cache_expiry_days")
end
function KindleFetchSettings:setMirrorCacheExpiryDays(days)
    return KindleFetchSettings:setSetting("mirror_cache_expiry_days", days)
end
function KindleFetchSettings:getAvailableCacheExpiryDays()
    return AVAILABLE_CACHE_EXPIRY_DAYS
end

-- last_version (plugin version the last time KOReader was started)
function KindleFetchSettings:getLastVersion()
    return KindleFetchSettings:getSetting("last_version")
end
function KindleFetchSettings:setLastVersion(version)
    return KindleFetchSettings:setSetting("last_version", version)
end

-- download_dir
function KindleFetchSettings:getDownloadDir()
    local settings_file = getSettingsFile()
    local download_dir = settings_file:readSetting("download_dir")

    if not StringUtil.assertValidString(download_dir) then
        local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/../settings.reader.lua")
        download_dir = settings:readSetting("home_dir") or ""

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
function KindleFetchSettings:setDownloadDir(path)
    if not FileUtil.isValidDirectory(path) then
        return false, "Invalid directory path"
    end

    local settings_file = getSettingsFile()
    settings_file:saveSetting("download_dir", path)
    settings_file:flush()
    LogUtil.debug("download directory set to", path)
    return true
end

-- preferred_languages
function KindleFetchSettings:getPreferredLanguages()
    return KindleFetchSettings:getSetting("preferred_languages")
end
function KindleFetchSettings:setPreferredLanguages(languages)
    return KindleFetchSettings:setSetting("preferred_languages", languages)
end
function KindleFetchSettings:getAvailableLanguages()
    return AVAILABLE_LANGUAGES
end

-- preferred_file_types
function KindleFetchSettings:getPreferredFileTypes()
    return KindleFetchSettings:getSetting("preferred_file_types")
end
function KindleFetchSettings:setPreferredFileTypes(file_types)
    return KindleFetchSettings:setSetting("preferred_file_types", file_types)
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

-- preferred_book_types
function KindleFetchSettings:getPreferredBookTypes()
    local book_types = {}
    for _, book_type in ipairs(KindleFetchSettings:getSetting("preferred_book_types")) do
        book_type = OLD_BOOK_TYPES[book_type] or book_type
        for _, available in ipairs(AVAILABLE_BOOK_TYPES) do
            if available.code == book_type then
                table.insert(book_types, book_type)
            end
        end
    end

    if #book_types == 0 then
        return DEFAULTS.preferred_book_types
    end
    return book_types
end
function KindleFetchSettings:setPreferredBookTypes(book_types)
    return KindleFetchSettings:setSetting("preferred_book_types", book_types)
end
function KindleFetchSettings:getAvailableBookTypes()
    return AVAILABLE_BOOK_TYPES
end

return KindleFetchSettings
