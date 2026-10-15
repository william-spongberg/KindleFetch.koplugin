local helper = require("helper")
local fixtures = require("fixtures")

describe("CoverCache", function()
    local data_dir, covers_dir, CurlUtil, CoverCache

    local function book(id, image_url)
        return {
            id = id,
            title = "Book " .. id,
            image_url = image_url,
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

    it("can be cleared, removing the covers' files", function()
        fixtures.cacheCover(helper, "abc")
        local path = CoverCache:get("abc")
        assert.is_true(helper.exists(path))

        CoverCache:clear()
        assert.is_nil(CoverCache:get("abc"))
        assert.is_false(helper.exists(path))
        -- and can be cleared again, empty
        CoverCache:clear()
    end)

    -- which lfs.dir raises, and KOReader would exit on
    it("carries on when its folder can't be read", function()
        fixtures.cacheCover(helper, "abc")
        helper.stubs.lfs.dir = function(path)
            error("cannot open " .. path .. ": Permission denied")
        end
        CoverCache:clear()
        CurlUtil.canFetch = function()
            return true
        end
        CurlUtil.downloadMultiple = function()
            return nil, nil, nil, "unable to launch curl"
        end
        assert.is_true(CoverCache:downloadMultiple({ book("a", "https://covers.example/a.jpg") }, 6))
        assert.is_true(CurlUtil.removeLeftovers() == nil)
    end)

    it("stores covers by book id", function()
        assert.are.equal(covers_dir .. "abc.jpg", CoverCache:getPath("abc"))
        assert.is_true(helper.isDir(covers_dir))
    end)

    describe("download", function()
        it("downloads and remembers a cover", function()
            CurlUtil.download = function(url, path, use_proxy, max_time)
                assert.are.equal("https://covers.example/abc.jpg", url)
                -- the download prompt waits for the cover, so a stalled one mustn't hold it up
                assert.are.equal(10, max_time)
                helper.writeFile(path, fixtures.JPEG)
                return true
            end

            assert.are.equal(covers_dir .. "abc.jpg", CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.is_true(CoverCache:cacheExists("abc"))
            assert.are.equal(covers_dir .. "abc.jpg", CoverCache:get("abc"))
        end)

        -- e.g. a web page sent in its place, which would be kept for good, as covers are
        it("doesn't keep a cover that isn't an image", function()
            CurlUtil.download = function(_, path)
                helper.writeFile(path, "<!DOCTYPE html><html><title>Not Found</title></html>")
                return true
            end

            assert.is_nil(CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.is_false(CoverCache:cacheExists("abc"))
            assert.is_false(helper.exists(covers_dir .. "abc.jpg"))
            assert.is_truthy(helper.logged("warn", "^left out the cover of abc as it isn't an image: Not Found$"))
        end)

        it("retries through PROXY_URL when the direct download fails", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            local attempts = {}
            CurlUtil.download = function(_, path, use_proxy)
                table.insert(attempts, use_proxy)
                if use_proxy then
                    helper.writeFile(path, fixtures.JPEG)
                    return true
                end
                return nil, "TLS/SSL connection failed"
            end

            assert.are.equal(covers_dir .. "abc.jpg", CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.are.same({ false, true }, attempts)
        end)

        it("does not retry without PROXY_URL", function()
            helper.state.env.PROXY_URL = false
            local attempts = 0
            CurlUtil.download = function()
                attempts = attempts + 1
                return nil, "TLS/SSL connection failed"
            end

            assert.is_nil(CoverCache:download("abc", "https://covers.example/abc.jpg"))
            assert.are.equal(1, attempts)
        end)

        it("returns nil when the download fails", function()
            CurlUtil.download = function()
                return nil, "HTTP error response"
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
            CurlUtil.canFetch = function()
                return true
            end
            CurlUtil.downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end
            CoverCache:downloadMultiple({ a }, 6)
            assert.is_false(CoverCache:isComing(a))

            CurlUtil.downloadMultiple = function()
                return 4000, "exit", "config"
            end
            CoverCache:downloadMultiple({ a }, 6)
            assert.is_true(CoverCache:isComing(a))
        end)
    end)

    describe("get", function()
        it("returns nil for covers that were never downloaded", function()
            assert.is_nil(CoverCache:get("abc"))
        end)

        it("agrees with cacheExists for covers dropped from the cache", function()
            -- older versions dropped covers from the cache once it was full, but left their files behind
            helper.writeFile(covers_dir .. "abc.jpg", fixtures.JPEG)

            assert.is_nil(CoverCache:get("abc"))
            assert.is_false(CoverCache:cacheExists("abc"))
        end)

        it("forgets covers whose file has been deleted", function()
            CurlUtil.download = function(_, path)
                helper.writeFile(path, fixtures.JPEG)
                return true
            end
            CoverCache:download("abc", "https://covers.example/abc.jpg")
            os.remove(covers_dir .. "abc.jpg")

            assert.is_nil(CoverCache:get("abc"))
            assert.is_nil(helper.state.settings_files[data_dir .. "/settings/kindlefetch_covercache.lua"].abc)
        end)
    end)

    -- which KOReader exited on, with every cover on the page left waiting for
    it("takes the placeholders away when the covers can't be downloaded, as the device's storage is full", function()
        CurlUtil.canFetch = function()
            return true
        end
        local results = {}
        local covers = { book("a", "https://covers.example/a.jpg") }
        helper.writeFile(data_dir .. "/settings/tmp", "not a folder")

        assert.is_true(CoverCache:downloadMultiple(covers, 6, function(count)
            table.insert(results, count)
        end))
        assert.are.same({ 0 }, results)
        assert.is_false(CoverCache:isComing(covers[1]))
        assert.are.same({ "KindleFetchCoversDownloaded" }, helper.state.broadcasts)
    end)

    -- which left every cover a placeholder on a device without curl, as a Kobo can be (#63)
    it("downloads covers with KOReader's own HTTP where curl can't", function()
        helper.stubs.http.request = function(request)
            request.sink(fixtures.JPEG .. " " .. request.url)
            return 1, 200, {}, "HTTP/1.1 200 OK"
        end
        local counts = {}
        CoverCache:downloadMultiple(
            { book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg") },
            6,
            function(count)
                table.insert(counts, count)
            end
        )
        helper.runScheduled()

        assert.are.same({ 2 }, counts)
        assert.are.equal(fixtures.JPEG .. " https://covers.example/b.jpg", helper.readFile(CoverCache:get("b")))
        assert.is_true(helper.state.subprocesses_collected[helper.state.subprocesses[1]])
    end)

    describe("downloadMultiple", function()
        local runs, results

        -- pretend to be curl running in the background: the spec finishes each run with finishRun
        local function finishRun(run, succeeded, exit_code)
            for i, path in ipairs(run.paths) do
                if succeeded[i] then
                    helper.writeFile(path, fixtures.JPEG)
                end
            end
            helper.writeFile(run.exit_file, tostring(exit_code or 0))
        end

        local function onDone(count)
            table.insert(results, count)
        end

        before_each(function()
            runs, results = {}, {}
            CurlUtil.canFetch = function()
                return true
            end
            CurlUtil.downloadMultiple = function(urls, paths, use_proxy, background, parallel_jobs, _, _, opts)
                assert.is_true(background)
                local run = {
                    urls = urls,
                    paths = paths,
                    use_proxy = use_proxy,
                    parallel_jobs = parallel_jobs,
                    stall_time = opts.stall_time,
                    pid = 4000 + #runs,
                    exit_file = CurlUtil.createExitFile() .. #runs,
                }
                table.insert(runs, run)
                return run.pid, run.exit_file, data_dir .. "/settings/curl_config.txt"
            end
            CurlUtil.isPidRunning = function()
                return true
            end
        end)

        it("leaves out covers that aren't images, rather than keeping them for good", function()
            CoverCache:downloadMultiple(
                { book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg") },
                6,
                onDone
            )
            finishRun(runs[1], { true, true })
            helper.writeFile(covers_dir .. "b.jpg", "<html><head><title>Not Found</title></head></html>")
            helper.runScheduled()

            assert.are.same({ 1 }, results)
            assert.is_true(CoverCache:cacheExists("a"))
            assert.is_false(CoverCache:cacheExists("b"))
            assert.is_false(helper.exists(covers_dir .. "b.jpg"))
            -- showing no placeholder for it
            assert.is_false(CoverCache:isComing(book("b", "https://covers.example/b.jpg")))
            assert.is_truthy(helper.logged("warn", "^left out the cover of b as it isn't an image: Not Found$"))
        end)

        it("downloads missing covers in the background", function()
            fixtures.cacheCover(helper, "cached")
            local books = {
                book("cached", "https://covers.example/cached.jpg"),
                book("new", "https://covers.example/new.jpg"),
                book("no-image"),
                { title = "no id", image_url = "https://covers.example/x.jpg" },
            }

            assert.is_true(CoverCache:downloadMultiple(books, 6, onDone))
            assert.are.equal(1, #runs)
            assert.are.same({ "https://covers.example/new.jpg" }, runs[1].urls)
            assert.are.same({ covers_dir .. "new.jpg" }, runs[1].paths)
            assert.are.equal(6, runs[1].parallel_jobs)
            assert.is_false(runs[1].use_proxy)
            -- one that has stalled mustn't keep its placeholder showing, or the next page's covers waiting
            assert.are.equal(10, runs[1].stall_time)
            -- search results show placeholders, rather than a notification
            assert.are.equal(0, #helper.state.notifications)

            -- nothing happens until curl has finished
            helper.tick()
            assert.are.same({}, results)
            assert.is_false(CoverCache:cacheExists("new"))

            finishRun(runs[1], { true })
            helper.tick()
            assert.are.same({ 1 }, results)
            assert.are.equal(covers_dir .. "new.jpg", CoverCache:get("new"))
            -- so every open search result can show them
            assert.are.same({ "KindleFetchCoversDownloaded" }, helper.state.broadcasts)
        end)

        -- rather than once the slowest has, which curl can wait on for a while before giving up
        describe("as they arrive", function()
            local results_file, cache_file

            -- curl writes each cover's result as soon as it has downloaded
            local function arrive(...)
                local lines = {}
                for _, result in ipairs({ ... }) do
                    if result[2] == 0 then
                        helper.writeFile(covers_dir .. result[1] .. ".jpg", fixtures.JPEG)
                    end
                    table.insert(lines, result[2] .. " " .. covers_dir .. result[1] .. ".jpg")
                end
                helper.writeFile(results_file, table.concat(lines, "\n") .. "\n")
            end

            before_each(function()
                results_file = data_dir .. "/settings/curl_config.txt.results"
                cache_file = data_dir .. "/settings/kindlefetch_covercache.lua"
                CoverCache:downloadMultiple({
                    book("a", "https://covers.example/a.jpg"),
                    book("b", "https://covers.example/b.jpg"),
                    book("c", "https://covers.example/c.jpg"),
                }, 6, onDone)
            end)

            it("shows each cover while the others are still coming", function()
                arrive({ "a", 0 })
                helper.tick()
                assert.are.equal(covers_dir .. "a.jpg", CoverCache:get("a"))
                assert.is_true(CoverCache:isComing(book("b", "https://covers.example/b.jpg")))
                assert.are.same({ "KindleFetchCoversDownloaded" }, helper.state.broadcasts)
                assert.are.same({}, results)

                -- c stalls, and is given up on once curl has finished
                arrive({ "a", 0 }, { "b", 0 }, { "c", 28 })
                finishRun(runs[1], {}, 28)
                helper.runScheduled()
                assert.are.same({ 2 }, results)
                assert.is_true(CoverCache:cacheExists("b"))
                assert.is_false(CoverCache:isComing(book("c", "https://covers.example/c.jpg")))
                -- so its placeholder can be taken away
                assert.are.equal(2, #helper.state.broadcasts)
            end)

            -- each time, the screen is refreshed
            it("shows them at most once a second", function()
                arrive({ "a", 0 })
                helper.tick()
                arrive({ "a", 0 }, { "b", 0 })
                helper.tick()
                assert.are.equal(1, #helper.state.broadcasts)
                assert.is_false(CoverCache:cacheExists("b"))

                helper.tick()
                assert.are.equal(2, #helper.state.broadcasts)
                assert.is_true(CoverCache:cacheExists("b"))

                -- and not when nothing new has arrived
                helper.tick()
                helper.tick()
                assert.are.equal(2, #helper.state.broadcasts)
            end)

            it("writes the cache out once they've all finished", function()
                local function savedCovers()
                    local ids = {}
                    for id in pairs(helper.state.settings_files[cache_file] or {}) do
                        table.insert(ids, id)
                    end
                    table.sort(ids)
                    return ids
                end

                arrive({ "a", 0 }, { "b", 0 })
                helper.tick()
                assert.are.same({}, savedCovers())

                arrive({ "a", 0 }, { "b", 0 }, { "c", 0 })
                finishRun(runs[1], { true, true, true })
                helper.runScheduled()
                assert.are.same({ "a", "b", "c" }, savedCovers())
            end)

            it("only retries the covers that didn't arrive through PROXY_URL", function()
                helper.state.env.PROXY_URL = "http://proxy.example:8080"
                arrive({ "a", 0 })
                helper.tick()

                arrive({ "a", 0 }, { "b", 35 }, { "c", 35 })
                finishRun(runs[1], {}, 35)
                helper.tick()
                assert.are.equal(2, #runs)
                assert.are.same({ "https://covers.example/b.jpg", "https://covers.example/c.jpg" }, runs[2].urls)

                finishRun(runs[2], { true, true })
                helper.runScheduled()
                assert.are.same({ 3 }, results)
            end)
        end)

        -- the cache holds 500 covers
        it("removes the file of a cover pushed out of the cache by newer ones", function()
            local covers = {}
            for i = 1, 500 do
                covers["old" .. i] = {
                    timestamp = i,
                    value = covers_dir .. "old" .. i .. ".jpg",
                }
            end
            helper.state.settings_files[data_dir .. "/settings/kindlefetch_covercache.lua"] = covers
            helper.writeFile(covers_dir .. "old1.jpg", fixtures.JPEG)
            helper.writeFile(covers_dir .. "old2.jpg", fixtures.JPEG)

            CoverCache:downloadMultiple({ book("new", "https://covers.example/new.jpg") }, 6, onDone)
            finishRun(runs[1], { true })
            helper.runScheduled()

            assert.is_true(CoverCache:cacheExists("new"))
            assert.is_false(helper.exists(covers_dir .. "old1.jpg"))
            assert.is_true(helper.exists(covers_dir .. "old2.jpg"))
        end)

        -- older versions forgot covers once the cache was full, without removing their files
        it("removes covers left behind without being in the cache, once per session", function()
            fixtures.cacheCover(helper, "cached")
            helper.writeFile(covers_dir .. "orphan.jpg", fixtures.JPEG)
            helper.writeFile(covers_dir .. "orphan_full.jpg", fixtures.JPEG)
            helper.writeFile(covers_dir .. "notes.txt", "not a cover")

            CoverCache:downloadMultiple({ book("new", "https://covers.example/new.jpg") }, 6, onDone)
            assert.is_false(helper.exists(covers_dir .. "orphan.jpg"))
            assert.is_false(helper.exists(covers_dir .. "orphan_full.jpg"))
            assert.is_true(helper.exists(covers_dir .. "cached.jpg"))
            assert.is_true(helper.exists(covers_dir .. "notes.txt"))
            assert.is_truthy(helper.logged("info", "^removed 2 covers that were no longer in the cache$"))

            -- there are no more to find until the plugin is next updated, so it doesn't look again
            helper.writeFile(covers_dir .. "later.jpg", fixtures.JPEG)
            CoverCache:downloadMultiple({ book("another", "https://covers.example/another.jpg") }, 6, onDone)
            assert.is_true(helper.exists(covers_dir .. "later.jpg"))
        end)

        it("writes the cache out once for all the covers that downloaded", function()
            local flushes = 0
            local open = helper.stubs.luasettings.open
            helper.stubs.luasettings.open = function(...)
                local file = open(...)
                local flush = file.flush
                function file:flush()
                    flushes = flushes + 1
                    return flush(self)
                end
                return file
            end

            CoverCache:downloadMultiple({
                book("a", "https://covers.example/a.jpg"),
                book("b", "https://covers.example/b.jpg"),
                book("c", "https://covers.example/c.jpg"),
            }, 6, onDone)
            finishRun(runs[1], { true, true, true })
            helper.runScheduled()

            assert.are.same({ 3 }, results)
            assert.are.equal(1, flushes)
            assert.is_true(CoverCache:cacheExists("c"))
        end)

        describe("full-size", function()
            it("are downloaded from the thumbnail's address without _small, and kept apart from it", function()
                local b = book("abc", "https://libgen.example/fictioncovers/1000/abc_small.jpg")
                assert.is_nil(CoverCache:getFullSize(b))

                assert.is_true(CoverCache:downloadFullSize(b))
                assert.are.same({ "https://libgen.example/fictioncovers/1000/abc.jpg" }, runs[1].urls)
                assert.are.same({ covers_dir .. "abc_full.jpg" }, runs[1].paths)

                finishRun(runs[1], { true })
                helper.tick()
                assert.are.equal(covers_dir .. "abc_full.jpg", CoverCache:getFullSize(b))
                assert.is_nil(CoverCache:get("abc"))
                assert.is_false(CoverCache:downloadFullSize(b))
            end)

            it("aren't downloaded for covers that aren't thumbnails", function()
                assert.is_false(CoverCache:downloadFullSize(book("abc", "https://covers.example/abc.jpg")))
                assert.is_false(CoverCache:downloadFullSize(book("abc")))
                assert.are.equal(0, #runs)
                assert.is_nil(CoverCache:getFullSize(book("abc")))
            end)
        end)

        it("does not download covers that are already downloading", function()
            local books = { book("a", "https://covers.example/a.jpg") }
            CoverCache:downloadMultiple(books, 6, onDone)

            assert.is_false(CoverCache:downloadMultiple(books, 6, onDone))
            assert.are.equal(1, #runs)

            finishRun(runs[1], { false }, 22)
            helper.runScheduled()
            assert.is_true(CoverCache:downloadMultiple(books, 6, onDone))
        end)

        it("discards the covers when curl fails", function()
            CoverCache:downloadMultiple(
                { book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg") },
                6,
                onDone
            )
            finishRun(runs[1], { true, false }, 28)
            helper.runScheduled()

            assert.are.same({ 0 }, results)
            assert.is_false(helper.exists(covers_dir .. "a.jpg"))
            assert.is_false(CoverCache:cacheExists("a"))
            -- so the placeholders can be taken away
            assert.are.same({ "KindleFetchCoversDownloaded" }, helper.state.broadcasts)
        end)

        it("keeps the covers that downloaded when others fail", function()
            CoverCache:downloadMultiple(
                { book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg") },
                6,
                onDone
            )
            -- curl writes each cover's result next to its config file
            helper.writeFile(
                data_dir .. "/settings/curl_config.txt.results",
                "0 " .. covers_dir .. "a.jpg\n28 " .. covers_dir .. "b.jpg\n"
            )
            finishRun(runs[1], { true, true }, 28)
            helper.runScheduled()

            assert.are.same({ 1 }, results)
            assert.is_true(CoverCache:cacheExists("a"))
            assert.is_false(CoverCache:cacheExists("b"))
            assert.is_false(helper.exists(covers_dir .. "b.jpg"))
        end)

        -- curl can finish just after its exit code was checked, before checking whether it's running
        it("reads the exit code again once curl has stopped", function()
            CoverCache:downloadMultiple({ book("a", "https://covers.example/a.jpg") }, 6, onDone)
            CurlUtil.isPidRunning = function()
                finishRun(runs[1], { true })
                return false
            end
            helper.runScheduled()

            assert.are.same({ 1 }, results)
        end)

        it("stops when curl stops without reporting back", function()
            CurlUtil.isPidRunning = function()
                return false
            end
            CoverCache:downloadMultiple({ book("a", "https://covers.example/a.jpg") }, 6, onDone)
            helper.runScheduled()

            assert.are.same({ 0 }, results)
        end)

        -- which KOReader would have exited on, rather than taking the placeholders away
        it("gives up on the covers when checking on them goes wrong", function()
            CoverCache:downloadMultiple({ book("a", "https://covers.example/a.jpg") }, 6, onDone)
            CurlUtil.getExitCode = function()
                error("unexpected")
            end
            helper.runScheduled()

            assert.are.same({ 0 }, results)
            assert.is_false(CoverCache:isComing(book("a", "https://covers.example/a.jpg")))
            assert.are.same({ "KindleFetchCoversDownloaded" }, helper.state.broadcasts)
            assert.is_truthy(helper.logged("err", "^checking on covers' downloads went wrong:.*unexpected"))
            -- placeholders are all that would say so
            assert.is_nil(helper.lastError())
        end)

        it("reports nothing downloaded when curl cannot be started", function()
            CurlUtil.downloadMultiple = function()
                return nil, nil, nil, "unable to launch curl"
            end

            assert.is_true(CoverCache:downloadMultiple({ book("a", "https://covers.example/a.jpg") }, 6, onDone))
            assert.are.same({ 0 }, results)
        end)

        it("retries the covers that failed through PROXY_URL", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            local books = { book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg") }
            CoverCache:downloadMultiple(books, 6, onDone)

            finishRun(runs[1], { false, false }, 35)
            helper.tick()
            assert.are.equal(2, #runs)
            assert.is_true(runs[2].use_proxy)
            assert.are.same({ "https://covers.example/a.jpg", "https://covers.example/b.jpg" }, runs[2].urls)

            finishRun(runs[2], { true, true })
            helper.tick()
            assert.are.same({ 2 }, results)
            assert.is_true(CoverCache:cacheExists("b"))
            -- as for searches and books, which are retried through the proxy in crash.log too
            assert.is_truthy(helper.logged("info", "^retrying 2 cover downloads through the proxy"))
        end)

        it("does not retry covers without PROXY_URL", function()
            helper.state.env.PROXY_URL = false
            CoverCache:downloadMultiple({ book("a", "https://covers.example/a.jpg") }, 6, onDone)

            finishRun(runs[1], { false }, 35)
            helper.runScheduled()
            assert.are.equal(1, #runs)
            assert.are.same({ 0 }, results)
        end)

        it("does nothing when every cover is cached", function()
            assert.is_false(CoverCache:downloadMultiple({ book("no-image") }, 6, onDone))
            assert.are.equal(0, #runs)
            assert.are.equal(0, #helper.state.notifications)
        end)
    end)
end)
