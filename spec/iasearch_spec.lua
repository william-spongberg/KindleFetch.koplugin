local helper = require("helper")
local fixtures = require("fixtures")

describe("IaSearch", function()
    local web, IaSearch, Settings

    local SEARCH_URL = "https://archive.org/advancedsearch.php?"

    -- the search IaSearch makes for the query, with the preferred languages and file types
    local function searchUrl(query, page)
        local search =
            IaSearch.buildQuery(query or "emma", Settings:getPreferredLanguages(), Settings:getPreferredFileTypes())
        return SEARCH_URL .. IaSearch.buildParams(search, page or 1)
    end

    local function results(docs, total, page)
        web.pages[searchUrl(nil, page)] = fixtures.archiveResults(docs, total)
    end

    -- Emma as Internet Archive describes it, with the fields given changed (or left out, when false)
    local function doc(overrides)
        local d = helper.deepCopy(fixtures.ARCHIVE_EMMA)
        for k, v in pairs(overrides or {}) do
            if v == false then
                d[k] = nil
            else
                d[k] = v
            end
        end
        return d
    end

    local function searches()
        local urls = {}
        for _, url in ipairs(web.fetched) do
            if url:find(SEARCH_URL, 1, true) then
                table.insert(urls, url)
            end
        end
        return urls
    end

    -- the search sent, as it reads before it's escaped for the address
    local function sentSearch(url)
        local q = url:match("[?&]q=([^&]*)")
        return (q:gsub("%%(%x%x)", function(hex)
            return string.char(tonumber(hex, 16))
        end))
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        IaSearch = require("api.iasearch")
        Settings = require("settings.settings")
    end)

    after_each(helper.cleanup)

    describe("buildQuery", function()
        it("looks for each word in the title or the author's name", function()
            local search = IaSearch.buildQuery("emma austen", { "en" }, { "epub" })
            assert.matches(
                '^%(title:"emma" OR creator:"emma"%) AND %(title:"austen" OR creator:"austen"%) AND ',
                search
            )
        end)

        -- most of its books are lent out instead, as files only its app can open
        it("only looks for texts that anyone can download", function()
            local search = IaSearch.buildQuery("emma", { "en" }, { "epub" })
            assert.is_truthy(search:find(" AND mediatype:texts AND NOT access-restricted-item:true AND ", 1, true))
        end)

        it("looks for the formats the preferred file types are in, leaving out those it doesn't have", function()
            local search = IaSearch.buildQuery("emma", { "en" }, { "epub", "fb2", "pdf", "txt" })
            assert.is_truthy(
                search:find(
                    ' AND format:("EPUB" OR "Text PDF" OR "Image Container PDF" OR "Text" OR "DjVuTXT")',
                    1,
                    true
                )
            )
        end)

        it("looks for books in the preferred languages, by any of their names, or with no language", function()
            local search = IaSearch.buildQuery("emma", { "en", "de" }, { "epub" })
            local languages = ' AND (language:("eng" OR "English" OR "en" OR "ger" OR "deu" OR "German" OR "de")'
                .. " OR (mediatype:texts AND NOT language:[* TO *]))"
            assert.are.equal(languages, search:sub(-#languages))
        end)

        it("doesn't narrow the search down by language when every language is chosen", function()
            local every = {}
            for _, language in ipairs(Settings:getAvailableLanguages()) do
                table.insert(every, language.code)
            end
            assert.is_nil(IaSearch.buildQuery("emma", every, { "epub" }):find("language:", 1, true))
        end)

        -- which its search would otherwise read as more than what they are
        it("escapes quotes and backslashes in the words searched for", function()
            local search = IaSearch.buildQuery('"emma\\', { "en" }, { "epub" })
            assert.matches('^%(title:"\\"emma\\\\" OR creator:"\\"emma\\\\"%)', search)
        end)

        it("leaves out words that are only punctuation, and finds nothing to search for without any others", function()
            assert.matches(
                '^%(title:"emma" OR creator:"emma"%) AND mediatype',
                IaSearch.buildQuery("- emma :", { "en" }, { "epub" })
            )
            assert.is_nil(IaSearch.buildQuery(" - : ", { "en" }, { "epub" }))
        end)

        it("searches for words in other alphabets", function()
            assert.matches(
                '^%(title:"анна" OR creator:"анна"%)',
                IaSearch.buildQuery("анна", { "ru" }, { "epub" })
            )
        end)
    end)

    describe("search", function()
        it("asks for the most downloaded books first, 50 to a page", function()
            IaSearch:search("emma", 3)

            local url = searches()[1]
            assert.are.equal(1, #searches())
            assert.matches("&sort%%5B%%5D=downloads%%20desc&rows=50&page=3&output=json$", url)
            assert.is_truthy(url:find("&fl%5B%5D=identifier&fl%5B%5D=title&fl%5B%5D=creator", 1, true))
            assert.matches('^%(title:"emma" OR creator:"emma"%) AND mediatype:texts', sentSearch(url))
        end)

        it("reads each book from the results", function()
            results({ doc(), doc({ identifier = "emmanovel0000aust", title = "Emma", creator = "Jane Austen" }) })
            local books, err, next_page, results_read = IaSearch:search("emma", 1)

            assert.is_nil(err)
            assert.are.equal(2, #books)
            assert.is_nil(next_page)
            assert.are.equal(2, results_read)
            assert.are.same({
                source = "archive",
                id = "archive_emma00aust",
                identifier = "emma00aust",
                title = "Emma - a novel",
                display_title = "Emma : a novel",
                authors = "Jane Austen, Hugh Thomson",
                year = "1816",
                language = "English",
                file_type = "epub",
                image_url = "https://archive.org/services/img/emma00aust",
            }, books[1])
            assert.are.equal("Jane Austen", books[2].authors)
            -- the search and what it found, for crash.log
            assert.is_truthy(helper.logged("info", '^searching Internet Archive for "emma" from page 1, in en, as '))
            assert.is_truthy(
                helper.logged("info", "^page 1 of Internet Archive's 2 results: kept 2 of its 2, the last$")
            )
        end)

        -- as a library writes them
        it("names the authors with their surnames last, without when they lived or what they did", function()
            results({
                doc({
                    identifier = "a",
                    creator = { "Austen, Jane, 1775-1817, author", "Thomson, Hugh, 1860-1920, ill." },
                }),
                doc({ identifier = "b", creator = "Chapman, R. W. (Robert William), 1881-1960; Austen, Jane" }),
                doc({ identifier = "c", creator = { "Standard Ebooks", "Jane Austen", "Austen, Jane" } }),
            })

            local books = IaSearch:search("emma", 1)
            assert.are.same(
                { "Jane Austen, Hugh Thomson", "R. W. Chapman, Jane Austen", "Standard Ebooks, Jane Austen" },
                { books[1].authors, books[2].authors, books[3].authors }
            )
        end)

        it("gives each book the preferred file type it has, the first chosen", function()
            Settings:setPreferredFileTypes({ "pdf", "epub", "mobi" })
            results({
                doc({ identifier = "a", format = { "EPUB", "Text PDF" } }),
                doc({ identifier = "b", format = { "MOBI", "EPUB" } }),
                -- in whatever capitals it's written in
                doc({ identifier = "c", format = { "Mobi" } }),
            })

            local books = IaSearch:search("emma", 1)
            assert.are.same({ "pdf", "epub", "mobi" }, { books[1].file_type, books[2].file_type, books[3].file_type })
        end)

        -- a search for a format also finds those with its name in theirs, such as the Djvu XML every scan has
        it("leaves out books that only have formats whose names include a preferred one's", function()
            Settings:setPreferredFileTypes({ "djvu", "pdf" })
            results({
                doc({ identifier = "a", format = { "Djvu XML", "DjVuTXT" } }),
                doc({ identifier = "b", format = { "Djvu XML", "Additional Text PDF", "Image Container PDF" } }),
            })

            local books, _, _, results_read = IaSearch:search("emma", 1)
            assert.are.equal(1, #books)
            assert.are.equal("b", books[1].identifier)
            assert.are.equal("pdf", books[1].file_type)
            assert.are.equal(2, results_read)
        end)

        it("names the languages a book is in, by whichever of their names it has", function()
            Settings:setPreferredLanguages({ "en", "de", "la" })
            results({
                doc({ identifier = "a", language = "English" }),
                doc({ identifier = "b", language = "ger;lat" }),
                doc({ identifier = "c", language = { "en", "Klingon" } }),
                doc({ identifier = "d", language = false }),
            })

            local books = IaSearch:search("emma", 1)
            assert.are.same(
                { "English", "German, Latin", "English, Klingon" },
                { books[1].language, books[2].language, books[3].language }
            )
            assert.is_nil(books[4].language)
        end)

        it("leaves out what isn't known about a book", function()
            results({
                doc({ identifier = "a", creator = false, year = "0000", language = false }),
                doc({ identifier = "b", year = "about 1900" }),
            })

            local books = IaSearch:search("emma", 1)
            assert.are.equal("Unknown author", books[1].authors)
            assert.is_nil(books[1].year)
            assert.is_nil(books[1].language)
            assert.is_nil(books[2].year)
        end)

        -- its address is made from its identifier
        it("skips books without an identifier or a title, or with an identifier that isn't one", function()
            results({
                doc({ identifier = false }),
                doc({ title = false }),
                doc({ identifier = "a/../../b" }),
                doc({ identifier = "fine" }),
            })

            local books, _, _, results_read = IaSearch:search("emma", 1)
            assert.are.equal(1, #books)
            assert.are.equal("fine", books[1].identifier)
            assert.are.equal(4, results_read)
        end)

        it("carries on from the next page while there are more results", function()
            results({ doc() }, 120, 2)
            local _, _, next_page = IaSearch:search("emma", 2)
            assert.are.equal(3, next_page)
        end)

        it("stops at the last page", function()
            results({ doc() }, 150, 3)
            local _, _, next_page = IaSearch:search("emma", 3)
            assert.is_nil(next_page)
        end)

        it("saves the books found, to show again without searching", function()
            results({ doc() })
            IaSearch:search("emma", 1)

            assert.is_true(IaSearch:isCached("emma", 1))
            local books = IaSearch:search("emma", 1)
            assert.are.equal(1, #searches())
            assert.are.equal("emma00aust", books[1].identifier)
            -- unlike Library Genesis' results for the same search
            assert.is_false(require("api.lglisearch"):isCached("emma", 1))
        end)

        it("doesn't save a search that found nothing, which may have been an error", function()
            results({})
            IaSearch:search("emma", 1)
            assert.is_false(IaSearch:isCached("emma", 1))
        end)

        it("says when Internet Archive doesn't answer", function()
            local books, err = IaSearch:search("emma", 1)
            assert.is_nil(books)
            assert.are.equal("Internet Archive didn't answer (failed to connect to server)", err)
        end)

        it("says when Internet Archive answers with an error", function()
            web.pages[searchUrl()] = function()
                return "<html>Service Unavailable</html>", nil, 503
            end

            local books, err = IaSearch:search("emma", 1)
            assert.is_nil(books)
            assert.are.equal("Internet Archive answered with an error (HTTP 503), try again later", err)
        end)

        it("says when Internet Archive answers with something other than results", function()
            web.pages[searchUrl()] = "<html>Down for maintenance</html>"

            local books, err = IaSearch:search("emma", 1)
            assert.is_nil(books)
            assert.are.equal("unexpected response from Internet Archive", err)
            assert.matches("Down for maintenance", helper.logged("warn", "^unexpected search results from"))
        end)

        it("passes on that the search was called off", function()
            web.pages[searchUrl()] = function()
                return nil, require("util.httputil").CANCELLED
            end

            local books, err = IaSearch:search("emma", 1)
            assert.is_nil(books)
            assert.are.equal(require("util.httputil").CANCELLED, err)
        end)

        it("says when Internet Archive has none of the file types chosen, without searching", function()
            Settings:setPreferredFileTypes({ "fb2", "azw" })

            local books, err = IaSearch:search("emma", 1)
            assert.is_nil(books)
            -- which the search box explains, offering the settings
            assert.are.equal(require("util.errors").NO_FILE_TYPES, err)
            assert.are.equal(0, #searches())
        end)

        it("finds nothing for a search that's only punctuation, without searching", function()
            local books, err, next_page, results_read = IaSearch:search("?!", 1)
            assert.are.same({}, books)
            assert.is_nil(err)
            assert.is_nil(next_page)
            assert.are.equal(0, results_read)
            assert.are.equal(0, #searches())
        end)
    end)

    describe("findDownloadLink", function()
        local FILES_URL = "https://archive.org/metadata/emma00aust/files"
        local book

        before_each(function()
            book = {
                source = "archive",
                id = "archive_emma00aust",
                identifier = "emma00aust",
                title = "Emma",
                file_type = "pdf",
            }
        end)

        it("links to the file in the best of the formats its file type can be in", function()
            web.pages[FILES_URL] = fixtures.archiveFiles({
                { name = "emma00aust_images.pdf", format = "Image Container PDF", size = "90000000" },
                { name = "emma00aust_text.pdf", format = "Text PDF", size = "9000000" },
                { name = "emma00aust.epub", format = "EPUB", size = "900000" },
            })

            local url, err = IaSearch.findDownloadLink(book)
            assert.is_nil(err)
            assert.are.equal("https://archive.org/download/emma00aust/emma00aust_text.pdf", url)
            assert.is_truthy(
                helper.logged("info", '^downloading emma00aust\'s Text PDF file "emma00aust_text.pdf", 9000000 bytes$')
            )
        end)

        it("links to the first file in the format, when there are several", function()
            book.file_type = "epub"
            web.pages[FILES_URL] = fixtures.archiveFiles({
                { name = "pg158-images.epub", format = "EPUB" },
                { name = "pg158.epub", format = "EPUB" },
            })

            assert.are.equal(
                "https://archive.org/download/emma00aust/pg158-images.epub",
                IaSearch.findDownloadLink(book)
            )
        end)

        it("escapes what's in the file's name and folder, keeping the folders apart", function()
            book.file_type = "txt"
            web.pages[FILES_URL] = fixtures.archiveFiles({
                { name = "texts/Emma (1816) & more.txt", format = "Text" },
            })

            assert.are.equal(
                "https://archive.org/download/emma00aust/texts/Emma%20%281816%29%20%26%20more.txt",
                IaSearch.findDownloadLink(book)
            )
        end)

        -- e.g. it has been taken down since it was found, which leaves its folder empty
        it("says when the book isn't there in its file type any more", function()
            web.pages[FILES_URL] = "{}"

            local url, err = IaSearch.findDownloadLink(book)
            assert.is_nil(url)
            assert.are.equal("Internet Archive no longer has this book as PDF", err)
        end)

        -- for crash.log, which said only how big it was
        it("logs what Internet Archive answered with when it can't be read", function()
            web.pages[FILES_URL] = "<html><body>Bad gateway</body></html>"

            local url = IaSearch.findDownloadLink(book)
            assert.is_nil(url)
            local logged = helper.logged("warn", "^unexpected list of files from Internet Archive")
            assert.matches("37 bytes, which", logged, 1, true)
            assert.matches("Bad gateway", logged, 1, true)
        end)

        it("says when Internet Archive doesn't answer, without looking the link up again", function()
            local url, err, look_again = IaSearch.findDownloadLink(book)
            assert.is_nil(url)
            assert.are.equal("Internet Archive didn't answer (failed to connect to server)", err)
            assert.is_falsy(look_again)
        end)

        it("says when Internet Archive answers with an error", function()
            web.pages[FILES_URL] = function()
                return "<html>Bad gateway</html>", nil, 502
            end

            local url, err = IaSearch.findDownloadLink(book)
            assert.is_nil(url)
            assert.are.equal("Internet Archive answered with an error (HTTP 502), try again later", err)
        end)

        it("passes on that it was called off", function()
            web.pages[FILES_URL] = function()
                return nil, require("util.httputil").CANCELLED
            end

            local url, err = IaSearch.findDownloadLink(book)
            assert.is_nil(url)
            assert.are.equal(require("util.httputil").CANCELLED, err)
        end)
    end)

    -- catches Internet Archive changing its search, or what it says about its books
    describe("on the live Internet Archive site", function()
        before_each(function()
            web.live = true
        end)

        it("finds books, and their download links", function()
            local books, err = IaSearch:search("pride and prejudice austen", 1)

            assert.is_nil(err)
            assert.is_true(#books > 0, "no books found")
            local preferred = {}
            for _, file_type in ipairs(Settings:getPreferredFileTypes()) do
                preferred[file_type] = true
            end
            for _, book in ipairs(books) do
                assert.matches("^archive_[%w%._%-]+$", book.id)
                assert.is_true(#book.title > 0)
                assert.is_truthy(preferred[book.file_type])
            end

            local url
            url, err = IaSearch.findDownloadLink(books[1])
            assert.is_nil(err)
            assert.matches("^https://archive%.org/download/" .. books[1].identifier:gsub("%p", "%%%0") .. "/.+", url)
        end)
    end)
end)
