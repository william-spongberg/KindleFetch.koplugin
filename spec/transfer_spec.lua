local helper = require("helper")
local fixtures = require("fixtures")

describe("Transfer", function()
    local data_dir, spawned, results, over, widget
    local CurlUtil, Transfer

    -- a progress widget that remembers being closed, as DownloadProgress's would be
    local function progressWidget()
        return {
            update = function() end,
            close = function(self)
                self.closed = true
            end,
        }
    end

    -- the download of an EPUB of Dune to the data folder, from a site whose links can be asked for again where relink
    local function transfer(relink)
        widget = progressWidget()
        return Transfer.new {
            book = { id = "dune", title = "Dune", file_type = "epub", source = "test" },
            site = { NAME = "Test Site" },
            filepath = data_dir .. "/Dune.epub",
            progress_widget = widget,
            callback = function(ok, err)
                table.insert(results, { ok = ok, err = err })
            end,
            on_over = function()
                over = over + 1
            end,
            on_relink = relink,
        }
    end

    -- curl writing the book, all bytes of it, and exiting with exit_code
    local function curlWrote(bytes, exit_code)
        helper.writeFile(spawned[#spawned].headers_file, "HTTP/2 200\r\ncontent-length: " .. bytes .. "\r\n\r\n")
        helper.writeFile(spawned[#spawned].path, fixtures.bookFile("epub", bytes))
        helper.writeFile(spawned[#spawned].exit_file, tostring(exit_code))
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        spawned, results, over = {}, {}, 0
        CurlUtil = require("util.curlutil")
        CurlUtil.canFetch = function()
            return true
        end
        CurlUtil.startDownload = function(url, path, _, opts)
            local exit_file = CurlUtil.createExitFile()
            table.insert(spawned, { url = url, path = path, exit_file = exit_file, headers_file = opts.headers_file })
            return 1000 + #spawned, exit_file
        end
        require("util.backgroundprocess").isPidRunning = function()
            return true
        end
        Transfer = require("api.transfer")
    end)

    after_each(helper.cleanup)

    it("finds its link, downloads, then is done once what arrived is moved into place", function()
        local dune = transfer()
        assert.are.equal(Transfer.FINDING_LINK, dune.state)

        dune:download("https://books.example/dune.epub", { bytes = 1000 })
        assert.are.equal(Transfer.DOWNLOADING, dune.state)
        assert.are.equal("https://books.example/dune.epub", spawned[1].url)
        assert.are.equal(dune.part_path, spawned[1].path)

        curlWrote(1000, 0)
        helper.runScheduled()
        assert.are.equal(Transfer.DONE, dune.state)
        assert.are.same({ { ok = true } }, results)
        assert.are.equal(1, over)
        assert.is_true(widget.closed)
        assert.is_true(helper.exists(data_dir .. "/Dune.epub"))
        assert.is_false(helper.exists(dune.part_path))
    end)

    it("pauses while Wi-Fi is off, then carries on from what arrived", function()
        local dune = transfer()
        dune:download("https://books.example/dune.epub")
        dune:pause("Wi-Fi went off")
        assert.are.equal(Transfer.PAUSED, dune.state)

        assert.is_true(dune:resume())
        assert.are.equal(Transfer.DOWNLOADING, dune.state)
        assert.are.equal(2, #spawned)
    end)

    it("isn't paused before it has a link, or once it's over", function()
        local dune = transfer()
        dune:pause("Wi-Fi went off")
        assert.are.equal(Transfer.FINDING_LINK, dune.state)

        dune:download("https://books.example/dune.epub")
        curlWrote(1000, 0)
        helper.runScheduled()
        dune:pause("Wi-Fi went off")
        assert.are.equal(Transfer.DONE, dune.state)
    end)

    it("fails where the book doesn't arrive whole, or asks for another link where it can", function()
        local dune = transfer()
        dune:download("https://books.example/dune.epub", { bytes = 2000 })
        curlWrote(1000, 0)
        helper.runScheduled()
        assert.are.equal(Transfer.FAILED, dune.state)
        assert.is_false(results[1].ok)

        local relinked = {}
        local persuasion = transfer(function(failed_url)
            table.insert(relinked, failed_url)
        end)
        persuasion:download("https://books.example/dune.epub")
        helper.writeFile(spawned[#spawned].exit_file, "56")
        helper.runScheduled()
        assert.are.equal(Transfer.FAILED, persuasion.state)
        assert.are.same({ "https://books.example/dune.epub" }, relinked)
        -- (with no say of how it went, as the download carries on with the new link)
        assert.are.equal(1, #results)
    end)

    it("is abandoned after a mistake, cleaning up, but not once it's over", function()
        local dune = transfer()
        dune:abandon("broken")
        assert.are.equal(Transfer.FAILED, dune.state)
        assert.are.same({ { ok = false, err = "broken" } }, results)

        dune:abandon("broken again")
        assert.are.equal(1, #results)
        assert.are.equal(1, over)
    end)
end)
