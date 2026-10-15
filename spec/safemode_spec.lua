local helper = require("helper")

-- what's left of Kindle Fetch when an update doesn't work with this KOReader, which was gone from KOReader's menu,
-- along with checking for updates, until it was copied over USB
describe("SafeMode", function()
    local plugin_path, registered

    -- a version of Kindle Fetch that can't be loaded, as main.lua loads it
    local function loadBroken()
        package.preload["kindlefetch"] = function()
            error("kindlefetch.lua:12: attempt to call field 'isKobo' (a nil value)")
        end
        package.loaded["safemode"] = helper.loadPluginFileFrom(plugin_path, "safemode.lua")
        local Plugin = dofile("kindlefetch.koplugin/main.lua")
        Plugin:new {
            ui = {
                menu = {
                    registerToMainMenu = function(_, widget)
                        table.insert(registered, widget)
                    end,
                },
            },
        }
        local menu_items = {}
        registered[1]:addToMainMenu(menu_items)
        return menu_items.kindlefetch
    end

    before_each(function()
        helper.reset()
        plugin_path = helper.tmpdir("plugins") .. "/kindlefetch.koplugin"
        helper.writeFile(plugin_path .. "/main.lua", "-- v0.4")
        helper.writeFile(plugin_path .. "/version.txt", "0.4\n")
        registered = {}
    end)

    after_each(function()
        package.preload["kindlefetch"] = nil
        helper.cleanup()
    end)

    it("shows Kindle Fetch's menu, saying it couldn't start, and why", function()
        local menu = loadBroken()
        assert.are.equal("Kindle Fetch", menu.text)
        assert.are.equal("Kindle Fetch couldn't start", menu.sub_item_table[1].text)
        assert.is_truthy(helper.logged("err", "^could not load Kindle Fetch:.*isKobo"))

        menu.sub_item_table[1].callback()
        assert.matches("^Kindle Fetch couldn't start: .*attempt to call field 'isKobo'", helper.lastError())
        assert.matches("See crash.log for where.$", helper.lastError())
    end)

    it("goes back to the version installed before the last update", function()
        helper.writeFile(plugin_path .. ".previous/main.lua", "-- v0.3")
        helper.writeFile(plugin_path .. ".previous/version.txt", "0.3\n")
        local go_back = loadBroken().sub_item_table[2]
        assert.are.equal("Go back to v0.3", go_back.text)
        assert.is_true(go_back.enabled)

        go_back.callback()
        helper.lastShown().ok_callback()
        assert.are.equal("-- v0.3", helper.readFile(plugin_path .. "/main.lua"))
        assert.are.same(
            { "Kindle Fetch has gone back to v0.3, which KOReader will use once it restarts." },
            helper.state.restart_prompts
        )
    end)

    it("can't go back when no version is kept from before", function()
        local go_back = loadBroken().sub_item_table[2]
        assert.are.equal("Go back to the version before", go_back.text)
        assert.is_false(go_back.enabled)
    end)
end)
