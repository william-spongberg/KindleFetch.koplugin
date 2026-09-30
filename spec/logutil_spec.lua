local helper = require("helper")

describe("LogUtil", function()
    before_each(helper.reset)

    it("prefixes messages with the plugin name", function()
        local LogUtil = require("util.logutil")
        LogUtil.warn("download failed", 22)
        LogUtil.debug("searching")

        assert.are.same({"warn", "KindleFetch:", "download failed", 22}, helper.state.logs[1])
        assert.are.same({"dbg", "KindleFetch:", "searching"}, helper.state.logs[2])

        LogUtil.info("found 12 books")
        LogUtil.err("crashed")
        assert.are.same({"info", "KindleFetch:", "found 12 books"}, helper.state.logs[3])
        assert.are.same({"err", "KindleFetch:", "crashed"}, helper.state.logs[4])
    end)

    -- download links carry a temporary key, which isn't worth logging
    it("gives the site a url is on", function()
        local LogUtil = require("util.logutil")
        assert.are.equal("libgen.li", LogUtil.site("https://libgen.li/get.php?md5=abc&key=SECRET"))
        assert.are.equal("libgen.li", LogUtil.site("https://libgen.li"))
        assert.are.equal("nil", LogUtil.site(nil))
    end)
end)

describe("NotifyUtil", function()
    before_each(helper.reset)

    it("shows a notification", function()
        local NotifyUtil = require("util.notifyutil")
        NotifyUtil.info("Searching...")
        assert.are.same({"Searching..."}, helper.state.notifications)
    end)
end)
