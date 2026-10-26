local helper = require("helper")

-- logging in to a library's site with KOReader's own HTTP, where curl can't
describe("HttpLogin", function()
    local requests, responses, HttpLogin, LibrarySites

    local CALIBRE_CHALLENGE = 'Digest realm="calibre", nonce="5f2a:9c1e", algorithm="MD5", qop="auth"'

    -- queue up what luasocket answers with, each { code, headers, body }
    local function respond(...)
        responses = { ... }
    end

    -- ask for url, returning its results and what arrived the last time, as each answer gets a sink of its own
    local function ask(url)
        local arrived
        local ok, code, headers, status = HttpLogin.request(url, { ["User-Agent"] = "Mozilla/5.0" }, function()
            arrived = {}
            return function(chunk)
                if chunk then
                    table.insert(arrived, chunk)
                end
                return 1
            end
        end)
        return ok, code, headers, status, table.concat(arrived or {})
    end

    -- a Digest Authorization header's parameters
    local function digestParams(header)
        local params = {}
        for name, value in header:gmatch('(%w+)="([^"]*)"') do
            params[name] = value
        end
        for name, value in header:gmatch('(%w+)=([^",%s]+)') do
            params[name] = params[name] or value
        end
        return params
    end

    before_each(function()
        helper.reset()
        requests, responses = {}, {}
        helper.stubs.http.request = function(request)
            request.proxy_used = helper.stubs.http.PROXY
            table.insert(requests, request)
            local response = table.remove(responses, 1) or { 200, {}, "" }
            if response[3] and response[3] ~= "" then
                request.sink(response[3])
            end
            return 1, response[1], response[2] or {}, "HTTP/1.1 " .. tostring(response[1])
        end
        HttpLogin = require("util.httplogin")
        LibrarySites = require("util.librarysites")
        LibrarySites.add("http://nas:8080/opds", { username = "will", password = "Circle Of Life" })
    end)

    describe("the ways a site says it can be logged in to", function()
        it("reads each way and its parameters", function()
            local challenges = HttpLogin.challenges(
                'Digest realm="my \\"books\\"", nonce="abc", qop="auth,auth-int", algorithm=MD5, Basic realm="books"'
            )
            assert.are.equal(2, #challenges)
            assert.are.equal("digest", challenges[1].scheme)
            assert.are.same(
                { realm = 'my "books"', nonce = "abc", qop = "auth,auth-int", algorithm = "MD5" },
                challenges[1].params
            )
            assert.are.equal("basic", challenges[2].scheme)
            assert.are.same({ realm = "books" }, challenges[2].params)
        end)

        it("answers the Digest way where it can, otherwise the Basic way", function()
            assert.are.equal("digest", HttpLogin.bestChallenge('Basic realm="x", ' .. CALIBRE_CHALLENGE).scheme)
            assert.are.equal(
                "basic",
                HttpLogin.bestChallenge('Digest realm="x", nonce="n", algorithm=SHA-256, Basic realm="x"').scheme
            )
            assert.are.equal(
                "basic",
                HttpLogin.bestChallenge('Digest realm="x", nonce="n", qop="auth-int", Basic').scheme
            )
            assert.is_nil(HttpLogin.bestChallenge('Bearer realm="x"'))
            assert.is_nil(HttpLogin.bestChallenge(nil))
        end)
    end)

    -- its example (with its errata), as the response is worked out
    it("logs in the Digest way as RFC 2617 says", function()
        local challenge = HttpLogin.bestChallenge(
            'Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", '
                .. 'opaque="5ccc069c403ebaf9f0171e9517f40e41"'
        )
        local header = HttpLogin.digest(
            { username = "Mufasa", password = "Circle Of Life" },
            challenge,
            "GET",
            "/dir/index.html",
            "0a4f113b"
        )
        assert.are.same({
            username = "Mufasa",
            realm = "testrealm@host.com",
            nonce = "dcd98b7102dd2f0e8b11d0f600bfb0c093",
            uri = "/dir/index.html",
            response = "6629fae49393a05397450978507c4ef1",
            opaque = "5ccc069c403ebaf9f0171e9517f40e41",
            qop = "auth",
            nc = "00000001",
            cnonce = "0a4f113b",
        }, digestParams(header))
        assert.matches("^Digest ", header)
    end)

    describe("asking a library's site", function()
        -- as Calibre's content server does unless it's set up with HTTPS
        it("asks without logging in, then answers the Digest way it asks with", function()
            respond(
                { 401, { ["www-authenticate"] = CALIBRE_CHALLENGE }, "<html>Unauthorized</html>" },
                { 200, {}, "<feed/>" }
            )
            local ok, code, _, _, arrived = ask("http://nas:8080/opds/search/dune%20messiah?offset=30")

            assert.are.equal(1, ok)
            assert.are.equal(200, code)
            -- what it sent without the login isn't what arrived
            assert.are.equal("<feed/>", arrived)
            assert.are.equal(2, #requests)
            assert.is_nil(requests[1].headers.Authorization)
            assert.is_false(requests[1].redirect)

            local params = digestParams(requests[2].headers.Authorization)
            assert.are.equal("will", params.username)
            assert.are.equal("/opds/search/dune%20messiah?offset=30", params.uri)
            local md5 = require("ffi/sha2").md5
            local ha1 = md5("will:calibre:Circle Of Life")
            local ha2 = md5("GET:/opds/search/dune%20messiah?offset=30")
            assert.are.equal(
                md5(table.concat({ ha1, "5f2a:9c1e", "00000001", params.cnonce, "auth", ha2 }, ":")),
                params.response
            )
            assert.are.equal("Mozilla/5.0", requests[2].headers["User-Agent"])
        end)

        -- which luasocket sends itself, given the password escaped, as it unescapes it
        it("logs in the Basic way where that's what it asks for", function()
            LibrarySites.add("http://nas:8080/", { username = "will", password = "100% sure" })
            respond({ 401, { ["www-authenticate"] = 'Basic realm="Calibre-Web"' } }, { 200, {}, "<feed/>" })
            local _, code = ask("http://nas:8080/opds")

            assert.are.equal(200, code)
            assert.are.equal("will", requests[2].user)
            assert.are.equal("100%25%20sure", requests[2].password)
            assert.is_nil(requests[2].headers.Authorization)
        end)

        it("says it wasn't let in once the login it asked for is turned down", function()
            respond(
                { 401, { ["www-authenticate"] = CALIBRE_CHALLENGE } },
                { 401, { ["www-authenticate"] = CALIBRE_CHALLENGE } }
            )
            local _, code = ask("http://nas:8080/opds")
            assert.are.equal(401, code)
            assert.are.equal(2, #requests)
        end)

        it("doesn't ask again where it has no login for the site", function()
            LibrarySites.add("http://nas:8083/opds")
            respond({ 401, { ["www-authenticate"] = 'Basic realm="x"' } })
            local _, code = ask("http://nas:8083/opds")
            assert.are.equal(401, code)
            assert.are.equal(1, #requests)
        end)

        it("says when it asks to be logged in to in a way it can't be", function()
            respond({ 401, { ["www-authenticate"] = 'Bearer realm="x"' } })
            local _, code = ask("http://nas:8080/opds")
            assert.are.equal(401, code)
            assert.are.equal(1, #requests)
            assert.is_truthy(helper.logged("warn", "asks to be logged in to in a way KOReader's HTTP can't"))
        end)

        -- rather than luasocket, which would send the login on with it
        it("follows where it sends the request, logging in only on its own site", function()
            respond(
                { 302, { location = "/opds/v2" } },
                { 401, { ["www-authenticate"] = 'Basic realm="x"' } },
                { 302, { location = "https://cdn.example/book.epub" } },
                { 200, {}, "epub" }
            )
            local _, code, _, _, arrived = ask("http://nas:8080/opds")

            assert.are.equal(200, code)
            assert.are.equal("epub", arrived)
            assert.are.equal("http://nas:8080/opds/v2", requests[2].url)
            assert.are.equal("will", requests[3].user)
            assert.are.equal("https://cdn.example/book.epub", requests[4].url)
            assert.is_nil(requests[4].user)
            assert.is_nil(requests[4].headers.Authorization)
        end)

        it("gives up on a site that sends the request on too many times", function()
            for i = 1, 6 do
                responses[i] = { 302, { location = "/opds/" .. i } }
            end
            local ok, err = ask("http://nas:8080/opds")
            assert.is_nil(ok)
            assert.are.equal("too many redirects", err)
        end)

        -- which a proxy on the internet can't reach
        it("goes without KOReader's proxy on the network the device is on, putting it back after", function()
            helper.stubs.http.PROXY = "http://proxy.example:3128"
            LibrarySites.add("https://books.example/opds")
            respond({ 200, {}, "<feed/>" }, { 200, {}, "<feed/>" })

            ask("http://nas:8080/opds")
            assert.is_nil(requests[1].proxy_used)
            assert.is_nil(requests[1].proxy)
            assert.are.equal("http://proxy.example:3128", helper.stubs.http.PROXY)

            ask("https://books.example/opds")
            assert.are.equal("http://proxy.example:3128", requests[2].proxy_used)
        end)

        it("returns what luasocket raises, rather than raising it", function()
            helper.stubs.http.request = function()
                error("closed")
            end
            local ok, err = ask("http://nas:8080/opds")
            assert.is_nil(ok)
            assert.matches("closed", err)
        end)
    end)
end)
