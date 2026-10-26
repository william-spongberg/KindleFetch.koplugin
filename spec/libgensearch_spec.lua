local helper = require("helper")
local fixtures = require("fixtures")

-- mirrors are scraped from the live Wikipedia page, so these need internet access
describe("LibgenSearch", function()
    local web, mirrors, LibgenSearch

    -- with the default book types
    local function searchUrl(mirror, page, query)
        return mirror
            .. "/index.php?"
            .. LibgenSearch.buildParams(
                query or "dune",
                page or 1,
                require("settings.settings"):getPreferredBookTypes()
            )
    end

    -- the books on the given page of results, of the pages Library Genesis says there are, when it says
    local function results(mirror, books, page, pages)
        web.pages[searchUrl(mirror, page)] = fixtures.libgenResults(books, pages, page)
    end

    local function searches()
        local urls = {}
        for _, url in ipairs(web.fetched) do
            if url:find("/index.php?", 1, true) then
                table.insert(urls, url)
            end
        end
        return urls
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        mirrors = fixtures.scrapeMirrors(web, function(UrlApi)
            return UrlApi:getLibgenUrls()
        end, "Library Genesis")
        LibgenSearch = require("api.libgensearch")
    end)

    after_each(helper.cleanup)

    describe("search", function()
        it("searches the preferred book types", function()
            LibgenSearch:search("dune messiah", 2)

            assert.are.equal(
                mirrors[1]
                    .. "/index.php?req=dune%20messiah&res=100&columns%5B%5D=t&columns%5B%5D=a"
                    .. "&columns%5B%5D=s&objects%5B%5D=f&topics%5B%5D=f&topics%5B%5D=l&topics%5B%5D=c"
                    .. "&topics%5B%5D=m&topics%5B%5D=a&topics%5B%5D=s&covers=on&filesuns=all&page=2",
                searches()[1]
            )
        end)

        -- the boxes ticked for which fields to search on its search page (as an archived copy of libgen.li's from
        -- 2026-10-11 has them, when the site itself couldn't be reached)
        it("searches the books' titles, authors and series, or the one field the search is narrowed to", function()
            local function columns(scope)
                local found = {}
                for column in LibgenSearch.buildParams("dune", 1, {}, scope):gmatch("columns%%5B%%5D=(%a)") do
                    table.insert(found, column)
                end
                return found
            end
            assert.are.same({ "t", "a", "s" }, columns(nil))
            assert.are.same({ "t" }, columns("title"))
            assert.are.same({ "a" }, columns("author"))
            assert.are.same({ "i" }, columns("isbn"))
            assert.are.same({ "title", "author", "isbn" }, LibgenSearch.SCOPES)
        end)

        -- which finds different books
        it("saves a search that's narrowed down apart from one that isn't", function()
            local book_types = require("settings.settings"):getPreferredBookTypes()
            web.pages[mirrors[1] .. "/index.php?" .. LibgenSearch.buildParams("dune", 1, book_types, "author")] =
                fixtures.libgenResults({ fixtures.DUNE })
            assert.are.equal(1, #LibgenSearch:search("dune", 1, "author"))
            assert.is_true(LibgenSearch:isCached("dune", 1, "author"))
            assert.is_false(LibgenSearch:isCached("dune", 1))
            assert.is_truthy(helper.logged("info", '^searching Library Genesis for "dune" by author from page 1, in '))
        end)

        it("maps every book type to a Library Genesis topic", function()
            local params = LibgenSearch.buildParams(
                "dune",
                1,
                { "fiction", "nonfiction", "comics", "magazines", "articles", "standards", "unknown" }
            )
            local topics = {}
            for topic in params:gmatch("topics%%5B%%5D=(%a)") do
                table.insert(topics, topic)
            end
            assert.are.same({ "f", "l", "c", "m", "a", "s" }, topics)
        end)

        it("reads each book from the results table", function()
            results(mirrors[1], { fixtures.DUNE, fixtures.MESSIAH })
            local books = LibgenSearch:search("dune", 1)

            assert.are.equal(2, #books)
            -- the search and what it found, for crash.log
            assert.is_truthy(helper.logged("info", '^searching Library Genesis for "dune" from page 1, in '))
            assert.is_truthy(helper.logged("info", "^page 1 from [%w%.]+: kept 2 of its 2 results$"))
            assert.is_truthy(helper.logged("info", '^found 2 books for "dune"$'))
            assert.are.same({
                source = "libgen",
                id = "24778aacb1d0844950bf463c145b3d21",
                image_url = mirrors[1] .. "/fictioncovers/2509000/24778aacb1d0844950bf463c145b3d21_small.jpg",
                title = "Dune",
                display_title = "Dune",
                authors = "Frank Herbert",
                year = "1990",
                language = "English",
                book_type = "Book",
                file_type = "epub",
                file_size = "1 MB",
            }, books[1])
            assert.are.equal("Dune Messiah", books[2].title)
        end)

        -- as most comic issues are, which were all skipped before
        it("finds a comic issue's title in its tooltip when the page leaves it out", function()
            results(mirrors[1], {
                {
                    md5 = "4dc14e7148d7150c77634508303d76d8",
                    series = "Dune Comics",
                    issue = "",
                    title = "Dune - House Atreides(Boom 2020)",
                    title_in_tooltip_only = true,
                    book_type = "Comics issue",
                    language = "English",
                    file_type = "cbr",
                },
            })
            local book = LibgenSearch:search("dune", 1)[1]

            -- without what's in brackets, like every title
            assert.are.equal("Dune - House Atreides", book.title)
            assert.are.equal("Comics issue", book.book_type)
        end)

        it("names a comic issue after its series when there's no title at all", function()
            results(mirrors[1], {
                {
                    md5 = "4dc14e7148d7150c77634508303d76d8",
                    series = "Dune Comics",
                    issue = "",
                    language = "English",
                    file_type = "cbr",
                },
            })
            assert.are.equal("Dune Comics", LibgenSearch:search("dune", 1)[1].title)
        end)

        it("finds the title after a comic's series and issue number", function()
            results(mirrors[1], {
                {
                    md5 = "e0d1e178d828288622b7ee6b8dc4dfbe",
                    series = "Dune",
                    issue = "1984-jan",
                    title = "Dune - The official Marvel Comics adaptation",
                    isbn = "0425076326",
                    book_type = "Comics issue",
                    authors = "Macchio, Ralph (sc.);Sienkiewicz, Bill (des.);",
                    language = "English",
                    file_type = "cbz",
                },
            })
            local book = LibgenSearch:search("dune", 1)[1]

            assert.are.equal("Dune - The official Marvel Comics adaptation", book.title)
            assert.are.equal("Comics issue", book.book_type)
            assert.are.equal("Macchio, Ralph (sc.);Sienkiewicz, Bill (des.)", book.authors)
        end)

        it("keeps covers that link to another site", function()
            results(mirrors[1], {
                {
                    md5 = "abc",
                    cover = "https://covers.example/abc.jpg",
                    title = "Dune",
                    file_type = "epub",
                },
            })
            assert.are.equal("https://covers.example/abc.jpg", LibgenSearch:search("dune", 1)[1].image_url)
        end)

        -- covers are downloaded by writing their addresses to a file of options for curl. a mirror could send an
        -- address with a line break in it, and add options of its own, such as where to save a file
        it("leaves out a cover whose address isn't just an address", function()
            results(mirrors[1], {
                {
                    md5 = "abc",
                    cover = "https://covers.example/abc.jpg&#10;output = /mnt/us/koreader/patches/2-evil.lua",
                    title = "Dune",
                    file_type = "epub",
                },
                {
                    md5 = "def",
                    cover = "/covers/def.jpg\noutput = /mnt/us/koreader/patches/2-evil.lua",
                    title = "Dune Messiah",
                    file_type = "epub",
                },
            })
            local books = LibgenSearch:search("dune", 1)

            assert.are.equal(2, #books)
            assert.is_nil(books[1].image_url)
            assert.is_nil(books[2].image_url)
            assert.is_truthy(helper.logged("warn", "^left out a cover whose address can't be used"))
        end)

        it("fills in missing details", function()
            results(mirrors[1], {
                {
                    md5 = "ABC",
                    title = "Anonymous",
                    year = "0",
                    file_type = "EPUB",
                },
            })
            local book = LibgenSearch:search("dune", 1)[1]

            assert.are.equal("abc", book.id)
            assert.are.equal("epub", book.file_type)
            assert.are.equal("Unknown author", book.authors)
            assert.are.equal("0", book.file_size)
            assert.is_nil(book.year)
            assert.is_nil(book.language)
            assert.is_nil(book.image_url)
        end)

        -- what shows them shortens them to fit. cutting them at 50 bytes here split letters in other alphabets
        it("keeps long titles and author lists whole", function()
            local title =
                "Мастер и Маргарита: роман в двух частях, с иллюстрациями и комментариями"
            results(mirrors[1], {
                {
                    md5 = "abc",
                    title = title,
                    authors = string.rep("Author, ", 10),
                    file_type = "epub",
                },
            })
            local book = LibgenSearch:search("dune", 1)[1]

            assert.are.equal(title, book.display_title)
            assert.are.equal(string.rep("Author, ", 10):gsub("[,%s]+$", ""), book.authors)
        end)

        it("shows a title as it's written, while naming its file safely", function()
            results(mirrors[1], {
                {
                    md5 = "abc",
                    title = "Orwell, George: Animal farm (a fairy story)",
                    file_type = "epub",
                },
            })
            local book = LibgenSearch:search("dune", 1)[1]

            assert.are.equal("Orwell, George: Animal farm", book.display_title)
            assert.are.equal("Orwell, George- Animal farm", book.title)
        end)

        it("decodes html entities", function()
            results(mirrors[1], {
                {
                    md5 = "abc",
                    title = "Pride &amp; Prejudice",
                    file_type = "epub",
                },
            })
            assert.are.equal("Pride & Prejudice", LibgenSearch:search("dune", 1)[1].title)
        end)

        it("shows each book once, though Library Genesis may list it more than once", function()
            results(mirrors[1], { fixtures.DUNE, fixtures.MESSIAH, fixtures.DUNE })
            local books = LibgenSearch:search("dune", 1)

            assert.are.same({ "Dune", "Dune Messiah" }, { books[1].title, books[2].title })
            assert.are.equal(2, #books)
        end)

        it("keeps the dots in titles", function()
            results(mirrors[1], {
                {
                    md5 = "abc",
                    title = "Mr. Mercedes",
                    file_type = "epub",
                },
            })
            assert.are.equal("Mr. Mercedes", LibgenSearch:search("dune", 1)[1].title)
        end)

        it("skips rows that are not usable books", function()
            results(mirrors[1], {
                {
                    title = "No md5",
                    file_type = "epub",
                },
                {
                    md5 = "abc",
                    title = "No file type",
                },
                {
                    md5 = "def",
                    file_type = "epub",
                },
                {
                    md5 = "ghi",
                    title = "Too few cells",
                    file_type = "epub",
                    cells = 9,
                },
                fixtures.DUNE,
            })
            local books = LibgenSearch:search("dune", 1)

            assert.are.equal(1, #books)
            assert.are.equal("Dune", books[1].title)
        end)

        -- so books KOReader can't open are never found
        -- which were said to be results in other languages or file types, offering the settings, when Library Genesis
        -- had changed its page
        it("doesn't count rows it can't read as results", function()
            results(mirrors[1], {
                { title = "No md5", file_type = "epub" },
                { md5 = "abc", title = "Too few cells", file_type = "epub", cells = 9 },
                { md5 = "def", title = "Dune", language = "Spanish", file_type = "epub" },
            })
            local books, err, _, results_read = LibgenSearch:search("dune", 1)
            assert.is_nil(err)
            assert.are.same({}, books)
            assert.are.equal(1, results_read)
            assert.is_truthy(helper.logged("warn", "^2 of the page's 3 rows couldn't be read as books"))
        end)

        it("says its results couldn't be read when none of its rows can be", function()
            results(mirrors[1], {
                { title = "No md5", file_type = "epub" },
                { md5 = "abc", title = "Too few cells", file_type = "epub", cells = 9 },
            })
            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(require("util.errors").UNREADABLE, err)
        end)

        it("only keeps the preferred file types and languages", function()
            results(mirrors[1], {
                fixtures.DUNE,
                {
                    md5 = "abc",
                    title = "Dune azw3",
                    language = "English",
                    file_type = "azw3",
                },
                {
                    md5 = "def",
                    title = "Дюна",
                    language = "Russian",
                    file_type = "epub",
                },
                {
                    md5 = "fed",
                    title = "Dune unknown language",
                    file_type = "epub",
                },
            })
            local books = LibgenSearch:search("dune", 1)

            assert.are.same({ "Dune", "Dune unknown language" }, { books[1].title, books[2].title })
            assert.are.equal(2, #books)
        end)

        describe("across pages", function()
            -- a full page of results, as many as Library Genesis sends, of which the first `wanted` are books to show
            local function fullPage(page, wanted)
                local books = {}
                for i = 1, 25 do
                    table.insert(books, {
                        md5 = string.format("%030x%02x", page, i),
                        title = string.format("Book %d.%d", page, i),
                        language = i <= wanted and "English" or "Spanish",
                        file_type = "epub",
                    })
                end
                return books
            end

            local function titles(books)
                local list = {}
                for _, book in ipairs(books) do
                    table.insert(list, book.title)
                end
                return list
            end

            it("reads pages until there are enough books to show", function()
                for page = 1, 3 do
                    results(mirrors[1], fullPage(page, 4), page, 10)
                end

                local books, err, next_page, results_read = LibgenSearch:search("dune", 1)
                assert.is_nil(err)
                assert.are.equal(12, #books)
                assert.are.equal("Book 3.4", books[12].title)
                assert.are.equal(4, next_page)
                assert.are.equal(3, #searches())
                -- so it can be said how many were left out when none are found
                assert.are.equal(75, results_read)
            end)

            it("says how many results it read when none of them were books to show", function()
                results(mirrors[1], fullPage(1, 0), 1, 2)
                results(mirrors[1], { { md5 = "abc", title = "Dune", language = "Spanish", file_type = "epub" } }, 2, 2)

                local books, err, next_page, results_read = LibgenSearch:search("dune", 1)
                assert.are.same({}, books)
                assert.is_nil(err)
                assert.is_nil(next_page)
                assert.are.equal(26, results_read)
            end)

            -- which Library Genesis says, as its last page can be full
            it("stops at the last page of results", function()
                results(mirrors[1], fullPage(1, 2), 1, 2)
                results(mirrors[1], fullPage(2, 1), 2, 2)

                local books, _, next_page = LibgenSearch:search("dune", 1)
                assert.are.same({ "Book 1.1", "Book 1.2", "Book 2.1" }, titles(books))
                assert.is_nil(next_page)
                assert.are.equal(2, #searches())
            end)

            -- whatever's asked for, so a page of fewer than were asked for isn't the last one, as it was taken to be,
            -- which left a single page of results and nothing to load more of (#56)
            it("carries on while Library Genesis says there are more pages", function()
                results(mirrors[1], fullPage(1, 10), 1, 80)

                local books, _, next_page = LibgenSearch:search("dune", 1)
                assert.are.equal(10, #books)
                assert.are.equal(2, next_page)
                assert.are.equal(1, #searches())
            end)

            -- e.g. if its page stops saying, in case it has more
            it("carries on after a full page when Library Genesis doesn't say how many pages it has", function()
                results(mirrors[1], fullPage(1, 2), 1)
                results(mirrors[1], { fixtures.DUNE }, 2)

                local books, _, next_page = LibgenSearch:search("dune", 1)
                assert.are.same({ "Book 1.1", "Book 1.2", "Dune" }, titles(books))
                assert.is_nil(next_page)
            end)

            -- as when it didn't say how many pages it had, and its last was full
            it("stops at a page past the last one", function()
                results(mirrors[1], fullPage(1, 2), 1)
                web.pages[searchUrl(mirrors[1], 2)] = fixtures.libgenNoResults(25)

                local books, err, next_page = LibgenSearch:search("dune", 1)
                assert.is_nil(err)
                assert.are.same({ "Book 1.1", "Book 1.2" }, titles(books))
                assert.is_nil(next_page)
                assert.are.same(mirrors, require("api.urlapi"):getLibgenUrls())
            end)

            -- which can be carried on from once it isn't
            it("keeps the books found when Library Genesis is too busy for a later page", function()
                results(mirrors[1], fullPage(1, 3), 1, 10)
                for _, mirror in ipairs(mirrors) do
                    web.pages[searchUrl(mirror, 2)] = function()
                        return fixtures.LIBGEN_BUSY, nil, 500
                    end
                end

                local books, err, next_page = LibgenSearch:search("dune", 1)
                assert.is_nil(err)
                assert.are.equal(3, #books)
                assert.are.equal(2, next_page)
                assert.are.equal(1, web.scrapes)
            end)

            it("reads at most five pages at a time", function()
                for page = 1, 6 do
                    results(mirrors[1], fullPage(page, 1), page, 10)
                end

                local books, _, next_page = LibgenSearch:search("dune", 1)
                assert.are.equal(5, #books)
                assert.are.equal(6, next_page)
                assert.are.equal(5, #searches())
            end)

            it("carries on from the given page", function()
                results(mirrors[1], { fixtures.DUNE }, 3)

                local books = LibgenSearch:search("dune", 3)
                assert.are.same({ "Dune" }, titles(books))
                assert.are.equal(searchUrl(mirrors[1], 3), searches()[1])
            end)

            it("keeps the books found when a later page fails", function()
                results(mirrors[1], fullPage(1, 3), 1, 10)

                local books, err, next_page = LibgenSearch:search("dune", 1)
                assert.is_nil(err)
                assert.are.equal(3, #books)
                -- so the failed page is tried again next time
                assert.are.equal(2, next_page)
            end)

            -- which was said to have failed, though the pages before had results, only none to show, so Keep
            -- searching can carry on from the page that failed
            it("says how many results it read when a later page fails before any books to show were found", function()
                results(mirrors[1], fullPage(1, 0), 1, 10)

                local books, err, next_page, results_read = LibgenSearch:search("dune", 1)
                assert.are.same({}, books)
                assert.is_nil(err)
                assert.are.equal(2, next_page)
                assert.are.equal(25, results_read)
                assert.is_truthy(helper.logged("warn", "^page 2 of the search failed %(.*%), so showing the 0 books"))
            end)

            -- by a tap on the message saying that it's searching, see HttpUtil
            describe("called off", function()
                local HttpUtil

                -- as if the message were tapped while waiting for a page whose address contains part
                local function callOffAt(part)
                    HttpUtil = require("util.httputil")
                    local getBody = HttpUtil.getBody
                    HttpUtil.getBody = function(url)
                        if url:find(part, 1, true) then
                            table.insert(web.fetched, url)
                            return nil, HttpUtil.CANCELLED
                        end
                        return getBody(url)
                    end
                end

                it("stops without finding fault with any of the mirrors", function()
                    callOffAt("/index.php?")

                    local books, err = LibgenSearch:search("dune", 1)
                    assert.is_nil(books)
                    assert.are.equal(HttpUtil.CANCELLED, err)
                    assert.are.equal(1, #searches())
                    assert.are.same(mirrors, require("api.urlapi"):getLibgenUrls())
                    assert.are.equal(1, web.scrapes)
                end)

                -- which there may have been a few of, when it was called off while looking for more
                it("shows the books found on earlier pages, carrying on from the one it was called off on", function()
                    results(mirrors[1], fullPage(1, 3), 1, 10)
                    callOffAt("&page=2")

                    local books, err, next_page = LibgenSearch:search("dune", 1)
                    assert.is_nil(err)
                    assert.are.equal(3, #books)
                    assert.are.equal(2, next_page)
                    assert.is_truthy(helper.logged("info", "^search called off on page 2 so showing the 3 books"))
                end)

                -- rather than saying none of the results read were in the languages and file types chosen
                it("says nothing more when no books to show had been found yet", function()
                    results(mirrors[1], fullPage(1, 0), 1, 10)
                    callOffAt("&page=2")

                    local books, err = LibgenSearch:search("dune", 1)
                    assert.is_nil(books)
                    assert.are.equal(HttpUtil.CANCELLED, err)
                end)

                it("stops while the mirrors are being looked up, rather than taking it for being offline", function()
                    callOffAt("wikipedia.org")

                    local books, err = LibgenSearch:search("dune", 1)
                    assert.is_nil(books)
                    assert.are.equal(HttpUtil.CANCELLED, err)
                    assert.are.equal(0, #searches())
                    assert.is_nil(helper.logged("warn", "could not look up mirrors"))
                end)
            end)

            it("remembers where to carry on from", function()
                for page = 1, 3 do
                    results(mirrors[1], fullPage(page, 4), page, 10)
                end
                LibgenSearch:search("dune", 1)

                local books, _, next_page = LibgenSearch:search("dune", 1)
                assert.are.equal(12, #books)
                assert.are.equal(4, next_page)
                assert.are.equal(3, #searches())
            end)
        end)

        it("ignores searches cached by older versions", function()
            require("cache.searchcache"):set(
                { {
                    title = "Old",
                } },
                "libgen",
                "dune",
                1,
                { "en" },
                { "epub", "pdf", "cbr", "cbz" },
                { "fiction", "comics" }
            )
            results(mirrors[1], { fixtures.DUNE })

            assert.are.equal("Dune", LibgenSearch:search("dune", 1)[1].title)
        end)

        it("caches results", function()
            results(mirrors[1], { fixtures.DUNE })
            LibgenSearch:search("dune", 1)
            LibgenSearch:search("dune", 1)

            assert.are.equal(1, #searches())
        end)

        it("says whether a search's results are saved, e.g. to show them offline", function()
            results(mirrors[1], { fixtures.DUNE })
            assert.is_false(LibgenSearch:isCached("dune", 1))

            LibgenSearch:search("dune", 1)
            assert.is_true(LibgenSearch:isCached("dune", 1))
            assert.is_false(LibgenSearch:isCached("dune", 2))
            assert.is_false(LibgenSearch:isCached("dune messiah", 1))
        end)

        it("does not cache searches that found nothing", function()
            results(mirrors[1], {})
            assert.are.same({}, LibgenSearch:search("dune", 1))

            results(mirrors[1], { fixtures.DUNE })
            assert.are.equal(1, #LibgenSearch:search("dune", 1))
        end)

        -- which Library Genesis sends without a table of results, rather than with an empty one
        it("finds no books when Library Genesis has none, without finding fault with the mirror", function()
            web.pages[searchUrl(mirrors[1])] = fixtures.libgenNoResults(0)

            local books, err, next_page, results_read = LibgenSearch:search("dune", 1)
            assert.are.same({}, books)
            assert.is_nil(err)
            assert.is_nil(next_page)
            assert.are.equal(0, results_read)
            assert.are.equal(1, #searches())
            assert.are.equal(1, web.scrapes)
            assert.are.same(mirrors, require("api.urlapi"):getLibgenUrls())
        end)

        -- rather than forgetting it, as it may only not have for a moment
        it("tries the next mirror, and the one that didn't answer after the others from then on", function()
            results(mirrors[2], { fixtures.DUNE })

            assert.are.equal(1, #LibgenSearch:search("dune", 1))
            assert.are.same({ searchUrl(mirrors[1]), searchUrl(mirrors[2]) }, searches())

            local reordered = {}
            for i = 2, #mirrors do
                table.insert(reordered, mirrors[i])
            end
            table.insert(reordered, mirrors[1])
            assert.are.same(reordered, require("api.urlapi"):getLibgenUrls())
            assert.is_truthy(helper.logged("info", "^trying mirror .* after the others for a while"))
        end)

        -- rather than asking the ones before it every time, which may be blocking searches for a while
        it("asks the mirror that last answered first", function()
            web.pages[searchUrl(mirrors[1])] =
                "<html><head><title>DDoS-Guard</title></head><body>Checking your browser</body></html>"
            results(mirrors[2], { fixtures.DUNE })
            assert.are.equal(1, #LibgenSearch:search("dune", 1))
            assert.are.equal(mirrors[2], require("api.urlapi"):getLibgenUrls()[1])

            web.fetched = {}
            web.pages[searchUrl(mirrors[2], 1, "dune messiah")] = fixtures.libgenResults({ fixtures.DUNE })
            assert.are.equal(1, #LibgenSearch:search("dune messiah", 1))
            assert.are.same({ searchUrl(mirrors[2], 1, "dune messiah") }, searches())
        end)

        it("treats unexpected pages as failures", function()
            web.pages[searchUrl(mirrors[1])] = "<html><body>Under maintenance</body></html>"
            results(mirrors[2], { fixtures.DUNE })

            assert.are.equal(1, #LibgenSearch:search("dune", 1))
            -- saying what the page was, for crash.log
            assert.matches("Under maintenance", helper.logged("warn", "^unexpected search page from"))
        end)

        -- on what's waiting, e.g. the message saying a search is going on, so it doesn't look stuck while a mirror
        -- that doesn't answer is waited for
        describe("says which mirror it's trying", function()
            local statuses
            before_each(function()
                require("api.urlapi"):getLibgenUrls()
                statuses = {}
                require("util.httputil").setTrapWidget({
                    setStatus = function(_, status)
                        table.insert(statuses, status)
                    end,
                })
            end)

            local function site(mirror)
                return (mirror:gsub("^https://", ""))
            end

            it("and that the one before didn't answer", function()
                results(mirrors[2], { fixtures.DUNE })
                LibgenSearch:search("dune", 1)

                assert.are.same({
                    string.format("Trying %s (mirror 1 of %d)...", site(mirrors[1]), #mirrors),
                    string.format(
                        "%s didn't answer.\nTrying %s (mirror 2 of %d)...",
                        site(mirrors[1]),
                        site(mirrors[2]),
                        #mirrors
                    ),
                }, statuses)
            end)

            it("and what was wrong with what the one before sent", function()
                web.pages[searchUrl(mirrors[1])] = "<html><body>Loading...</body></html>"
                results(mirrors[2], { fixtures.DUNE })
                LibgenSearch:search("dune", 1)

                assert.are.equal(
                    string.format(
                        "%s sent a page that isn't Library Genesis' results.\nTrying %s (mirror 2 of %d)...",
                        site(mirrors[1]),
                        site(mirrors[2]),
                        #mirrors
                    ),
                    statuses[2]
                )
            end)

            it("when looking up a book's download link", function()
                web.pages[mirrors[1] .. "/ads.php?md5=" .. fixtures.DUNE.md5] = function()
                    return "<html>Service Unavailable</html>", nil, 503
                end
                web.pages[mirrors[2] .. "/ads.php?md5=" .. fixtures.DUNE.md5] = fixtures.libgenAds(fixtures.DUNE.md5)
                LibgenSearch.findDownloadLink({ id = fixtures.DUNE.md5 })

                assert.are.equal(
                    string.format(
                        "%s answered with an error (HTTP 503).\nTrying %s (mirror 2 of %d)...",
                        site(mirrors[1]),
                        site(mirrors[2]),
                        #mirrors
                    ),
                    statuses[2]
                )
            end)
        end)

        it("scrapes the mirrors again when every mirror fails, searching those that have moved", function()
            -- every mirror is down, as Library Genesis has moved to another, which Wikipedia lists once it's scraped
            -- again
            local moved = "https://libgen.moved"
            web.pages[require("api.urlapi").LIBGEN_PAGE] = function()
                local items = {}
                for _, mirror in ipairs(web.scrapes > 1 and { moved } or mirrors) do
                    table.insert(items, "<li>" .. mirror:gsub("^https://", "") .. "</li>")
                end
                return "<html><body><ul>" .. table.concat(items) .. "</ul></body></html>"
            end
            results(moved, { fixtures.DUNE })

            local books = LibgenSearch:search("dune", 1)
            assert.are.equal(2, web.scrapes)
            assert.are.equal(1, #books)
            assert.are.equal("Dune", books[1].title)
            assert.are.equal(searchUrl(moved), searches()[#searches()])
        end)

        -- which have just failed, some (such as one that takes the connection but never answers) only after a while
        it("gives up once scraping the mirrors again finds no others, without asking them again", function()
            local books, err = LibgenSearch:search("dune", 1)

            assert.is_nil(books)
            assert.are.equal("failed to connect to server", err)
            assert.are.equal(2, web.scrapes)
            assert.are.equal(#mirrors, #searches())
        end)

        -- which its mirrors all say at once, as they share it, rather than that each sent something unexpected, which
        -- forgot every mirror
        describe("while Library Genesis' database is too busy", function()
            local function busy(mirror)
                web.pages[searchUrl(mirror)] = function()
                    return fixtures.LIBGEN_BUSY, nil, 500
                end
            end

            it("says so, keeping the mirrors rather than looking them up again", function()
                for _, mirror in ipairs(mirrors) do
                    busy(mirror)
                end

                local books, err = LibgenSearch:search("dune", 1)
                assert.is_nil(books)
                assert.are.equal("Library Genesis is too busy to search right now, try again in a few minutes", err)
                assert.are.equal(#mirrors, #searches())
                assert.are.equal(1, web.scrapes)
                assert.are.same(mirrors, require("api.urlapi"):getLibgenUrls())
                assert.is_truthy(helper.logged("warn", "found Library Genesis' database too busy %(HTTP 500%)$"))
                assert.is_nil(helper.logged("warn", "^unexpected search page"))
            end)

            it("searches a mirror that isn't too busy, keeping the one that was", function()
                busy(mirrors[1])
                results(mirrors[2], { fixtures.DUNE })

                assert.are.equal(1, #LibgenSearch:search("dune", 1))
                local remaining = require("api.urlapi"):getLibgenUrls()
                assert.are.equal(#mirrors, #remaining)
                assert.are.equal(mirrors[2], remaining[1])
            end)
        end)

        -- which was only said when the last mirror asked was the one blocked
        it("says searches are blocked by ddos protection, whichever mirror was", function()
            web.pages[searchUrl(mirrors[1])] =
                "<html><head><title>DDoS-Guard</title></head><body>Checking your browser</body></html>"

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("Library Genesis is blocking automated searches right now, try again later", err)
        end)

        -- as for the other sites
        it("says which error a mirror answered with", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] = function()
                    return "<html>Service Temporarily Unavailable</html>", nil, 503
                end
            end

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("Library Genesis answered with an error (HTTP 503), try again later", err)
        end)

        it("says when searches are blocked by ddos protection", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] =
                    "<html><head><title>DDoS-Guard</title></head><body>Checking your browser</body></html>"
            end

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("Library Genesis is blocking automated searches right now, try again later", err)
            -- the mirrors work, so they are kept and not scraped again
            assert.are.equal(1, web.scrapes)
            assert.are.same(mirrors, require("api.urlapi"):getLibgenUrls())
        end)

        -- rather than that the last one's name couldn't be looked up: Wikipedia answered, so the device is online, and
        -- most likely the network is blocking them, as many internet providers do (#55)
        it("says when none of the mirrors can be found on this network", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] = function()
                    return nil, "could not resolve host"
                end
            end

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(
                "none of Library Genesis' sites can be found on this network, which may be blocking them. Try "
                    .. "another Wi-Fi network or DNS server",
                err
            )
            assert.are.equal(2, web.scrapes)
            assert.is_truthy(helper.logged("warn", "^none of the mirrors' names could be looked up"))
        end)

        -- when it's less clear that the network is blocking them
        it("says what went wrong with the last mirror when only some can't be found", function()
            web.pages[searchUrl(mirrors[1])] = function()
                return nil, "could not resolve host"
            end

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("failed to connect to server", err)
        end)

        -- which was said to be there being no internet connection
        it("says when Wikipedia can't be connected to securely, as when the device's clock is wrong", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] = function()
                    return nil, "TLS/SSL connection failed"
                end
            end
            web.wikipedia_down = "TLS/SSL connection failed"

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal(
                "Wikipedia, where the mirrors are looked up, couldn't be connected to securely (TLS/SSL connection "
                    .. "failed): check the device's date and time",
                err
            )
        end)

        it("says what went wrong looking the mirrors up on Wikipedia, when it isn't the connection", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] = function()
                    return nil, "request timed out"
                end
            end
            web.wikipedia_down = "server returned an empty response"

            local _, err = LibgenSearch:search("dune", 1)
            assert.are.equal("the mirrors couldn't be looked up on Wikipedia (server returned an empty response)", err)
        end)

        it("says there's no internet connection when Wikipedia can't be found either", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] = function()
                    return nil, "could not resolve host"
                end
            end
            web.wikipedia_down = true

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("no internet connection", err)
        end)

        it("says there's no internet connection when neither the mirrors nor Wikipedia answer", function()
            web.wikipedia_down = true

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("no internet connection", err)
        end)

        -- rather than forgetting every mirror while offline
        it("keeps the mirrors when nothing answers", function()
            local UrlApi = require("api.urlapi")
            UrlApi:getLibgenUrls()
            web.wikipedia_down = true

            local books, err = LibgenSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("no internet connection", err)
            assert.are.same(mirrors, UrlApi:getLibgenUrls())
        end)

        -- catches Library Genesis changing its results page, like Anna's Archive blocking searches did (#24)
        it("finds books on the live Library Genesis site #live", function()
            web.live = true
            local books, err, next_page = LibgenSearch:search("frank herbert dune", 1)

            assert.is_nil(err)
            assert.is_true(#books > 0, "no books found")
            -- it has many pages of results, which there was no going on to once it sent fewer a page than were asked
            -- for (#56)
            assert.is_not_nil(next_page, "no page of results to carry on from")
            for _, book in ipairs(books) do
                assert.matches("^%x+$", book.id)
                assert.are.equal(32, #book.id)
                assert.is_true(#book.title > 0)
                local preferred = {}
                for _, file_type in ipairs(require("settings.settings"):getPreferredFileTypes()) do
                    preferred[file_type] = true
                end
                assert.is_truthy(preferred[book.file_type])
            end
        end)
    end)
end)
