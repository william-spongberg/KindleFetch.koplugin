local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local ZlibAccount = require("api.zlibaccount")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches Z-Library as the account logged into (see ZlibAccount), and finds its books' download links (see Sources)
local ZlibSearch = {
    NAME = "Z-Library",
    -- searching it needs an account, logged into before searching (see ZlibLogin)
    NEEDS_LOGIN = true,
    -- its download links each go to one of its servers, some of which can fail for a while, and asking it for the
    -- same book's link again the same day doesn't count as another download (see findDownloadLink)
    NEW_LINK_WHEN_SERVER_FAILS = true,
    SOURCE = "zlib",
}

-- constants
local SOURCE = ZlibSearch.SOURCE
local RESULTS_PER_PAGE = 50
-- how many times to ask for a link that goes to another server than one that failed, as each goes to one of them,
-- picked at random
local LINK_ASKS = 4

-- the books whose links Z-Library has given this session, and on which day (as Z-Library counts them, by UTC), as
-- asking for one again the same day doesn't count as another of the account's downloads, so it can be once it has
-- downloaded as many as it can that day, as when the download failed
local links_given = {}

local function today()
    return os.date("!%Y-%m-%d")
end

-- the search for the query, as the form Z-Library's API is sent: in the languages, by their names (which is how
-- Z-Library knows them, unless every one is chosen), and the file types, from the given page of its results
function ZlibSearch.buildForm(query, page, languages, file_types)
    local form = { { "message", query } }
    local available = KindleFetchSettings:getAvailableLanguages()
    if #languages < #available then
        for __, code in ipairs(languages) do
            for __, language in ipairs(available) do
                if language.code == code then
                    table.insert(form, { "languages[]", language.text:lower() })
                end
            end
        end
    end
    for __, file_type in ipairs(file_types) do
        table.insert(form, { "extensions[]", file_type })
    end
    table.insert(form, { "page", page })
    table.insert(form, { "limit", RESULTS_PER_PAGE })
    return form
end

-- a field of a book as text, or nil when it's empty, or isn't text at all (e.g. JSON's null)
local function text(value)
    if type(value) == "number" then
        value = tostring(value)
    end
    if type(value) ~= "string" then
        return nil
    end
    value = StringUtil.trim(StringUtil.collapseWhitespace(StringUtil.convertHtmlToText(value)))
    return value ~= "" and value or nil
end

-- the book, or nil, and whether that's because it couldn't be read, rather than it not being in a preferred file type
local function parseBook(book, is_preferred)
    if type(book) ~= "table" then
        return nil, true
    end
    local id = tonumber(book.id)
    -- both of which are sent back in the address its download link is asked for at
    local hash = text(book.hash)
    hash = hash and hash:match("^%w+$")
    local title = text(book.title)
    local file_type = text(book.extension)
    file_type = file_type and file_type:lower()
    if not (id and hash and title and file_type) then
        LogUtil.warn("skipped a book without an id, hash, title or file type")
        return nil, true
    end
    -- in case Z-Library didn't keep to the file types it was asked for
    if not is_preferred[file_type] then
        LogUtil.debug("skipped", id, "as it isn't in a preferred file type")
        return nil
    end

    -- without the other ways of writing the authors' names, in brackets, or what's left of a name that's missing
    -- after them, e.g. "Austen, Jane &"
    local authors = StringUtil.cleanTitle(text(book.author) or ""):gsub("[,;&%s]+$", "")
    local year = tonumber(book.year)
    local cover = text(book.cover)
    return {
        source = SOURCE,
        id = SOURCE .. "_" .. id,
        zlib_id = id,
        hash = hash,
        -- (or after the book's id, when there's nothing in its title to name its file after)
        title = StringUtil.cleanFileName(title) ~= "" and StringUtil.cleanFileName(title) or SOURCE .. "_" .. id,
        display_title = StringUtil.cleanTitle(title),
        authors = authors ~= "" and authors or "Unknown author",
        year = year and year > 0 and tostring(year) or nil,
        language = text(book.language),
        file_type = file_type,
        file_size = text(book.filesizeString),
        -- the book is shown without a cover rather than asking curl for an address that isn't just an address
        image_url = StringUtil.isSafeUrl(cover) and cover or nil,
    }
end

-- the books in the preferred file types, from what Z-Library answers a search with, and how many of its books could
-- be read (which are the results read), or nil if it isn't that
function ZlibSearch.parseResults(data, file_types)
    if type(data) ~= "table" or type(data.books) ~= "table" then
        return nil
    end
    local is_preferred = {}
    for __, file_type in ipairs(file_types) do
        is_preferred[file_type] = true
    end

    local books, read = {}, 0
    for __, result in ipairs(data.books) do
        local book, unreadable = parseBook(result, is_preferred)
        if book then
            table.insert(books, book)
            LogUtil.debug("new book found", book)
        end
        if not unreadable then
            read = read + 1
        end
    end
    return books, read
end

-- whether there are results saved from an earlier search, which can be shown without an internet connection
function ZlibSearch:isCached(query, page)
    return SearchCache:hasPage(self, query, page)
end

-- the books on a page of Z-Library's results, as search returns them
local function fetchResults(query, page, languages, file_types)
    local data, err = ZlibAccount:request("/eapi/book/search", ZlibSearch.buildForm(query, page, languages, file_types))
    if not data then
        return nil, err
    end
    local books, read = ZlibSearch.parseResults(data, file_types)
    if not books then
        LogUtil.warn("Z-Library's answer to a search had no books in it")
        return nil, T(_("unexpected response from %1"), ZlibSearch.NAME)
    end
    -- none of them could be read, as when Z-Library has changed what it answers with
    if read == 0 and #data.books > 0 then
        return nil, Errors.UNREADABLE
    end

    local pagination = type(data.pagination) == "table" and data.pagination or {}
    local next_page = tonumber(pagination.next)
    if next_page and next_page <= page then
        next_page = nil
    end
    LogUtil.info(
        string.format(
            "page %d of %s's %s results: kept %d of its %d%s",
            page,
            ZlibSearch.NAME,
            tostring(tonumber(pagination.total_items) or "unknown"),
            #books,
            #data.books,
            next_page and "" or ", the last"
        )
    )
    return books, nil, next_page, read
end

-- search the given page of Z-Library's results, returning the books found, the page to carry on from (or nil once
-- there are no more results), and how many results were read to find them (as LlgiSearch:search does)
function ZlibSearch:search(query, page)
    return SearchCache:search(self, query, page, nil, function(languages, file_types)
        return fetchResults(query, page, languages, file_types)
    end)
end

-- the book's download link, which Z-Library only gives the account a few of a day, so it's only asked for while
-- the account has any left (each one it gives counts, whether or not the book downloads, but not the same book's
-- again the same day). when the book failed to download from failed_url, a link to another of its servers. otherwise
-- nil, and why not (HttpUtil.CANCELLED when called off)
function ZlibSearch.findDownloadLink(book, __, failed_url)
    local profile, err = ZlibAccount:request("/eapi/user/profile")
    if not profile then
        return nil, err
    end
    local user = type(profile.user) == "table" and profile.user or {}
    local downloaded, limit = tonumber(user.downloads_today), tonumber(user.downloads_limit)
    if downloaded and limit then
        -- unless it's this book's link that's asked for again, which doesn't count again
        if downloaded >= limit and not failed_url and links_given[book.zlib_id] ~= today() then
            LogUtil.warn(string.format("the account has downloaded the %d books a day Z-Library allows", limit))
            return nil,
                T(
                    _("Z-Library lets this account download %1 books a day, which it has today, so try again tomorrow"),
                    limit
                )
        end
        LogUtil.info(string.format("the account can download %d more of its %d books today", limit - downloaded, limit))
    end

    local failed_site = failed_url and LogUtil.site(failed_url)
    local link
    for __ = 1, failed_site and LINK_ASKS or 1 do
        local data
        data, err = ZlibAccount:request(string.format("/eapi/book/%d/%s/file", book.zlib_id, book.hash))
        if not data then
            return nil, err
        end
        link = type(data.file) == "table" and data.file.downloadLink
        if not StringUtil.isSafeUrl(link) then
            -- (without the link itself, which carries a key)
            LogUtil.warn(
                "Z-Library didn't give a download link that can be used, answering with",
                type(data.file) ~= "table" and "no file"
                    or type(link) == "string" and "a link to " .. LogUtil.site(link)
                    or "a link that's a " .. type(link)
            )
            return nil, _("Z-Library didn't give a download link")
        end
        links_given[book.zlib_id] = today()
        if LogUtil.site(link) ~= failed_site then
            break
        end
        LogUtil.info("Z-Library's link went to", failed_site, "again, which failed, so asking for another")
    end
    return link
end

return ZlibSearch
