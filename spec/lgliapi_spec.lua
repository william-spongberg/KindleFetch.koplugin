local helper = require("helper")
local fixtures = require("fixtures")

-- mirrors are scraped from the live Wikipedia page, so these need internet access
describe("LlgiAPI", function()
    local MB = 1024 * 1024
    local data_dir, filepath, book, web, mirrors, prompts, spawned, running, killed, results, remote_size
    local cover_downloads
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

    local saved_filepath, opened_existing

    local function onResult(ok, err, path)
        table.insert(results, {
            ok = ok,
            err = err,
        })
        saved_filepath = path
    end

    local function onOpenExisting(path)
        opened_existing = path
    end

    -- ask to download the book, then confirm the download prompt
    local function download()
        local shown = #prompts
        LlgiAPI:downloadBook(book, filepath, onResult, onOpenExisting)
        if #prompts > shown then
            prompts[#prompts].on_download(prompts[#prompts].filepath)
        end
    end

    local function progress()
        return LlgiAPI.active_downloads[book.md5].progress_widget
    end

    -- simulate curl noting down the headers it was sent, then writing the book and exiting
    local function curlWrote(bytes, exit_code)
        if remote_size then
            helper.writeFile(
                spawned[#spawned].headers_file,
                "HTTP/2 200\r\ncontent-type: application/epub+zip\r\ncontent-length: " .. remote_size .. "\r\n\r\n"
            )
        end
        helper.writeFile(spawned[#spawned].path, string.rep("x", bytes))
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
            file_type = "epub",
        }

        prompts, spawned, running, killed, results = {}, {}, {}, {}, {}
        opened_existing = nil
        remote_size = MB
        web = fixtures.fakeWeb(helper)

        CurlUtil = require("util.curlutil")
        CurlUtil.download = function(url, path, use_proxy, background, _, opts)
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
                exit_file = exit_file,
                headers_file = opts.headers_file,
                stall_time = opts.stall_time,
            })
            return spawned[#spawned].pid, exit_file
        end
        -- book covers, which download in the background (and fail here)
        cover_downloads = {}
        CurlUtil.downloadMultiple = function(urls)
            table.insert(cover_downloads, urls)
            return nil, nil, nil, "unable to launch curl"
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
                    end,
                }
            end,
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
        it("asks where to save the book, getting its cover in the background", function()
            LlgiAPI:downloadBook(book, filepath, onResult)

            assert.are.equal(1, #prompts)
            assert.are.equal(filepath, prompts[1].filepath)
            assert.are.same({ { book.image_url } }, cover_downloads)
            assert.are.equal(0, #spawned)
        end)

        it("does not download covers it already has", function()
            fixtures.cacheCover(helper, book.md5)
            CurlUtil.downloadMultiple = function()
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
            LlgiAPI:downloadBook(book, filepath, onResult)
            helper.runScheduled()

            assert.are.equal(1, #prompts)
            assert.is_false(require("cache.covercache"):cacheExists(book.md5))
        end)

        it("downloads to the folder chosen in the prompt", function()
            LlgiAPI:downloadBook(book, filepath, onResult)
            prompts[1].on_download(data_dir .. "/Books/Dune.epub")

            assert.are.equal(data_dir .. "/Books/Dune.epub.part", spawned[1].path)
        end)

        it("says where the book was saved", function()
            LlgiAPI:downloadBook(book, filepath, onResult)
            filepath = data_dir .. "/Books/Dune.epub"
            prompts[1].on_download(filepath)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(data_dir .. "/Books/Dune.epub", saved_filepath)
        end)

        describe("when the book is already there", function()
            local confirm

            before_each(function()
                helper.writeFile(filepath, "another edition of Dune")
                download()
                confirm = helper.lastShown()
            end)

            -- rather than downloading over what may be another edition with the same title
            it("asks before downloading over it", function()
                assert.are.equal(filepath .. " already exists.", confirm.text)
                assert.are.equal("Overwrite", confirm.ok_text)
                assert.are.equal(0, #spawned)
                assert.are.equal("another edition of Dune", helper.readFile(filepath))
            end)

            it("downloads over it once told to", function()
                confirm.ok_callback()
                assert.are.equal(1, #spawned)

                -- keeping it until the new one has all arrived
                curlWrote(MB / 2)
                helper.tick()
                assert.are.equal("another edition of Dune", helper.readFile(filepath))

                curlWrote(MB, 0)
                helper.runScheduled()
                assert.are.same({ { ok = true } }, results)
                assert.are.equal(MB, #helper.readFile(filepath))
            end)

            it("keeps it when downloading over it fails", function()
                confirm.ok_callback()
                curlWrote(MB / 2, 28)
                helper.runScheduled()

                assert.are.same({ { ok = false, err = "request timed out" } }, results)
                assert.are.equal("another edition of Dune", helper.readFile(filepath))
            end)

            it("can open it instead", function()
                local read_existing = confirm.other_buttons[1][1]
                assert.are.equal("Read existing book", read_existing.text)

                read_existing.callback()
                assert.are.equal(filepath, opened_existing)
                assert.are.equal(0, #spawned)
                assert.are.same({}, results)
            end)

            it("only offers to open it when it can be", function()
                LlgiAPI:downloadBook(book, filepath, onResult)
                prompts[#prompts].on_download(filepath)

                assert.are.equal("Overwrite", helper.lastShown().ok_text)
                assert.is_nil(helper.lastShown().other_buttons)
            end)

            it("doesn't ask when another folder is chosen in the prompt", function()
                LlgiAPI:downloadBook(book, filepath, onResult, onOpenExisting)
                prompts[#prompts].on_download(data_dir .. "/Books/Dune.epub")

                assert.is_nil(helper.lastShown().ok_text)
                assert.are.equal(data_dir .. "/Books/Dune.epub.part", spawned[1].path)
            end)
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
                path = filepath .. ".part",
                use_proxy = false,
                pid = 1000,
                exit_file = spawned[1].exit_file,
                headers_file = spawned[1].headers_file,
                -- rather than waiting forever on a download that has stalled
                stall_time = 30,
            }, spawned[1])
            assert.is_string(spawned[1].headers_file)
        end)

        -- so that half a book is never left looking like a whole one
        it("downloads next to where the book is wanted, moving it there once it has all arrived", function()
            download()
            curlWrote(MB / 2)
            helper.tick()
            assert.is_false(helper.exists(filepath))
            assert.is_true(helper.exists(filepath .. ".part"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.equal(MB, #helper.readFile(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
        end)

        it("fails when the book can't be moved to where it's wanted", function()
            download()
            -- something else is in the way
            helper.run("mkdir -p " .. helper.quote(filepath .. "/folder"))
            curlWrote(MB, 0)
            helper.runScheduled()

            assert.are.same({ { ok = false, err = "could not save the book" } }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_truthy(helper.logged("warn", "^could not move the downloaded book from"))
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

        -- rather than asking for it before downloading, and waiting for the answer
        it("works out the book's size from the headers curl notes down as the book starts to arrive", function()
            download()
            local widget = progress()

            helper.tick()
            assert.are.equal("Starting download...", widget.status_widget.text)

            helper.writeFile(
                spawned[1].headers_file,
                "HTTP/1.1 302 Found\r\nLocation: https://cdn.example/dune\r\nContent-Length: 0\r\n\r\n"
                    .. "HTTP/2 200\r\ncontent-length: "
                    .. 2 * MB
                    .. "\r\n\r\n"
            )
            helper.writeFile(spawned[1].path, string.rep("x", MB / 2))
            helper.tick()
            assert.are.equal("25% · 0.5 / 2.0 MB", widget.status_widget.text)
            assert.is_truthy(helper.logged("info", "^the file is " .. 2 * MB .. " bytes$"))
        end)

        it("removes the headers curl noted down once the download is over", function()
            download()
            curlWrote(MB, 0)
            assert.is_true(helper.exists(spawned[1].headers_file))

            helper.runScheduled()
            assert.is_false(helper.exists(spawned[1].headers_file))
        end)

        it("stays below 100% until curl has finished", function()
            remote_size = 2 * MB
            download()
            local widget = progress()

            curlWrote(2 * MB)
            helper.tick()
            assert.are.equal(0.99, widget.bar_widget.percentage)
        end)

        it("shows how much has downloaded when the file is bigger than its size said", function()
            remote_size = 638
            download()
            local widget = progress()

            curlWrote(2 * MB)
            helper.tick()
            assert.are.equal("2.0 MB", widget.status_widget.text)
        end)

        it("shows how much has downloaded when the size is unknown", function()
            remote_size = nil
            download()
            local widget = progress()

            curlWrote(MB / 2)
            helper.tick()
            assert.are.equal("0.5 MB", widget.status_widget.text)
        end)

        it("finishes once curl exits successfully", function()
            download()
            local widget = progress()

            curlWrote(MB, 0)
            helper.runScheduled()

            assert.are.same({ { ok = true } }, results)
            assert.are.equal(1, widget.bar_widget.percentage)
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, LlgiAPI:getActiveDownloads())
            assert.are.equal(MB, #helper.readFile(filepath))
            -- for reading crash.log from a device
            assert.is_truthy(helper.logged("info", '^downloading "Dune" %(epub, .-, md5 %x+%) to '))
            assert.is_truthy(helper.logged("info", '^downloaded "Dune": ' .. MB .. " bytes in %d+s$"))
        end)

        it("works without knowing the file size", function()
            remote_size = nil
            download()

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
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
            assert.are.same({ { ok = true } }, results)
        end)

        it("fails when no mirror has the book", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[adsUrl(mirror)] = "<html>Not found</html>"
            end

            download()
            assert.are.same({ { ok = false, err = "no Library Genesis download link found" } }, results)
            assert.are.same({}, LlgiAPI:getActiveDownloads())
            -- the mirrors answered, so they aren't looked up again
            assert.are.equal(1, web.scrapes)
        end)

        -- as every mirror did at once while this was written, their shared database refusing connections
        it("says when Library Genesis is too busy to send the book", function()
            local busy_page = "<html><body>Could not connect to the database 3306. User 'libgen_get' has exceeded the "
                .. "'max_user_connections' resource (current value: 80) <a href=''>Report an error</a>.</body></html>"
            for _, mirror in ipairs(mirrors) do
                web.pages[adsUrl(mirror)] = busy_page
            end

            download()
            assert.are.same({
                {
                    ok = false,
                    err = "Library Genesis is too busy to send books right now, try again in a few minutes",
                },
            }, results)
            -- the mirrors themselves are fine
            assert.are.same(mirrors, UrlApi:getLibgenUrls())
            assert.are.equal(1, web.scrapes)
        end)

        it("downloads from a mirror that isn't too busy", function()
            web.pages[adsUrl(mirrors[1])] = "<html>Could not connect to the database 3306.</html>"
            hasBook(mirrors[2])

            download()
            assert.are.equal(getUrl(mirrors[2]), spawned[1].url)
        end)

        it("says there's no internet connection when neither the mirrors nor Wikipedia answer", function()
            web.wikipedia_down = true

            download()
            assert.are.same({ { ok = false, err = "no internet connection" } }, results)
            assert.is_true(helper.wasClosed(helper.lastShown()))
        end)

        -- rather than forgetting every mirror while offline
        it("keeps the mirrors when nothing answers", function()
            UrlApi:getLibgenUrls()
            for _, mirror in ipairs(mirrors) do
                web.pages[adsUrl(mirror)] = nil
            end
            web.wikipedia_down = true

            download()
            assert.are.same({ { ok = false, err = "no internet connection" } }, results)
            assert.are.same(mirrors, UrlApi:getLibgenUrls())
        end)

        it("turns on wifi first when offline, then downloads once connected", function()
            hasBook(mirrors[1])
            helper.stubs.network.connected = false

            download()
            assert.are.equal("turn wifi on", helper.stubs.network.prompted)
            assert.are.same({}, spawned)

            helper.stubs.network.connected = true
            helper.stubs.network.when_connected()
            assert.are.equal(getUrl(mirrors[1]), spawned[1].url)
        end)

        it("fails when curl cannot be started", function()
            CurlUtil.download = function(_, _, _, background)
                if background then
                    return nil, nil, "unable to launch curl"
                end
                return true
            end

            download()
            assert.are.same({ { ok = false, err = "unable to launch curl" } }, results)
            assert.are.same({}, LlgiAPI:getActiveDownloads())
        end)

        it("fails and removes the partial file when curl fails", function()
            download()

            curlWrote(MB / 2, 22)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "HTTP error response" } }, results)
            assert.is_false(helper.exists(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
            -- with what's needed to work out why from crash.log
            assert.matches(
                'download of "Dune" from [%w%.]+ failed after %d+s: curl exit code 22 %(HTTP error '
                    .. "response%), "
                    .. MB / 2
                    .. " of %d+ bytes",
                helper.logged("warn", "failed after")
            )
        end)

        it("fails when the downloaded file is empty", function()
            download()

            curlWrote(0, 0)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "download produced empty file" } }, results)
        end)

        -- curl can finish just after its exit code was checked, before checking whether it's running
        it("finishes when curl exits between checks", function()
            download()
            CurlUtil.isPidRunning = function()
                curlWrote(MB, 0)
                return false
            end
            helper.runScheduled()

            assert.are.same({ { ok = true } }, results)
        end)

        it("fails when curl stops without reporting back", function()
            download()

            running[spawned[1].pid] = false
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "download process ended unexpectedly" } }, results)
        end)

        it("retries through PROXY_URL when the download fails", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            download()

            curlWrote(0, 7)
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].use_proxy)
            assert.are.equal(filepath .. ".part", spawned[2].path)
            assert.are.equal(30, spawned[2].stall_time)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        it("fails when the proxy retry fails too", function()
            helper.state.env.PROXY_URL = "http://proxy.example:8080"
            download()

            curlWrote(0, 7)
            helper.tick()
            curlWrote(0, 7)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "failed to connect to server" } }, results)
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
            assert.are.same({ { ok = false, err = "unable to launch curl" } }, results)
        end)

        it("can be cancelled from the progress widget", function()
            download()
            curlWrote(MB / 2)

            progress().cancel_button.callback()
            helper.runScheduled()

            assert.are.same({ spawned[1].pid, spawned[1].pid }, killed)
            assert.are.same({ { ok = false, err = "cancelled" } }, results)
            assert.is_false(helper.exists(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
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
            assert.are.same({ spawned[1].pid }, killed)
            assert.is_true(helper.wasClosed(widget.container))
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_false(helper.exists(spawned[1].headers_file))
            assert.are.same({}, LlgiAPI:getActiveDownloads())

            helper.runScheduled()
            assert.are.same({ { ok = false, err = "cancelled" } }, results)
        end)
    end)
end)
