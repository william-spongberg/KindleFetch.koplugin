local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local FileUtil = require("util.fileutil")
local StringUtil = require("util.stringutil")
local logger = require("logger")

local KindleFetchSettings = {}

-- default settings
local DEFAULTS = {
    download_dir = nil,
    preferred_languages = {"en"},
    preferred_file_types = {"epub", "pdf", "cbr", "cbz"}
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

local function getSettingsFile()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/kindlefetch.lua")
end

function KindleFetchSettings:load()
    self:setDownloadDir(self:getDownloadDir())
    self:setPreferredLanguages(self:getPreferredLanguages())
    self:setPreferredFileTypes(self:getPreferredFileTypes())
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
            logger.warn("KindleFetchSettings: home directory not found, defaulting to", download_dir)
        end

        if not FileUtil.isValidDirectory(download_dir) then
            download_dir = "/mnt/us"
            logger.warn("KindleFetchSettings: documents directory does not exist, defaulting to", download_dir)
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
    logger.info("KindleFetchSettings: download directory set to", path)
    return true
end

-- preferred_languages
function KindleFetchSettings:getPreferredLanguages()
    local settings_file = getSettingsFile()
    return settings_file:readSetting("preferred_languages") or DEFAULTS.preferred_languages
end
function KindleFetchSettings:setPreferredLanguages(languages)
    if type(languages) ~= "table" then
        languages = {languages}
    end

    local settings_file = getSettingsFile()
    settings_file:saveSetting("preferred_languages", languages)
    settings_file:flush()
    logger.info("KindleFetchSettings: preferred languages set to", table.concat(languages, ", "))
    return true
end
function KindleFetchSettings:getAvailableLanguages()
    return AVAILABLE_LANGUAGES
end

-- preferred_file_types
function KindleFetchSettings:getPreferredFileTypes()
    local settings_file = getSettingsFile()
    return settings_file:readSetting("preferred_file_types") or DEFAULTS.preferred_file_types
end
function KindleFetchSettings:setPreferredFileTypes(file_types)
    if type(file_types) ~= "table" then
        file_types = {file_types}
    end

    local settings_file = getSettingsFile()
    settings_file:saveSetting("preferred_file_types", file_types)
    settings_file:flush()
    logger.info("KindleFetchSettings: preferred file types set to", table.concat(file_types, ", "))
    return true
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

return KindleFetchSettings
