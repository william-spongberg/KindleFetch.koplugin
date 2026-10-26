local LogUtil = require("util.logutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local T = require("ffi/util").template
local _ = require("gettext")

-- a site books are searched for and downloaded from: each kind is a subclass (see extend), e.g. IaSearch
local Site = {
    -- the name it's shown with, and the one its books and saved searches are kept under (see Sites)
    NAME = nil,
    SOURCE = nil,
    -- whether searches are narrowed down to the book types chosen in the settings, as Library Genesis' are
    HAS_BOOK_TYPES = false,
    -- what a search can be narrowed down to, e.g. { "title", "author", "isbn" }, or nil where it can't be
    SCOPES = nil,
    -- whether it can only be searched once logged into (see ZlibLogin)
    NEEDS_LOGIN = false,
    -- whether a download link can be asked for again once the server it went to fails (see Downloader)
    NEW_LINK_WHEN_SERVER_FAILS = false,
    -- whether its searches are saved, to show again without a connection (not a library's, whose books change)
    SAVES_SEARCHES = true,
}
Site.__index = Site

-- a kind of site, with the fields and methods in fields, which has the rest of Site's
function Site:extend(fields)
    fields.__index = fields
    return setmetatable(fields, self)
end

-- the languages, file types and book types the settings narrow its searches down to
function Site:choices()
    return KindleFetchSettings:getPreferredLanguages(),
        KindleFetchSettings:getPreferredFileTypes(),
        self.HAS_BOOK_TYPES and KindleFetchSettings:getPreferredBookTypes() or {}
end

-- whether a page of results is saved from an earlier search, to show straight away, even offline
function Site:isCached(query, page, scope)
    if not self.SAVES_SEARCHES then
        return false
    end
    local languages, file_types, book_types = self:choices()
    local cached = SearchCache:get(self.SOURCE, query, page, languages, file_types, book_types, scope)
    return cached ~= nil and cached.books ~= nil
end

-- search from page, by scope where given: the books, or nil and why not, the page after or nil, and the results read
function Site:search(query, page, scope)
    local languages, file_types, book_types = self:choices()
    LogUtil.info(
        string.format(
            "searching %s for %q%s from page %d, in %s, as %s%s",
            self.NAME,
            query,
            scope and " by " .. scope or "",
            page,
            table.concat(languages, "/"),
            table.concat(file_types, "/"),
            self.HAS_BOOK_TYPES and ", from " .. table.concat(book_types, "/") or ""
        )
    )
    if self.SAVES_SEARCHES then
        local cached = SearchCache:get(self.SOURCE, query, page, languages, file_types, book_types, scope)
        if cached and cached.books then
            LogUtil.info("showing", #cached.books, "books saved from an earlier search")
            return cached.books, nil, cached.next_page
        end
    end

    local books, err, next_page, results_read = self:fetchResults({
        query = query,
        page = page,
        scope = scope,
        languages = languages,
        file_types = file_types,
        book_types = book_types,
    })
    -- unless none were found, as the page may have been an error
    if self.SAVES_SEARCHES and books and #books > 0 then
        SearchCache:set({
            books = books,
            next_page = next_page,
        }, self.SOURCE, query, page, languages, file_types, book_types, scope)
    end
    return books, err, next_page, results_read
end

-- what went wrong when the site answered with body (and status), or didn't answer at all (err)
function Site:explainFailure(body, err, status)
    if body and status and status >= 400 then
        return T(_("%1 answered with an error (HTTP %2), try again later"), self.NAME, status)
    elseif body then
        return T(_("unexpected response from %1"), self.NAME)
    end
    return T(_("%1 didn't answer (%2)"), self.NAME, err)
end

-- the address of the search's page of results, or nil where there's nothing to search for, or nil and why not
function Site:searchUrl()
    error(self.NAME .. " has no address for its results")
end

-- the books on a page of results at url, how many results it had, the page after (or nil) and how many in all, or nil
function Site:parsePage()
    error(self.NAME .. " can't read its results")
end

-- whether the site answering with this status means it found nothing, as Calibre's content server's 404 does
function Site:foundNothing()
    return false
end

-- note down how many of a page's results were kept, of how many there are in all, where total says
function Site:logPage(page, kept, results, next_page, total)
    LogUtil.info(
        string.format(
            "page %d of %s's %sresults: kept %d of its %d%s",
            page,
            self.NAME,
            total and total .. " " or "",
            kept,
            results,
            next_page and "" or ", the last"
        )
    )
end

-- the books on the search's page of results, as search returns them, from its address (see searchUrl and parsePage)
function Site:fetchResults(search)
    local url, url_err = self:searchUrl(search)
    if not url then
        if url_err then
            return nil, url_err
        end
        return {}, nil, nil, 0
    end

    local body, err, status = HttpUtil.getBody(url)
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    if self:foundNothing(status) then
        LogUtil.info(string.format("%s found no books for %q", self.NAME, search.query))
        return {}, nil, nil, 0
    end
    local books, results, next_page, total
    if body and not (status and status >= 400) then
        books, results, next_page, total = self:parsePage(body, url, search)
    end
    if not books then
        if body then
            LogUtil.warn(
                "unexpected search results from",
                self.NAME .. ": HTTP",
                status,
                #body,
                "bytes:",
                LogUtil.excerpt(body)
            )
        end
        return nil, self:explainFailure(body, err, status)
    end

    self:logPage(search.page, #books, results, next_page, total)
    return books, nil, next_page, results
end

-- the book's download link, then nil, nil and what the site lists its file as ({ md5, bytes }), or nil and why not
function Site:findDownloadLink()
    error(self.NAME .. " can't find download links")
end

return Site
