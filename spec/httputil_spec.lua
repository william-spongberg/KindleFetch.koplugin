local helper = require("helper")

describe("HttpUtil", function()
    local data_dir, requests, responses, http, HttpUtil

    -- queue up luasocket responses: {body, ok, status}
    local function respond(...)
        responses = { ... }
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
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

    after_each(helper.cleanup)

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

    -- curl asks for pages compressed, which Library Genesis sends several times sooner, and doesn't hold KOReader
    -- up while it waits
    describe("with a curl that can fetch pages", function()
        local fetches

        -- pretend to be curl: save the page in the file it was told to, then print the status and its exit code
        local function curlAnswers(answer)
            helper.stubCommand("curl -sL -o", function(cmd)
                table.insert(fetches, cmd)
                local page, status, exit_code = answer(cmd)
                if page then
                    helper.writeFile(cmd:match("%-o '([^']+)'"), page)
                end
                return string.format("%s %d\n", status or "000", exit_code or 0)
            end)
        end

        before_each(function()
            fetches = {}
            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )
        end)

        it("fetches the page with curl rather than luasocket, within the same time limits", function()
            curlAnswers(function()
                return "<html>results</html>\n", 200
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example/index.php?req=dune")
            assert.are.equal("<html>results</html>", body)
            assert.is_nil(err)
            assert.are.equal(200, status)
            assert.are.equal(0, #requests)
            assert.matches("'https://libgen.example/index.php?req=dune' --compressed", fetches[1], 1, true)
            assert.matches("--connect-timeout 10 --max-time 60", fetches[1], 1, true)
            -- and removes the file the page was fetched into
            assert.are.same({}, helper.readDir(data_dir .. "/settings/tmp"))
        end)

        it("returns the HTTP status and page of an error", function()
            curlAnswers(function()
                return "<html>Forbidden</html>", 403
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.are.equal("<html>Forbidden</html>", body)
            assert.is_nil(err)
            assert.are.equal(403, status)
        end)

        it("fails without a status when the site doesn't answer", function()
            curlAnswers(function()
                return nil, "000", 6
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("could not resolve host", err)
            assert.is_nil(status)
        end)

        -- part of a page of search results would be taken for all of them
        it("fails when the site stops part of the way through the page", function()
            curlAnswers(function()
                return "<html><table id='tablelibgen'><tbody><tr>", 200, 28
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("request timed out", err)
            assert.is_nil(status)
            assert.are.same({}, helper.readDir(data_dir .. "/settings/tmp"))
        end)

        it("treats an empty page as a failure", function()
            curlAnswers(function()
                return nil, 200
            end)

            local body, err, status = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("empty response (HTTP 200)", err)
            assert.are.equal(200, status)
        end)

        it("says when curl has gone since it was last looked for", function()
            helper.stubCommand("curl -sL -o", " 127\n")

            local body, err = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("curl isn't installed on this device", err)
        end)

        it("retries through PROXY_URL when the direct request fails", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            curlAnswers(function(cmd)
                if cmd:find("-x 'http://proxy.example:8080'", 1, true) then
                    return "<html>via proxy</html>", 200
                end
                return nil, "000", 7
            end)

            assert.are.equal("<html>via proxy</html>", HttpUtil.getBody("https://libgen.example"))
            assert.are.equal(2, #fetches)
        end)

        it("holds KOReader up while it waits, when it wasn't asked to wait in the background", function()
            curlAnswers(function()
                return "<html>results</html>", 200
            end)
            HttpUtil.getBody("https://libgen.example")

            assert.are.same({}, helper.state.trapped)
        end)

        describe("asked to wait in the background", function()
            local message

            before_each(function()
                helper.stubs.trapper.wrapped = true
                message = { text = "Searching..." }
                HttpUtil.trap_widget = message
                curlAnswers(function()
                    return "<html>results</html>", 200
                end)
            end)

            it("lets KOReader carry on, with a tap on the message given calling it off", function()
                assert.are.equal("<html>results</html>", HttpUtil.getBody("https://libgen.example"))
                assert.are.equal(1, #helper.state.trapped)
                assert.are.equal(message, helper.state.trapped[1].trap_widget)
                assert.are.equal(fetches[1], helper.state.trapped[1].cmd)
            end)

            it("says so when it's called off, without trying again through PROXY_URL", function()
                helper.state.env.PROXY_URL = "http://proxy.example:8080"
                helper.state.dismiss = true

                local body, err, status = HttpUtil.getBody("https://libgen.example")
                assert.is_nil(body)
                assert.are.equal(HttpUtil.CANCELLED, err)
                assert.is_nil(status)
                assert.are.equal(1, #helper.state.trapped)
                -- it's what was asked for, so not a warning
                assert.is_nil(helper.logged("warn", "could not fetch"))
            end)
        end)
    end)
end)
