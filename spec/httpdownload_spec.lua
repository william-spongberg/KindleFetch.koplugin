local helper = require("helper")

-- downloads with KOReader's own HTTP, where curl can't, as on a Kobo without curl (#63)
describe("HttpDownload", function()
    local data_dir, path, headers_file, requests, CurlUtil, HttpDownload

    -- KOReader's HTTP answering with the body, and what it returns
    local function answer(body, ...)
        local returned = { ... }
        helper.stubs.http.request = function(request)
            table.insert(requests, request)
            request.timeouts = helper.state.http_timeouts
            if body then
                request.sink(body)
            end
            return unpack(returned, 1, 4)
        end
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        path = data_dir .. "/Dune.epub.part"
        headers_file = data_dir .. "/headers"
        requests = {}
        CurlUtil = require("util.curlutil")
        HttpDownload = require("util.httpdownload")
    end)

    after_each(helper.cleanup)

    it("downloads the file in a process of its own, followed as curl's downloads are", function()
        answer("epub data", 1, 200, { ["content-length"] = "9" }, "HTTP/1.1 200 OK")
        local pid, exit_file = HttpDownload.start("https://libgen.example/get.php?md5=abc", path, {
            headers_file = headers_file,
            stall_time = 30,
        })

        assert.are.equal(helper.state.subprocesses[1], pid)
        assert.are.equal(0, require("util.backgroundprocess").getExitCode(exit_file))
        assert.are.equal("epub data", helper.readFile(path))
        -- noting down what curl would, for how big it is
        assert.are.equal(9, CurlUtil.getDownloadSize(headers_file))
        assert.are.equal(200, CurlUtil.getDownloadStatus(headers_file))
        -- as curl sends them, and giving up once nothing has arrived for a while, however long it takes
        assert.are.equal("Mozilla/5.0", requests[1].headers["User-Agent"])
        assert.are.equal("https://libgen.example/", requests[1].headers["Referer"])
        assert.are.same({ 30, -1 }, requests[1].timeouts)
        assert.is_nil(helper.state.http_timeouts)
    end)

    -- the Digest way, as Calibre's content server asks unless it's set up with HTTPS (see HttpLogin)
    it("logs in to a library's site the way it asks, keeping only the book it sends once it has", function()
        require("util.librarysites").add("http://nas:8080/opds", { username = "will", password = "secret" })
        local answers = {
            { "<html>Unauthorized</html>", 401, { ["www-authenticate"] = 'Digest realm="calibre", nonce="n"' } },
            { "epub data", 200, { ["content-length"] = "9" } },
        }
        helper.stubs.http.request = function(request)
            table.insert(requests, request)
            local reply = table.remove(answers, 1)
            request.sink(reply[1])
            return 1, reply[2], reply[3], "HTTP/1.1 " .. reply[2]
        end
        local _, exit_file = HttpDownload.start("http://nas:8080/get/epub/1", path, { headers_file = headers_file })

        assert.are.equal(0, require("util.backgroundprocess").getExitCode(exit_file))
        assert.are.equal("epub data", helper.readFile(path))
        -- noting down the headers of what was sent once logged in
        assert.are.equal(200, CurlUtil.getDownloadStatus(headers_file))
        assert.are.equal(9, CurlUtil.getDownloadSize(headers_file))
        assert.matches('^Digest username="will"', requests[2].headers.Authorization)
        assert.are.equal("http://nas:8080/", requests[2].headers["Referer"])
    end)

    it("says the site answered with an error as curl does", function()
        answer("<html>Not Found</html>", 1, 404, {}, "HTTP/1.1 404 Not Found")
        local _, exit_file = HttpDownload.start("https://libgen.example/get.php", path, { headers_file = headers_file })
        assert.are.equal(22, require("util.backgroundprocess").getExitCode(exit_file))
        assert.are.equal(404, CurlUtil.getDownloadStatus(headers_file))
    end)

    it("says what went wrong as curl would have", function()
        for luasocket_err, exit_code in pairs({
            ["timeout"] = 28,
            ["host not found"] = 6,
            ["connection refused"] = 7,
            ["wantread"] = 35,
            ["something else"] = 56,
        }) do
            answer(nil, nil, luasocket_err)
            local _, exit_file = HttpDownload.start("https://libgen.example/get.php", path)
            assert.are.equal(exit_code, require("util.backgroundprocess").getExitCode(exit_file), luasocket_err)
        end

        -- including what it raises rather than returns
        helper.stubs.http.request = function()
            error("closed")
        end
        local _, exit_file = HttpDownload.start("https://libgen.example/get.php", path)
        assert.are.equal(56, require("util.backgroundprocess").getExitCode(exit_file))
    end)

    it("says when the file can't be written, as curl does", function()
        answer("epub data", 1, 200)
        local _, exit_file = HttpDownload.start("https://libgen.example/get.php", data_dir .. "/missing/Dune.epub")
        assert.are.equal(23, require("util.backgroundprocess").getExitCode(exit_file))
    end)

    it("says when its process couldn't be started", function()
        helper.state.fork_fails = true
        local pid, err = HttpDownload.start("https://libgen.example/get.php", path)
        assert.is_nil(pid)
        assert.are.equal("could not start downloading", err)
    end)

    it("downloads several files one after another, saying how each went as curl does", function()
        local covers = { data_dir .. "/a.jpg", data_dir .. "/b.jpg" }
        helper.stubs.http.request = function(request)
            if request.url:find("a.jpg", 1, true) then
                request.sink("jpeg")
                return 1, 200, {}, "HTTP/1.1 200 OK"
            end
            return nil, "timeout"
        end

        local pid, exit_file, config_file =
            HttpDownload.startMultiple({ "https://covers.example/a.jpg", "https://covers.example/b.jpg" }, covers)
        assert.is_not_nil(pid)
        local results = CurlUtil.getTransferResults(CurlUtil.getResultsFile(config_file))
        assert.are.same({ [covers[1]] = 0, [covers[2]] = 28 }, results)
        assert.are.equal("jpeg", helper.readFile(covers[1]))
        assert.is_false(helper.exists(covers[2]))
        assert.are.equal(28, require("util.backgroundprocess").getExitCode(exit_file))
    end)

    -- which KOReader keeps as a zombie until it closes, otherwise
    it("collects a download's process once it has finished", function()
        helper.state.subprocesses_running[5000000] = true
        require("util.backgroundprocess").collectPid(5000000)
        assert.is_nil(helper.state.subprocesses_collected[5000000])

        helper.state.subprocesses_running[5000000] = nil
        helper.runScheduled()
        assert.is_true(helper.state.subprocesses_collected[5000000])
    end)
end)
