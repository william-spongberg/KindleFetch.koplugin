local helper = require("helper")
local fixtures = require("fixtures")

describe("GutenbergSearch", function()
    local web, GutenbergSearch, Settings

    -- a book in the catalogue's search feed, as it lists them
    local function entry(id, title, author)
        return string.format(
            "<entry>\n<updated>2026-10-15T12:46:19Z</updated>\n<id>https://www.gutenberg.org/ebooks/%d.opds</id>\n"
                .. '<title>%s</title>\n<content type="text">%s</content>\n<link type="application/atom+xml;'
                .. 'profile=opds-catalog" rel="subsection" href="/ebooks/%d.opds"/>\n<link type="image/png" '
                .. 'rel="http://opds-spec.org/image/thumbnail" href="data:image/png;base64,iVBORw0KGgo="/>\n</entry>\n',
            id,
            title,
            author,
            id
        )
    end

    -- what it lists first for a search that names an author, which isn't a book
    local AUTHORS = "<entry>\n<id>https://www.gutenberg.org/ebooks/authors/search.opds/?query=austen</id>\n"
        .. "<title>Authors</title>\n</entry>\n"

    -- the link to the next page of results, where there are more
    local NEXT_PAGE = '<link rel="next" title="Next Page" type="application/atom+xml;profile=opds-catalog" '
        .. 'href="/ebooks/search.opds/?query=dickens&amp;start_index=26"/>\n'

    -- the catalogue's search feed, with the entries, and a link to the next page where there's more
    local function feed(entries, more)
        return '<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom">\n'
            .. "<opensearch:itemsPerPage>25</opensearch:itemsPerPage>\n"
            .. (more and NEXT_PAGE or "")
            .. table.concat(entries)
            .. "</feed>\n"
    end

    -- a book's entry in the catalogue, with its files (each its address and how many bytes it is)
    local function catalogueEntry(files)
        local links = {}
        for _, file in ipairs(files) do
            table.insert(
                links,
                string.format(
                    '<link type="application/epub+zip" rel="http://opds-spec.org/acquisition" title="A file" '
                        .. 'length="%d" href="%s"/>',
                    file[2],
                    file[1]
                )
            )
        end
        return '<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom">\n<entry>\n'
            .. table.concat(links, "\n")
            .. "\n</entry>\n</feed>\n"
    end

    local PRIDE_FILES = {
        { "https://www.gutenberg.org/ebooks/1342.epub.noimages", 400000 },
        { "https://www.gutenberg.org/ebooks/1342.kindle.noimages", 500000 },
        { "https://www.gutenberg.org/ebooks/1342.epub3.images", 25165824 },
        { "https://www.gutenberg.org/ebooks/1342.epub.images", 25000000 },
        { "https://www.gutenberg.org/ebooks/1342.kf8.images", 26000000 },
        { "https://www.gutenberg.org/ebooks/1342.kindle.images", 27000000 },
        { "https://www.gutenberg.org/ebooks/1342.txt.utf-8", 772000 },
    }

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        GutenbergSearch = require("api.gutenbergsearch")
        Settings = require("settings.settings")
    end)

    after_each(helper.cleanup)

    describe("parseResults", function()
        it("reads each book's title, authors, language and cover, in the first of the file types it has", function()
            local books, results, more = GutenbergSearch.parseResults(
                feed({ entry(1342, "Pride and Prejudice", "Jane Austen") }),
                { "en" },
                { "pdf", "epub", "txt" }
            )
            assert.are.equal(1, results)
            assert.is_false(more)
            assert.are.same({
                source = "gutenberg",
                id = "gutenberg_1342",
                gutenberg_id = 1342,
                title = "Pride and Prejudice",
                display_title = "Pride and Prejudice",
                authors = "Jane Austen",
                language = "English",
                file_type = "epub",
                image_url = "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg",
            }, books[1])
        end)

        -- as the catalogue says after the titles of those not in English
        it("reads the language from the end of the title, leaving it out of the title", function()
            local books = GutenbergSearch.parseResults(
                feed({ entry(23700, "Der Weihnachtsabend (German)", "Charles Dickens") }),
                { "de" },
                { "epub" }
            )
            assert.are.equal("German", books[1].language)
            assert.are.equal("Der Weihnachtsabend", books[1].display_title)
        end)

        -- which the catalogue can only be asked for one of at once (see buildUrl)
        it("keeps the books in the languages chosen", function()
            local books, results = GutenbergSearch.parseResults(
                feed({
                    entry(98, "A Tale of Two Cities", "Charles Dickens"),
                    entry(23700, "Der Weihnachtsabend (German)", "Charles Dickens"),
                    entry(13771, "Aventures de Monsieur Pickwick, Vol. I (French)", "Charles Dickens"),
                }),
                { "en", "fr" },
                { "epub" }
            )
            assert.are.equal(3, results)
            assert.are.same({ "A Tale of Two Cities", "Aventures de Monsieur Pickwick, Vol. I" }, {
                books[1].display_title,
                books[2].display_title,
            })
        end)

        -- rather than leaving the book out, as one in no language chosen
        it("takes brackets at the end of a title that aren't a language as part of it, in English", function()
            local books = GutenbergSearch.parseResults(
                feed({ entry(1, "Poems (Selected)", "Someone") }),
                { "en" },
                { "epub" }
            )
            assert.are.equal(1, #books)
            assert.are.equal("English", books[1].language)
        end)

        -- as a search that names one lists them first
        it("leaves out authors, which aren't books", function()
            local books, results = GutenbergSearch.parseResults(
                feed({ AUTHORS, entry(1342, "Pride and Prejudice", "Jane Austen") }),
                { "en" },
                { "epub" }
            )
            assert.are.equal(1, #books)
            assert.are.equal(1, results)
        end)

        it("reads what's escaped in the feed", function()
            local books = GutenbergSearch.parseResults(
                feed({ entry(2, "Sense &amp; Sensibility", "Jane Austen") }),
                { "en" },
                { "epub" }
            )
            assert.are.equal("Sense & Sensibility", books[1].display_title)
        end)

        it("says when there are more pages", function()
            local _, _, more = GutenbergSearch.parseResults(feed({ entry(98, "A Tale", "Dickens") }, true), { "en" }, {
                "epub",
            })
            assert.is_true(more)
        end)

        it("isn't fooled by what isn't the catalogue's feed", function()
            assert.is_nil(GutenbergSearch.parseResults("<html>Bad Gateway</html>", { "en" }, { "epub" }))
        end)
    end)

    describe("search", function()
        -- as it can't be asked for several at once (see parseResults)
        it("searches in the one language chosen, where only one is", function()
            assert.are.equal(
                "https://www.gutenberg.org/ebooks/search.opds/?query=dickens%20l.de",
                GutenbergSearch.buildUrl("dickens", 1, { "de" })
            )
            assert.are.equal(
                "https://www.gutenberg.org/ebooks/search.opds/?query=dickens&start_index=26",
                GutenbergSearch.buildUrl("dickens", 2, { "en", "fr" })
            )
        end)

        it("finds the books, and the page to carry on from", function()
            Settings:setPreferredFileTypes({ "epub" })
            web.pages[GutenbergSearch.buildUrl("dickens", 1, Settings:getPreferredLanguages())] =
                feed({ entry(98, "A Tale of Two Cities", "Charles Dickens") }, true)

            local books, err, next_page, results_read = GutenbergSearch:search("dickens", 1)
            assert.is_nil(err)
            assert.are.equal(1, #books)
            assert.are.equal(2, next_page)
            assert.are.equal(1, results_read)
            -- and saves them, to show again without searching
            assert.is_true(GutenbergSearch:isCached("dickens", 1))
        end)

        it("says when it has none of the file types chosen, without searching", function()
            Settings:setPreferredFileTypes({ "pdf", "cbz" })
            local books, err = GutenbergSearch:search("emma", 1)
            assert.is_nil(books)
            assert.are.equal(require("util.errors").NO_FILE_TYPES, err)
            assert.are.same({}, web.fetched)
        end)

        it("says when it didn't answer, or answered with an error", function()
            Settings:setPreferredFileTypes({ "epub" })
            local _, err = GutenbergSearch:search("emma", 1)
            assert.are.equal("Project Gutenberg didn't answer (failed to connect to server)", err)

            web.pages[GutenbergSearch.buildUrl("emma", 1, Settings:getPreferredLanguages())] = function()
                return "<html>Service Unavailable</html>", nil, 503
            end
            _, err = GutenbergSearch:search("emma", 1)
            assert.are.equal("Project Gutenberg answered with an error (HTTP 503), try again later", err)
        end)
    end)

    describe("findDownloadLink", function()
        local function book(file_type)
            return { id = "gutenberg_1342", gutenberg_id = 1342, file_type = file_type }
        end

        it("downloads the best file in the book's file type, with how many bytes it is", function()
            web.pages["https://www.gutenberg.org/ebooks/1342.opds"] = catalogueEntry(PRIDE_FILES)
            local url, err, mirror_failed, listed = GutenbergSearch:findDownloadLink(book("epub"))
            assert.are.equal("https://www.gutenberg.org/ebooks/1342.epub3.images", url)
            assert.is_nil(err)
            assert.is_nil(mirror_failed)
            assert.are.same({ bytes = 25165824 }, listed)

            -- rather than a KF8, which KOReader can't open
            assert.are.equal(
                "https://www.gutenberg.org/ebooks/1342.kindle.images",
                GutenbergSearch:findDownloadLink(book("mobi"))
            )
            assert.are.equal(
                "https://www.gutenberg.org/ebooks/1342.txt.utf-8",
                GutenbergSearch:findDownloadLink(book("txt"))
            )
        end)

        -- as its audiobooks aren't in any
        it("says when the book isn't in its file type", function()
            web.pages["https://www.gutenberg.org/ebooks/1342.opds"] = catalogueEntry({})
            local url, err = GutenbergSearch:findDownloadLink(book("epub"))
            assert.is_nil(url)
            assert.are.equal("Project Gutenberg doesn't have this book as EPUB", err)
        end)

        it("says when the catalogue didn't answer", function()
            local url, err = GutenbergSearch:findDownloadLink(book("epub"))
            assert.is_nil(url)
            assert.are.equal("Project Gutenberg didn't answer (failed to connect to server)", err)
        end)
    end)

    describe("on the live Project Gutenberg site #live", function()
        before_each(function()
            web.live = true
        end)

        it("finds books, and their download links", function()
            Settings:setPreferredFileTypes({ "epub" })
            local books, err = GutenbergSearch:search("pride and prejudice austen", 1)

            assert.is_nil(err)
            assert.is_true(#books > 0, "no books found")
            for _, b in ipairs(books) do
                assert.matches("^gutenberg_%d+$", b.id)
                assert.are.equal("epub", b.file_type)
            end
            local url, link_err = GutenbergSearch:findDownloadLink(books[1])
            assert.is_nil(link_err)
            assert.matches("^https://www%.gutenberg%.org/ebooks/%d+%.epub", url)
        end)
    end)
end)
