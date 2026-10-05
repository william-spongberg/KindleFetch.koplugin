local helper = require("helper")

describe("HttpUtil", function()
    local requests, responses, http, HttpUtil

    -- queue up luasocket responses: {body, ok, status}
    local function respond(...)
        responses = { ... }
    end

    before_each(function()
        helper.reset()
        requests = {}
        responses = {}
        http = helper.stubs.http
        http.request = function(request)
            table.insert(requests, request)
            request.timeouts = helper.state.http_timeouts
            local response = table.remove(responses, 1) or { "", nil, "connection refused" }
            if response[1] ~= "" then
                request.sink(response[1])
            end
            return response[2], response[3]
        end
        HttpUtil = require("util.httputil")
    end)

    it("fetches a page with a browser user agent, following redirects", function()
        respond({ "<html>results</html>", 1, 200 })

        assert.are.equal("<html>results</html>", HttpUtil.getBody("https://libgen.example/index.php?req=dune"))
        assert.are.equal("https://libgen.example/index.php?req=dune", requests[1].url)
        assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
        assert.is_true(requests[1].redirect)
        assert.is_nil(requests[1].proxy)
    end)

    -- https requests ignore luasocket's own timeout, and would wait a minute for a mirror that is down
    it("waits 10 seconds for an answer and a minute for the page, then puts KOReader's timeouts back", function()
        respond({ "<html>results</html>", 1, 200 })
        HttpUtil.getBody("https://libgen.example")

        assert.are.same({ 10, 60 }, requests[1].timeouts)
        assert.is_nil(helper.state.http_timeouts)
        assert.is_nil(http.TIMEOUT)
    end)

    it("puts KOReader's timeouts back when the request fails", function()
        respond({ "", nil, "timeout" })
        HttpUtil.getBody("https://libgen.example")

        assert.are.same({ 10, 60 }, requests[1].timeouts)
        assert.is_nil(helper.state.http_timeouts)
    end)

    it("returns the HTTP status, e.g. of an error page", function()
        respond({ "<html>Forbidden</html>", 1, 403 })

        local body, err, status = HttpUtil.getBody("https://libgen.example")
        assert.are.equal("<html>Forbidden</html>", body)
        assert.is_nil(err)
        assert.are.equal(403, status)
    end)

    it("returns the error when the request fails, and logs it", function()
        respond({ "", nil, "timeout" })

        local body, err = HttpUtil.getBody("https://libgen.example")
        assert.is_nil(body)
        assert.are.equal("timeout", err)
        assert.are.equal(
            "could not fetch https://libgen.example error: timeout",
            helper.logged("warn", "^could not fetch")
        )
    end)

    it("treats an empty page as a failure", function()
        respond({ "", 1, 200 })
        assert.is_nil(HttpUtil.getBody("https://libgen.example"))
    end)

    it("retries through PROXY_URL when the direct request fails", function()
        helper.state.env.PROXY_URL = "http://proxy.example:8080"
        respond({ "", nil, "connection refused" }, { "<html>via proxy</html>", 1, 200 })

        assert.are.equal("<html>via proxy</html>", HttpUtil.getBody("https://libgen.example"))
        assert.are.equal("http://proxy.example:8080", requests[2].proxy)
    end)

    it("returns the proxy error when both requests fail, without logging the proxy's address", function()
        helper.state.env.PROXY_URL = "http://user:secret@proxy.example:8080"
        respond({ "", nil, "connection refused" }, { "", nil, "proxy unreachable" })

        local body, err = HttpUtil.getBody("https://libgen.example")
        assert.is_nil(body)
        assert.are.equal("proxy unreachable", err)
        for _, log in ipairs(helper.state.logs) do
            for i = 3, #log do
                assert.is_nil(tostring(log[i]):find("secret", 1, true))
            end
        end
    end)

    it("does not use a proxy when PROXY_URL is not set", function()
        helper.state.env.PROXY_URL = false
        respond({ "", nil, "connection refused" })

        assert.is_nil(HttpUtil.getBody("https://libgen.example"))
        assert.are.equal(1, #requests)
    end)
end)
