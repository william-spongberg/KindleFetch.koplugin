local helper = require("helper")

describe("HttpUtil", function()
    local data_dir, requests, responses, http, HttpUtil

    -- queue up luasocket responses: {body, ok, status, headers}
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
            return response[2], response[3], response[4]
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

    -- e.g. from the TLS library, which KOReader exited on, without its timeouts being put back
    it("says what went wrong when KOReader's HTTP raises it rather than returning it", function()
        http.request = function()
            error("wantread")
        end

        local body, err = HttpUtil.getBody("https://libgen.example")
        assert.is_nil(body)
        assert.matches("wantread", err)
        assert.is_nil(helper.state.http_timeouts)
        assert.is_truthy(helper.logged("warn", "^KOReader's HTTP raised an error rather than returning it"))
    end)

    it("returns the HTTP status, e.g. of an error page", function()
        respond({ "<html>Forbidden</html>", 1, 403 })

        local body, err, status = HttpUtil.getBody("https://libgen.example")
        assert.are.equal("<html>Forbidden</html>", body)
        assert.is_nil(err)
        assert.are.equal(403, status)
    end)

    -- as curl says it, so it can be told apart from other failures, e.g. when the network blocks a site (#55)
    it("says that a site's name couldn't be looked up as curl does", function()
        for _, said in ipairs({
            "host or service not provided, or not known",
            "No address associated with hostname",
            "temporary failure in name resolution",
        }) do
            respond({ "", nil, said })
            local body, err = HttpUtil.getBody("https://libgen.example")
            assert.is_nil(body)
            assert.are.equal("could not resolve host", err)
            assert.are.equal(HttpUtil.UNRESOLVED, err)
        end
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
    describe("posting a form", function()
        local form = { { "email", "reader@example.com" }, { "password", "p@ss word" }, { "languages[]", "english" } }

        it("sends its fields, as a browser does", function()
            respond({ '{"success":1}', 1, 200 })

            assert.are.equal(
                '{"success":1}',
                HttpUtil.getBody("https://z-lib.example/eapi/user/login", { form = form })
            )
            assert.are.equal("POST", requests[1].method)
            local body = "email=reader%40example.com&password=p%40ss%20word&languages%5B%5D=english"
            assert.are.equal(body, requests[1].source.text)
            assert.are.equal("application/x-www-form-urlencoded", requests[1].headers["Content-Type"])
            assert.are.equal(tostring(#body), requests[1].headers["Content-Length"])
        end)

        -- which can be a password
        it("logs the names of its fields, but not what's in them", function()
            respond({ '{"success":1}', 1, 200 })
            HttpUtil.getBody("https://z-lib.example/eapi/user/login", { form = form })

            assert.is_truthy(
                helper.logged(
                    "dbg",
                    "^posting email, password, languages%[%] to https://z%-lib%.example/eapi/user/login$"
                )
            )
            for _, log in ipairs(helper.state.logs) do
                for i = 2, #log do
                    assert.is_nil(tostring(log[i]):find("p@ss", 1, true))
                end
            end
        end)
    end)

    it("sends the cookies it's given", function()
        respond({ "<html>profile</html>", 1, 200 })
        HttpUtil.getBody("https://z-lib.example/eapi/user/profile", { cookies = "remix_userid=1; remix_userkey=abc" })

        assert.are.equal("GET", requests[1].method)
        assert.are.equal("remix_userid=1; remix_userkey=abc", requests[1].headers["Cookie"])
    end)

    -- as a site's check that it isn't a bot can, which luasocket can't follow by itself, as it doesn't keep cookies
    it("asks again with the cookie a site answers with, along with a redirect back to where it was", function()
        respond({
            "",
            1,
            307,
            {
                location = "https://z-lib.example/eapi/user/login",
                ["set-cookie"] = "__wall=xyz; Path=/; Expires=Fri, 09 Oct 2026 12:00:00 GMT; Secure",
            },
        }, { '{"success":1}', 1, 200 })

        local body = HttpUtil.getBody(
            "https://z-lib.example/eapi/user/login",
            { form = { { "email", "a@b.c" } }, cookies = "remix_userid=1" }
        )
        assert.are.equal('{"success":1}', body)
        assert.are.equal(2, #requests)
        assert.is_false(requests[1].redirect)
        assert.are.equal("remix_userid=1; __wall=xyz", requests[2].headers["Cookie"])
        assert.are.equal("POST", requests[2].method)
        assert.are.equal("email=a%40b.c", requests[2].source.text)
    end)

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

        -- in a file of its own, rather than on curl's command line, where any program on the device can read them
        it("passes curl the form and cookies in a file", function()
            local config
            curlAnswers(function(cmd)
                config = helper.readFile(cmd:match("%-K '([^']+)'"))
                return '{"success":1}', 200
            end)

            local body = HttpUtil.getBody("https://z-lib.example/eapi/user/login", {
                form = { { "email", "a@b.c" }, { "password", "secret" } },
                cookies = "remix_userid=1",
            })
            assert.are.equal('{"success":1}', body)
            assert.are.equal(
                'cookie = ""\nheader = "Cookie: remix_userid=1"\ndata = "email=a%40b.c&password=secret"\n',
                config
            )
            assert.is_nil(fetches[1]:find("secret", 1, true))
        end)

        -- so that curl keeps the cookie a site's check that it isn't a bot answers with, which it only does when not
        -- given cookies of its own to send
        it("has curl keep cookies, even when there are none to send", function()
            local config
            curlAnswers(function(cmd)
                config = helper.readFile(cmd:match("%-K '([^']+)'"))
                return "{}", 200
            end)

            HttpUtil.getBody("https://z-lib.example/eapi/user/login", { form = { { "email", "a@b.c" } } })
            assert.are.equal('cookie = ""\ndata = "email=a%40b.c"\n', config)
        end)

        -- which was said to have been called off, so nothing was said at all, and the password was left in a file
        it("says when curl couldn't be started, rather than that it was called off", function()
            local popen = io.popen
            io.popen = function(cmd, ...)
                if cmd:find(" -w '%{http_code}'", 1, true) then
                    return nil
                end
                return popen(cmd, ...)
            end
            local body, err = HttpUtil.getBody("https://z-lib.example/eapi/user/login", {
                form = { { "password", "secret" } },
            })
            io.popen = popen
            assert.is_nil(body)
            assert.are.equal("could not start curl", err)
            assert.are.same({}, helper.readDir(data_dir .. "/settings/tmp"))

            -- as it does when waiting in the background with a message that wasn't tapped
            helper.stubs.trapper.wrapped = true
            HttpUtil.setTrapWidget({ text = "Logging in..." })
            helper.state.dismiss = true
            body, err = HttpUtil.getBody("https://z-lib.example/eapi/user/login")
            assert.is_nil(body)
            assert.are.equal("could not start curl", err)
        end)

        it("fetches other pages without a file of options", function()
            curlAnswers(function()
                return "<html>results</html>", 200
            end)

            HttpUtil.getBody("https://libgen.example")
            assert.is_nil(fetches[1]:find(" -K ", 1, true))
        end)

        describe("asked to wait in the background", function()
            local message

            before_each(function()
                helper.stubs.trapper.wrapped = true
                message = { text = "Searching..." }
                HttpUtil.setTrapWidget(message)
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

            -- each search, download and login waits in a coroutine of its own: hiding one download while it looked up
            -- its link, then starting another, had the second's Cancel call off the first, and once the first was
            -- over, a tap anywhere call off the second
            it("calls off each coroutine's requests with its own widget", function()
                local first_message, second_message = { text = "Finding a download link..." }, { text = "Searching..." }
                local first = coroutine.create(function()
                    HttpUtil.setTrapWidget(first_message)
                    coroutine.yield()
                    HttpUtil.getBody("https://libgen.example/ads.php")
                    HttpUtil.setTrapWidget(nil)
                end)
                local second = coroutine.create(function()
                    HttpUtil.setTrapWidget(second_message)
                    coroutine.yield()
                    HttpUtil.getBody("https://libgen.example/index.php")
                    HttpUtil.setTrapWidget(nil)
                end)

                assert.is_true(coroutine.resume(first))
                assert.is_true(coroutine.resume(second))
                assert.is_true(coroutine.resume(first))
                assert.is_true(coroutine.resume(second))
                assert.are.equal(first_message, helper.state.trapped[1].trap_widget)
                assert.are.equal(second_message, helper.state.trapped[2].trap_widget)
                -- and what's waited for outside them still has the one given there
                assert.are.equal(message, HttpUtil.getTrapWidget())
            end)

            it("says so when it's called off, without trying again through PROXY_URL", function()
                helper.state.env.PROXY_URL = "http://proxy.example:8080"
                -- a tap on its Cancel
                message.cancelled = true
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

    describe("downloading a file", function()
        local path

        before_each(function()
            path = data_dir .. "/curl-armhf"
        end)

        -- as a Kindle's own curl is too old to connect to many sites, such as GitHub (#57)
        it("downloads it with KOReader's own HTTP where curl can't fetch, following redirects", function()
            respond({ "\127ELF\0binary", 1, 200 })

            assert.is_true(HttpUtil.downloadFile("https://github.example/releases/curl-armhf", path))
            assert.are.equal("\127ELF\0binary", helper.readFile(path))
            assert.are.equal("https://github.example/releases/curl-armhf", requests[1].url)
            assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
            assert.is_true(requests[1].redirect)
        end)

        -- as a file can be several megabytes, and an e-reader's Wi-Fi slow
        it(
            "waits 10 seconds for an answer and five minutes for the file, then puts KOReader's timeouts back",
            function()
                respond({ "binary", 1, 200 })
                HttpUtil.downloadFile("https://github.example/curl-armhf", path)

                assert.are.same({ 10, 300 }, requests[1].timeouts)
                assert.is_nil(helper.state.http_timeouts)
            end
        )

        it("leaves nothing behind when the download fails", function()
            respond({ "", nil, "timeout" })

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("timeout", err)
            assert.is_false(helper.exists(path))
        end)

        it("leaves nothing behind when KOReader's HTTP raises what went wrong", function()
            http.request = function()
                error("closed")
            end

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.matches("closed", err)
            assert.is_false(helper.exists(path))
            assert.is_nil(helper.state.http_timeouts)
        end)

        -- rather than keeping the page saying what's wrong in place of the file
        it("says that the site's name couldn't be looked up as curl does", function()
            respond({ "", nil, "No address associated with hostname" })

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("could not resolve host", err)
        end)

        it("leaves nothing behind when the site answers with an error", function()
            respond({ "<html>Not Found</html>", 1, 404 })

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("HTTP error response (404)", err)
            assert.is_false(helper.exists(path))
        end)

        it("downloads it with curl where curl can fetch", function()
            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )
            local CurlUtil = require("util.curlutil")
            local download
            CurlUtil.download = function(url, filepath, use_proxy, max_time, opts)
                download = { url, filepath, use_proxy, max_time, opts }
                return nil, "request timed out"
            end

            local ok, err = HttpUtil.downloadFile("https://github.example/curl-armhf", path)
            assert.is_nil(ok)
            assert.are.equal("request timed out", err)
            -- for at most 5 minutes, and 30 seconds without anything arriving, as it holds KOReader up meanwhile
            assert.are.same({ "https://github.example/curl-armhf", path, false, 300, { stall_time = 30 } }, download)
            assert.are.equal(0, #requests)
        end)
    end)
end)
