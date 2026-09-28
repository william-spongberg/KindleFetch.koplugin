local helper = require("helper")

describe("PathUtil", function()
    local data_dir

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
    end)

    after_each(helper.cleanup)

    describe("getPluginPath", function()
        it("returns the directory the plugin was loaded from", function()
            local PathUtil = require("util.pathutil")
            assert.are.equal("kindlefetch.koplugin", PathUtil.getPluginPath())
        end)

        it("finds plugins installed in koreader's data dir (android)", function()
            -- koreader registers "<data dir>/plugins/" as an extra plugin path, hence the double slash
            local plugin_path = helper.abs(data_dir) .. "/plugins//kindlefetch.koplugin"
            local PathUtil = helper.loadPluginFileFrom(plugin_path, "util/pathutil.lua")
            assert.are.equal(plugin_path, PathUtil.getPluginPath())
        end)

        it("finds plugins installed under a different folder name", function()
            local plugin_path = data_dir .. "/plugins/KindleFetch-main.koplugin"
            local PathUtil = helper.loadPluginFileFrom(plugin_path, "util/pathutil.lua")
            assert.are.equal(plugin_path, PathUtil.getPluginPath())
        end)

        it("falls back to koreader's data dir when the load location is unknown", function()
            local source = helper.readFile("kindlefetch.koplugin/util/pathutil.lua")
            local PathUtil = (loadstring or load)(source, "=pathutil")()
            assert.are.equal(data_dir .. "/plugins/kindlefetch.koplugin", PathUtil.getPluginPath())
        end)
    end)

    describe("getTmpPath", function()
        it("creates a kindlefetch directory inside koreader's cache dir", function()
            local PathUtil = require("util.pathutil")
            local tmp_path = PathUtil.getTmpPath()
            assert.are.equal(data_dir .. "/cache/kindlefetch", tmp_path)
            assert.is_true(helper.isDir(tmp_path))
        end)

        it("reuses the directory when it already exists", function()
            local PathUtil = require("util.pathutil")
            helper.writeFile(PathUtil.getTmpPath() .. "/partial.zip", "data")
            assert.are.equal(data_dir .. "/cache/kindlefetch", PathUtil.getTmpPath())
            assert.is_true(helper.exists(data_dir .. "/cache/kindlefetch/partial.zip"))
        end)
    end)
end)
