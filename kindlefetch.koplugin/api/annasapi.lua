local util = require("util")
local logger = require("logger")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("util.settings")

local AnnasAPI = {}
AnnasAPI.base_url = "https://annas-archive.gl"

local function parseBookTable(html)
    local books = {}

    -- clean html
    html = StringUtil.cleanEmojis(html)

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
            book.title = cells[2]:match('>([^<]+)</span>')
            book.safe_title = StringUtil.removeParentheses(StringUtil.removeExtension(book.title))

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
function AnnasAPI:search(query)
    local endpoint = string.format("%s/search?page=1&display=table&src=lgli&lang=en&q=%s", self.base_url,
        util.urlEncode(query))
    logger.info("KindleFetch: fetching search page", endpoint)

    local html, err = HttpUtil.getBody(endpoint)
    if not html then
        logger.warn("KindleFetch: failed to fetch search page for", query, err or "unknown error")
        return nil, err
    end
    logger.info("KindleFetch: search page fetched", #html, "bytes for", query)

    local books = parseBookTable(html)
    logger.info("KindleFetch: parsed", #books, "results for", query)

    return books
end

return AnnasAPI
