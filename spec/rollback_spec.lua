local helper = require("helper")

describe("Rollback", function()
    local plugin_path, Rollback

    before_each(function()
        helper.reset()
        plugin_path = helper.tmpdir("plugins") .. "/kindlefetch.koplugin"
        helper.writeFile(plugin_path .. "/main.lua", "-- v0.4")
        helper.writeFile(plugin_path .. "/version.txt", "0.4\n")
        Rollback = require("updater.rollback")
    end)

    after_each(helper.cleanup)

    local function keepPrevious(version)
        helper.writeFile(plugin_path .. ".previous/main.lua", "-- v" .. version)
        helper.writeFile(plugin_path .. ".previous/version.txt", version .. "\n")
    end

    it("says which version is kept from before, when there is one", function()
        assert.is_nil(Rollback.previousVersion(plugin_path))
        keepPrevious("0.3")
        assert.are.equal("0.3", Rollback.previousVersion(plugin_path))
    end)

    it("goes back to it, keeping the version installed now to go forward to again", function()
        keepPrevious("0.3")
        assert.is_true(Rollback.goBack(plugin_path))
        assert.are.equal("-- v0.3", helper.readFile(plugin_path .. "/main.lua"))
        assert.are.equal("-- v0.4", helper.readFile(plugin_path .. ".previous/main.lua"))
        assert.is_false(helper.exists(plugin_path .. ".swap"))

        assert.is_true(Rollback.goBack(plugin_path))
        assert.are.equal("-- v0.4", helper.readFile(plugin_path .. "/main.lua"))
    end)

    it("leaves them as they were when the version before can't be moved into place", function()
        keepPrevious("0.3")
        local rename = os.rename
        os.rename = function(from, to)
            if from == plugin_path .. ".previous" then
                return nil, "Permission denied"
            end
            return rename(from, to)
        end
        finally(function()
            os.rename = rename
        end)

        local ok, err = Rollback.goBack(plugin_path)
        assert.is_nil(ok)
        assert.are.equal("Permission denied", err)
        assert.are.equal("-- v0.4", helper.readFile(plugin_path .. "/main.lua"))
        assert.are.equal("-- v0.3", helper.readFile(plugin_path .. ".previous/main.lua"))
    end)
end)
