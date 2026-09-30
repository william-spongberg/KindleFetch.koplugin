local helper = require("helper")
local fixtures = require("fixtures")

-- mirrors are scraped from the live Wikipedia page, so these need internet access
describe("LlgiAPI", function()
    local MB = 1024 * 1024
    local data_dir, filepath, book, web, mirrors, prompts, spawned, running, killed, results, remote_size
    local CurlUtil, UrlApi, LlgiAPI

    local function adsUrl(mirror)
        return mirror .. "/ads.php?md5=" .. book.md5
    end

    local function getUrl(mirror)
        return mirror .. "/get.php?md5=" .. book.md5 .. "&key=ABC123"
    end

    local function hasBook(mirror)
        web.pages[adsUrl(mirror)] = fixtures.libgenAds(book.md5)
    end

    local saved_filepath

    local function onResult(ok, err, filepath)
        table.insert(results, {
            ok = ok,
            err = err
        })
        saved_filepath = filepath
    end

    -- ask to download the book, then confirm the download prompt
    local function download()
        local shown = #prompts
        LlgiAPI:downloadBook(book, filepath, onResult)
        if #prompts > shown then
            prompts[#prompts].on_download(prompts[#prompts].filepath)
        end
    end

    local function progress()
        return LlgiAPI.active_downloads[book.md5].progress_widget
    end

    -- simulate curl writing the book and exiting
    local function curlWrote(bytes, exit_code)
        helper.writeFile(filepath, string.rep("x", bytes))
        if exit_code then
            helper.writeFile(spawned[#spawned].exit_file, tostring(exit_code))
        end
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        filepath = data_dir .. "/Dune.epub"
        book = {
            md5 = fixtures.DUNE.md5,
            title = "Dune",
            display_title = "Dune",
            image_url = fixtures.DUNE.image_url,
            file_type = "epub"
        }

        prompts, spawned, running, killed, results = {}, {}, {}, {}, {}
        remote_size = MB
        web = fixtures.fakeWeb(helper)

        CurlUtil = require("util.curlutil")
        CurlUtil.download = function(url, path, use_proxy, background)
            if not background then -- book cover
                helper.writeFile(path, "jpeg")
                return true
            end
            local exit_file = CurlUtil.createExitFile()
            table.insert(spawned, {
                url = url,
                path = path,
                use_proxy = use_proxy,
                pid = 1000 + #spawned,
                exit_file = exit_file
            })
            return spawned[#spawned].pid, exit_file
        end
        CurlUtil.getRemoteFileSize = function()
            return remote_size
        end
        CurlUtil.isPidRunning = function(pid)
            return running[pid] ~= false
        end
        CurlUtil.killPid = function(pid)
            table.insert(killed, pid)
        end

        helper.stub("ui.downloadprompt", {
            new = function(prompt_book, prompt_filepath, on_download)
                return {
                    book = prompt_book,
                    filepath = prompt_filepath,
                    on_download = on_download,
                    show = function(self)
                        table.insert(prompts, self)
                    end
                }
            end
        })

        UrlApi = require("api.urlapi")
        LlgiAPI = require("api.lgliapi")
        LlgiAPI.active_downloads = {}

        mirrors = fixtures.scrapeMirrors(web, function(api)
            return api:getLibgenUrls()
        end, "Library Genesis")
        hasBook(mirrors[1])
    end)

    after_each(helper.cleanup)

    describe("downloadBook", function()
        it("gets the book cover, then asks where to save the book", function()
            LlgiAPI:downloadBook(book, filepath, onResult)

            assert.is_true(require("cache.covercache"):cacheExists(book.md5))
            assert.are.equal(1, #prompts)
            assert.are.equal(filepath, prompts[1].filepath)
            assert.are.equal(0, #spawned)
        end)

        it("does not download covers it already has", function()
            fixtures.cacheCover(helper, book.md5)
            CurlUtil.download = function()
                error("should not download")
            end

            LlgiAPI:downloadBook(book, filepath, onResult)
            assert.are.equal(1, #prompts)
        end)

        it("still offers the download when the book has no cover", function()
            book.image_url = nil
            LlgiAPI:downloadBook(book, filepath, onResult)

            assert.is_false(require("cache.covercache"):cacheExists(book.md5))
            assert.are.equal(1, #prompts)
        end)

        it("still offers the download when the cover cannot be fetched", function()
            local download = CurlUtil.download
            CurlUtil.download = function(url, path, use_proxy, background)
                if not background then
                    return false, "HTTP error response"
                end
                return download(url, path, use_proxy, background)
            end

            LlgiAPI:downloadBook(book, filepath, onResult)
            assert.are.equal(1, #prompts)
        end)

        it("downloads to the folder chosen in the prompt", function()
            LlgiAPI:downloadBook(book, filepath, onResult)
            prompts[1].on_download(data_dir .. "/Books/Dune.epub")

            assert.are.equal(data_dir .. "/Books/Dune.epub", spawned[1].path)
        end)

        it("says where the book was saved", function()
            LlgiAPI:downloadBook(book, filepath, onResult)
            filepath = data_dir .. "/Books/Dune.epub"
            prompts[1].on_download(filepath)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({{ok = true}}, results)
            assert.are.equal(data_dir .. "/Books/Dune.epub", saved_filepath)
        end)

        it("shows the progress again when a book that is already downloading is chosen", function()
            download()
            local widget = progress()
            widget.hide_button.callback()
            assert.is_false(widget.is_visible)

            download()
            assert.is_true(widget.is_visible)
            assert.are.equal(widget.container, helper.lastShown())
            assert.are.equal(1, #spawned)
            assert.are.same({}, results)
        end)

        it("leaves visible progress alone when a book that is already downloading is chosen", function()
            download()
            local shown = #helper.state.shown

            download()
            assert.is_true(progress().is_visible)
            assert.are.equal(shown, #helper.state.shown)
            assert.are.equal(1, #spawned)
        end)
    end)

    describe("downloading", function()
        it("downloads the book through the link on the mirror's ads page", function()
            download()

            assert.are.same({
                url = getUrl(mirrors[1]),
                path = filepath,
                use_proxy = false,
                pid = 1000,
                exit_file = spawned[1].exit_file
            }, spawned[1])
        end)

        it("shows the download progress", function()
            download()
            local widget = progress()
            assert.are.same(widget.container, helper.lastShown())

            curlWrote(MB / 2)
            helper.tick()
            assert.are.equal(0.5, widget.bar_widget.percentage)
            assert.are.equal("50% · 0.5 / 1.0 MB", widget.status_widget.text)
        end)

        it("stays below 100% until curl has finished", function()
            download()
            local widget = progress()

            curlWrote(2 * MB)
            helper.tick()
            assert.are.equal(0.99, widget.bar_widget.percentage)
        end)

        it("finishes once curl exits successfully", function()
            download()
            local widget = progress()

            curlWrote(MB, 0)
            helper.runScheduled()

            assert.are.same({{ok = true}}, results)
            assert.are.equal(1, widget.bar_widget.percentage)
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, LlgiAPI:getActiveDownloads())
            assert.are.equal(MB, #helper.readFile(filepath))
        end)

        it("works without knowing the file size", function()
            remote_size = nil
            download()

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({{ok = true}}, results)
        end)

        it("tries the next mirror and forgets ones that fail", function()
            web.pages[adsUrl(mirrors[1])] = nil
            hasBook(mirrors[2])

            download()
            assert.are.equal(getUrl(mirrors[2]), spawned[1].url)

            local remaining = {}
            for i = 2, #mirrors do
                table.insert(remaining, mirrors[i])
            end
            assert.are.same(remaining, UrlApi:getLibgenUrls())
        end)

        it("keeps mirrors that just do not have the book", function()
            web.pages[adsUrl(mirrors[1])] = "<html>Not found</html>"
            hasBook(mirrors[2])

            download()
            assert.are.equal(getUrl(mirrors[2]), spawned[1].url)
            assert.are.same(mirrors, UrlApi:getLibgenUrls())
        end)

        it("scrapes the mirrors again when every mirror fails", function()
            -- every mirror is down until they have been scraped again
            web.pages[adsUrl(mirrors[1])] = function()
                if web.scrapes > 1 then
                    return fixtures.libgenAds(book.md5)
                end
            end

            download()
            assert.are.equal(2, web.scrapes)
            assert.are.equal(1, #spawned)
            assert.are.same({}, results)
            assert.are.equal(1, #LlgiAPI:getActiveDownloads())

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({{ok = true}}, results)
        end)

        it("fails when no mirror has the book", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[adsUrl(mirror)] = "<html>Not found</html>"
            end

            download()
            assert.are.same({{ok = false, err = "no Library Genesis download link found"}}, results)
            assert.are.same({}, LlgiAPI:getActiveDownloads())
        end)

        it("fails when the mirrors cannot be scraped", function()
            web.wikipedia_down = true

            download()
            assert.are.same({{ok = false, err = "no Library Genesis urls available"}}, results)
            assert.is_true(helper.wasClosed(helper.lastShown()))
        end)

        it("fails when curl cannot be started", function()
            CurlUtil.download = function(_, _, _, background)
                if background then
                    return nil, nil, "unable to launch curl"
                end
                return true
            end

            download()
            assert.are.same({{ok = false, err = "unable to launch curl"}}, results)
            assert.are.same({}, LlgiAPI:getActiveDownloads())
        end)

        it("fails and removes the partial file when curl fails", function()
            download()

            curlWrote(MB / 2, 22)
            helper.runScheduled()
            assert.are.same({{ok = false, err = "HTTP error response"}}, results)
            assert.is_false(helper.exists(filepath))
        end)

        it("fails when the downloaded file is empty", function()
            download()

            curlWrote(0, 0)
            helper.runScheduled()
            assert.are.same({{ok = false, err = "download produced empty file"}}, results)
        end)

        -- curl can finish just after its exit code was checked, before checking whether it's running
        it("finishes when curl exits between checks", function()
            download()
            CurlUtil.isPidRunning = function()
                curlWrote(MB, 0)
                return false
            end
            helper.runScheduled()

            assert.are.same({{ok = true}}, results)
        end)

        it("fails when curl stops without reporting back", function()
            download()

            running[spawned[1].pid] = false
            helper.runScheduled()
            assert.are.same({{ok = false, err = "download process ended unexpectedly"}}, results)
        end)

        it("retries through PROXY_URL when the download fails", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            download()

            curlWrote(0, 7)
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].use_proxy)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({{ok = true}}, results)
        end)

        it("fails when the proxy retry fails too", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            download()

            curlWrote(0, 7)
            helper.tick()
            curlWrote(0, 7)
            helper.runScheduled()
            assert.are.same({{ok = false, err = "failed to connect to server"}}, results)
            assert.are.equal(2, #spawned)
        end)

        it("fails when the proxy retry cannot be started", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            download()
            CurlUtil.download = function()
                return nil, nil, "unable to launch curl"
            end

            curlWrote(0, 7)
            helper.runScheduled()
            assert.are.same({{ok = false, err = "unable to launch curl"}}, results)
        end)

        it("can be cancelled from the progress widget", function()
            download()
            curlWrote(MB / 2)

            progress().cancel_button.callback()
            helper.runScheduled()

            assert.are.same({spawned[1].pid, spawned[1].pid}, killed)
            assert.are.same({{ok = false, err = "cancelled"}}, results)
            assert.is_false(helper.exists(filepath))
        end)
    end)

    describe("active downloads", function()
        it("lists downloads in progress", function()
            download()

            local downloads = LlgiAPI:getActiveDownloads()
            assert.are.equal(1, #downloads)
            assert.are.equal(book.md5, downloads[1].id)
            assert.are.equal("Dune", downloads[1].title)
            assert.are.equal(filepath, downloads[1].filepath)
            assert.are.equal(progress(), downloads[1].widget)
        end)

        it("can all be cancelled at once", function()
            download()
            local widget = progress()
            curlWrote(MB / 2)

            LlgiAPI:cancelAllDownloads()
            assert.is_true(widget.cancelled)
            assert.are.same({spawned[1].pid}, killed)
            assert.is_true(helper.wasClosed(widget.container))
            assert.is_false(helper.exists(filepath))
            assert.are.same({}, LlgiAPI:getActiveDownloads())

            helper.runScheduled()
            assert.are.same({{ok = false, err = "cancelled"}}, results)
        end)
    end)
end)
