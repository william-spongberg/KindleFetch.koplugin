local helper = require("helper")

describe("Diagnostics", function()
    local Diagnostics, Settings, LogUtil, data_dir, plugin_dir
    -- what each address answers with, as getBody returns it, and the addresses asked, in order
    local answers, asked
    local can_fetch

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        plugin_dir = helper.tmpdir("plugin")
        helper.writeFile(plugin_dir .. "/version.txt", "0.8\n")
        helper.stub("util.pathutil", {
            getPluginPath = function()
                return plugin_dir
            end,
        })
        can_fetch = true
        helper.stub("util.curlutil", {
            getVersion = function()
                return "8.21.0"
            end,
            canFetch = function()
                return can_fetch
            end,
        })
        answers, asked = {}, {}
        helper.stub("util.httputil", {
            CANCELLED = "request cancelled",
            canCancel = function()
                return true
            end,
            setTrapWidget = function(widget)
                helper.state.trap_widget = widget
            end,
            sayStatus = function() end,
            getBody = function(url)
                table.insert(asked, url)
                local answer = answers[url] or { nil, "could not resolve host" }
                return answer[1], answer[2], answer[3]
            end,
        })

        Settings = require("settings.settings")
        Settings:load()
        LogUtil = require("util.logutil")
        Diagnostics = require("ui.diagnostics")
    end)

    after_each(helper.cleanup)

    local function viewer()
        local shown = helper.lastShown()
        assert.are.equal("Kindle Fetch diagnostics", shown.title)
        return shown
    end

    local function button(text)
        for _, row in ipairs(viewer().buttons_table) do
            for _, b in ipairs(row) do
                if b.text == text then
                    return b
                end
            end
        end
        error("no button " .. text)
    end

    describe("report", function()
        it("says which versions, device and settings are in use", function()
            local report = Diagnostics.report()

            assert.matches("^KindleFetch 0.8 on KOReader .*, curl 8.21.0\n", report)
            assert.matches("\nTime: %d%d%d%d%-%d%d%-%d%d %d%d:%d%d", report)
            assert.matches("\nFetching with: curl\n", report)
            assert.matches("\nDownload folder: [^\n]+\n", report)
            -- the ones known when it was written, as none have been looked up
            assert.matches("\nLibrary Genesis mirrors: https://libgen.vg, ", report, 1, true)
            assert.matches("\nZ-Library: not logged in, at https://z-lib.sk\n", report, 1, true)
            assert.matches("\nLanguages: en\n", report, 1, true)
            assert.matches("\nCovers: on\n", report, 1, true)
        end)

        it("says when KOReader's own HTTP fetches, as curl can't", function()
            can_fetch = false
            assert.matches("\nFetching with: KOReader's own HTTP, as curl can't\n", Diagnostics.report(), 1, true)
        end)

        it("ends with what was logged this session, at info and above", function()
            LogUtil.debug("fetching a page")
            LogUtil.info("downloaded", '"Dune"')
            LogUtil.warn("could not fetch", "https://libgen.vg")

            local log = Diagnostics.report():match("\nRecent log:\n(.*)$")
            assert.matches('%d%d:%d%d:%d%d INFO downloaded "Dune"\n', log)
            assert.matches("\n%d%d:%d%d:%d%d WARN could not fetch https://libgen.vg$", log)
            assert.is_nil(log:find("fetching a page", 1, true))
        end)

        -- which would let whoever reads it into the account
        it("says whether Z-Library is logged into, without the account", function()
            Settings:setZlibAccount({ email = "reader@example.com", user_id = 42, user_key = "secret-key" })
            local report = Diagnostics.report()

            assert.matches("\nZ-Library: logged in, at ", report, 1, true)
            assert.is_nil(report:find("reader@example.com", 1, true))
            assert.is_nil(report:find("secret-key", 1, true))
        end)
    end)

    describe("the page", function()
        it("shows the report, with KOReader's own buttons too", function()
            Diagnostics.show()

            assert.are.equal(Diagnostics.report(), viewer().text)
            assert.are.equal("code", viewer().text_type)
            assert.is_true(viewer().add_default_buttons)
        end)

        it("copies the report", function()
            Diagnostics.show()
            button("Copy").callback()

            assert.are.equal(viewer().text, helper.state.clipboard)
            assert.are.equal("Copied", helper.lastNotification())
        end)

        -- where it can be copied from over USB, without showing up among the books
        it("saves the report in KOReader's folder, saying where", function()
            Diagnostics.show()
            button("Save").callback()

            local path = data_dir .. "/kindlefetch-diagnostics.txt"
            assert.are.equal(viewer().text, helper.readFile(path))
            assert.are.equal("Saved to " .. path, helper.lastNotification())
        end)
    end)

    describe("testing the connection", function()
        it("asks each site, then shows how it went", function()
            answers["https://en.wikipedia.org/wiki/Library_Genesis"] = { "<html></html>", nil, 200 }
            answers["https://libgen.li/"] = { "<html></html>", nil, 200 }
            answers["https://libgen.vg/"] = { "<html>Bad gateway</html>", nil, 502 }
            Diagnostics.show()
            button("Test connection").callback()

            assert.are.equal("https://en.wikipedia.org/wiki/Library_Genesis", asked[1])
            assert.are.equal("https://libgen.vg/", asked[2])
            assert.matches("^https://archive.org/advancedsearch.php", asked[#asked - 1])
            assert.are.equal("https://z-lib.sk/eapi/info/languages", asked[#asked])

            local tested = viewer().text:match("\nConnection test:\n(.-)\n\n")
            assert.matches("^  en.wikipedia.org answered %(HTTP 200%)\n", tested)
            assert.matches("\n  libgen.vg answered %(HTTP 502%)\n", tested)
            assert.matches("\n  libgen.li answered %(HTTP 200%)\n", tested)
            assert.matches("\n  archive.org didn't answer: could not resolve host\n", tested, 1, true)
            assert.is_truthy(helper.logged("info", "^tested the connection: en.wikipedia.org answered"))
            -- with the message saying it was testing closed
            assert.is_nil(helper.state.trap_widget)
        end)

        -- rather than looking them up again, or changing them
        it("asks the mirrors as they are", function()
            local UrlCache = require("cache.urlcache")
            UrlCache:set({ "https://libgen.example", "https://libgen.other" }, "libgen")
            Diagnostics.testConnection()

            assert.are.equal("https://libgen.example/", asked[2])
            assert.are.equal("https://libgen.other/", asked[3])
            assert.are.same({ "https://libgen.example", "https://libgen.other" }, UrlCache:get("libgen"))
        end)

        -- as each site that doesn't answer is waited on for a while
        it("can be called off, saying how it went with the sites tested by then", function()
            answers["https://en.wikipedia.org/wiki/Library_Genesis"] = { "<html></html>", nil, 200 }
            answers["https://libgen.vg/"] = { nil, "request cancelled" }
            Diagnostics.testConnection()

            assert.are.equal(2, #asked)
            local tested = viewer().text:match("\nConnection test:\n(.-)\n\n")
            assert.are.equal("  en.wikipedia.org answered (HTTP 200)\n  (called off at libgen.vg)", tested)
            assert.is_nil(helper.state.trap_widget)
        end)
    end)
end)
