local helper = require("helper")
local fixtures = require("fixtures")

-- mirrors are scraped from the live Wikipedia page, so these need internet access
describe("AnnasAPI", function()
    local web, mirrors, AnnasAPI

    local function searchUrl(mirror, page, query)
        return string.format("%s/search?page=%d&display=table&src=lgli&q=%s&lang=en&ext=epub&ext=pdf&ext=cbr" ..
                                 "&ext=cbz&content=book_fiction&content=book_comic", mirror, page or 1, query or "dune")
    end

    local function results(mirror, books, page)
        web.pages[searchUrl(mirror, page)] = fixtures.annasResults(books)
    end

    local function searches()
        local urls = {}
        for _, url in ipairs(web.fetched) do
            if url:find("/search?", 1, true) then
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
            return UrlApi:getAnnasUrls()
        end, "Anna's Archive")
        AnnasAPI = require("api.annasapi")
    end)

    after_each(helper.cleanup)

    describe("search", function()
        it("searches Library Genesis books with the preferred filters", function()
            AnnasAPI:search("dune messiah", 2)
            assert.are.equal(searchUrl(mirrors[1], 2, "dune%20messiah"), searches()[1])
        end)

        it("reads each book from the results table", function()
            results(mirrors[1], {fixtures.DUNE, fixtures.MESSIAH})
            local books = AnnasAPI:search("dune", 1)

            assert.are.equal(2, #books)
            assert.are.same({
                md5 = "d41d8cd98f00b204e9800998ecf8427e",
                image_url = "https://covers.example/zlib1/d41d8cd9.jpg",
                title = "Dune",
                display_title = "Dune",
                authors = "Frank Herbert",
                year = "1990",
                language = "English [en]",
                book_type = "Book (fiction)",
                file_type = "epub",
                file_size = "1.2MB"
            }, books[1])
            assert.are.equal("Dune Messiah", books[2].title)
        end)

        it("fills in missing authors and sizes", function()
            results(mirrors[1], {{
                md5 = "abc",
                title = "Anonymous",
                file_type = "epub"
            }})
            local book = AnnasAPI:search("dune", 1)[1]

            assert.are.equal("Unknown author", book.authors)
            assert.are.equal("0", book.file_size)
        end)

        it("shortens long titles and author lists for display", function()
            results(mirrors[1], {{
                md5 = "abc",
                title = string.rep("Long title ", 10),
                authors = string.rep("Author, ", 10),
                file_type = "epub"
            }})
            local book = AnnasAPI:search("dune", 1)[1]

            assert.are.equal(string.rep("Long title ", 10):sub(1, 50) .. "…", book.display_title)
            assert.are.equal(string.rep("Author, ", 10):sub(1, 50) .. "…", book.authors)
        end)

        it("decodes html entities", function()
            results(mirrors[1], {{
                md5 = "abc",
                title = "Pride &amp; Prejudice",
                file_type = "epub"
            }})
            assert.are.equal("Pride & Prejudice", AnnasAPI:search("dune", 1)[1].title)
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
                title = "file: lgli/Dune.epub",
                file_type = "epub"
            }, {
                md5 = "ghi",
                title = "Too few cells",
                file_type = "epub",
                cells = 9
            }, fixtures.DUNE})
            local books = AnnasAPI:search("dune", 1)

            assert.are.equal(1, #books)
            assert.are.equal("Dune", books[1].title)
        end)

        it("caches results", function()
            results(mirrors[1], {fixtures.DUNE})
            AnnasAPI:search("dune", 1)
            AnnasAPI:search("dune", 1)

            assert.are.equal(1, #searches())
        end)

        it("does not cache searches that found nothing", function()
            results(mirrors[1], {})
            assert.are.same({}, AnnasAPI:search("dune", 1))

            results(mirrors[1], {fixtures.DUNE})
            assert.are.equal(1, #AnnasAPI:search("dune", 1))
        end)

        it("tries the next mirror and forgets ones that fail", function()
            results(mirrors[2], {fixtures.DUNE})

            assert.are.equal(1, #AnnasAPI:search("dune", 1))
            assert.are.same({searchUrl(mirrors[1]), searchUrl(mirrors[2])}, searches())

            local remaining = {}
            for i = 2, #mirrors do
                table.insert(remaining, mirrors[i])
            end
            assert.are.same(remaining, require("api.urlapi"):getAnnasUrls())
        end)

        it("scrapes the mirrors again when every mirror fails", function()
            -- every mirror is down until they have been scraped again
            web.pages[searchUrl(mirrors[1])] = function()
                if web.scrapes > 1 then
                    return fixtures.annasResults({fixtures.DUNE})
                end
            end

            local books = AnnasAPI:search("dune", 1)
            assert.are.equal(2, web.scrapes)
            assert.are.equal(1, #books)
            assert.are.equal("Dune", books[1].title)
        end)

        it("gives up after scraping the mirrors again once", function()
            local books, err = AnnasAPI:search("dune", 1)

            assert.is_nil(books)
            assert.are.equal("failed to connect to server", err)
            assert.are.equal(2, web.scrapes)
            assert.are.equal(2 * #mirrors, #searches())
        end)

        it("fails when the mirrors cannot be scraped", function()
            web.wikipedia_down = true

            local books, err = AnnasAPI:search("dune", 1)
            assert.is_nil(books)
            assert.are.equal("no Anna's Archive URLs available", err)
        end)
    end)
end)
