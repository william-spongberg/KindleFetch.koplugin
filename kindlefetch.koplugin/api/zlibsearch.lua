local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local KindleFetchSettings = require("settings.settings")
local Site = require("api.site")
local Book = require("api.book")
local ZlibAccount = require("api.zlibaccount")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches Z-Library as the account logged into (see ZlibAccount), and finds its books' download links (see Site)
local ZlibSearch = Site:extend {
    NAME = "Z-Library",
    -- searching it needs an account, logged into before searching (see ZlibLogin)
    NEEDS_LOGIN = true,
    -- its links each go to one of its servers, which can fail, and asking again the same day isn't another download
    NEW_LINK_WHEN_SERVER_FAILS = true,
    SOURCE = "zlib",
}

-- constants
local SOURCE = ZlibSearch.SOURCE
local RESULTS_PER_PAGE = 50
-- how many times to ask for a link to a server other than one that failed, as each goes to one picked at random
local LINK_ASKS = 4

-- the books given links this session, by UTC day, as asking again that day doesn't count, even once at the limit
local links_given = {}

local function today()
    return os.date("!%Y-%m-%d")
end

-- the search as the form Z-Library's API is sent: the languages by name, as it knows them (unless all are chosen)
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

    -- without the other ways of writing the authors' names, in brackets, or what's left of a missing name after them
    local authors = StringUtil.cleanTitle(text(book.author) or ""):gsub("[,;&%s]+$", "")
    local year = tonumber(book.year)
    local cover = text(book.cover)
    -- (named after its id where there's nothing in its title to name its file after)
    local book_id = SOURCE .. "_" .. id
    return Book.new(SOURCE, {
        id = book_id,
        zlib_id = id,
        hash = hash,
        title = title,
        authors = authors,
        year = year and year > 0 and tostring(year) or nil,
        language = text(book.language),
        file_type = file_type,
        file_size = text(book.filesizeString),
        -- the book is shown without a cover rather than asking curl for an address that isn't just an address
        image_url = StringUtil.isSafeUrl(cover) and cover or nil,
    }, book_id)
end

-- the books in the preferred file types from Z-Library's answer, and how many could be read (the results read), or nil
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

-- the books on the search's page of Z-Library's results, as Site:search returns them, asked for as a form
function ZlibSearch:fetchResults(search)
    local page, file_types = search.page, search.file_types
    local data, err =
        ZlibAccount:request("/eapi/book/search", ZlibSearch.buildForm(search.query, page, search.languages, file_types))
    if not data then
        return nil, err
    end
    local books, read = ZlibSearch.parseResults(data, file_types)
    if not books then
        LogUtil.warn("Z-Library's answer to a search had no books in it")
        return nil, T(_("unexpected response from %1"), self.NAME)
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
    self:logPage(page, #books, #data.books, next_page, tostring(tonumber(pagination.total_items) or "unknown"))
    return books, nil, next_page, read
end

-- the book's link, only asked for with downloads left today, as each link counts; with failed_url, another server's
function ZlibSearch:findDownloadLink(book, __, failed_url)
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
