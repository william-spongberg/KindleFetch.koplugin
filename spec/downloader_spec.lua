local helper = require("helper")
local fixtures = require("fixtures")

-- mirrors are scraped from the live Wikipedia page, so these need internet access
describe("Downloader", function()
    local MB = 1024 * 1024
    local data_dir, filepath, book, web, mirrors, prompts, spawned, running, killed, results, remote_size
    local cover_downloads
    local CurlUtil, UrlApi, Downloader

    local function adsUrl(mirror)
        return mirror .. "/ads.php?md5=" .. book.id
    end

    local function getUrl(mirror)
        return mirror .. "/get.php?md5=" .. book.id .. "&key=ABC123"
    end

    local function hasBook(mirror)
        web.pages[adsUrl(mirror)] = fixtures.libgenAds(book.id)
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
        Downloader:downloadBook(book, filepath, onResult, onOpenExisting)
        if #prompts > shown then
            prompts[#prompts].on_download(prompts[#prompts].filepath)
        end
    end

    local function progress()
        return Downloader.active_downloads[book.id].progress_widget
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
            source = "libgen",
            id = fixtures.DUNE.md5,
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
        CurlUtil.startDownload = function(url, path, use_proxy, _, opts)
            local exit_file = CurlUtil.createExitFile()
            table.insert(spawned, {
                url = url,
                path = path,
                use_proxy = use_proxy,
                pid = 1000 + #spawned,
                exit_file = exit_file,
                headers_file = opts.headers_file,
                stall_time = opts.stall_time,
                resume = opts.resume,
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
        Downloader = require("api.downloader")
        Downloader.active_downloads = {}

        mirrors = fixtures.scrapeMirrors(web, function(api)
            return api:getLibgenUrls()
        end, "Library Genesis")
        hasBook(mirrors[1])
    end)

    after_each(helper.cleanup)

    describe("downloadBook", function()
        it("asks where to save the book, getting its cover in the background", function()
            Downloader:downloadBook(book, filepath, onResult)

            assert.are.equal(1, #prompts)
            assert.are.equal(filepath, prompts[1].filepath)
            assert.are.same({ { book.image_url } }, cover_downloads)
            assert.are.equal(0, #spawned)
        end)

        it("does not download covers it already has", function()
            fixtures.cacheCover(helper, book.id)
            CurlUtil.downloadMultiple = function()
                error("should not download")
            end

            Downloader:downloadBook(book, filepath, onResult)
            assert.are.equal(1, #prompts)
        end)

        it("still offers the download when the book has no cover", function()
            book.image_url = nil
            Downloader:downloadBook(book, filepath, onResult)

            assert.is_false(require("cache.covercache"):cacheExists(book.id))
            assert.are.equal(1, #prompts)
        end)

        it("still offers the download when the cover cannot be fetched", function()
            Downloader:downloadBook(book, filepath, onResult)
            helper.runScheduled()

            assert.are.equal(1, #prompts)
            assert.is_false(require("cache.covercache"):cacheExists(book.id))
        end)

        it("downloads to the folder chosen in the prompt", function()
            Downloader:downloadBook(book, filepath, onResult)
            prompts[1].on_download(data_dir .. "/Books/Dune.epub")

            assert.are.equal(data_dir .. "/Books/Dune.epub.part", spawned[1].path)
        end)

        it("says where the book was saved", function()
            Downloader:downloadBook(book, filepath, onResult)
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
                Downloader:downloadBook(book, filepath, onResult)
                prompts[#prompts].on_download(filepath)

                assert.are.equal("Overwrite", helper.lastShown().ok_text)
                assert.is_nil(helper.lastShown().other_buttons)
            end)

            it("doesn't ask when another folder is chosen in the prompt", function()
                Downloader:downloadBook(book, filepath, onResult, onOpenExisting)
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
                -- and when curl tries it again, carrying on from where it stopped rather than from the beginning
                resume = true,
            }, spawned[1])
            assert.is_string(spawned[1].headers_file)
        end)

        -- which can mean trying several mirrors, each taking a while to answer
        describe("while looking up the download link", function()
            local HttpUtil, Trapper, getBody

            before_each(function()
                HttpUtil = require("util.httputil")
                Trapper = require("ui/trapper")
                getBody = HttpUtil.getBody
            end)

            it("doesn't hold KOReader up, letting the progress's Cancel call it off", function()
                local waits = {}
                HttpUtil.getBody = function(url)
                    table.insert(waits, { wrapped = Trapper:isWrapped(), trap_widget = HttpUtil.getTrapWidget() })
                    return getBody(url)
                end

                download()
                -- Wikipedia's list of mirrors, then the mirror's download page
                assert.are.equal(2, #waits)
                for _, wait in ipairs(waits) do
                    assert.is_true(wait.wrapped)
                    assert.are.equal(progress(), wait.trap_widget)
                end
                assert.is_nil(HttpUtil.getTrapWidget())
                assert.are.equal(1, #spawned)
            end)

            it("can be called off, which says nothing about the mirrors", function()
                HttpUtil.getBody = function(url)
                    if url:find("/ads.php", 1, true) then
                        progress().cancel_button.callback()
                        return nil, HttpUtil.CANCELLED
                    end
                    return getBody(url)
                end

                download()
                assert.are.same({ { ok = false, err = "request cancelled" } }, results)
                assert.are.equal(0, #spawned)
                assert.are.same({}, Downloader:getActiveDownloads())
                assert.is_nil(HttpUtil.getTrapWidget())
                -- none are dropped, or looked up again
                HttpUtil.getBody = getBody
                assert.are.same(mirrors, UrlApi:getLibgenUrls())
                assert.are.equal(1, web.scrapes)
            end)

            it("says something went wrong, rather than leaving the progress showing", function()
                local widget
                HttpUtil.getBody = function()
                    widget = progress()
                    error("unexpected")
                end

                download()
                assert.are.same({ { ok = false, err = "something went wrong, see crash.log" } }, results)
                assert.is_true(helper.wasClosed(widget.container))
                assert.are.same({}, Downloader:getActiveDownloads())
                assert.is_nil(HttpUtil.getTrapWidget())
                assert.is_truthy(helper.logged("err", "^looking up the download link went wrong:.*unexpected"))
            end)
        end)

        -- which KOReader would have exited on, leaving curl running and the progress up
        it("stops the download, and says something went wrong, when checking on it goes wrong", function()
            download()
            local widget = progress()
            CurlUtil.getDownloadSize = function()
                error("unexpected")
            end
            curlWrote(MB / 2)
            helper.tick()

            assert.are.same({ { ok = false, err = "something went wrong, see crash.log" } }, results)
            assert.are.same({ 1000 }, killed)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_false(helper.exists(spawned[1].headers_file))
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.is_truthy(helper.logged("err", "^checking on a download went wrong:.*unexpected"))
            -- and isn't checked on again
            assert.are.equal(0, helper.tick())
        end)

        -- e.g. offering to read it: the book did download
        it("doesn't say a download failed once it has finished, when what's done with the book goes wrong", function()
            Downloader:downloadBook(book, filepath, function(ok, err)
                table.insert(results, { ok = ok, err = err })
                if ok then
                    error("unexpected")
                end
            end, onOpenExisting)
            prompts[1].on_download(prompts[1].filepath)
            curlWrote(MB, 0)
            helper.tick()

            assert.are.same({ { ok = true } }, results)
            assert.is_true(helper.exists(filepath))
            assert.is_truthy(helper.logged("err", "^checking on a download went wrong:.*unexpected"))
        end)

        -- which was only lost, as Trapper drops what goes wrong once its function has waited on something
        it("says something went wrong when starting the download goes wrong once its link is found", function()
            CurlUtil.createHeadersFile = function()
                error("unexpected")
            end
            Downloader:downloadBook(book, filepath, onResult)
            local widget
            local show = require("ui.downloadprogress").show
            require("ui.downloadprogress").show = function(self)
                widget = self
                return show(self)
            end
            prompts[1].on_download(filepath)

            assert.are.same({ { ok = false, err = "something went wrong, see crash.log" } }, results)
            assert.is_true(helper.wasClosed(widget.container))
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.is_truthy(helper.logged("err", "^starting the download of Dune went wrong:.*unexpected"))
        end)

        -- which could be another book entirely, with the same title
        it("doesn't carry on from what's left of an earlier download of a book of the same name", function()
            helper.writeFile(filepath .. ".part", "another book")
            download()
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_true(spawned[1].resume)
        end)

        it("starts again from the beginning when the site can't carry on from where the download stopped", function()
            download()
            curlWrote(MB / 2, 33)
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.is_false(spawned[2].resume)
            assert.is_false(spawned[2].use_proxy)
            assert.is_false(helper.exists(filepath .. ".part"))

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
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

        -- which can take a while
        it("says what it's waiting for until the book starts to arrive", function()
            local HttpUtil = require("util.httputil")
            local getBody = HttpUtil.getBody
            local while_finding_the_link
            HttpUtil.getBody = function(url)
                if url:find("/ads.php", 1, true) then
                    while_finding_the_link = progress().status_text
                end
                return getBody(url)
            end

            download()
            assert.are.equal("Finding a download link...", while_finding_the_link)
            assert.are.equal("Waiting for Library Genesis...", progress().status_widget.text)
            helper.tick()
            assert.are.equal("Waiting for Library Genesis...", progress().status_widget.text)

            curlWrote(MB / 2)
            helper.tick()
            assert.are.equal("50% · 0.5 / 1.0 MB", progress().status_widget.text)
        end)

        -- rather than looking as if KOReader is stuck, as curl only tries again once it has stalled for a while
        -- once nothing has arrived for 10 seconds, the 20 checks on it since, however the clock has changed (it can be
        -- put back, or jump forward once the time is looked up)
        it("says when the download has stalled", function()
            helper.state.time = 1000
            download()
            curlWrote(MB / 2)
            helper.tick()
            helper.state.time = 5000
            for _ = 1, 19 do
                helper.tick()
            end
            assert.are.equal("50% · 0.5 / 1.0 MB", progress().status_widget.text)

            helper.state.time = 10
            helper.tick()
            assert.are.equal("Stalled at 50%, retrying...", progress().status_widget.text)
            assert.are.equal(0.5, progress().bar_widget.percentage)

            -- until more arrives
            curlWrote(MB * 3 / 4)
            helper.tick()
            assert.are.equal("75% · 0.8 / 1.0 MB", progress().status_widget.text)
        end)

        it("says when a download of unknown size has stalled", function()
            remote_size = nil
            download()
            curlWrote(MB / 2)
            for _ = 1, 21 do
                helper.tick()
            end
            assert.are.equal("Stalled at 0.5 MB, retrying...", progress().status_widget.text)
        end)

        -- rather than asking for it before downloading, and waiting for the answer
        it("works out the book's size from the headers curl notes down as the book starts to arrive", function()
            download()
            local widget = progress()

            helper.tick()
            assert.are.equal("Waiting for Library Genesis...", widget.status_widget.text)

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
            assert.are.same({}, Downloader:getActiveDownloads())
            assert.are.equal(MB, #helper.readFile(filepath))
            -- for reading crash.log from a device
            assert.is_truthy(helper.logged("info", '^downloading "Dune" %(epub, .-, id %x+%) to '))
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
            local reordered = { mirrors[2], mirrors[1] }
            for i = 3, #mirrors do
                table.insert(reordered, mirrors[i])
            end
            assert.are.same(reordered, UrlApi:getLibgenUrls())
        end)

        -- rather than asking the ones before it every time, which may be too busy for a while
        it("asks the mirror that last gave a download link first", function()
            web.pages[adsUrl(mirrors[1])] = "<html><body>Could not connect to the database 3306. User 'libgen_get' "
                .. "has exceeded the 'max_user_connections' resource (current value: 80)</body></html>"
            hasBook(mirrors[2])
            download()
            curlWrote(MB, 0)
            helper.runScheduled()

            web.fetched = {}
            os.remove(filepath)
            download()
            assert.are.same({ adsUrl(mirrors[2]) }, web.fetched)
            assert.are.equal(getUrl(mirrors[2]), spawned[2].url)
        end)

        it("scrapes the mirrors again when every mirror fails", function()
            -- every mirror is down until they have been scraped again
            web.pages[adsUrl(mirrors[1])] = function()
                if web.scrapes > 1 then
                    return fixtures.libgenAds(book.id)
                end
            end

            download()
            assert.are.equal(2, web.scrapes)
            assert.are.equal(1, #spawned)
            assert.are.same({}, results)
            assert.are.equal(1, #Downloader:getActiveDownloads())

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
            assert.are.same({}, Downloader:getActiveDownloads())
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

        -- as when the network is blocking them, as many internet providers do (#55)
        it("says when none of the mirrors can be found on this network", function()
            for _, mirror in ipairs(mirrors) do
                web.pages[adsUrl(mirror)] = function()
                    return nil, "could not resolve host"
                end
            end

            download()
            assert.are.same({
                {
                    ok = false,
                    err = "none of Library Genesis' sites can be found on this network, which may be blocking "
                        .. "them. Try another Wi-Fi network or DNS server",
                },
            }, results)
            assert.are.equal(2, web.scrapes)
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
            CurlUtil.startDownload = function()
                return nil, "could not start curl"
            end

            download()
            assert.are.same({ { ok = false, err = "could not start curl" } }, results)
            assert.are.same({}, Downloader:getActiveDownloads())
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

        -- rather than that the TLS connection failed, which doesn't say what to do about it
        it("says when a Kindle's curl is too old to download the book, and how to update it", function()
            helper.stubCommand("curl --version", "curl 7.68.0 (arm-kindle-linux-gnueabi) libcurl/7.68.0\n")
            CurlUtil.forgetVersion()
            download()
            curlWrote(0, 35)
            helper.runScheduled()

            assert.are.same({ { ok = false, err = CurlUtil.OUTDATED_ERROR } }, results)
            assert.matches("Check for updates", CurlUtil.OUTDATED_ERROR, 1, true)
        end)

        -- as happened while this was written: the mirrors linked to the book, then answered with an error
        it("says Library Genesis is too busy when its servers fail to send the book", function()
            download()
            helper.writeFile(spawned[1].headers_file, "HTTP/2 503 \r\ncontent-length: 212\r\n\r\n")
            helper.writeFile(spawned[1].exit_file, "22")
            helper.runScheduled()

            assert.are.same({
                {
                    ok = false,
                    err = "Library Genesis is too busy to send books right now, try again in a few minutes",
                },
            }, results)
            assert.matches("curl exit code 22 %(HTTP error response, HTTP 503%)", helper.logged("warn", "failed after"))
        end)

        it("says which HTTP error stopped the download when it isn't Library Genesis' servers failing", function()
            download()
            helper.writeFile(spawned[1].headers_file, "HTTP/2 404 \r\ncontent-length: 9\r\n\r\n")
            helper.writeFile(spawned[1].exit_file, "22")
            helper.runScheduled()

            assert.are.same({ { ok = false, err = "HTTP error response (HTTP 404)" } }, results)
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

            curlWrote(MB / 4, 7)
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].use_proxy)
            assert.are.equal(filepath .. ".part", spawned[2].path)
            assert.are.equal(30, spawned[2].stall_time)
            -- carrying on from what had downloaded
            assert.is_true(spawned[2].resume)
            assert.are.equal(MB / 4, #helper.readFile(filepath .. ".part"))

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
            CurlUtil.startDownload = function()
                return nil, "could not start curl"
            end

            curlWrote(0, 7)
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "could not start curl" } }, results)
        end)

        it("can be cancelled from the progress widget", function()
            download()
            curlWrote(MB / 2)

            progress().cancel_button.callback()
            helper.runScheduled()

            assert.are.same({ spawned[1].pid, spawned[1].pid }, killed)
            assert.are.same({ { ok = false, err = "request cancelled" } }, results)
            assert.is_false(helper.exists(filepath))
            assert.is_false(helper.exists(filepath .. ".part"))
        end)
    end)

    -- the same way as from Library Genesis, but with the link looked up on the site the book was found on
    describe("a book found on Internet Archive", function()
        before_each(function()
            book = {
                source = "archive",
                id = "archive_emma00aust",
                identifier = "emma00aust",
                title = "Emma",
                display_title = "Emma",
                file_type = "epub",
            }
            web.pages["https://archive.org/metadata/emma00aust/files"] = fixtures.archiveFiles({
                { name = "emma00aust.epub", format = "EPUB" },
            })
        end)

        it("downloads it from there, saying so while it waits", function()
            download()

            assert.are.equal("https://archive.org/download/emma00aust/emma00aust.epub", spawned[1].url)
            assert.are.equal("Waiting for Internet Archive...", progress().status_widget.text)
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
        end)

        it("says Internet Archive is too busy when its servers fail to send the book", function()
            download()
            helper.writeFile(spawned[1].headers_file, "HTTP/2 503 \r\ncontent-length: 212\r\n\r\n")
            helper.writeFile(spawned[1].exit_file, "22")
            helper.runScheduled()

            assert.are.same({
                {
                    ok = false,
                    err = "Internet Archive is too busy to send books right now, try again in a few minutes",
                },
            }, results)
        end)

        it("says why it couldn't find the link, without looking it up again", function()
            web.pages["https://archive.org/metadata/emma00aust/files"] = "{}"
            download()

            assert.are.same({ { ok = false, err = "Internet Archive no longer has this book as EPUB" } }, results)
            assert.are.equal(0, #spawned)
            assert.are.equal(1, #web.fetched)
        end)
    end)

    -- whose download links each go to one of its servers, some of which can fail for a while
    describe("a book found on Z-Library", function()
        local links

        -- curl being answered with the HTTP status, and giving up
        local function serverAnswered(status)
            helper.writeFile(spawned[#spawned].headers_file, "HTTP/2 " .. status .. " \r\ncontent-length: 0\r\n\r\n")
            helper.writeFile(spawned[#spawned].exit_file, "22")
        end

        before_each(function()
            local account = { email = "reader@example.com", user_id = 42, user_key = "abc" }
            require("settings.settings"):setZlibAccount(account)
            book = {
                source = "zlib",
                id = "zlib_7",
                zlib_id = 7,
                hash = "abc123",
                title = "1984",
                display_title = "1984",
                file_type = "epub",
            }
            -- Z-Library's address, as if looked up already (see UrlApi)
            require("cache.urlcache"):set({ "https://z-lib.example" }, "zlib")
            web.pages["https://z-lib.example/eapi/user/profile"] =
                '{"success":1,"user":{"downloads_today":1,"downloads_limit":10}}'
            links = 0
            web.pages["https://z-lib.example/eapi/book/7/abc123/file"] = function()
                links = links + 1
                return string.format('{"success":1,"file":{"downloadLink":"https://dl%d.example/1984.epub"}}', links)
            end
        end)

        it("asks for another link once the server the link went to fails", function()
            download()
            assert.are.equal("https://dl1.example/1984.epub", spawned[1].url)
            serverAnswered(522)
            helper.tick()

            assert.are.equal(2, links)
            assert.are.equal("https://dl2.example/1984.epub", spawned[2].url)
            assert.are.same({}, results)
            assert.is_truthy(helper.logged("info", "^asking for another download link"))
            assert.are.equal("Waiting for Z-Library...", progress().status_widget.text)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(MB, #helper.readFile(filepath))
        end)

        -- which can count as another of the few downloads Z-Library allows a day
        it("doesn't ask for another link when Wi-Fi went off, carrying on with the same one once it's back", function()
            download()
            require("ui/network/manager").connected = false
            curlWrote(MB / 2, 6)
            helper.tick()
            assert.are.equal(1, links)

            require("ui/network/manager").connected = true
            helper.tick()
            assert.are.equal(1, links)
            assert.are.equal("https://dl1.example/1984.epub", spawned[2].url)
        end)

        it("asks for another link when the server doesn't answer at all", function()
            download()
            helper.writeFile(spawned[1].exit_file, "7")
            helper.tick()

            assert.are.equal(2, #spawned)
        end)

        it("gives up when the server the second link went to fails too", function()
            download()
            serverAnswered(522)
            helper.tick()
            serverAnswered(522)
            helper.runScheduled()

            assert.are.equal(2, links)
            assert.are.same({
                { ok = false, err = "Z-Library is too busy to send books right now, try again in a few minutes" },
            }, results)
        end)

        -- which another link to it wouldn't change
        it("doesn't ask for another link when the book isn't there", function()
            download()
            serverAnswered(404)
            helper.runScheduled()

            assert.are.equal(1, links)
            assert.are.same({ { ok = false, err = "HTTP error response (HTTP 404)" } }, results)
        end)
    end)

    -- which failed the download as if the site had, removing what had arrived, and for Z-Library, asking for another
    -- link, which can count as another download
    describe("when Wi-Fi goes off, or the device goes to sleep", function()
        local network

        before_each(function()
            network = require("ui/network/manager")
            download()
            curlWrote(MB / 2)
            helper.tick()
        end)

        local function progressText()
            return progress().status_text
        end

        it("waits for Wi-Fi to come back, then carries on from what had arrived with the same link", function()
            network.connected = false
            curlWrote(MB / 2, 6)
            helper.tick()
            assert.are.same({}, results)
            assert.are.equal("Waiting for Wi-Fi...", progressText())
            assert.are.equal(MB / 2, #helper.readFile(filepath .. ".part"))
            assert.are.same({}, killed)
            -- still waiting
            helper.tick()
            assert.are.equal(1, #spawned)

            -- found to be back, as KOReader doesn't say so on every device
            network.connected = true
            helper.tick()
            assert.are.equal(2, #spawned)
            assert.are.equal(spawned[1].url, spawned[2].url)
            assert.is_true(spawned[2].resume)
            assert.are.equal("Waiting for Library Genesis...", progressText())

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(MB, #helper.readFile(filepath))
        end)

        it("stops curl as soon as KOReader says Wi-Fi went off, and starts it again once it says it's back", function()
            Downloader:onNetworkDisconnected()
            assert.are.same({ 1000 }, killed)
            assert.are.equal("Waiting for Wi-Fi...", progressText())
            helper.tick()
            assert.are.same({}, results)

            Downloader:onNetworkConnected()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].resume)
        end)

        it("stops curl while the device sleeps, carrying on once it's awake", function()
            Downloader:onSuspend()
            assert.are.same({ 1000 }, killed)
            assert.is_true(helper.exists(filepath .. ".part"))
            -- not while it's asleep, whatever it says about Wi-Fi
            Downloader:onNetworkConnected()
            helper.tick()
            assert.are.equal(1, #spawned)

            Downloader:onResume()
            assert.are.equal(2, #spawned)
            assert.is_true(spawned[2].resume)
        end)

        it("waits once the device is awake for Wi-Fi to reconnect", function()
            Downloader:onSuspend()
            network.connected = false
            Downloader:onResume()
            helper.tick()
            assert.are.equal(1, #spawned)

            network.connected = true
            Downloader:onNetworkConnected()
            assert.are.equal(2, #spawned)
        end)

        it("can be cancelled while it waits", function()
            Downloader:onNetworkDisconnected()
            progress().cancel_button.callback()
            helper.runScheduled()
            assert.are.same({ { ok = false, err = "request cancelled" } }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
        end)

        it("fails when curl can't be started again", function()
            Downloader:onNetworkDisconnected()
            CurlUtil.startDownload = function()
                return nil, "could not start curl"
            end
            Downloader:onNetworkConnected()
            assert.are.same({ { ok = false, err = "could not start curl" } }, results)
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.are.same({}, Downloader:getActiveDownloads())
        end)
    end)

    -- as going to sleep turns Wi-Fi off, which stopped the download
    describe("keeping the device awake", function()
        local PluginShare

        before_each(function()
            PluginShare = require("pluginshare")
        end)

        it("while a book downloads, letting it sleep again once it has", function()
            download()
            assert.are.equal(1, helper.state.standby_prevented)
            assert.is_true(PluginShare.pause_auto_suspend)
            assert.are.same({ "lipc-set-prop com.lab126.powerd preventScreenSaver 1" }, helper.state.lipc)

            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({ { ok = true } }, results)
            assert.are.equal(0, helper.state.standby_prevented)
            assert.is_nil(PluginShare.pause_auto_suspend)
            assert.are.equal("lipc-set-prop com.lab126.powerd preventScreenSaver 0", helper.state.lipc[2])
        end)

        it("until every book has downloaded", function()
            download()
            local first = book
            book = {
                source = "libgen",
                id = fixtures.DUNE.md5:gsub("^.", "f"),
                title = "Dune Messiah",
                file_type = "epub",
            }
            hasBook(mirrors[1])
            filepath = data_dir .. "/Dune Messiah.epub"
            download()
            assert.are.equal(2, #spawned)
            assert.are.equal(1, helper.state.standby_prevented)
            assert.are.equal(1, #helper.state.lipc)

            curlWrote(MB, 0)
            helper.tick()
            assert.are.equal(1, helper.state.standby_prevented)
            assert.is_not_nil(Downloader.active_downloads[first.id])
        end)

        it("putting auto-suspend back as it was, unless something else has changed it since", function()
            PluginShare.pause_auto_suspend = false
            download()
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.is_false(PluginShare.pause_auto_suspend)

            -- e.g. AutoTurn, which was turned off meanwhile
            PluginShare.pause_auto_suspend = nil
            download()
            PluginShare.pause_auto_suspend = false
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.is_false(PluginShare.pause_auto_suspend)
        end)

        it("leaving a Kindle's screensaver to Keep alive, when that's keeping it awake", function()
            PluginShare.keepalive = true
            download()
            curlWrote(MB, 0)
            helper.runScheduled()
            assert.are.same({}, helper.state.lipc)
        end)

        it("only holding off a Kindle's own screensaver on a Kindle", function()
            helper.stubs.device.kindle = false
            download()
            assert.are.equal(1, helper.state.standby_prevented)
            assert.are.same({}, helper.state.lipc)
        end)

        it("letting it sleep again however downloads end", function()
            -- no link
            web.pages[adsUrl(mirrors[1])] = "<html>nothing</html>"
            download()
            assert.are.equal(0, helper.state.standby_prevented)

            -- cancelled
            hasBook(mirrors[1])
            download()
            progress().cancel_button.callback()
            helper.runScheduled()
            assert.are.equal(0, helper.state.standby_prevented)

            -- all cancelled at once, as when KOReader closes
            download()
            Downloader:cancelAllDownloads()
            assert.are.equal(0, helper.state.standby_prevented)
            assert.is_nil(PluginShare.pause_auto_suspend)
        end)
    end)

    describe("active downloads", function()
        it("lists downloads in progress", function()
            download()

            local downloads = Downloader:getActiveDownloads()
            assert.are.equal(1, #downloads)
            assert.are.equal(book.id, downloads[1].id)
            assert.are.equal("Dune", downloads[1].title)
            assert.are.equal(filepath, downloads[1].filepath)
            assert.are.equal(progress(), downloads[1].widget)
        end)

        -- even once the clock has been put back, as an e-reader's can be when its battery runs flat
        it("are listed in the order they were started", function()
            helper.state.time = 3000
            for i, title in ipairs({ "Zebra", "Apple" }) do
                Downloader:track("other" .. i, {
                    book = { id = "other" .. i, title = title },
                    progress_widget = {},
                })
                helper.state.time = helper.state.time - 1000
            end
            download()

            local titles = {}
            for _, active_download in ipairs(Downloader:getActiveDownloads()) do
                table.insert(titles, active_download.title)
            end
            assert.are.same({ "Zebra", "Apple", "Dune" }, titles)
        end)

        -- e.g. from the Downloads entry in KindleFetch's menu
        it("can have their progress shown again once hidden", function()
            download()
            local widget = progress()
            widget.hide_button.callback()

            assert.is_true(Downloader:showDownload(book.id))
            assert.is_true(widget.is_visible)
            assert.are.equal(widget.container, helper.lastShown())

            -- and nothing happens when it's showing already
            local shown = #helper.state.shown
            assert.is_true(Downloader:showDownload(book.id))
            assert.are.equal(shown, #helper.state.shown)
        end)

        it("can't have their progress shown once they're over", function()
            assert.is_false(Downloader:showDownload(book.id))
        end)

        it("can all be cancelled at once", function()
            download()
            local widget = progress()
            curlWrote(MB / 2)

            Downloader:cancelAllDownloads()
            assert.is_true(widget.cancelled)
            assert.are.same({ spawned[1].pid }, killed)
            assert.is_true(helper.wasClosed(widget.container))
            assert.is_false(helper.exists(filepath .. ".part"))
            assert.is_false(helper.exists(spawned[1].headers_file))
            assert.are.same({}, Downloader:getActiveDownloads())

            helper.runScheduled()
            assert.are.same({ { ok = false, err = "request cancelled" } }, results)
        end)
    end)
end)
