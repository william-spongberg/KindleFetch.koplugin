local helper = require("helper")

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
            CurlUtil.download = function(url, path)
                assert.are.equal("https://covers.example/abc.jpg", url)
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
        it("downloads only covers that are missing, in parallel", function()
            local requested
            CurlUtil.downloadMultiple = function(urls, paths, _, _, parallel_jobs)
                requested = {
                    urls = urls,
                    paths = paths,
                    parallel_jobs = parallel_jobs
                }
                for _, path in ipairs(paths) do
                    helper.writeFile(path, "jpeg")
                end
                return #paths
            end
            CurlUtil.download = function(_, path)
                helper.writeFile(path, "jpeg")
                return true
            end
            CoverCache:download("cached", "https://covers.example/cached.jpg")

            local books = {book("cached", "https://covers.example/cached.jpg"), book("new", "https://covers.example/new.jpg"),
                           book("no-image"), {title = "no md5", image_url = "https://covers.example/x.jpg"}}
            assert.are.equal(1, CoverCache:downloadMultiple(books, 6))

            assert.are.same({
                urls = {"https://covers.example/new.jpg"},
                paths = {covers_dir .. "new.jpg"},
                parallel_jobs = 6
            }, requested)
            assert.are.equal(covers_dir .. "new.jpg", CoverCache:get("new"))
            assert.are.equal("Getting book covers...", helper.lastNotification())
        end)

        it("retries the covers that failed through PROXY_URL", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            local attempts = {}
            CurlUtil.downloadMultiple = function(urls, paths, use_proxy)
                table.insert(attempts, {
                    urls = urls,
                    use_proxy = use_proxy
                })
                -- only the first cover gets through directly
                for i, path in ipairs(paths) do
                    if use_proxy or i == 1 then
                        helper.writeFile(path, "jpeg")
                    end
                end
                return use_proxy and #paths or 1
            end

            local books = {book("a", "https://covers.example/a.jpg"), book("b", "https://covers.example/b.jpg"),
                           book("c", "https://covers.example/c.jpg")}
            assert.are.equal(3, CoverCache:downloadMultiple(books, 6))
            assert.are.same({{
                urls = {"https://covers.example/a.jpg", "https://covers.example/b.jpg", "https://covers.example/c.jpg"},
                use_proxy = false
            }, {
                urls = {"https://covers.example/b.jpg", "https://covers.example/c.jpg"},
                use_proxy = true
            }}, attempts)
            assert.is_true(CoverCache:cacheExists("c"))
        end)

        it("does not retry covers without PROXY_URL", function()
            helper.state.env.PROXY_URL = false
            local attempts = 0
            CurlUtil.downloadMultiple = function()
                attempts = attempts + 1
                return 0
            end

            assert.are.equal(0, CoverCache:downloadMultiple({book("a", "https://covers.example/a.jpg")}, 6))
            assert.are.equal(1, attempts)
        end)

        it("does nothing when every cover is cached", function()
            CurlUtil.downloadMultiple = function()
                error("should not download")
            end

            assert.are.equal(0, CoverCache:downloadMultiple({book("no-image")}, 6))
            assert.are.equal(0, #helper.state.notifications)
        end)
    end)
end)
