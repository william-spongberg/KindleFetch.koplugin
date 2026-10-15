-- HTML shaped like the pages the plugin scrapes, trimmed down to the parts its parsers rely on.

local fixtures = {}

-- Mirrors are scraped from the live Wikipedia pages, while every other page is served from web.pages
-- (url -> html, or a function given the request's form and cookies, see HttpUtil.getBody, returning html, and the
-- HTTP status or what went wrong when it says) so specs don't contact the sites themselves, unless web.live is set.
-- web.requests keeps each request's form and cookies too
function fixtures.fakeWeb(helper)
    local web = {
        pages = {},
        fetched = {},
        requests = {},
        scrapes = 0,
        wikipedia_down = false,
    }
    helper.useLiveHttp()
    local HttpUtil = require("util.httputil")
    local fetchLive = HttpUtil.getBody
    -- live, with luasocket (see helper.useLiveHttp), whatever curl can do in the spec
    local function fetchWithLuasocket(url, opts)
        local CurlUtil = require("util.curlutil")
        local canFetch = CurlUtil.canFetch
        CurlUtil.canFetch = function()
            return false
        end
        local body, err, status = fetchLive(url, opts)
        CurlUtil.canFetch = canFetch
        return body, err, status
    end
    HttpUtil.getBody = function(url, opts)
        table.insert(web.fetched, url)
        table.insert(web.requests, { url = url, form = opts and opts.form, cookies = opts and opts.cookies })
        if url:find("wikipedia.org", 1, true) then
            -- (saying what went wrong, when it's given)
            if web.wikipedia_down then
                return nil, type(web.wikipedia_down) == "string" and web.wikipedia_down or "could not resolve host"
            end
            web.scrapes = web.scrapes + 1
            -- or a page given in its place, or what gives it, e.g. listing other mirrors once they've moved
            if type(web.pages[url]) == "function" then
                return web.pages[url]()
            elseif web.pages[url] then
                return web.pages[url]
            end
            return fetchWithLuasocket(url)
        end
        if web.live then
            return fetchWithLuasocket(url, opts)
        end
        local page, err, status = web.pages[url], nil, nil
        if type(page) == "function" then
            page, err, status = page(opts or {})
        end
        if page or err then
            return page, err, status
        end
        return nil, "failed to connect to server"
    end
    return web
end

-- what stands in for a cover, starting as a JPEG does (see FileCheck)
fixtures.JPEG = "\255\216\255\224jpeg"

-- how books of a few file types start (see FileCheck)
local BOOK_STARTS = {
    epub = "PK\3\4",
    pdf = "%PDF-1.7\n",
    mobi = string.rep("\0", 60) .. "BOOKMOBI",
}

-- what stands in for a book of the file type, starting as books in it do, as many bytes as given
function fixtures.bookFile(file_type, bytes)
    local start = BOOK_STARTS[file_type] or ""
    return (start .. string.rep("x", bytes)):sub(1, bytes)
end

-- add a downloaded cover for the book with the id to the cover cache
function fixtures.cacheCover(helper, id)
    local CurlUtil = require("util.curlutil")
    local download = CurlUtil.download
    CurlUtil.download = function(_, path)
        helper.writeFile(path, fixtures.JPEG)
        return true
    end
    require("cache.covercache"):download(id, "https://covers.example/" .. id .. ".jpg")
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

-- the website row of the infobox on Wikipedia's Z-Library page, linking to each of the sites given (e.g.
-- "z-lib.example"), as it does to its addresses, along with those on Tor and I2P, as the real page does
function fixtures.wikipediaZlib(sites)
    local items = {}
    for _, site in ipairs(sites) do
        table.insert(
            items,
            '<li><a rel="mw:ExtLink nofollow" href="https://'
                .. site
                .. '/" class="external free">https://'
                .. site
                .. '/</a><sup class="reference"><a href="./Z-Library#cite_note-1">[1]</a></sup></li>'
        )
    end
    table.insert(
        items,
        "<li><span>bookszlibb74ugqojhzhg2a63w5i2atv5bqarulgczawnbmsb6s6qead.onion</span> (accessing via "
            .. '<a href="https://en.wikipedia.org/wiki/Tor_(network)">Tor</a>)</li>'
    )
    table.insert(
        items,
        '<li><a href="http://zlib24th6ptyb4ibzn3tj2cndqafs6rhm4ed4gruxztaaco35lka.b32.i2p">I2P</a></li>'
    )
    return '<html><body><table class="infobox vcard"><tbody><tr><th scope="row" class="infobox-label">Type of site</th>'
        .. '<td class="infobox-data">Shadow library</td></tr><tr><th scope="row" class="infobox-label">Website</th>'
        .. '<td class="infobox-data url"><div class="plainlist"><ul>'
        .. table.concat(items)
        .. "</ul></div></td></tr></tbody></table>"
        .. '<p>It was previously at <a href="https://z-lib.org/">z-lib.org</a>, until it was seized.</p></body></html>'
end

local function cell(value)
    return "<td>" .. (value or "") .. "</td>\n"
end

-- one row of Library Genesis' search results (index.php with covers=on), with the same markup as the real page
function fixtures.libgenRow(book)
    local tooltip = 'data-toggle="tooltip" data-placement="right" data-html="true" '
        .. 'title="Add/Edit : 2021-06-18/2021-10-17; ID: 6518940<br>'
        .. (book.title or "")
        .. '"'
    local title = ""
    if book.series and book.issue then
        -- comics link the series and the issue number before the title
        title = '<b><a href="series.php?id=164150">'
            .. book.series
            .. " </a><a "
            .. tooltip
            .. ' href="edition.php?id=317043"><i> '
            .. book.issue
            .. "</i></a></b><br>"
    elseif book.series then
        title = "<b>" .. book.series .. "</b><br>"
    end
    -- some comic issues leave the title out of the page, apart from the tooltips
    if book.title and not book.title_in_tooltip_only then
        title = title .. "<a " .. tooltip .. ' href="edition.php?id=317043">' .. book.title .. " <i></i></a>"
    end
    if book.isbn then
        title = title
            .. "<br><a "
            .. tooltip
            .. ' href="edition.php?id=317043"><i><font color="green"> '
            .. book.isbn
            .. "</font></a></i>"
    end
    title = title
        .. ' <nobr><span class="badge badge-primary"><a data-toggle="tooltip" data-placement="bottom" '
        .. 'data-html="true" title="'
        .. (book.book_type or "Book")
        .. '">b</a></span> '
        .. '<span class="badge badge-secondary"">f 6270247</span></nobr>'

    local cover = ""
    if book.cover then
        local style = "max-height:70px;max-width:150px;height:auto;width:auto;"
        cover = '<a href="edition.php?id=6270247"><img src="' .. book.cover .. '" style="' .. style .. '"></a>'
    end
    local mirrors = ""
    if book.md5 then
        local mirror_tooltip = 'data-toggle="tooltip" data-placement="bottom" data-html="true"'
        mirrors = "<a " .. mirror_tooltip .. ' title="libgen" href="/ads.php?md5=' .. book.md5 .. '">'
        mirrors = mirrors .. '<span class="badge badge-primary">1</span></a> '
        mirrors = mirrors
            .. "<a "
            .. mirror_tooltip
            .. ' title="Randombook" href="https://randombook.org/book/'
            .. book.md5
        mirrors = mirrors .. '"><span class="badge badge-primary">2</span></a>'
    end

    local cells = {
        cell(cover),
        cell(title),
        cell(book.authors),
        cell('<a href="publisher.php?id=17868">Ace</a>'),
        cell(book.year and ("<nobr>" .. book.year .. "</nobr>")),
        cell(book.language),
        cell("412"),
        cell(book.file_size and ('<nobr><a href="/file.php?id=6518940">' .. book.file_size .. "</a></nobr>")),
        cell(book.file_type),
        cell(mirrors),
    }
    if book.cells then
        cells = { unpack(cells, 1, book.cells) }
    end
    return "<tr>\n" .. table.concat(cells) .. "</tr>\n"
end

-- a page of Library Genesis' search results, with the books in its table. pages optionally gives how many pages of
-- results it says there are, in the script that shows links to them (which it leaves out when there's only one), and
-- page the one these are on
function fixtures.libgenResults(books, pages, page)
    local rows = {}
    for _, book in ipairs(books) do
        table.insert(rows, fixtures.libgenRow(book))
    end
    local paginator = ""
    if pages then
        paginator = string.format(
            '<div style="text-align: center;" class="paginator" id="paginator_example_top"></div>'
                .. '<script type="text/javascript">paginator_example_top = new Paginator("paginator_example_top", '
                .. '%d, 25, %d, "/index.php?req=dune&res=100&curtab=f&order=&ordermode=desc&filesuns=all&page=" );'
                .. "</script>",
            pages,
            page or 1
        )
    end
    return "<html><head><title>Library Genesis</title></head><body>"
        .. paginator
        .. '<table class="table  table-striped" '
        .. 'id="tablelibgen"><thead><tr><th scope="col" class="first_col">Title</th></tr></thead><tbody>'
        .. table.concat(rows)
        .. "</tbody></table></body></html>"
end

-- Library Genesis' search page when there are no results on it to list, as for a search that found nothing, or a
-- page past its last: there's no table of results (only its style), but it says how many files were found, in a tab
-- that pages with results have too
function fixtures.libgenNoResults(files)
    return "<html><head><title>Library Genesis</title><style>#tablelibgen td { margin: 0; }</style></head><body>"
        .. '<ul class="nav nav-tabs"><li class="nav-item"> <a class="nav-link active " '
        .. 'href="/index.php?req=dune&curtab=f">Files <span class="badge badge-primary">'
        .. (files or 0)
        .. "</span></a> </li></ul></body></html>"
end

-- what Library Genesis' mirrors send in place of their search results while its database is refusing connections,
-- as it does while it's very busy (with HTTP 500), word for word
fixtures.LIBGEN_BUSY = "\u{FEFF} Could not connect to the database 3306. User 'libgen_read' has exceeded the "
    .. "'max_user_connections' resource (current value: 300) <a href=''>Report an error</a>."

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
    file_size = "1 MB",
}

fixtures.MESSIAH = {
    md5 = "f5a2858c141b73a63f56f164a79acee8",
    cover = "/fictioncovers/7791000/f5a2858c141b73a63f56f164a79acee8_small.jpg",
    title = "Dune Messiah",
    authors = "Frank Herbert",
    year = "1987",
    language = "English",
    file_type = "pdf",
    file_size = "3 MB",
}

-- Library Genesis' ads.php page links to get.php with a download key
function fixtures.libgenAds(md5)
    return [[<html><body><table id="main"><tr><td><a href="get.php?md5=]]
        .. md5
        .. [[&key=ABC123"><h2>GET</h2></a></td></tr></table></body></html>]]
end

-- Internet Archive's answer to a search (advancedsearch.php), with the books as its docs, and how many results
-- there are altogether
function fixtures.archiveResults(docs, total)
    return require("dkjson").encode({
        responseHeader = { status = 0 },
        response = {
            numFound = total or #docs,
            start = 0,
            docs = docs,
        },
    })
end

-- the list of the files in a book's folder on Internet Archive (metadata/<identifier>/files)
function fixtures.archiveFiles(files)
    return require("dkjson").encode({
        result = files,
    })
end

fixtures.ARCHIVE_EMMA = {
    identifier = "emma00aust",
    title = "Emma : a novel",
    creator = { "Austen, Jane, 1775-1817", "Thomson, Hugh" },
    year = 1816,
    language = "eng",
    format = { "Abbyy GZ", "DjVuTXT", "Djvu XML", "EPUB", "Item Tile", "Metadata", "Text PDF" },
}

-- Z-Library's answer to logging in, with the user id and key that log in as the account from then on
function fixtures.zlibLogin(user_id, user_key)
    return require("dkjson").encode({
        success = 1,
        user = {
            id = user_id,
            email = "reader@example.com",
            name = "Reader",
            remix_userkey = user_key,
            downloads_today = 0,
            downloads_limit = 10,
        },
    })
end

-- what Z-Library answers with when something's wrong, e.g. "Please login"
function fixtures.zlibError(message)
    return require("dkjson").encode({
        success = 0,
        error = message,
    })
end

-- Z-Library's answer to a search, with the books, and the page after this one (or false on the last)
function fixtures.zlibResults(books, next_page, total)
    return require("dkjson").encode({
        success = 1,
        books = books,
        exactBooksCount = total or #books,
        pagination = {
            limit = 50,
            current = 1,
            before = false,
            next = next_page or false,
            total_items = total or #books,
            total_pages = 1,
        },
    })
end

-- a book as Z-Library describes it in its results (trimmed down to what the plugin reads, and a few more)
fixtures.ZLIB_1984 = {
    id = 15846732,
    content_type = "book",
    title = "Orwell, George - 1984 (Penguin)",
    author = "George Orwell [Orwell, George]",
    year = 2004,
    publisher = "Penguin UK",
    language = "English",
    cover = "https://covers.example/covers299/1984.jpg",
    filesize = 2158260,
    filesizeString = "2.06 MB",
    extension = "epub",
    md5 = "9d4f939243175e76e973a1555ed70ecc",
    hash = "728638",
    dl = "/dl/knMa5dywnD",
}

return fixtures
