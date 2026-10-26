local helper = require("helper")
local fixtures = require("fixtures")

describe("Site", function()
    local web, Site, HttpUtil

    -- a page of the test site's results, a title a line, saying there are more where there are
    local function results(titles, more)
        return "books" .. (more and " more" or "") .. "\n" .. table.concat(titles, "\n")
    end

    -- a site searched at an address made from the query (none for an empty one), whose results are as above
    local function testSite(fields)
        local site = Site:extend {
            NAME = "Test Site",
            SOURCE = "test",
        }
        function site:searchUrl(search)
            if search.query == "" then
                return nil
            end
            return "https://books.example/?q=" .. search.query .. "&page=" .. search.page
        end
        function site:parsePage(body, __, search)
            local header, rest = body:match("^(books[^\n]*)\n?(.*)$")
            if not header then
                return nil
            end
            local books = {}
            for title in rest:gmatch("[^\n]+") do
                table.insert(books, { source = "test", id = "test_" .. title, title = title })
            end
            return books, #books, header:find("more") and search.page + 1 or nil
        end
        for key, value in pairs(fields or {}) do
            site[key] = value
        end
        return site
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        web = fixtures.fakeWeb(helper)
        Site = require("api.site")
        HttpUtil = require("util.httputil")
    end)

    after_each(helper.cleanup)

    it("has what a site has, where a kind of site doesn't say otherwise", function()
        local site = testSite({ NEEDS_LOGIN = true })
        assert.is_true(site.NEEDS_LOGIN)
        assert.is_false(site.HAS_BOOK_TYPES)
        assert.is_false(site.NEW_LINK_WHEN_SERVER_FAILS)
        assert.is_true(site.SAVES_SEARCHES)
        assert.is_nil(site.SCOPES)
    end)

    it("searches a page of results at its address, saying how many it kept", function()
        web.pages["https://books.example/?q=austen&page=1"] = results({ "Emma", "Persuasion" }, true)

        local books, err, next_page, results_read = testSite():search("austen", 1)
        assert.is_nil(err)
        assert.are.same({ "Emma", "Persuasion" }, { books[1].title, books[2].title })
        assert.are.equal(2, next_page)
        assert.are.equal(2, results_read)
        assert.is_truthy(helper.logged("info", '^searching Test Site for "austen" from page 1, in en, as '))
        assert.is_truthy(helper.logged("info", "^page 1 of Test Site's results: kept 2 of its 2$"))
    end)

    it("says how many results there are in all, where the page does", function()
        local site = testSite()
        local parsePage = site.parsePage
        function site:parsePage(...)
            local books, results_read, next_page = parsePage(self, ...)
            return books, results_read, next_page, 40
        end
        web.pages["https://books.example/?q=austen&page=1"] = results({ "Emma" }, true)

        site:search("austen", 1)
        assert.is_truthy(helper.logged("info", "^page 1 of Test Site's 40 results: kept 1 of its 1$"))
    end)

    it("shows a page saved from an earlier search, even once the site is down", function()
        local site = testSite()
        web.pages["https://books.example/?q=austen&page=1"] = results({ "Emma" })
        assert.is_false(site:isCached("austen", 1))
        site:search("austen", 1)
        web.pages = {}

        assert.is_true(site:isCached("austen", 1))
        local books, err, next_page, results_read = site:search("austen", 1)
        assert.are.equal("Emma", books[1].title)
        assert.is_nil(err)
        assert.is_nil(next_page)
        assert.is_nil(results_read)
    end)

    -- as the page may have been an error
    it("doesn't save a page that found nothing", function()
        local site = testSite()
        web.pages["https://books.example/?q=austen&page=1"] = results({})
        site:search("austen", 1)
        assert.is_false(site:isCached("austen", 1))
    end)

    it("neither saves nor shows saved searches where it doesn't save them", function()
        local site = testSite({ SAVES_SEARCHES = false })
        web.pages["https://books.example/?q=austen&page=1"] = results({ "Emma" })
        site:search("austen", 1)
        assert.is_false(site:isCached("austen", 1))
        site:search("austen", 1)
        assert.are.equal(2, #web.fetched)
    end)

    it("narrows searches down to the book types chosen only where it has them", function()
        assert.are.same({}, select(3, testSite():choices()))
        assert.are.same(
            require("settings.settings"):getPreferredBookTypes(),
            select(3, testSite({ HAS_BOOK_TYPES = true }):choices())
        )
    end)

    it("finds nothing where there's nothing to search for, without asking the site", function()
        local books, err, next_page, results_read = testSite():search("", 1)
        assert.are.same({}, books)
        assert.is_nil(err)
        assert.is_nil(next_page)
        assert.are.equal(0, results_read)
        assert.are.equal(0, #web.fetched)
    end)

    it("says why it can't search where it can't make the address", function()
        local site = testSite()
        function site:searchUrl()
            return nil, "none of the file types chosen"
        end
        local books, err = site:search("austen", 1)
        assert.is_nil(books)
        assert.are.equal("none of the file types chosen", err)
    end)

    it("explains an answer that isn't its results, an error and no answer", function()
        local site = testSite()
        web.pages["https://books.example/?q=emma&page=1"] = "<html>Moved</html>"
        web.pages["https://books.example/?q=busy&page=1"] = function()
            return "<html>Busy</html>", nil, 503
        end

        assert.are.same({ nil, "unexpected response from Test Site" }, { site:search("emma", 1) })
        assert.are.same(
            { nil, "Test Site answered with an error (HTTP 503), try again later" },
            { site:search("busy", 1) }
        )
        assert.are.same(
            { nil, "Test Site didn't answer (failed to connect to server)" },
            { site:search("persuasion", 1) }
        )
        assert.is_truthy(helper.logged("warn", "^unexpected search results from Test Site: HTTP 503 17 bytes: "))
    end)

    it("passes on being called off, rather than explaining it", function()
        web.pages["https://books.example/?q=emma&page=1"] = function()
            return nil, HttpUtil.CANCELLED
        end
        assert.are.same({ nil, HttpUtil.CANCELLED }, { testSite():search("emma", 1) })
    end)

    -- as Calibre's content server answers a search that finds nothing (see OpdsSearch)
    it("finds no books where the site's error says there are none", function()
        local site = testSite()
        function site:foundNothing(status)
            return status == 404
        end
        web.pages["https://books.example/?q=zzz&page=1"] = function()
            return "<html>Not found</html>", nil, 404
        end

        assert.are.same({ {}, nil, nil, 0 }, { site:search("zzz", 1) })
        assert.is_truthy(helper.logged("info", '^Test Site found no books for "zzz"$'))
    end)
end)
