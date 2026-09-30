local helper = require("helper")

describe("LogUtil", function()
    before_each(helper.reset)

    it("prefixes messages with the plugin name", function()
        local LogUtil = require("util.logutil")
        LogUtil.warn("download failed", 22)
        LogUtil.debug("searching")

        assert.are.same({"warn", "KindleFetch:", "download failed", 22}, helper.state.logs[1])
        assert.are.same({"dbg", "KindleFetch:", "searching"}, helper.state.logs[2])
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
