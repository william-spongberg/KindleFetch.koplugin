local helper = require("helper")
local fixtures = require("fixtures")

describe("CoverCache", function()
    local data_dir, covers_dir, CurlUtil, CoverCache

    local function book(md5, image_url)
        return {
            md5 = md5,
            title = "Book " .. md5,
            image_url = image_url
        }
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        covers_dir = data_dir .. "/settings/kindlefetch_covers/"
        CurlUtil = require("util.curlutil")
        CoverCache = require("cache.covercache")
    end)

    after_each(helper.cleanup)

    it("stores covers by md5", function()
        assert.are.equal(covers_dir .. "abc.jpg", CoverCache:getPath("abc"))
        assert.is_true(helper.isDir(covers_dir))
    end)

    describe("download", function()
        it("downloads and remembers a cover", function()
            CurlUtil.download = function(url, path, use_proxy, background, max_time)
                assert.are.equal("https://covers.example/abc.jpg", url)
                -- the download prompt waits for the cover, so a stalled one mustn't hold it up
                assert.are.equal(10, max_time)
                helper.writeFile(path, "jpeg")
                return true
            end

            assert.are.equal(covers_dir .. "abc.jpg", CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.is_true(CoverCache:cacheExists("abc"))
            assert.are.equal(covers_dir .. "abc.jpg", CoverCache:get("abc"))
        end)

        it("retries through PROXY_URL when the direct download fails", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            local attempts = {}
            CurlUtil.download = function(_, path, use_proxy)
                table.insert(attempts, use_proxy)
                if use_proxy then
                    helper.writeFile(path, "jpeg")
                    return true
                end
                return false, "TLS/SSL connection failed"
            end

            assert.are.equal(covers_dir .. "abc.jpg", CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.are.same({false, true}, attempts)
        end)

        it("does not retry without PROXY_URL", function()
            helper.state.env.PROXY_URL = false
            local attempts = 0
            CurlUtil.download = function()
                attempts = attempts + 1
                return false, "TLS/SSL connection failed"
            end

            assert.is_nil(CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.are.equal(1, attempts)
        end)

        it("returns nil when the download fails", function()
            CurlUtil.download = function()
                return false, "HTTP error response"
            end

            assert.is_nil(CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.is_false(CoverCache:cacheExists("abc"))
        end)
    end)

    describe("isComing", function()
        it("is true for covers yet to download", function()
            assert.is_true(CoverCache:isComing(book("a", "https://covers.example/a.jpg")))
        end)

        it("is false for books without a cover", function()
            assert.is_false(CoverCache:isComing(book("a")))
        end)

        it("is false once the cover has downloaded", function()
            fixtures.cacheCover(helper, "a")
            assert.is_false(CoverCache:isComing(book("a", "https://covers.example/a.jpg")))
        end)

        it("is false once the cover couldn't be downloaded, until it's tried again", function()
            local a = book("a", "https://covers.example/a.jpg")
            CurlUtil.downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end
            CoverCache:downloadMultiple({a}, 6)
            assert.is_false(CoverCache:isComing(a))

            CurlUtil.downloadMultiple = function()
                return 4000, "exit", "config"
            end
            CoverCache:downloadMultiple({a}, 6)
            assert.is_true(CoverCache:isComing(a))
        end)
    end)

    describe("get", function()
        it("returns nil for covers that were never downloaded", function()
            assert.is_nil(CoverCache:get("abc"))
        end)

        it("agrees with cacheExists for covers dropped from the cache", function()
            -- older covers are dropped from the cache once it is full, but their files stay behind
            helper.writeFile(covers_dir .. "abc.jpg", "jpeg")

            assert.is_nil(CoverCache:get("abc"))
            assert.is_false(CoverCache:cacheExists("abc"))
        end)

        it("forgets covers whose file has been deleted", function()
            CurlUtil.download = function(_, path)
                helper.writeFile(path, "jpeg")
                return true
            end
            CoverCache:download("abc", "https://covers.example/abc.jpg")
            os.remove(covers_dir .. "abc.jpg")

            assert.is_nil(CoverCache:get("abc"))
            assert.is_nil(helper.state.settings_files[data_dir .. "/settings/kindlefetch_covercache.lua"].abc)
        end)
    end)

    describe("downloadMultiple", function()
        local runs, results

        -- pretend to be curl running in the background: the spec finishes each run with finishRun
        local function finishRun(run, succeeded, exit_code)
            for i, path in ipairs(run.paths) do
                if succeeded[i] then
                    helper.writeFile(path, "jpeg")
                end
            end
            helper.writeFile(run.exit_file, tostring(exit_code or 0))
        end

        local function onDone(count)
            table.insert(results, count)
        end

        before_each(function()
            runs, results = {}, {}
            CurlUtil.downloadMultiple = function(urls, paths, use_proxy, background, parallel_jobs)
                assert.is_true(background)
                local run = {
                    urls = urls,
                    paths = paths,
                    use_proxy = use_proxy,
                    parallel_jobs = parallel_jobs,
                    pid = 4000 + #runs,
                    exit_file = CurlUtil.createExitFile() .. #runs
                }
                table.insert(runs, run)
                return run.pid, run.exit_file, data_dir .. "/settings/curl_config.txt"
            end
            CurlUtil.isPidRunning = function()
                return true
            end
        end)

        it("downloads missing covers in the background", function()
            fixtures.cacheCover(helper, "cached")
            local books = {book("cached", "https://covers.example/cached.jpg"), book("new", "https://covers.example/new.jpg"),
                           book("no-image"), {title = "no md5", image_url = "https://covers.example/x.jpg"}}

            assert.is_true(CoverCache:downloadMultiple(books, 6, onDone))
            assert.are.equal(1, #runs)
            assert.are.same({"https://covers.example/new.jpg"}, runs[1].urls)
            assert.are.same({covers_dir .. "new.jpg"}, runs[1].paths)
            assert.are.equal(6, runs[1].parallel_jobs)
            assert.is_false(runs[1].use_proxy)
            -- search results show placeholders, rather than a notification
            assert.are.equal(0, #helper.state.notifications)

            -- nothing happens until curl has finished
            helper.tick()
            assert.are.same({}, results)
            assert.is_false(CoverCache:cacheExists("new"))

            finishRun(runs[1], {true})
            helper.tick()
            assert.are.same({1}, results)
            assert.are.equal(covers_dir .. "new.jpg", CoverCache:get("new"))
            -- so every open search result can show them
            assert.are.same({"KindleFetchCoversDownloaded"}, helper.state.broadcasts)
        end)

        it("does not download covers that are already downloading", function()
            local books = {book("a", "https://covers.example/a.jpg")}
            CoverCache:downloadMultiple(books, 6, onDone)

            assert.is_false(CoverCache:downloadMultiple(books, 6, onDone))
            assert.are.equal(1, #runs)

            finishRun(runs[1], {false}, 22)
            helper.runScheduled()
            assert.is_true(CoverCache:downloadMultiple(books, 6, onDone))
        end)

        it("discards the covers when curl fails", function()
            CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg")},
                6, onDone)
            finishRun(runs[1], {true, false}, 28)
            helper.runScheduled()

            assert.are.same({0}, results)
            assert.is_false(helper.exists(covers_dir .. "a.jpg"))
            assert.is_false(CoverCache:cacheExists("a"))
            -- so the placeholders can be taken away
            assert.are.same({"KindleFetchCoversDownloaded"}, helper.state.broadcasts)
        end)

        it("keeps the covers that downloaded when others fail", function()
            CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg")},
                6, onDone)
            -- curl writes each cover's result next to its config file
            helper.writeFile(data_dir .. "/settings/curl_config.txt.results",
                "0 " .. covers_dir .. "a.jpg\n28 " .. covers_dir .. "b.jpg\n")
            finishRun(runs[1], {true, true}, 28)
            helper.runScheduled()

            assert.are.same({1}, results)
            assert.is_true(CoverCache:cacheExists("a"))
            assert.is_false(CoverCache:cacheExists("b"))
            assert.is_false(helper.exists(covers_dir .. "b.jpg"))
        end)

        -- curl can finish just after its exit code was checked, before checking whether it's running
        it("reads the exit code again once curl has stopped", function()
            CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg")}, 6, onDone)
            CurlUtil.isPidRunning = function()
                finishRun(runs[1], {true})
                return false
            end
            helper.runScheduled()

            assert.are.same({1}, results)
        end)

        it("stops when curl stops without reporting back", function()
            CurlUtil.isPidRunning = function()
                return false
            end
            CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg")}, 6, onDone)
            helper.runScheduled()

            assert.are.same({0}, results)
        end)

        it("reports nothing downloaded when curl cannot be started", function()
            CurlUtil.downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end

            assert.is_true(CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg")}, 6, onDone))
            assert.are.same({0}, results)
        end)

        it("retries the covers that failed through PROXY_URL", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            local books = {book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg")}
            CoverCache:downloadMultiple(books, 6, onDone)

            finishRun(runs[1], {false, false}, 35)
            helper.tick()
            assert.are.equal(2, #runs)
            assert.is_true(runs[2].use_proxy)
            assert.are.same({"https://covers.example/a.jpg", "https://covers.example/b.jpg"}, runs[2].urls)

            finishRun(runs[2], {true, true})
            helper.tick()
            assert.are.same({2}, results)
            assert.is_true(CoverCache:cacheExists("b"))
        end)

        it("does not retry covers without PROXY_URL", function()
            helper.state.env.PROXY_URL = false
            CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg")}, 6, onDone)

            finishRun(runs[1], {false}, 35)
            helper.runScheduled()
            assert.are.equal(1, #runs)
            assert.are.same({0}, results)
        end)

        it("does nothing when every cover is cached", function()
            assert.is_false(CoverCache:downloadMultiple({book("no-image")}, 6, onDone))
            assert.are.equal(0, #runs)
            assert.are.equal(0, #helper.state.notifications)
        end)
    end)
end)
