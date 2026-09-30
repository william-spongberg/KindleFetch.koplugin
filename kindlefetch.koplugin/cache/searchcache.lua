local KindleFetchCache = require("cache.cache")
local KindleFetchSettings = require("settings.settings")
local LogUtil = require("util.logutil")

return KindleFetchCache:new {
    filename = "kindlefetch_searchcache.lua",
    expiry = function()
        return KindleFetchSettings:getSearchCacheExpiryDays() * 24 * 60 * 60
    end,
    max_entries = 1000,

    makeKey = function(...)
        LogUtil.debug("data for makeKey:", ...)
        local query, page, languages, file_types, book_types = ...

        return table.concat({
            query,
            tostring(page),
            table.concat(languages, ","),
            table.concat(file_types, ","),
            table.concat(book_types, ","),
        }, "|")
    end,
}
