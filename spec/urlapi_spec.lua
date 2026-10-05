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
            assert.are.same({ "Looking up Library Genesis mirrors..." }, helper.state.notifications)

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
            assert.are.same({ urls[#urls] }, UrlApi:getLibgenUrls())
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

        -- the page can be edited by anyone
        it("are only the names of sites", function()
            http.request = function(request)
                request.sink(
                    "<ul><li>libgen.example</li><li> libgen.my-mirror.example </li>"
                        .. "<li>libgen.evil.example/steal?from=you</li><li>libgen.evil example</li>"
                        .. '<li>libgen.evil.example"</li><li>not-libgen.example</li></ul>'
                )
                return 1, 200
            end

            assert.are.same({ "https://libgen.example", "https://libgen.my-mirror.example" }, UrlApi:getLibgenUrls())
        end)

        -- e.g. once its page has been rearranged, which would otherwise stop every search until the next update
        describe("when Wikipedia answers without any", function()
            before_each(function()
                http.request = function(request)
                    table.insert(http.requests, request.url)
                    request.sink("<html><body>Page not found</body></html>")
                    return 1, 404
                end
            end)

            it("are the ones known when the plugin was written", function()
                local urls = UrlApi:getLibgenUrls()

                assert.are.equal("https://libgen.vg", urls[1])
                assert.are.equal(5, #urls)
                assert.is_truthy(helper.logged("warn", "^using the mirrors known when KindleFetch was written"))
            end)

            -- rather than for every page of every search
            it("are kept, so Wikipedia isn't asked again until they stop working", function()
                local urls = UrlApi:getLibgenUrls()
                UrlApi:getLibgenUrls()
                assert.are.equal(1, #http.requests)

                UrlApi:deleteLibgenUrl(urls[1])
                assert.are.equal("https://libgen.la", UrlApi:getLibgenUrls()[1])
                assert.are.equal(4, #UrlApi:getLibgenUrls())
                assert.are.equal(1, #http.requests)

                -- the built-in list itself is left as it was
                assert.are.equal("https://libgen.vg", UrlApi:getLibgenUrls(true)[1])
                assert.are.equal(2, #http.requests)
            end)
        end)
    end)
end)
