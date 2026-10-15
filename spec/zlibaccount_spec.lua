local helper = require("helper")
local fixtures = require("fixtures")

describe("ZlibAccount", function()
    local web, ZlibAccount, Settings

    -- Z-Library's address, as if looked up already (see UrlApi), and another it has had
    local SITE = "https://z-lib.example"
    local OTHER_SITE = "https://z-library.example"
    local LOGIN_URL = SITE .. "/eapi/user/login"
    local PROFILE_URL = SITE .. "/eapi/user/profile"
    local WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Z-Library"
    local KEY = "0123456789abcdef0123456789abcdef"

    -- the addresses Z-Library is asked at, as they're cached, in the order they're tried
    local function addresses()
        return require("cache.urlcache"):get("zlib")
    end

    local function loggedIn()
        Settings:setZlibAccount({ email = "reader@example.com", user_id = 42, user_key = KEY })
    end

    -- the settings as they're saved, rather than as they're read back
    local function saved()
        return helper.state.settings_files[helper.state.data_dir .. "/settings/kindlefetch_settings.lua"] or {}
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        require("cache.urlcache"):set({ SITE }, "zlib")
        -- where it's looked up again, when its addresses fail
        web.pages[WIKIPEDIA_URL] = fixtures.wikipediaZlib({ "z-lib.example" })
        ZlibAccount = require("api.zlibaccount")
        Settings = require("settings.settings")
    end)

    after_each(helper.cleanup)

    describe("login", function()
        it(
            "logs in with the email and password, keeping what Z-Library answers with rather than the password",
            function()
                web.pages[LOGIN_URL] = fixtures.zlibLogin(42, KEY)

                assert.are.same({ true }, { ZlibAccount:login("reader@example.com", "p4ssword") })
                assert.are.same({ { "email", "reader@example.com" }, { "password", "p4ssword" } }, web.requests[1].form)
                assert.is_true(ZlibAccount:isLoggedIn())
                assert.are.equal("reader@example.com", ZlibAccount:getEmail())
                assert.are.same({ email = "reader@example.com", user_id = 42, user_key = KEY }, saved().zlib_account)
                assert.is_truthy(helper.logged("info", "^logged in to Z%-Library$"))
            end
        )

        -- which logs into the account, as the password does
        it("doesn't log the key", function()
            web.pages[LOGIN_URL] = fixtures.zlibLogin(42, KEY)
            ZlibAccount:login("reader@example.com", "p4ssword")

            for _, log in ipairs(helper.state.logs) do
                for i = 2, #log do
                    assert.is_nil(tostring(log[i]):find(KEY, 1, true))
                    assert.is_nil(tostring(log[i]):find("p4ssword", 1, true))
                end
            end
        end)

        it("says why it couldn't, as Z-Library does", function()
            web.pages[LOGIN_URL] = function()
                return fixtures.zlibError("Incorrect email or password"), nil, 400
            end

            assert.are.same(
                { false, "Z-Library says: Incorrect email or password" },
                { ZlibAccount:login("reader@example.com", "wrong") }
            )
            assert.is_false(ZlibAccount:isLoggedIn())
        end)

        it("says when Z-Library doesn't answer", function()
            assert.are.same(
                { false, "Z-Library didn't answer (failed to connect to server)" },
                { ZlibAccount:login("reader@example.com", "p4ssword") }
            )
        end)

        it("says when Z-Library answers with an error page", function()
            web.pages[LOGIN_URL] = function()
                return "<html>Bad gateway</html>", nil, 502
            end

            assert.are.same(
                { false, "Z-Library answered with an error (HTTP 502), try again later" },
                { ZlibAccount:login("reader@example.com", "p4ssword") }
            )
            assert.matches(
                "Bad gateway",
                helper.logged("warn", "^unexpected answer from z%-lib%.example to /eapi/user/login: HTTP 502")
            )
        end)

        -- as it's sent to curl in a cookie
        it("won't keep a key that isn't only letters and digits", function()
            web.pages[LOGIN_URL] = fixtures.zlibLogin(42, 'abc"\ndef')

            assert.are.same(
                { false, "unexpected response from Z-Library" },
                { ZlibAccount:login("reader@example.com", "p4ssword") }
            )
            assert.is_false(ZlibAccount:isLoggedIn())
        end)

        it("passes on that it was called off", function()
            web.pages[LOGIN_URL] = function()
                return nil, require("util.httputil").CANCELLED
            end

            local logged_in, err = ZlibAccount:login("reader@example.com", "p4ssword")
            assert.is_false(logged_in)
            assert.are.equal(require("util.httputil").CANCELLED, err)
        end)
    end)

    describe("request", function()
        it("asks as the account logged into", function()
            loggedIn()
            web.pages[PROFILE_URL] = '{"success":1,"user":{"downloads_today":1}}'

            local data = ZlibAccount:request("/eapi/user/profile")
            assert.are.equal(1, data.user.downloads_today)
            assert.are.equal("remix_userid=42; remix_userkey=" .. KEY, web.requests[1].cookies)
        end)

        -- e.g. once it has been logged out of elsewhere
        it("forgets the account once Z-Library no longer accepts it", function()
            loggedIn()
            web.pages[PROFILE_URL] = function()
                return fixtures.zlibError("Please login"), nil, 400
            end

            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(data)
            assert.are.equal(ZlibAccount.LOGGED_OUT_ERROR, err)
            assert.is_false(ZlibAccount:isLoggedIn())
        end)

        -- e.g. downloading a book found before logging out
        it("says to log in again when there's no account to ask as", function()
            web.pages[PROFILE_URL] = function()
                return fixtures.zlibError("Please login"), nil, 400
            end

            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(data)
            assert.are.equal(ZlibAccount.LOGGED_OUT_ERROR, err)
            assert.are.equal("", web.requests[1].cookies)
        end)

        it("keeps the account when Z-Library says something else is wrong", function()
            loggedIn()
            web.pages[PROFILE_URL] = function()
                return fixtures.zlibError("Invalid hash"), nil, 400
            end

            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(data)
            assert.are.equal("Z-Library says: Invalid hash", err)
            assert.is_true(ZlibAccount:isLoggedIn())
        end)
    end)

    -- which it moves between as they're taken down
    describe("at Z-Library's addresses", function()
        before_each(function()
            web.pages[PROFILE_URL] = '{"success":1,"user":{"downloads_today":1}}'
        end)

        it("asks at the next address when one doesn't answer, trying the one that does first from then on", function()
            require("cache.urlcache"):set({ OTHER_SITE, SITE }, "zlib")

            local data = ZlibAccount:request("/eapi/user/profile")
            assert.are.equal(1, data.user.downloads_today)
            assert.are.same({ OTHER_SITE .. "/eapi/user/profile", PROFILE_URL }, web.fetched)
            -- as the internet is working, it may be down, so it's asked after the other
            assert.are.same({ SITE, OTHER_SITE }, addresses())
        end)

        it("drops an address that answers with something other than Z-Library's API", function()
            require("cache.urlcache"):set({ OTHER_SITE, SITE }, "zlib")
            web.pages[OTHER_SITE .. "/eapi/user/profile"] = "<html>This domain is for sale</html>"

            assert.are.equal(1, ZlibAccount:request("/eapi/user/profile").user.downloads_today)
            assert.are.same({ SITE }, addresses())
            assert.matches("for sale", helper.logged("warn", "^unexpected answer from z%-library%.example"))
        end)

        it("looks the addresses up on Wikipedia again when none of them answer", function()
            require("cache.urlcache"):set({ OTHER_SITE }, "zlib")

            assert.are.equal(1, ZlibAccount:request("/eapi/user/profile").user.downloads_today)
            assert.are.equal(1, web.scrapes)
            assert.are.same({ SITE }, addresses())
        end)

        -- as when the network is blocking them, as for Library Genesis (#55)
        it("says when none of its addresses can be found on this network, though Wikipedia can", function()
            web.pages[PROFILE_URL] = function()
                return nil, "could not resolve host"
            end

            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(data)
            assert.are.equal(require("util.errors").ZLIB_UNFOUND, err)
            assert.matches("which may be blocking them", err, 1, true)
        end)

        it("says there's no internet connection when neither its addresses nor Wikipedia answer", function()
            web.pages[PROFILE_URL] = nil
            web.wikipedia_down = true

            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(data)
            assert.are.equal("no internet connection", err)
            -- rather than forgetting them while offline
            assert.are.same({ SITE }, addresses())
        end)

        it("says Z-Library didn't answer when its addresses don't, even once looked up again", function()
            web.pages[PROFILE_URL] = nil

            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(data)
            assert.are.equal("Z-Library didn't answer (failed to connect to server)", err)
            assert.are.equal(1, web.scrapes)
        end)
    end)

    it("logs out, forgetting the account", function()
        loggedIn()
        ZlibAccount:logout()

        assert.is_false(ZlibAccount:isLoggedIn())
        assert.is_nil(ZlibAccount:getEmail())
        assert.is_nil(saved().zlib_account)
    end)

    -- catches Z-Library changing how it's logged into. needs an account, given by KINDLEFETCH_ZLIB_EMAIL and
    -- KINDLEFETCH_ZLIB_PASSWORD, so it's skipped without them (as in CI)
    local email, password = os.getenv("KINDLEFETCH_ZLIB_EMAIL"), os.getenv("KINDLEFETCH_ZLIB_PASSWORD")
    if email and password then
        it("logs in to the live Z-Library site #live", function()
            web.live = true
            -- at the addresses Wikipedia lists
            require("cache.urlcache"):clear()
            web.pages[WIKIPEDIA_URL] = nil

            assert.are.same({ true }, { ZlibAccount:login(email, password) })
            local data, err = ZlibAccount:request("/eapi/user/profile")
            assert.is_nil(err)
            assert.are.equal("number", type(data.user.downloads_limit))
        end)
    else
        pending("logs in to the live Z-Library site (needs KINDLEFETCH_ZLIB_EMAIL and KINDLEFETCH_ZLIB_PASSWORD)")
    end
end)
