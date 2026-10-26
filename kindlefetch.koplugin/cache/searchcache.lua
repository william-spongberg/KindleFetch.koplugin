local KindleFetchCache = require("cache.cache")
local KindleFetchSettings = require("settings.settings")
local LogUtil = require("util.logutil")

local SearchCache = KindleFetchCache:new {
    filename = "kindlefetch_searchcache.lua",
    expiry = function()
        return KindleFetchSettings:getSearchCacheExpiryDays() * 24 * 60 * 60
    end,
    -- each search is around 25KB, and the whole cache is read and written at once
    max_entries = 100,

    -- the site (see Sites), as each finds different books, and the scope where given, as keys saved before have none
    makeKey = function(...)
        LogUtil.debug("data for makeKey:", ...)
        local source, query, page, languages, file_types, book_types, scope = ...

        local parts = {
            source,
            query,
            tostring(page),
            table.concat(languages, ","),
            table.concat(file_types, ","),
            table.concat(book_types, ","),
        }
        if scope then
            table.insert(parts, scope)
        end
        return table.concat(parts, "|")
    end,
}

return SearchCache
