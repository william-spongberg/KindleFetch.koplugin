-- HTML shaped like the pages the plugin scrapes, trimmed down to the parts its parsers rely on.

local fixtures = {}

-- Mirrors are scraped from the live Wikipedia pages, while every other page is served from web.pages
-- (url -> html, or a function returning html) so specs never contact the mirrors themselves.
function fixtures.fakeWeb(helper)
    local web = {
        pages = {},
        fetched = {},
        scrapes = 0,
        wikipedia_down = false
    }
    helper.useLiveHttp()
    local HttpUtil = require("util.httputil")
    local fetchLive = HttpUtil.getBody
    HttpUtil.getBody = function(url)
        table.insert(web.fetched, url)
        if url:find("wikipedia.org", 1, true) then
            if web.wikipedia_down then
                return nil, "could not resolve host"
            end
            web.scrapes = web.scrapes + 1
            return fetchLive(url)
        end
        local page = web.pages[url]
        if type(page) == "function" then
            page = page()
        end
        if page then
            return page
        end
        return nil, "failed to connect to server"
    end
    return web
end

-- add a downloaded cover for md5 to the cover cache
function fixtures.cacheCover(helper, md5)
    local CurlUtil = require("util.curlutil")
    local download = CurlUtil.download
    CurlUtil.download = function(_, path)
        helper.writeFile(path, "jpeg")
        return true
    end
    require("cache.covercache"):download(md5, "https://covers.example/" .. md5 .. ".jpg")
    CurlUtil.download = download
end

-- scrape the current mirrors, then forget them so each spec starts without any cached
function fixtures.scrapeMirrors(web, getUrls, site)
    local mirrors = getUrls(require("api.urlapi"))
    assert(mirrors, "could not scrape " .. site .. " mirrors from Wikipedia, these specs need internet access")
    assert(#mirrors >= 2, "these specs need Wikipedia to list at least two " .. site .. " mirrors")
    require("cache.urlcache"):clear()
    web.fetched, web.scrapes = {}, 0
    return mirrors
end

local function cell(value)
    if value == nil then
        return '<td class="p-0"><span class="line-clamp-2"></span></td>'
    end
    return string.format('<td class="p-0"><span class="line-clamp-2">%s</span></td>', value)
end

-- one row of Anna's Archive's table view (display=table)
function fixtures.annasRow(book)
    local cover = '<td class="p-0"><a href="/md5/' .. (book.md5 or "") .. '" tabindex="-1">' ..
                      (book.image_url and ('<img class="w-[50px]" src="' .. book.image_url .. '" alt="">') or "") ..
                      '</a></td>'
    local cells = {cover, cell(book.title), cell(book.authors), cell(book.publisher or "Ace"), cell(book.year),
                   cell("lgli/fiction/dune.epub"), cell("lgli"), cell(book.language), cell(book.book_type),
                   cell(book.file_type), cell(book.file_size)}
    if book.cells then
        local unpack = table.unpack or unpack
        cells = {unpack(cells, 1, book.cells)}
    end
    return '<tr class="group h-full odd:bg-black/5">' .. table.concat(cells) .. '</tr>'
end

function fixtures.annasResults(books)
    local rows = {}
    for _, book in ipairs(books) do
        table.insert(rows, fixtures.annasRow(book))
    end
    return '<html><body><table class="text-sm w-full"><thead><tr><th>Cover</th></tr></thead><tbody>' ..
               table.concat(rows) .. '</tbody></table></body></html>'
end

fixtures.DUNE = {
    md5 = "d41d8cd98f00b204e9800998ecf8427e",
    image_url = "https://covers.example/zlib1/d41d8cd9.jpg",
    title = "Dune (Dune Chronicles, Book 1)",
    authors = "Frank Herbert",
    year = "1990",
    language = "English [en]",
    book_type = "📘 Book (fiction)",
    file_type = "epub",
    file_size = "1.2MB"
}

fixtures.MESSIAH = {
    md5 = "9e107d9d372bb6826bd81d3542a419d6",
    image_url = "https://covers.example/zlib1/9e107d9d.jpg",
    title = "Dune Messiah",
    authors = "Frank Herbert",
    year = "1987",
    language = "English [en]",
    book_type = "📘 Book (fiction)",
    file_type = "pdf",
    file_size = "3.4MB"
}

-- Library Genesis' ads.php page links to get.php with a download key
function fixtures.libgenAds(md5)
    return [[<html><body><table id="main"><tr><td><a href="get.php?md5=]] .. md5 ..
               [[&key=ABC123"><h2>GET</h2></a></td></tr></table></body></html>]]
end

return fixtures
