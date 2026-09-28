local helper = require("helper")
local fixtures = require("fixtures")

-- mirrors are scraped from the live Wikipedia page, so these need internet access
describe("LlgiSearch", function()
    local web, mirrors, LlgiSearch

    local function searchUrl(mirror, page, query)
        return mirror .. "/index.php?" .. LlgiSearch.buildParams(query or "dune", page or 1, {"fiction", "comics"})
    end

    local function results(mirror, books, page)
        web.pages[searchUrl(mirror, page)] = fixtures.libgenResults(books)
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
        LlgiSearch = require("api.lglisearch")
    end)

    after_each(helper.cleanup)

    describe("search", function()
        it("searches the preferred book types", function()
            LlgiSearch:search("dune messiah", 2)

            assert.are.equal(mirrors[1] .. "/index.php?req=dune%20messiah&res=100&columns%5B%5D=t&columns%5B%5D=a" ..
                                 "&columns%5B%5D=s&objects%5B%5D=f&topics%5B%5D=f&topics%5B%5D=c&covers=on" ..
                                 "&filesuns=all&page=2", searches()[1])
        end)

        it("maps every book type to a Library Genesis topic", function()
            local params = LlgiSearch.buildParams("dune", 1, {"fiction", "fiction_rus", "nonfiction", "comics",
                                                                "magazines", "articles", "standards", "unknown"})
            local topics = {}
            for topic in params:gmatch("topics%%5B%%5D=(%a)") do
                table.insert(topics, topic)
            end
            assert.are.same({"f", "r", "l", "c", "m", "a", "s"}, topics)
        end)

        it("reads each book from the results table", function()
            results(mirrors[1], {fixtures.DUNE, fixtures.MESSIAH})
            local books = LlgiSearch:search("dune", 1)

            assert.are.equal(2, #books)
            assert.are.same({
                md5 = "24778aacb1d0844950bf463c145b3d21",
                image_url = mirrors[1] .. "/fictioncovers/2509000/24778aacb1d0844950bf463c145b3d21_small.jpg",
                title = "Dune",
                display_title = "Dune",
                authors = "Frank Herbert",
                year = "1990",
                language = "English",
                book_type = "Book",
                file_type = "epub",
                file_size = "1 MB"
            }, books[1])
            assert.are.equal("Dune Messiah", books[2].title)
        end)

        it("finds the title after a comic's series and issue number", function()
            results(mirrors[1], {{
                md5 = "e0d1e178d828288622b7ee6b8dc4dfbe",
                series = "Dune",
                issue = "1984-jan",
                title = "Dune - The official Marvel Comics adaptation",
                isbn = "0425076326",
                book_type = "Comics issue",
                authors = "Macchio, Ralph (sc.);Sienkiewicz, Bill (des.);",
                language = "English",
                file_type = "cbz"
            }})
            local book = LlgiSearch:search("dune", 1)[1]

            assert.are.equal("Dune - The official Marvel Comics adaptation", book.title)
            assert.are.equal("Comics issue", book.book_type)
            assert.are.equal("Macchio, Ralph (sc.);Sienkiewicz, Bill (des.)", book.authors)
        end)

        it("keeps covers that link to another site", function()
            results(mirrors[1], {{
                md5 = "abc",
                cover = "https://covers.example/abc.jpg",
                title = "Dune",
                file_type = "epub"
            }})
            assert.are.equal("https://covers.example/abc.jpg", LlgiSearch:search("dune", 1)[1].image_url)
        end)

        it("fills in missing details", function()
            results(mirrors[1], {{
                md5 = "ABC",
                title = "Anonymous",
                year = "0",
                file_type = "EPUB"
            }})
            local book = LlgiSearch:search("dune", 1)[1]

            assert.are.equal("abc", book.md5)
            assert.are.equal("epub", book.file_type)
            assert.are.equal("Unknown author", book.authors)
            assert.are.equal("0", book.file_size)
            assert.is_nil(book.year)
            assert.is_nil(book.language)
            assert.is_nil(book.image_url)
        end)

        it("shortens long titles and author lists for display", function()
            results(mirrors[1], {{
                md5 = "abc",
                title = string.rep("Long title ", 10),
                authors = string.rep("Author, ", 10),
                file_type = "epub"
            }})
            local book = LlgiSearch:search("dune", 1)[1]

            assert.are.equal(string.rep("Long title ", 10):sub(1, 50) .. "…", book.display_title)
            assert.are.equal(string.rep("Author, ", 10):sub(1, 50) .. "…", book.authors)
        end)

        it("decodes html entities", function()
            results(mirrors[1], {{
                md5 = "abc",
                title = "Pride &amp; Prejudice",
                file_type = "epub"
            }})
            assert.are.equal("Pride & Prejudice", LlgiSearch:search("dune", 1)[1].title)
        end)

        it("keeps the dots in titles", function()
            results(mirrors[1], {{
                md5 = "abc",
                title = "Mr. Mercedes",
                file_type = "epub"
            }})
            assert.are.equal("Mr. Mercedes", LlgiSearch:search("dune", 1)[1].title)
        end)

        it("skips rows that are not usable books", function()
            results(mirrors[1], {{
                title = "No md5",
                file_type = "epub"
            }, {
                md5 = "abc",
                title = "No file type"
            }, {
                md5 = "def",
                file_type = "epub"
            }, {
                md5 = "ghi",
                title = "Too few cells",
                file_type = "epub",
                cells = 9
            }, fixtures.DUNE})
            local books = LlgiSearch:search("dune", 1)

            assert.are.equal(1, #books)
            assert.are.equal("Dune", books[1].title)
        end)

        it("only keeps the preferred file types and languages", function()
            results(mirrors[1], {fixtures.DUNE, {
                md5 = "abc",
                title = "Dune mobi",
                language = "English",
                file_type = "mobi"
            }, {
                md5 = "def",
                title = "Дюна",
                language = "Russian",
                file_type = "epub"
            }, {
                md5 = "fed",
                title = "Dune unknown language",
                file_type = "epub"
            }})
            local books = LlgiSearch:search("dune", 1)

            assert.are.same({"Dune", "Dune unknown language"}, {books[1].title, books[2].title})
            assert.are.equal(2, #books)
        end)

        describe("across pages", function()
            -- a full page of results, of which the first `wanted` are books to show
            local function fullPage(page, wanted)
                local books = {}
                for i = 1, 100 do
                    table.insert(books, {
                        md5 = string.format("%030x%02x", page, i),
                        title = string.format("Book %d.%d", page, i),
                        language = i <= wanted and "English" or "Spanish",
                        file_type = "epub"
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
                    results(mirrors[1], fullPage(page, 4), page)
                end

                local books, err, next_page = LlgiSearch:search("dune", 1)
                assert.is_nil(err)
                assert.are.equal(12, #books)
                assert.are.equal("Book 3.4", books[12].title)
                assert.are.equal(4, next_page)
                assert.are.equal(3, #searches())
            end)

            it("stops at the last page of results", function()
                results(mirrors[1], fullPage(1, 2), 1)
                results(mirrors[1], {fixtures.DUNE}, 2)

                local books, _, next_page = LlgiSearch:search("dune", 1)
                assert.are.same({"Book 1.1", "Book 1.2", "Dune"}, titles(books))
                assert.is_nil(next_page)
            end)

            it("reads at most five pages at a time", function()
                for page = 1, 6 do
                    results(mirrors[1], fullPage(page, 1), page)
                end

                local books, _, next_page = LlgiSearch:search("dune", 1)
                assert.are.equal(5, #books)
                assert.are.equal(6, next_page)
                assert.are.equal(5, #searches())
            end)

            it("carries on from the given page", function()
                results(mirrors[1], {fixtures.DUNE}, 3)

                local books = LlgiSearch:search("dune", 3)
                assert.are.same({"Dune"}, titles(books))
                assert.are.equal(searchUrl(mirrors[1], 3), searches()[1])
            end)

            it("keeps the books found when a later page fails", function()
                results(mirrors[1], fullPage(1, 3), 1)

                local books, err, next_page = LlgiSearch:search("dune", 1)
                assert.is_nil(err)
                assert.are.equal(3, #books)
                -- so the failed page is tried again next time
                assert.are.equal(2, next_page)
            end)

            it("remembers where to carry on from", function()
                for page = 1, 3 do
                    results(mirrors[1], fullPage(page, 4), page)
                end
                LlgiSearch:search("dune", 1)

                local books, _, next_page = LlgiSearch:search("dune", 1)
                assert.are.equal(12, #books)
                assert.are.equal(4, next_page)
                assert.are.equal(3, #searches())
            end)
        end)

        it("ignores searches cached by older versions", function()
            require("cache.searchcache"):set({{
                title = "Old"
            }}, "dune", 1, {"en"}, {"epub", "pdf", "cbr", "cbz"}, {"fiction", "comics"})
            results(mirrors[1], {fixtures.DUNE})

            assert.are.equal("Dune", LlgiSearch:search("dune", 1)[1].title)
        end)

        it("caches results", function()
            results(mirrors[1], {fixtures.DUNE})
            LlgiSearch:search("dune", 1)
            LlgiSearch:search("dune", 1)

            assert.are.equal(1, #searches())
        end)

        it("does not cache searches that found nothing", function()
            results(mirrors[1], {})
            assert.are.same({}, LlgiSearch:search("dune", 1))

            results(mirrors[1], {fixtures.DUNE})
            assert.are.equal(1, #LlgiSearch:search("dune", 1))
        end)

        it("tries the next mirror and forgets ones that fail", function()
            results(mirrors[2], {fixtures.DUNE})

            assert.are.equal(1, #LlgiSearch:search("dune", 1))
            assert.are.same({searchUrl(mirrors[1]), searchUrl(mirrors[2])}, searches())

            local remaining = {}
            for i = 2, #mirrors do
                table.insert(remaining, mirrors[i])
            end
            assert.are.same(remaining, require("api.urlapi"):getLibgenUrls())
        end)

        it("treats unexpected pages as failures", function()
            web.pages[searchUrl(mirrors[1])] = "<html><body>Under maintenance</body></html>"
            results(mirrors[2], {fixtures.DUNE})

            assert.are.equal(1, #LlgiSearch:search("dune", 1))
        end)

        it("scrapes the mirrors again when every mirror fails", function()
            -- every mirror is down until they have been scraped again
            web.pages[searchUrl(mirrors[1])] = function()
                if web.scrapes > 1 then
                    return fixtures.libgenResults({fixtures.DUNE})
                end
            end

            local books = LlgiSearch:search("dune", 1)
            assert.are.equal(2, web.scrapes)
            assert.are.equal(1, #books)
            assert.are.equal("Dune", books[1].title)
        end)

        it("gives up after scraping the mirrors again once", function()
            local books, err = LlgiSearch:search("dune", 1)

            assert.is_nil(books)
            assert.are.equal("failed to connect to server", err)
            assert.are.equal(2, web.scrapes)
            assert.are.equal(2 * #mirrors, #searches())
        end)

        it("says when searches are blocked by ddos protection", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[searchUrl(mirror)] =
                    "<html><head><title>DDoS-Guard</title></head><body>Checking your browser</body></html>"
            end

            local books, err = LlgiSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("Library Genesis is blocking automated searches right now, try again later", err)
            -- the mirrors work, so they are kept and not scraped again
            assert.are.equal(1, web.scrapes)
            assert.are.same(mirrors, require("api.urlapi"):getLibgenUrls())
        end)

        it("fails when the mirrors cannot be scraped", function()
            web.wikipedia_down = true

            local books, err = LlgiSearch:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("no Library Genesis urls available", err)
        end)

        -- catches Library Genesis changing its results page, like Anna's Archive blocking searches did (#24)
        it("finds books on the live Library Genesis site", function()
            web.live = true
            local books, err = LlgiSearch:search("frank herbert dune", 1)

            assert.is_nil(err)
            assert.is_true(#books > 0, "no books found")
            for _, book in ipairs(books) do
                assert.matches("^%x+$", book.md5)
                assert.are.equal(32, #book.md5)
                assert.is_true(#book.title > 0)
                assert.is_truthy(({epub = true, pdf = true, cbr = true, cbz = true})[book.file_type])
            end
        end)
    end)
end)
