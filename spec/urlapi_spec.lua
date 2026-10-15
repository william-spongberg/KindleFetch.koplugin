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

        -- as it takes a while, especially on the first search, on what's waiting for them (where it can say so)
        it("say when they're being looked up on Wikipedia, but not when they're cached", function()
            local said = {}
            require("util.httputil").setTrapWidget({
                setStatus = function(_, text)
                    table.insert(said, text)
                end,
            })
            UrlApi:getLibgenUrls()
            assert.are.same({ "Looking up Library Genesis mirrors..." }, said)

            UrlApi:getLibgenUrls()
            assert.are.equal(1, #said)
            -- rather than in a notification of its own
            assert.are.same({}, helper.state.notifications)
            require("util.httputil").setTrapWidget(nil)
        end)

        it("can be removed once they stop working", function()
            local urls = UrlApi:getLibgenUrls()
            UrlApi:deleteLibgenUrl(urls[1])

            local remaining = UrlApi:getLibgenUrls()
            assert.are.equal(#urls - 1, #remaining)
            assert.are.equal(urls[2], remaining[1])
        end)

        it("can have the one that last worked tried first, without being looked up again any sooner", function()
            local urls = UrlApi:getLibgenUrls()
            UrlApi:preferLibgenUrl(urls[#urls])

            local reordered = UrlApi:getLibgenUrls()
            assert.are.equal(urls[#urls], reordered[1])
            assert.are.equal(urls[1], reordered[2])
            assert.are.equal(#urls, #reordered)
            assert.are.equal(1, #http.requests)
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

        -- e.g. where it's blocked, where the mirrors may well still work
        describe("when Wikipedia cannot be reached", function()
            local function unreachable()
                http.request = function(request)
                    table.insert(http.requests, request.url)
                    return nil, "could not resolve host"
                end
            end

            it("are the ones known when the plugin was written, when none were looked up before", function()
                unreachable()
                local urls = UrlApi:getLibgenUrls()

                assert.are.equal("https://libgen.vg", urls[1])
                assert.are.equal(5, #urls)
                assert.is_truthy(
                    helper.logged(
                        "warn",
                        "^using the mirrors known when KindleFetch was written, as Wikipedia couldn't be reached: "
                            .. "could not resolve host$"
                    )
                )
            end)

            it("are the ones looked up before, however long ago", function()
                helper.state.time = os.time()
                local urls = UrlApi:getLibgenUrls()
                helper.state.time = helper.state.time + 8 * 24 * 60 * 60
                unreachable()

                assert.are.same(urls, UrlApi:getLibgenUrls())
                assert.is_truthy(helper.logged("warn", "^using the mirrors looked up before"))
                -- kept, rather than Wikipedia being asked again for every page of every search
                UrlApi:getLibgenUrls()
                assert.are.equal(2, #http.requests)
            end)

            -- which there's no point in trying again
            it("are nil just after the ones there were failed, saying why", function()
                UrlApi:getLibgenUrls()
                unreachable()

                local urls, err = UrlApi:getLibgenUrls(true)
                assert.is_nil(urls)
                assert.are.equal("could not resolve host", err)
            end)
        end)

        -- rather than being forgotten, as it may only not have answered for a moment
        it("can have one that didn't answer tried after the others for a while, even once looked up again", function()
            local urls = UrlApi:getLibgenUrls()
            UrlApi:restLibgenUrl(urls[1])

            local reordered = UrlApi:getLibgenUrls()
            assert.are.equal(#urls, #reordered)
            assert.are.equal(urls[2], reordered[1])
            assert.are.equal(urls[1], reordered[#reordered])
            assert.are.equal(urls[1], UrlApi:getLibgenUrls(true)[#urls])

            -- until it has been a while
            helper.state.time = os.time() + 60 * 60 + 1
            assert.are.equal(urls[1], UrlApi:getLibgenUrls(true)[1])
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
                -- saying what Wikipedia answered with, for crash.log
                assert.matches("Page not found", helper.logged("warn", "^found no mirrors on .* %(HTTP 404, "))
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

    -- which it moves between as they're taken down
    describe("Z-Library's addresses", function()
        -- Wikipedia answering with the page
        local function wikipediaAnswers(page)
            http.request = function(request)
                table.insert(http.requests, request.url)
                request.sink(page)
                return 1, 200
            end
        end

        it("are looked up on Wikipedia", function()
            local urls = UrlApi:getZlibUrls()
            assert.is_not_nil(urls, "no Z-Library addresses found on Wikipedia")
            assert.is_true(#urls > 0)
            for _, url in ipairs(urls) do
                -- the site's root, not a link to a page on it
                assert.matches("^https://[%w%-]+%.%a+$", url)
            end
            assert.are.equal("https://en.wikipedia.org/wiki/Z-Library", http.requests[1])
            assert.is_truthy(helper.logged("info", "^looking up Z%-Library mirrors on en.wikipedia.org"))
        end)

        it("are cached apart from Library Genesis' mirrors", function()
            wikipediaAnswers(require("fixtures").wikipediaZlib({ "z-lib.example" }))
            UrlApi:getZlibUrls()

            assert.are.same({ "https://z-lib.example" }, UrlApi:getZlibUrls())
            assert.are.equal(1, #http.requests)
            assert.is_nil(require("cache.urlcache"):get("libgen"))
        end)

        -- rather than those on Tor or I2P, which need software of their own to reach, or ones that aren't Z-Library's,
        -- as the page can be edited by anyone, and the account's password is sent to them when logging in
        it(
            "are only the names of sites on the web, from the infobox's website row, named as Z-Library's are",
            function()
                wikipediaAnswers(require("fixtures").wikipediaZlib({
                    "z-lib.sk",
                    "Z-Library.example",
                    "zlibrary-global.se",
                    "1lib.sk",
                    "singlelogin.re",
                    "z-lib.sk",
                    "evil.example",
                    "z-lib.evil.example",
                    "z-lib.sk/steal?from=you",
                    'z-lib.sk" bad="',
                }))

                assert.are.same({
                    "https://z-lib.sk",
                    "https://z-library.example",
                    "https://zlibrary-global.se",
                    "https://1lib.sk",
                    "https://singlelogin.re",
                }, UrlApi:getZlibUrls())
            end
        )

        it("are the one known when the plugin was written, when Wikipedia answers without any", function()
            wikipediaAnswers("<html><body>Page not found</body></html>")

            assert.are.same({ "https://z-lib.sk" }, UrlApi:getZlibUrls())
            assert.is_truthy(helper.logged("warn", "^using the mirrors known when KindleFetch was written"))
        end)

        it("can have the one that answered tried first, and those that failed removed", function()
            wikipediaAnswers(
                require("fixtures").wikipediaZlib({ "z-lib.example", "z-library.example", "1lib.example" })
            )
            UrlApi:getZlibUrls()

            UrlApi:preferZlibUrl("https://1lib.example")
            UrlApi:deleteZlibUrl("https://z-lib.example")
            assert.are.same({ "https://1lib.example", "https://z-library.example" }, UrlApi:getZlibUrls())
            assert.are.equal(1, #http.requests)
        end)
    end)
end)
