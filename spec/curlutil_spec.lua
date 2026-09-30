local helper = require("helper")

describe("CurlUtil", function()
    local data_dir, CurlUtil

    -- pretend to be curl: write body to the -o file and the exit code to the exit file
    local function fakeCurl(body, exit_code)
        return function(cmd)
            local output = cmd:match("%-o '([^']+)'")
            if output and body then
                helper.writeFile(output, body)
            end
            helper.writeFile(cmd:match("echo %$%? > '([^']+)'"), tostring(exit_code or 0) .. "\n")
        end
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        CurlUtil = require("util.curlutil")
    end)

    after_each(helper.cleanup)

    it("quotes strings for the shell", function()
        assert.are.equal("'plain'", CurlUtil.shellQuote("plain"))
        assert.are.equal("'it'\\''s'", CurlUtil.shellQuote("it's"))
        assert.are.equal("'; rm -rf /'", CurlUtil.shellQuote("; rm -rf /"))
    end)

    it("sends the site as the referer", function()
        assert.are.equal(
            "curl -e 'https://libgen.example/'",
            CurlUtil.setReferer("curl", "https://libgen.example/fictioncovers/1/abc_small.jpg")
        )
        assert.are.equal("curl", CurlUtil.setReferer("curl", "not a url"))
    end)

    it("explains curl exit codes", function()
        assert.are.equal("could not resolve host", CurlUtil.getErrorMeaning(6))
        assert.are.equal("TLS certificate verification failed", CurlUtil.getErrorMeaning(60))
        assert.are.equal("(curl exit code 99)", CurlUtil.getErrorMeaning(99))
    end)

    it("reads curl's version", function()
        helper.stubCommand("curl --version", "curl 8.17.0 (arm-unknown-linux-musleabihf) libcurl/8.17.0\n")
        assert.are.equal("8.17.0", CurlUtil.getVersion())
        helper.stubCommand("curl --version", "")
        assert.is_nil(CurlUtil.getVersion())
    end)

    describe("processes", function()
        it("detects whether a process is running and can kill it", function()
            local pipe = io.popen("sleep 30 > /dev/null 2>&1 & echo $!")
            local pid = tonumber(pipe:read("*l"))
            pipe:close()

            assert.is_true(CurlUtil.isPidRunning(pid))
            CurlUtil.killPid(pid)
            os.execute("sleep 0.2")
            assert.is_false(CurlUtil.isPidRunning(pid))
        end)

        it("looks in /proc, without starting a shell", function()
            local proc = helper.tmpdir("proc")
            CurlUtil.PROC_DIR = proc
            helper.writeFile(proc .. "/self/stat", "100 (luajit) R 1")
            helper.writeFile(proc .. "/4242/stat", "4242 (sh (curl)) S 1 4242")
            helper.writeFile(proc .. "/4343/stat", "4343 (sh) Z 1 4343")
            helper.stubExecute("kill -0", function()
                error("started a shell")
            end)

            assert.is_true(CurlUtil.isPidRunning(4242))
            -- finished, but not cleaned up yet
            assert.is_false(CurlUtil.isPidRunning(4343))
            assert.is_false(CurlUtil.isPidRunning(4444))
        end)

        it("asks kill on systems without /proc", function()
            CurlUtil.PROC_DIR = helper.tmpdir("no-proc")
            helper.stubExecute("kill -0 4242", function()
                return 0
            end)
            assert.is_true(CurlUtil.isPidRunning(4242))
        end)

        it("ignores missing pids", function()
            assert.is_false(CurlUtil.isPidRunning(nil))
            CurlUtil.killPid(nil)
        end)
    end)

    describe("getRemoteFileSize", function()
        it("uses the content length of the final response after redirects", function()
            helper.stubCommand(
                "curl -sL -I 'https://libgen.example/get.php?md5=abc'",
                "HTTP/1.1 302 Found\r\nLocation: https://cdn.example/book\r\nContent-Length: 0\r\n\r\n"
                    .. "HTTP/2 200\r\ncontent-length: 1048576\r\n\r\n"
            )
            assert.are.equal(1048576, CurlUtil.getRemoteFileSize("https://libgen.example/get.php?md5=abc"))

            -- asks like a browser, or Library Genesis sends a small page instead of the file
            local cmd = helper.state.popen_calls[#helper.state.popen_calls]
            assert.matches("-A 'Mozilla/5.0'", cmd, 1, true)
            assert.matches("-e 'https://libgen.example/'", cmd, 1, true)
        end)

        it("returns nil when the size is unknown", function()
            helper.stubCommand("curl -sL -I", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            assert.is_nil(CurlUtil.getRemoteFileSize("https://libgen.example/get.php"))
        end)
    end)

    describe("exit files", function()
        it("creates a fresh exit file path in the plugin's tmp dir", function()
            local exit_file = CurlUtil.createExitFile()
            assert.matches(data_dir .. "/settings/tmp/curl_download_", exit_file, 1, true)
            assert.is_false(helper.exists(exit_file))
        end)

        -- a book's cover and the book itself can start downloading within the same second
        it("are different for downloads started within the same second", function()
            helper.state.time = 1000
            assert.are_not.equal(CurlUtil.createExitFile(), CurlUtil.createExitFile())
        end)

        it("reads and removes the exit code once curl has finished", function()
            local exit_file = CurlUtil.createExitFile()
            assert.is_nil(CurlUtil.getExitCode(exit_file))

            helper.writeFile(exit_file, "22\n")
            assert.are.equal(22, CurlUtil.getExitCode(exit_file))
            assert.is_false(helper.exists(exit_file))
        end)
    end)

    describe("getProxyFlag", function()
        it("uses PROXY_URL when asked to", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            assert.are.equal("-x 'http://proxy.example:8080'", CurlUtil.getProxyFlag(true))
            assert.are.equal("", CurlUtil.getProxyFlag(false))
        end)

        it("is empty without PROXY_URL", function()
            helper.state.env.PROXY_URL = ""
            assert.are.equal("", CurlUtil.getProxyFlag(true))
        end)
    end)

    it("builds a download command that saves curl's exit code", function()
        helper.state.env.PROXY_URL = "http://proxy.example:8080"
        local cmd = CurlUtil.getCMD("https://libgen.example/get.php", "Dune.epub", "exit", true)

        assert.are.equal(
            "(curl -sL -f -o 'Dune.epub' 'https://libgen.example/get.php' --retry 2 --retry-delay 2 "
                .. "--connect-timeout 15 -x 'http://proxy.example:8080'; echo $? > 'exit') >/dev/null 2>&1",
            cmd
        )
    end)

    describe("download", function()
        local filepath

        before_each(function()
            filepath = data_dir .. "/Dune.epub"
        end)

        it("downloads the file with retries, a timeout and a browser user agent", function()
            helper.stubExecute("curl -sL -f -o", fakeCurl("epub data"))

            assert.is_true(CurlUtil.download("https://libgen.example/get.php?md5=abc", filepath, false, false))
            assert.are.equal("epub data", helper.readFile(filepath))

            local cmd = helper.state.executed[#helper.state.executed]
            assert.matches("'https://libgen.example/get.php?md5=abc'", cmd, 1, true)
            assert.matches("-A 'Mozilla/5.0'", cmd, 1, true)
            -- Library Genesis sends empty covers without a referer
            assert.matches("-e 'https://libgen.example/'", cmd, 1, true)
            assert.matches("--retry 2 --retry-delay 2", cmd, 1, true)
            assert.matches("--connect-timeout 15", cmd, 1, true)
        end)

        it("can limit how long the download takes", function()
            helper.stubExecute("curl -sL -f -o", fakeCurl("jpeg"))

            CurlUtil.download("https://libgen.example/cover.jpg", filepath, false, false, 10)
            assert.matches("--max-time 10 --retry-max-time 10", helper.state.executed[#helper.state.executed], 1, true)

            CurlUtil.download("https://libgen.example/get.php", filepath, false, false)
            assert.is_nil(helper.state.executed[#helper.state.executed]:find("--max-time", 1, true))
        end)

        it("fails and cleans up when curl fails", function()
            helper.stubExecute("curl -sL -f -o", fakeCurl("partial", 6))

            local ok, err = CurlUtil.download("https://libgen.example/get.php", filepath, false, false)
            assert.is_false(ok)
            assert.are.equal("could not resolve host", err)
            assert.is_false(helper.exists(filepath))
        end)

        it("fails when the download is empty", function()
            helper.stubExecute("curl -sL -f -o", fakeCurl(""))

            local ok, err = CurlUtil.download("https://libgen.example/get.php", filepath, false, false)
            assert.is_false(ok)
            assert.are.equal("download produced empty file", err)
            assert.is_false(helper.exists(filepath))
        end)

        it("downloads through PROXY_URL when asked to", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            helper.stubExecute("curl -sL -f -o", fakeCurl("epub data"))

            assert.is_true(CurlUtil.download("https://libgen.example/get.php", filepath, true, false))
            assert.matches("-x 'http://proxy.example:8080'", helper.state.executed[#helper.state.executed], 1, true)
        end)

        it("runs in the background and returns the curl pid", function()
            helper.stubCommand("& echo $!", "4242\n")

            local pid, exit_file = CurlUtil.download("https://libgen.example/get.php", filepath, false, true)
            assert.are.equal(4242, pid)
            assert.matches(data_dir .. "/settings/tmp/curl_download_", exit_file, 1, true)
        end)

        it("reports when the background download cannot start", function()
            helper.stubCommand("& echo $!", "")

            local pid, exit_file, err = CurlUtil.download("https://libgen.example/get.php", filepath, false, true)
            assert.is_nil(pid)
            assert.is_nil(exit_file)
            assert.are.equal("unable to determine curl pid", err)
        end)
    end)

    describe("downloadMultiple", function()
        local urls, paths

        -- pretend to be curl --config: write each output listed in the config file, and each one's result
        local function fakeParallelCurl(bodies, exit_code, transfer_exit_codes)
            return function(cmd)
                local config = helper.readFile(cmd:match('%-%-config "([^"]+)"'))
                local results = {}
                local i = 0
                for output in config:gmatch('output = "([^"]+)"') do
                    i = i + 1
                    if bodies[i] then
                        helper.writeFile(output, bodies[i])
                    end
                    if transfer_exit_codes then
                        table.insert(results, transfer_exit_codes[i] .. " " .. output)
                    end
                end
                helper.writeFile(cmd:match("%-w '[^']*' > '([^']+)'"), table.concat(results, "\n"))
                helper.writeFile(cmd:match("echo %$%? > '([^']+)'"), tostring(exit_code or 0))
            end
        end

        before_each(function()
            urls = { "https://covers.example/a.jpg", "https://covers.example/b.jpg", "https://covers.example/c.jpg" }
            paths = { data_dir .. "/a.jpg", data_dir .. "/b.jpg", data_dir .. "/c.jpg" }
        end)

        it("downloads files in parallel and counts the successful ones", function()
            helper.stubExecute("curl -sL -f --config", fakeParallelCurl({ "a", "", "c" }))

            assert.are.equal(2, CurlUtil.downloadMultiple(urls, paths, false, false, 4, true, 15))
            assert.is_true(helper.exists(paths[1]))
            assert.is_false(helper.exists(paths[2]))
            assert.is_true(helper.exists(paths[3]))

            local cmd = helper.state.executed[#helper.state.executed]
            assert.matches("--parallel --parallel-max 4", cmd, 1, true)
            -- stalled files are given up on
            assert.matches("--connect-timeout 15 --max-time 30", cmd, 1, true)
            assert.matches("-w '%{exitcode} %{filename_effective}\\n'", cmd, 1, true)
            assert.matches("-e 'https://covers.example/'", cmd, 1, true)
            assert.matches("--retry 2", cmd, 1, true)
        end)

        it("removes the curl config file afterwards", function()
            local config_file
            helper.stubExecute("curl -sL -f --config", function(cmd)
                config_file = cmd:match('%-%-config "([^"]+)"')
                fakeParallelCurl({ "a", "b", "c" })(cmd)
            end)

            CurlUtil.downloadMultiple(urls, paths, false, false, 4, false, 15)
            assert.is_false(helper.exists(config_file))
        end)

        it("keeps the files that downloaded when others fail", function()
            helper.stubExecute("curl -sL -f --config", fakeParallelCurl({ "a", "partial", "c" }, 28, { 0, 28, 0 }))

            assert.are.equal(2, CurlUtil.downloadMultiple(urls, paths, false, false, 4, false, 15))
            assert.is_true(helper.exists(paths[1]))
            assert.is_false(helper.exists(paths[2]))
            assert.is_true(helper.exists(paths[3]))
        end)

        it("discards everything and notifies when curl fails", function()
            helper.stubExecute("curl -sL -f --config", fakeParallelCurl({ "a", "b", "c" }, 28))

            assert.are.equal(0, CurlUtil.downloadMultiple(urls, paths, false, false, 4, false, 15))
            assert.is_false(helper.exists(paths[1]))
            assert.matches("request timed out", helper.lastNotification(), 1, true)
        end)

        it("runs in the background and returns the pid and files to poll", function()
            helper.stubCommand("& echo $!", "4242\n")

            local pid, exit_file, config_file = CurlUtil.downloadMultiple(urls, paths, false, true, 4, false, 15)
            assert.are.equal(4242, pid)
            assert.is_not_nil(exit_file)
            assert.matches('output = "' .. paths[2] .. '"', helper.readFile(config_file), 1, true)
        end)

        it("keeps the files of downloads started within the same second apart", function()
            helper.stubCommand("& echo $!", "4242\n")
            helper.state.time = 1000

            local _, first_exit, first_config = CurlUtil.downloadMultiple(urls, paths, false, true, 4, false, 15)
            local _, second_exit, second_config = CurlUtil.downloadMultiple(
                { urls[1] },
                { paths[1] },
                false,
                true,
                4,
                false,
                15
            )
            assert.are_not.equal(first_exit, second_exit)
            assert.are_not.equal(first_config, second_config)
            assert.are_not.equal(CurlUtil.getResultsFile(first_config), CurlUtil.getResultsFile(second_config))
            assert.matches('output = "' .. paths[2] .. '"', helper.readFile(first_config), 1, true)
        end)

        it("cleans up when the background download cannot start", function()
            helper.stubCommand("& echo $!", "")

            local pid, _, _, err = CurlUtil.downloadMultiple(urls, paths, false, true, 4, false, 15)
            assert.is_nil(pid)
            assert.are.equal("unable to determine curl pid", err)
            assert.are.same({}, helper.readDir(data_dir .. "/settings/tmp"))
        end)
    end)
end)
