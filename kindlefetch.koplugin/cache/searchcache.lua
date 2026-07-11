local KindleFetchCache = require("cache.cache")
local logger = require("logger")

return KindleFetchCache:new{
    filename = "kindlefetch_searchcache.lua",
    expiry = 72 * 60 * 60, -- 72 hours
    max_entries = 100,

    makeKey = function(...)
        logger.info("KindleFetch: data for makeKey:", ...)
        local query, page, languages, file_types, book_types = ...

        return table.concat({query, tostring(page), table.concat(languages, ","),
                             table.concat(file_types, ","), table.concat(book_types, ",")}, "|")
    end
}
