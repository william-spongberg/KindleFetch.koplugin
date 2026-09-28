local helper = require("helper")

-- these scrape the live Wikipedia pages, so they need internet access
describe("UrlApi", function()
    local http, UrlApi

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        http = helper.useLiveHttp()
        UrlApi = require("api.urlapi")
    end)

    after_each(helper.cleanup)

    local function assertMirrors(urls, site)
        assert.is_not_nil(urls, "no " .. site .. " mirrors found on Wikipedia")
        assert.is_true(#urls > 0)
        local seen = {}
        for _, url in ipairs(urls) do
            -- the site's root, not a link to a page on it
            assert.matches("^https://" .. site:gsub("%-", "%%-") .. "%.[%w%.]+$", url)
            assert.is_nil(seen[url], "duplicate mirror " .. url)
            seen[url] = true
        end
    end

    describe("Anna's Archive mirrors", function()
        it("are scraped from Wikipedia", function()
            assertMirrors(UrlApi:getAnnasUrls(), "annas-archive")
            assert.matches("wikipedia.org", http.requests[1], 1, true)
        end)

        it("are cached so Wikipedia is only asked once", function()
            local urls = UrlApi:getAnnasUrls()
            assert.are.same(urls, UrlApi:getAnnasUrls())
            assert.are.equal(1, #http.requests)
        end)

        it("are scraped again once every cached mirror has failed", function()
            local urls = UrlApi:getAnnasUrls()

            for i = 1, #urls - 1 do
                UrlApi:deleteAnnasUrl(urls[i])
            end
            assert.are.same({urls[#urls]}, UrlApi:getAnnasUrls())
            assert.are.equal(1, #http.requests)

            UrlApi:deleteAnnasUrl(urls[#urls])
            assert.are.same(urls, UrlApi:getAnnasUrls())
            assert.are.equal(2, #http.requests)
        end)

        it("are nil when Wikipedia cannot be reached", function()
            http.request = function()
                return nil, "could not resolve host"
            end

            local urls, err = UrlApi:getAnnasUrls()
            assert.is_nil(urls)
            assert.are.equal("could not resolve host", err)
        end)

        it("are nil when Wikipedia does not list any", function()
            http.request = function(request)
                request.sink("<html><body>Page not found</body></html>")
                return 1, 200
            end
            assert.is_nil(UrlApi:getAnnasUrls())
        end)
    end)

    describe("Library Genesis mirrors", function()
        it("are scraped from Wikipedia", function()
            assertMirrors(UrlApi:getLibgenUrls(), "libgen")
        end)

        it("can be removed once they stop working", function()
            local urls = UrlApi:getLibgenUrls()
            UrlApi:deleteLibgenUrl(urls[1])

            local remaining = UrlApi:getLibgenUrls()
            assert.are.equal(#urls - 1, #remaining)
            assert.are.equal(urls[2], remaining[1])
        end)
    end)
end)
