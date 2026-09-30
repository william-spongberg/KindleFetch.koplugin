-- HTML shaped like the pages the plugin scrapes, trimmed down to the parts its parsers rely on.

local fixtures = {}

-- Mirrors are scraped from the live Wikipedia pages, while every other page is served from web.pages
-- (url -> html, or a function returning html) so specs don't contact the mirrors themselves, unless
-- web.live is set.
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
        if web.live then
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
    return "<td>" .. (value or "") .. "</td>\n"
end

-- one row of Library Genesis' search results (index.php with covers=on), with the same markup as the real page
function fixtures.libgenRow(book)
    local tooltip = 'data-toggle="tooltip" data-placement="right" data-html="true" ' ..
                        'title="Add/Edit : 2021-06-18/2021-10-17; ID: 6518940<br>' .. (book.title or "") .. '"'
    local title = ""
    if book.series and book.issue then
        -- comics link the series and the issue number before the title
        title = '<b><a href="series.php?id=164150">' .. book.series .. ' </a><a ' .. tooltip ..
                    ' href="edition.php?id=317043"><i> ' .. book.issue .. '</i></a></b><br>'
    elseif book.series then
        title = "<b>" .. book.series .. "</b><br>"
    end
    -- some comic issues leave the title out of the page, apart from the tooltips
    if book.title and not book.title_in_tooltip_only then
        title = title .. "<a " .. tooltip .. ' href="edition.php?id=317043">' .. book.title .. " <i></i></a>"
    end
    if book.isbn then
        title = title .. "<br><a " .. tooltip .. ' href="edition.php?id=317043"><i><font color="green"> ' .. book.isbn ..
                    "</font></a></i>"
    end
    title = title .. ' <nobr><span class="badge badge-primary"><a data-toggle="tooltip" data-placement="bottom" ' ..
                'data-html="true" title="' .. (book.book_type or "Book") .. '">b</a></span> ' ..
                '<span class="badge badge-secondary"">f 6270247</span></nobr>'

    local cover = book.cover and ('<a href="edition.php?id=6270247"><img src="' .. book.cover ..
                      '" style="max-height:70px;max-width:150px;height:auto;width:auto;"></a>') or ""
    local mirrors = book.md5 and ('<a data-toggle="tooltip" data-placement="bottom" data-html="true" title="libgen" ' ..
                        'href="/ads.php?md5=' .. book.md5 .. '"><span class="badge badge-primary">1</span></a> ' ..
                        '<a data-toggle="tooltip" data-placement="bottom" data-html="true" title="Randombook" ' ..
                        'href="https://randombook.org/book/' .. book.md5 .. '"><span class="badge badge-primary">2</span></a>') or ""

    local cells = {cell(cover), cell(title), cell(book.authors), cell('<a href="publisher.php?id=17868">Ace</a>'),
                   cell(book.year and ("<nobr>" .. book.year .. "</nobr>")), cell(book.language), cell("412"),
                   cell(book.file_size and ('<nobr><a href="/file.php?id=6518940">' .. book.file_size .. "</a></nobr>")),
                   cell(book.file_type), cell(mirrors)}
    if book.cells then
        local unpack = table.unpack or unpack
        cells = {unpack(cells, 1, book.cells)}
    end
    return "<tr>\n" .. table.concat(cells) .. "</tr>\n"
end

function fixtures.libgenResults(books)
    local rows = {}
    for _, book in ipairs(books) do
        table.insert(rows, fixtures.libgenRow(book))
    end
    return '<html><head><title>Library Genesis</title></head><body><table class="table  table-striped" ' ..
               'id="tablelibgen"><thead><tr><th scope="col" class="first_col">Title</th></tr></thead><tbody>' ..
               table.concat(rows) .. "</tbody></table></body></html>"
end

fixtures.DUNE = {
    md5 = "24778aacb1d0844950bf463c145b3d21",
    cover = "/fictioncovers/2509000/24778aacb1d0844950bf463c145b3d21_small.jpg",
    image_url = "https://covers.example/fictioncovers/24778aacb1d0844950bf463c145b3d21_small.jpg",
    series = "Dune Chronicles",
    title = "Dune (Dune Chronicles, Book 1)",
    authors = "Frank Herbert, ",
    year = "1990",
    language = "English",
    file_type = "epub",
    file_size = "1 MB"
}

fixtures.MESSIAH = {
    md5 = "f5a2858c141b73a63f56f164a79acee8",
    cover = "/fictioncovers/7791000/f5a2858c141b73a63f56f164a79acee8_small.jpg",
    title = "Dune Messiah",
    authors = "Frank Herbert",
    year = "1987",
    language = "English",
    file_type = "pdf",
    file_size = "3 MB"
}

-- Library Genesis' ads.php page links to get.php with a download key
function fixtures.libgenAds(md5)
    return [[<html><body><table id="main"><tr><td><a href="get.php?md5=]] .. md5 ..
               [[&key=ABC123"><h2>GET</h2></a></td></tr></table></body></html>]]
end

return fixtures
