local util = require("util")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local UrlCache = require("cache.urlcache")
local UrlApi = require("api.urlapi")

local AnnasAPI = {}

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
            book.image_url = cells[1]:match('src="([^"]+)"')
            -- Cell 1: Title
            local raw_title = cells[2]:match('>([^<]+)</span>')
            if raw_title and not raw_title:find("file:") and not raw_title:find("file might have issues") then
                book.title = StringUtil.cleanFileName(raw_title)
                book.display_title = StringUtil.truncate(book.title)
            end
            -- Cell 2: Authors
            book.authors = cells[3]:match('>([^<]+)</span>')
            if not StringUtil.assertValidString(book.authors) then
                book.authors = "Unknown author"
            else
                book.authors = StringUtil.truncate(book.authors)
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
            if not book.file_size then
                book.file_size = "0"
            end

            -- at minimum need title + md5 + file type for a valid book
            if book.title and book.md5 and book.file_type then
                table.insert(books, book)
                LogUtil.debug("new book found", book)
            else
                LogUtil.warn("skipped book with missing features")
            end
        else
            LogUtil.warn("skipped row with missing cells")
        end
    end

    return books
end

-- main search function
function AnnasAPI:search(query, page, retrying)
    retrying = retrying or false

    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    local book_types = KindleFetchSettings:getPreferredBookTypes()

    -- check cache first
    local cached = SearchCache:get(query, page, languages, file_types, book_types)

    if cached then
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

    -- get urls
    local base_urls = UrlApi:getAnnasUrls()
    if not base_urls then
        return nil, "no Anna's Archive URLs available"
    end

    local last_err
    for _, url in ipairs(base_urls) do
        local annas_url = string.format("%s/search?%s", url, table.concat(params, "&"))

        LogUtil.debug("trying Anna's Archive url:", url)

        local html, err = HttpUtil.getBody(annas_url)

        if html then
            LogUtil.debug("successfully fetched from url:", url)

            local books = parseBookTable(html)
            LogUtil.debug("parsed", #books, "books for", query)

            if books then
                -- add new query result to cache before returning
                SearchCache:set(books, query, page, languages, file_types, book_types)
                return books
            end

            return nil
        end

        LogUtil.warn("failed url:")
        last_err = err or "unknown error"

        -- delete from url cache
        UrlApi:deleteAnnasUrl(url)
    end

    -- scrape new urls since all current have failed, and search again
    if not retrying then
        AnnasAPI:search(query, page, true)
    end

    return nil, last_err or "all Anna's Archive mirrors failed"
end

return AnnasAPI
