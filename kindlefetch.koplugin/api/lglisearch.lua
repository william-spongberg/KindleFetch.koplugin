local util = require("util")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local UrlApi = require("api.urlapi")

local LlgiSearch = {}

-- constants
local RESULTS_PER_PAGE = 100
-- Library Genesis can't filter by language or file type, so a page of results may have few books to show.
-- Searches read its pages until they have this many books...
local MIN_BOOKS = 10
-- ...or have read this many pages
local MAX_PAGES = 5
-- Library Genesis topics for each preferred book type
local TOPICS = {
    fiction = "f",
    nonfiction = "l",
    comics = "c",
    magazines = "m",
    articles = "a",
    standards = "s",
}
local BLOCKED_ERROR = "Library Genesis is blocking automated searches right now, try again later"

local function stripTags(html)
    return StringUtil.trim(StringUtil.collapseWhitespace(html:gsub("<[^>]+>", " ")))
end

-- the title is the first edition link with text, after the series and issue links
local function parseTitle(cell)
    for text in cell:gmatch('href="edition%.php%?id=%d+"%s*>(.-)</a>') do
        text = stripTags(text:gsub("<i>.-</i>", ""))
        if text ~= "" then
            return text
        end
    end

    -- comic issues can leave the link without text, with the title only in its tooltip (after when it was added and
    -- its ID), e.g. "Hello, I'm Johnny Cash(Spire 1976)"
    for tooltip in cell:gmatch('title="([^"]*)"%s+href="edition%.php%?id=%d+"') do
        local text = stripTags(tooltip:match(".*<br>(.*)$") or "")
        if text ~= "" then
            return text
        end
    end

    -- or failing that, the series it's an issue of
    local series = stripTags(cell:match('href="series%.php%?id=%d+"%s*>(.-)</a>') or "")
    if series ~= "" then
        return series
    end
end

local function parseBook(row, base_url)
    local cells = {}
    for cell in row:gmatch("<td[^>]*>(.-)</td>") do
        table.insert(cells, cell)
    end

    -- cover, title, authors, publisher, year, language, pages, size, extension, mirrors
    if #cells < 10 then
        LogUtil.debug("skipped row with missing cells, e.g. the table's header")
        return nil
    end

    local book = {}
    book.md5 = cells[10]:match("md5=(%x+)")
    book.md5 = book.md5 and book.md5:lower()

    local image_path = cells[1]:match('src="([^"]+)"')
    if image_path then
        book.image_url = image_path:match("^https?://") and image_path or base_url .. "/" .. image_path:gsub("^/", "")
    end

    local raw_title = parseTitle(cells[2])
    if raw_title then
        book.title = StringUtil.cleanFileName(raw_title)
        book.display_title = StringUtil.truncate(book.title)
    end

    local authors = stripTags(cells[3]):gsub("[,;%s]+$", "")
    book.authors = StringUtil.assertValidString(authors) and StringUtil.truncate(authors) or "Unknown author"

    local year = stripTags(cells[5])
    book.year = year ~= "" and year ~= "0" and year or nil
    local language = stripTags(cells[6])
    book.language = language ~= "" and language or nil
    book.book_type = cells[2]:match('badge%-primary"><a[^>]-title="([^"]+)">%w+</a>')
    local file_type = stripTags(cells[9]):lower()
    book.file_type = file_type ~= "" and file_type or nil
    local file_size = stripTags(cells[8])
    book.file_size = file_size ~= "" and file_size or "0"

    -- at minimum need title + md5 + file type for a valid book
    if not (book.title and book.title ~= "" and book.md5 and book.file_type) then
        LogUtil.warn("skipped book with missing features")
        return nil
    end

    return book
end

-- whether the book matches the preferred languages and file types, which Library Genesis can't filter by
local function isPreferred(book, language_names, file_types)
    local file_type_ok = false
    for _, file_type in ipairs(file_types) do
        if book.file_type == file_type:lower() then
            file_type_ok = true
            break
        end
    end
    if not file_type_ok then
        return false
    end

    -- keep books with an unknown language
    if not book.language then
        return true
    end
    local language = book.language:lower()
    for _, name in ipairs(language_names) do
        if language:find(name:lower(), 1, true) then
            return true
        end
    end
    return false
end

local function languageNames(codes)
    local names = {}
    for _, code in ipairs(codes) do
        for _, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
            if language.code == code then
                table.insert(names, language.text)
            end
        end
    end
    return names
end

-- books in the preferred languages and file types, and the number of results on the page
function LlgiSearch.parseResults(html, base_url, languages, file_types)
    local books = {}
    local tbody = html:match('id="tablelibgen".-<tbody>(.-)</tbody>')
    if not tbody then
        return books, 0
    end

    local language_names = languageNames(languages)
    local results = 0
    for row in tbody:gmatch("<tr[^>]*>(.-)</tr>") do
        results = results + 1
        local book = parseBook(StringUtil.convertHtmlToText(row), base_url)
        if book and isPreferred(book, language_names, file_types) then
            table.insert(books, book)
            LogUtil.debug("new book found", book)
        end
    end

    return books, results
end

function LlgiSearch.buildParams(query, page, book_types)
    local params = {
        "req=" .. util.urlEncode(query),
        "res=" .. RESULTS_PER_PAGE,
        "columns%5B%5D=t",
        "columns%5B%5D=a",
        "columns%5B%5D=s",
        "objects%5B%5D=f",
    }
    for _, book_type in ipairs(book_types) do
        if TOPICS[book_type] then
            table.insert(params, "topics%5B%5D=" .. TOPICS[book_type])
        end
    end
    table.insert(params, "covers=on")
    table.insert(params, "filesuns=all")
    table.insert(params, "page=" .. tostring(page))
    return table.concat(params, "&")
end

local function isBlocked(html)
    return html:find("DDoS%-Guard") or html:find("Checking your browser", 1, true) or html:find("cf-chl", 1, true)
end

-- fetch a page of results from the first mirror that works, returning its html and the mirror
local function fetchResults(params, refresh)
    local base_urls, urls_err, wikipedia_answered = UrlApi:getLibgenUrls(refresh)
    if not base_urls then
        return nil,
            urls_err and not wikipedia_answered and UrlApi.NO_CONNECTION_ERROR or "no Library Genesis urls available"
    end

    local last_err
    -- mirrors that didn't answer at all, which may be down, or the device may be offline
    local unanswered = {}
    local answered = false
    for _, url in ipairs(base_urls) do
        local html, err, status = HttpUtil.getBody(string.format("%s/index.php?%s", url, params))
        answered = answered or html ~= nil or status ~= nil

        if html and html:find('id="tablelibgen"', 1, true) then
            for _, unanswered_url in ipairs(unanswered) do
                UrlApi:deleteLibgenUrl(unanswered_url)
            end
            return html, nil, url
        end

        if html and isBlocked(html) then
            LogUtil.warn(
                "searching",
                LogUtil.site(url),
                "was blocked by its DDoS protection (HTTP",
                status,
                #html,
                "bytes)"
            )
            last_err = BLOCKED_ERROR
        elseif html or status then
            -- it answered, but not with results: e.g. an error page, or a page Library Genesis has changed the layout of
            if html then
                LogUtil.warn(
                    "unexpected search page from",
                    LogUtil.site(url) .. ": HTTP",
                    status,
                    #html,
                    "bytes:",
                    html:gsub("<[^>]+>", " "):gsub("%s+", " "):sub(1, 200)
                )
            end
            last_err = err or "unexpected response from Library Genesis"
            UrlApi:deleteLibgenUrl(url)
        else
            table.insert(unanswered, url)
            last_err = err
        end
    end

    -- the internet is working if another mirror answered, or the mirrors were just looked up, so the ones that didn't
    -- are down. otherwise the device may be offline, so keep them
    if answered or refresh then
        for _, url in ipairs(unanswered) do
            UrlApi:deleteLibgenUrl(url)
        end
    end

    -- look the mirrors up again, in case they've moved, and search again
    if not refresh and last_err ~= BLOCKED_ERROR then
        LogUtil.info("every mirror failed, looking them up again")
        return fetchResults(params, true)
    end

    return nil, last_err or "all Library Genesis mirrors failed"
end

-- search from the given page of Library Genesis' results, returning the books found and the page to carry on
-- from, or nil once there are no more results
-- whether there are results saved from an earlier search, which can be shown without an internet connection
function LlgiSearch:isCached(query, page)
    local cached = SearchCache:get(
        query,
        page,
        KindleFetchSettings:getPreferredLanguages(),
        KindleFetchSettings:getPreferredFileTypes(),
        KindleFetchSettings:getPreferredBookTypes()
    )
    return cached ~= nil and cached.books ~= nil
end

function LlgiSearch:search(query, page)
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()

    -- check cache first (ignoring results cached by older versions, which were just a list of books)
    LogUtil.info(
        string.format(
            "searching for %q from page %d, in %s, as %s, from %s",
            query,
            page,
            table.concat(languages, "/"),
            table.concat(file_types, "/"),
            table.concat(book_types, "/")
        )
    )
    local cached = SearchCache:get(query, page, languages, file_types, book_types)
    if cached and cached.books then
        LogUtil.info("showing", #cached.books, "books saved from an earlier search")
        return cached.books, nil, cached.next_page
    end

    local books = {}
    -- Library Genesis can list the same file more than once, e.g. for each edition it's in
    local seen = {}
    local next_page = page
    for _ = 1, MAX_PAGES do
        local html, err, url = fetchResults(LlgiSearch.buildParams(query, next_page, book_types))
        if not html then
            -- show the books found so far, carrying on from the page that failed
            if #books > 0 then
                break
            end
            return nil, err
        end

        local page_books, results = LlgiSearch.parseResults(html, url, languages, file_types)
        LogUtil.info(
            string.format(
                "page %d from %s: kept %d of its %d results",
                next_page,
                LogUtil.site(url),
                #page_books,
                results
            )
        )
        for _, book in ipairs(page_books) do
            if not seen[book.md5] then
                seen[book.md5] = true
                table.insert(books, book)
            end
        end

        if results < RESULTS_PER_PAGE then
            next_page = nil
            break
        end
        next_page = next_page + 1
        if #books >= MIN_BOOKS then
            break
        end
    end

    LogUtil.info(
        string.format(
            "found %d books for %q%s",
            #books,
            query,
            next_page and ", and more from page " .. next_page or ""
        )
    )
    -- add new query result to cache before returning, unless empty as the page may have been an error
    if #books > 0 then
        SearchCache:set({
            books = books,
            next_page = next_page,
        }, query, page, languages, file_types, book_types)
    end
    return books, nil, next_page
end

return LlgiSearch
