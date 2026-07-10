local util = require("util")
local logger = require("logger")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.search_cache")

local AnnasAPI = {}
AnnasAPI.base_url = "https://annas-archive.gl"

local function parseBookTable(html)
    local books = {}

    -- clean html
    html = StringUtil.cleanEmojis(html)
    html = StringUtil.convertHtmlToText(html)

    -- grab all table rows
    for row in html:gmatch('<tr class="group h%-full[^>]*>(.-)</tr>') do
        local book = {}
        local cells = {}

        -- extract all table cells
        for cell in row:gmatch('<td[^>]*>(.-)</td>') do
            table.insert(cells, cell)
        end

        if #cells >= 10 then
            -- Cell 0: Cover image + MD5
            book.md5 = cells[1]:match('href="/md5/([a-f0-9]+)')
            -- book.cover_url = cells[1]:match('src="([^"]+)"')
            -- Cell 1: Title
            book.raw_title = cells[2]:match('>([^<]+)</span>')
            book.title = StringUtil.removeParentheses(StringUtil.removeExtension(book.raw_title))

            -- Cell 2: Authors
            book.authors = cells[3]:match('>([^<]+)</span>')
            if not StringUtil.assertValidString(book.authors) then
                book.authors = "Unknown author"
            end
            -- Cell 3: Publisher
            -- Cell 4: Year
            book.year = cells[5]:match('>([^<]+)</span>')
            -- Cell 5: File paths
            -- Cell 6: Mirrors/Sources
            -- Cell 7: Language
            book.language = cells[8]:match('>([^<]+)</span>')
            -- Cell 8: Book type
            book.book_type = cells[9]:match('>([^<]+)</span>')
            -- Cell 9: File type
            book.file_type = cells[10]:match('>([^<]+)</span>')
            -- Cell 10: File size
            book.file_size = cells[11]:match('>([^<]+)</span>')

            -- at minimum need title + md5 for a valid book
            if book.title and book.md5 then
                table.insert(books, book)
                logger.info("KindleFetch: new book found", book)
            end
        else
            logger.info("KindleFetch: skipped row with missing cells", row)
        end
    end

    return books
end

-- main search function
function AnnasAPI:search(query, page)
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()

    -- check cache first
    local cached = SearchCache:get(
        query,
        page,
        languages,
        file_types,
        book_types
    )

    if cached then
        logger.info("KindleFetch: cache hit for query:", query, ". Returned book: ", cached)
        return cached
    end

    -- build params
    local params = {"page=" .. tostring(page), "display=table", "src=lgli", "q=" .. util.urlEncode(query)}
    for _, lang in ipairs(languages) do
        table.insert(params, "lang=" .. util.urlEncode(lang))
    end
    for _, ext in ipairs(file_types) do
        table.insert(params, "ext=" .. util.urlEncode(ext))
    end
    for _, content in ipairs(book_types) do
        table.insert(params, "content=" .. util.urlEncode(content))
    end

    -- create url
    local annas_url = string.format("%s/search?%s", self.base_url, table.concat(params, "&"))

    -- fetch page
    logger.info("KindleFetch: fetching search page", annas_url)
    local html, err = HttpUtil.getBody(annas_url)
    if not html then
        logger.warn("KindleFetch: failed to fetch search page for", query, err or "unknown error")
        return nil, err
    end
    logger.info("KindleFetch: search page fetched", #html, "bytes for", query)

    -- parse into books
    local books = parseBookTable(html)
    logger.info("KindleFetch: parsed", #books, "books for", query)

    -- add new query result to cache
    SearchCache:set(
        query,
        page,
        languages,
        file_types,
        book_types,
        books
    )

    return books
end

return AnnasAPI
