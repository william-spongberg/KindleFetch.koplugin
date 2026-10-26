local helper = require("helper")
local fixtures = require("fixtures")

describe("ZlibSearch", function()
    local web, ZlibSearch, Settings

    -- Z-Library's address, as if looked up already (see UrlApi)
    local SITE = "https://z-lib.example"
    local SEARCH_URL = SITE .. "/eapi/book/search"
    local PROFILE_URL = SITE .. "/eapi/user/profile"
    local FILE_URL = SITE .. "/eapi/book/15846732/728638/file"
    local WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Z-Library"
    local KEY = "0123456789abcdef0123456789abcdef"

    -- 1984 as Z-Library describes it, with the fields given changed (or left out, when false)
    local function book(overrides)
        local b = helper.deepCopy(fixtures.ZLIB_1984)
        for k, v in pairs(overrides or {}) do
            if v == false then
                b[k] = nil
            else
                b[k] = v
            end
        end
        return b
    end

    local function results(books, next_page, total)
        web.pages[SEARCH_URL] = fixtures.zlibResults(books, next_page, total)
    end

    -- the value of each of the form's fields with the name, in order
    local function field(form, name)
        local found = {}
        for _, f in ipairs(form) do
            if f[1] == name then
                table.insert(found, f[2])
            end
        end
        return found
    end

    local function searches()
        local found = {}
        for _, request in ipairs(web.requests) do
            if request.url == SEARCH_URL then
                table.insert(found, request)
            end
        end
        return found
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        require("cache.urlcache"):set({ SITE }, "zlib")
        -- where it's looked up again, when its address fails
        web.pages[WIKIPEDIA_URL] = fixtures.wikipediaZlib({ "z-lib.example" })
        Settings = require("settings.settings")
        Settings:setZlibAccount({ email = "reader@example.com", user_id = 42, user_key = KEY })
        ZlibSearch = require("api.zlibsearch")
    end)

    after_each(helper.cleanup)

    describe("buildForm", function()
        it("searches for the query in the preferred languages, by their names, and file types", function()
            local form = ZlibSearch.buildForm("1984 orwell", 2, { "en", "de" }, { "epub", "pdf" })

            assert.are.same({
                { "message", "1984 orwell" },
                { "languages[]", "english" },
                { "languages[]", "german" },
                { "extensions[]", "epub" },
                { "extensions[]", "pdf" },
                { "page", 2 },
                { "limit", 50 },
            }, form)
        end)

        it("doesn't narrow the search down by language when every language is chosen", function()
            local every = {}
            for _, language in ipairs(Settings:getAvailableLanguages()) do
                table.insert(every, language.code)
            end
            assert.are.same({}, field(ZlibSearch.buildForm("1984", 1, every, { "epub" }), "languages[]"))
        end)
    end)

    describe("search", function()
        it("asks as the account logged into", function()
            results({ book() })
            ZlibSearch:search("1984 orwell", 1)

            local request = searches()[1]
            assert.are.equal("remix_userid=42; remix_userkey=" .. KEY, request.cookies)
            assert.are.same({ "1984 orwell" }, field(request.form, "message"))
            assert.are.same({ "english" }, field(request.form, "languages[]"))
            assert.are.same(Settings:getPreferredFileTypes(), field(request.form, "extensions[]"))
        end)

        -- rather than leaving its file named only for its type, e.g. ".epub", which hid it
        it("names a book's file after its title in brackets, or its id when there's nothing else", function()
            results({ book({ title = "[Poems]" }), book({ id = 2, hash = "abc", title = "..." }) })
            local books = ZlibSearch:search("orwell", 1)
            assert.are.equal("[Poems]", books[1].title)
            assert.are.equal("zlib_2", books[2].title)
        end)

        -- which were said to be results in other file types, when Z-Library had changed what it answers with
        it("doesn't count books it can't read as results", function()
            results({ book(), { id = "not a number" }, book({ id = 3, hash = "abc", extension = "azw3" }) })
            local books, err, _, results_read = ZlibSearch:search("orwell", 1)
            assert.is_nil(err)
            assert.are.equal(1, #books)
            assert.are.equal(2, results_read)
        end)

        it("says its results couldn't be read when none of its books can be", function()
            results({ { id = "not a number" }, { title = "no id" } })
            local books, err = ZlibSearch:search("orwell", 1)
            assert.is_nil(books)
            assert.are.equal(require("util.errors").UNREADABLE, err)
        end)

        it("reads each book from the results", function()
            results({
                book(),
                book({ id = 2, hash = "abc", title = "Animal Farm", year = 0, author = "George Orwell" }),
            })
            local books, err, next_page, results_read = ZlibSearch:search("orwell", 1)

            assert.is_nil(err)
            assert.are.equal(2, #books)
            assert.is_nil(next_page)
            assert.are.equal(2, results_read)
            assert.are.same({
                source = "zlib",
                id = "zlib_15846732",
                zlib_id = 15846732,
                hash = "728638",
                title = "Orwell, George - 1984",
                display_title = "Orwell, George - 1984",
                -- without the other way of writing it, in brackets
                authors = "George Orwell",
                year = "2004",
                language = "English",
                file_type = "epub",
                file_size = "2.06 MB",
                image_url = "https://covers.example/covers299/1984.jpg",
            }, books[1])
            -- when it isn't known
            assert.is_nil(books[2].year)
            -- the search and what it found, for crash.log
            assert.is_truthy(helper.logged("info", '^searching Z%-Library for "orwell" from page 1, in en, as '))
            assert.is_truthy(helper.logged("info", "^page 1 of Z%-Library's 2 results: kept 2 of its 2, the last$"))
        end)

        it("carries on from the next page while there are more results", function()
            results({ book() }, 2, 120)
            local _, _, next_page = ZlibSearch:search("1984", 1)
            assert.are.equal(2, next_page)
        end)

        -- in case Z-Library didn't keep to the file types it was asked for
        it("leaves out books in other file types, whatever their capitals", function()
            Settings:setPreferredFileTypes({ "epub" })
            results({ book({ id = 1, extension = "EPUB" }), book({ id = 2, extension = "azw3" }) })

            local books, _, _, results_read = ZlibSearch:search("1984", 1)
            assert.are.equal(1, #books)
            assert.are.equal("epub", books[1].file_type)
            assert.are.equal(2, results_read)
        end)

        it("skips books without an id, a hash that can be sent back, a title or a file type", function()
            results({
                book({ id = false }),
                book({ hash = "../1" }),
                book({ title = false }),
                book({ extension = false }),
                book({ id = 7 }),
            })

            local books = ZlibSearch:search("1984", 1)
            assert.are.equal(1, #books)
            assert.are.equal(7, books[1].zlib_id)
        end)

        it("leaves out what's left of a name that's missing from the authors", function()
            results({ book({ author = "Austen, Jane & " }) })
            assert.are.equal("Austen, Jane", ZlibSearch:search("1984", 1)[1].authors)
        end)

        it("leaves out what isn't known about a book", function()
            results({ book({ author = false, language = false, filesizeString = false, cover = "covers/1984.jpg" }) })

            local books = ZlibSearch:search("1984", 1)
            assert.are.equal("Unknown author", books[1].authors)
            assert.is_nil(books[1].language)
            assert.is_nil(books[1].file_size)
            -- rather than asking curl for an address that isn't just an address
            assert.is_nil(books[1].image_url)
        end)

        it("saves the books found, to show again without searching", function()
            results({ book() })
            ZlibSearch:search("1984", 1)

            assert.is_true(ZlibSearch:isCached("1984", 1))
            local books = ZlibSearch:search("1984", 1)
            assert.are.equal(1, #searches())
            assert.are.equal("zlib_15846732", books[1].id)
            assert.is_false(require("api.iasearch"):isCached("1984", 1))
        end)

        it("says why Z-Library didn't search", function()
            web.pages[SEARCH_URL] = function()
                return fixtures.zlibError("Too many requests"), nil, 429
            end

            local books, err = ZlibSearch:search("1984", 1)
            assert.is_nil(books)
            assert.are.equal("Z-Library says: Too many requests", err)
        end)

        it("says when Z-Library has logged it out", function()
            web.pages[SEARCH_URL] = function()
                return fixtures.zlibError("Please login"), nil, 400
            end

            local books, err = ZlibSearch:search("1984", 1)
            assert.is_nil(books)
            assert.are.equal(require("api.zlibaccount").LOGGED_OUT_ERROR, err)
        end)

        it("says when Z-Library answers without any books", function()
            web.pages[SEARCH_URL] = '{"success":1}'

            local books, err = ZlibSearch:search("1984", 1)
            assert.is_nil(books)
            assert.are.equal("unexpected response from Z-Library", err)
        end)

        it("says when Z-Library doesn't answer", function()
            local books, err = ZlibSearch:search("1984", 1)
            assert.is_nil(books)
            assert.are.equal("Z-Library didn't answer (failed to connect to server)", err)
        end)
    end)

    describe("findDownloadLink", function()
        local zlib_book

        local function profile(downloaded, limit)
            web.pages[PROFILE_URL] = require("dkjson").encode({
                success = 1,
                user = { id = 42, downloads_today = downloaded, downloads_limit = limit },
            })
        end

        before_each(function()
            zlib_book = {
                source = "zlib",
                id = "zlib_15846732",
                zlib_id = 15846732,
                hash = "728638",
                title = "1984",
                file_type = "epub",
            }
            profile(3, 10)
            web.pages[FILE_URL] = require("dkjson").encode({
                success = 1,
                file = {
                    downloadLink = "https://dl.example/books/1984.epub?token=abc",
                    extension = "epub",
                    allowDownload = true,
                },
            })
        end)

        it("asks Z-Library for the link, as the account logged into", function()
            local url, err = ZlibSearch.findDownloadLink(zlib_book)

            assert.is_nil(err)
            assert.are.equal("https://dl.example/books/1984.epub?token=abc", url)
            assert.are.equal("remix_userid=42; remix_userkey=" .. KEY, web.requests[#web.requests].cookies)
            assert.is_truthy(helper.logged("info", "^the account can download 7 more of its 10 books today$"))
        end)

        -- each link counts even if the book doesn't download, but the same book's again doesn't, yet that was refused
        it("asks for a book's link again the same day, once the account has downloaded as many as it can", function()
            assert.is_not_nil(ZlibSearch.findDownloadLink(zlib_book))
            profile(10, 10)
            assert.are.equal("https://dl.example/books/1984.epub?token=abc", ZlibSearch.findDownloadLink(zlib_book))

            -- but not another book's
            local other = { source = "zlib", id = "zlib_7", zlib_id = 7, hash = "abc", title = "Emma" }
            local url, err = ZlibSearch.findDownloadLink(other)
            assert.is_nil(url)
            assert.matches("which it has today", err, 1, true)
        end)

        it("doesn't ask for the link once the account has downloaded as many books as it can today", function()
            profile(10, 10)

            local url, err = ZlibSearch.findDownloadLink(zlib_book)
            assert.is_nil(url)
            assert.are.equal(
                "Z-Library lets this account download 10 books a day, which it has today, so try again tomorrow",
                err
            )
            for _, request in ipairs(web.requests) do
                assert.are_not.equal(FILE_URL, request.url)
            end
        end)

        -- as each link goes to one of its servers, picked at random, and asking for the same book's again doesn't count
        describe("once the server a link went to has failed", function()
            local hosts

            before_each(function()
                hosts = {}
                web.pages[FILE_URL] = function()
                    local host = table.remove(hosts, 1) or "dl-failed.example"
                    return string.format('{"success":1,"file":{"downloadLink":"https://%s/1984.epub"}}', host)
                end
            end)

            local function linksAskedFor()
                local count = 0
                for _, request in ipairs(web.requests) do
                    if request.url == FILE_URL then
                        count = count + 1
                    end
                end
                return count
            end

            it("asks for links until one goes to another server", function()
                hosts = { "dl-failed.example", "dl-failed.example", "dl-other.example" }

                local url = ZlibSearch.findDownloadLink(zlib_book, true, "https://dl-failed.example/1984.epub?t=1")
                assert.are.equal("https://dl-other.example/1984.epub", url)
                assert.are.equal(3, linksAskedFor())
            end)

            it("gives the last link it was given once it has asked a few times", function()
                local url = ZlibSearch.findDownloadLink(zlib_book, true, "https://dl-failed.example/1984.epub?t=1")
                assert.are.equal("https://dl-failed.example/1984.epub", url)
                assert.are.equal(4, linksAskedFor())
            end)

            it(
                "asks even when the account has downloaded as many books as it can today, as it doesn't count",
                function()
                    profile(10, 10)
                    hosts = { "dl-other.example" }

                    local url = ZlibSearch.findDownloadLink(zlib_book, true, "https://dl-failed.example/1984.epub?t=1")
                    assert.are.equal("https://dl-other.example/1984.epub", url)
                end
            )
        end)

        it("says why Z-Library didn't give the link", function()
            web.pages[FILE_URL] = function()
                return fixtures.zlibError("Invalid hash"), nil, 400
            end

            local url, err = ZlibSearch.findDownloadLink(zlib_book)
            assert.is_nil(url)
            assert.are.equal("Z-Library says: Invalid hash", err)
        end)

        -- which is passed on to curl
        it("won't use a link that isn't just an address", function()
            web.pages[FILE_URL] = '{"success":1,"file":{"downloadLink":"https://dl.example/a b\\"c"}}'

            local url, err = ZlibSearch.findDownloadLink(zlib_book)
            assert.is_nil(url)
            assert.are.equal("Z-Library didn't give a download link", err)
            -- saying what it gave instead, but not the link, which carries a key
            assert.are.equal(
                "Z-Library didn't give a download link that can be used, answering with a link to dl.example",
                helper.logged("warn", "^Z%-Library didn't give a download link")
            )
        end)

        it("says when Z-Library has logged it out, without asking for the link", function()
            web.pages[PROFILE_URL] = function()
                return fixtures.zlibError("Please login"), nil, 400
            end

            local url, err = ZlibSearch.findDownloadLink(zlib_book)
            assert.is_nil(url)
            assert.are.equal(require("api.zlibaccount").LOGGED_OUT_ERROR, err)
            assert.are.equal(1, #web.requests)
        end)
    end)

    -- catches Z-Library changing its search, skipped without an account (as in CI). no download link, as each counts
    local email, password = os.getenv("KINDLEFETCH_ZLIB_EMAIL"), os.getenv("KINDLEFETCH_ZLIB_PASSWORD")
    -- (or empty, as the Canary workflow gives them where the repository has no secrets of those names)
    if email and email ~= "" and password and password ~= "" then
        it("finds books on the live Z-Library site #live", function()
            web.live = true
            -- at the addresses Wikipedia lists
            require("cache.urlcache"):clear()
            web.pages[WIKIPEDIA_URL] = nil
            assert.is_true(require("api.zlibaccount"):login(email, password))

            local books, err = ZlibSearch:search("pride and prejudice austen", 1)
            assert.is_nil(err)
            assert.is_true(#books > 0, "no books found")
            local preferred = {}
            for _, file_type in ipairs(Settings:getPreferredFileTypes()) do
                preferred[file_type] = true
            end
            for _, found in ipairs(books) do
                assert.matches("^zlib_%d+$", found.id)
                assert.matches("^%w+$", found.hash)
                assert.is_true(#found.title > 0)
                assert.is_truthy(preferred[found.file_type])
            end
        end)
    else
        pending("finds books on the live Z-Library site (needs KINDLEFETCH_ZLIB_EMAIL and KINDLEFETCH_ZLIB_PASSWORD)")
    end
end)
