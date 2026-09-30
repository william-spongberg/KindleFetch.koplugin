local helper = require("helper")

describe("HttpUtil", function()
    local requests, responses, http, HttpUtil

    -- queue up luasocket responses: {body, ok, status}
    local function respond(...)
        responses = {...}
    end

    before_each(function()
        helper.reset()
        requests = {}
        responses = {}
        http = helper.stubs.http
        http.request = function(request)
            table.insert(requests, request)
            local response = table.remove(responses, 1) or {"", nil, "connection refused"}
            if response[1] ~= "" then
                request.sink(response[1])
            end
            return response[2], response[3]
        end
        HttpUtil = require("util.httputil")
    end)

    it("fetches a page with a browser user agent, following redirects", function()
        respond({"<html>results</html>", 1, 200})

        assert.are.equal("<html>results</html>", HttpUtil.getBody("https://annas-archive.example/search?q=dune"))
        assert.are.equal("https://annas-archive.example/search?q=dune", requests[1].url)
        assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
        assert.is_true(requests[1].redirect)
        assert.is_nil(requests[1].proxy)
        assert.are.equal(10, http.TIMEOUT)
    end)

    it("returns the error when the request fails", function()
        respond({"", nil, "timeout"})

        local body, err = HttpUtil.getBody("https://annas-archive.example")
        assert.is_nil(body)
        assert.are.equal("timeout", err)
    end)

    it("treats an empty page as a failure", function()
        respond({"", 1, 200})
        assert.is_nil(HttpUtil.getBody("https://annas-archive.example"))
    end)

    it("retries through PROXY_URL when the direct request fails", function()
        helper.state.env.PROXY_URL = "http://proxy.example:8080"
        respond({"", nil, "connection refused"}, {"<html>via proxy</html>", 1, 200})

        assert.are.equal("<html>via proxy</html>", HttpUtil.getBody("https://annas-archive.example"))
        assert.are.equal("http://proxy.example:8080", requests[2].proxy)
    end)

    it("returns the proxy error when both requests fail", function()
        helper.state.env.PROXY_URL = "http://proxy.example:8080"
        respond({"", nil, "connection refused"}, {"", nil, "proxy unreachable"})

        local body, err = HttpUtil.getBody("https://annas-archive.example")
        assert.is_nil(body)
        assert.are.equal("proxy unreachable", err)
    end)

    it("does not use a proxy when PROXY_URL is not set", function()
        helper.state.env.PROXY_URL = false
        respond({"", nil, "connection refused"})

        assert.is_nil(HttpUtil.getBody("https://annas-archive.example"))
        assert.are.equal(1, #requests)
    end)
end)
