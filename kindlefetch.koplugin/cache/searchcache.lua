local KindleFetchCache = require("cache.cache")
local KindleFetchSettings = require("settings.settings")
local LogUtil = require("util.logutil")

return KindleFetchCache:new {
    filename = "kindlefetch_searchcache.lua",
    expiry = function()
        return KindleFetchSettings:getSearchCacheExpiryDays() * 24 * 60 * 60
    end,
    -- each search is around 25KB, and the whole cache is read and written at once
    max_entries = 100,

    -- the site searched (see Sources), as each finds different books
    makeKey = function(...)
        LogUtil.debug("data for makeKey:", ...)
        local source, query, page, languages, file_types, book_types = ...

        return table.concat({
            source,
            query,
            tostring(page),
            table.concat(languages, ","),
            table.concat(file_types, ","),
            table.concat(book_types, ","),
        }, "|")
    end,
}
