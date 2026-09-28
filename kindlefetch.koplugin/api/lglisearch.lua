local util = require("util")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local UrlApi = require("api.urlapi")

local LlgiSearch = {}

-- constants
local RESULTS_PER_PAGE = 50
-- Library Genesis topics for each preferred book type
local TOPICS = {
    fiction = "f",
    fiction_rus = "r",
    nonfiction = "l",
    comics = "c",
    magazines = "m",
    articles = "a",
    standards = "s"
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
end

local function parseBook(row, base_url)
    local cells = {}
    for cell in row:gmatch("<td[^>]*>(.-)</td>") do
        table.insert(cells, cell)
    end

    -- cover, title, authors, publisher, year, language, pages, size, extension, mirrors
    if #cells < 10 then
        LogUtil.warn("skipped row with missing cells")
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

function LlgiSearch.parseResults(html, base_url, languages, file_types)
    local books = {}
    local tbody = html:match('id="tablelibgen".-<tbody>(.-)</tbody>')
    if not tbody then
        return books
    end

    local language_names = languageNames(languages)
    for row in tbody:gmatch("<tr[^>]*>(.-)</tr>") do
        local book = parseBook(StringUtil.convertHtmlToText(row), base_url)
        if book and isPreferred(book, language_names, file_types) then
            table.insert(books, book)
            LogUtil.debug("new book found", book)
        end
    end

    return books
end

function LlgiSearch.buildParams(query, page, book_types)
    local params = {"req=" .. util.urlEncode(query), "res=" .. RESULTS_PER_PAGE, "columns%5B%5D=t",
                    "columns%5B%5D=a", "columns%5B%5D=s", "objects%5B%5D=f"}
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

-- main search function
function LlgiSearch:search(query, page, retrying)
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()

    -- check cache first
    local cached = SearchCache:get(query, page, languages, file_types, book_types)
    if cached then
        return cached
    end

    local base_urls = UrlApi:getLibgenUrls()
    if not base_urls then
        return nil, "no Library Genesis urls available"
    end

    local params = LlgiSearch.buildParams(query, page, book_types)
    local last_err
    for _, url in ipairs(base_urls) do
        LogUtil.debug("trying Library Genesis url:", url)
        local html, err = HttpUtil.getBody(string.format("%s/index.php?%s", url, params))

        if html and html:find('id="tablelibgen"', 1, true) then
            local books = LlgiSearch.parseResults(html, url, languages, file_types)
            LogUtil.debug("parsed", #books, "books for", query)

            -- add new query result to cache before returning, unless empty as the page may have been an error
            if #books > 0 then
                SearchCache:set(books, query, page, languages, file_types, book_types)
            end
            return books
        end

        if html and isBlocked(html) then
            LogUtil.warn("search blocked by ddos protection on", url)
            last_err = BLOCKED_ERROR
        else
            LogUtil.warn("failed url:", url)
            last_err = err or "unexpected response from Library Genesis"
            -- delete from url cache
            UrlApi:deleteLibgenUrl(url)
        end
    end

    -- scrape new urls since all current have failed, and search again
    if not retrying and last_err ~= BLOCKED_ERROR then
        return LlgiSearch:search(query, page, true)
    end

    return nil, last_err or "all Library Genesis mirrors failed"
end

return LlgiSearch
