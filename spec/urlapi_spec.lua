local helper = require("helper")

-- these scrape the live Wikipedia page, so they need internet access
describe("UrlApi", function()
    local http, UrlApi

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        http = helper.useLiveHttp()
        UrlApi = require("api.urlapi")
    end)

    after_each(helper.cleanup)

    describe("Library Genesis mirrors", function()
        it("are scraped from Wikipedia", function()
            local urls = UrlApi:getLibgenUrls()
            assert.is_not_nil(urls, "no Library Genesis mirrors found on Wikipedia")
            assert.is_true(#urls > 0)

            local seen = {}
            for _, url in ipairs(urls) do
                -- the site's root, not a link to a page on it
                assert.matches("^https://libgen%.[%w%.]+$", url)
                assert.is_nil(seen[url], "duplicate mirror " .. url)
                seen[url] = true
            end
            assert.matches("wikipedia.org", http.requests[1], 1, true)
        end)

        it("are cached so Wikipedia is only asked once", function()
            local urls = UrlApi:getLibgenUrls()
            assert.are.same(urls, UrlApi:getLibgenUrls())
            assert.are.equal(1, #http.requests)
        end)

        -- as it takes a while, especially on the first search
        it("say when they're being looked up on Wikipedia, but not when they're cached", function()
            UrlApi:getLibgenUrls()
            assert.are.same({"Looking up Library Genesis mirrors..."}, helper.state.notifications)

            UrlApi:getLibgenUrls()
            assert.are.equal(1, #helper.state.notifications)
        end)

        it("can be removed once they stop working", function()
            local urls = UrlApi:getLibgenUrls()
            UrlApi:deleteLibgenUrl(urls[1])

            local remaining = UrlApi:getLibgenUrls()
            assert.are.equal(#urls - 1, #remaining)
            assert.are.equal(urls[2], remaining[1])
        end)

        it("are scraped again once every cached mirror has failed", function()
            local urls = UrlApi:getLibgenUrls()

            for i = 1, #urls - 1 do
                UrlApi:deleteLibgenUrl(urls[i])
            end
            assert.are.same({urls[#urls]}, UrlApi:getLibgenUrls())
            assert.are.equal(1, #http.requests)

            UrlApi:deleteLibgenUrl(urls[#urls])
            assert.are.same(urls, UrlApi:getLibgenUrls())
            assert.are.equal(2, #http.requests)
        end)

        it("are nil when Wikipedia cannot be reached", function()
            http.request = function()
                return nil, "could not resolve host"
            end

            local urls, err = UrlApi:getLibgenUrls()
            assert.is_nil(urls)
            assert.are.equal("could not resolve host", err)
        end)

        it("are nil when Wikipedia does not list any", function()
            http.request = function(request)
                request.sink("<html><body>Page not found</body></html>")
                return 1, 200
            end
            assert.is_nil(UrlApi:getLibgenUrls())
        end)
    end)
end)
