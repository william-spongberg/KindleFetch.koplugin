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

    -- the site searched (see Sources), as each finds different books, and what the search was narrowed to, where it
    -- was (e.g. only the books' authors), as searches that weren't were saved before
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

-- what a search of site (see Sources) is narrowed down to, as chosen in the settings: the languages, file types and,
-- where the site has them, book types
local function choices(site)
    return KindleFetchSettings:getPreferredLanguages(),
        KindleFetchSettings:getPreferredFileTypes(),
        site.HAS_BOOK_TYPES and KindleFetchSettings:getPreferredBookTypes() or {}
end

-- whether there are results saved from an earlier search of site, which can be shown without an internet connection
function SearchCache:hasPage(site, query, page, scope)
    local languages, file_types, book_types = choices(site)
    local cached = self:get(site.SOURCE, query, page, languages, file_types, book_types, scope)
    return cached ~= nil and cached.books ~= nil
end

-- search site from the given page of its results, narrowed down by scope, where given, returning what
-- fetch(languages, file_types, book_types) does: the books found, or nil and why not, then the page to carry on from
-- (or nil once there are no more results) and how many results were read to find them. that's the books saved from an
-- earlier search, where there are any (with how many were read unknown, so nil), otherwise they're saved
function SearchCache:search(site, query, page, scope, fetch)
    local languages, file_types, book_types = choices(site)
    LogUtil.info(
        string.format(
            "searching %s for %q%s from page %d, in %s, as %s%s",
            site.NAME,
            query,
            scope and " by " .. scope or "",
            page,
            table.concat(languages, "/"),
            table.concat(file_types, "/"),
            site.HAS_BOOK_TYPES and ", from " .. table.concat(book_types, "/") or ""
        )
    )

    local cached = self:get(site.SOURCE, query, page, languages, file_types, book_types, scope)
    if cached and cached.books then
        LogUtil.info("showing", #cached.books, "books saved from an earlier search")
        return cached.books, nil, cached.next_page
    end

    local books, err, next_page, results_read = fetch(languages, file_types, book_types)
    -- unless none were found, as the page may have been an error
    if books and #books > 0 then
        self:set({
            books = books,
            next_page = next_page,
        }, site.SOURCE, query, page, languages, file_types, book_types, scope)
    end
    return books, err, next_page, results_read
end

return SearchCache
