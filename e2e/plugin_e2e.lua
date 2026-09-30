local H = require("helpers")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

describe("KindleFetch", function()
    after_each(function()
        -- close anything left open, back to the file manager
        local FileManager = require("apps/filemanager/filemanager")
        for _, window in ipairs(H.windows()) do
            if window ~= FileManager.instance then
                UIManager:close(window)
            end
        end
        H.pump()
    end)

    it("is loaded from KOReader's data folder", function()
        assert(H.plugin(), "KindleFetch isn't loaded")
        local plugin_path = require("util.pathutil").getPluginPath():gsub("//+", "/")
        H.eq(os.getenv("KO_HOME") .. "/plugins/kindlefetch.koplugin", plugin_path, "plugin path")
    end)

    it("opens search from the Search menu", function()
        H.openMainMenu({"Kindle Fetch", "Search Library Genesis"})
        local plugin = H.plugin()
        H.waitFor("the search dialog", 10, function()
            return plugin.search_box and H.isShown(plugin.search_box)
        end)
        H.eq("Search Library Genesis", plugin.search_box.title, "dialog title")
        H.shot("search-dialog")

        H.tapButton("Cancel")
        assert(not H.isShown(plugin.search_box), "search dialog is still open")
    end)

    it("opens search from a gesture", function()
        UIManager:sendEvent(Event:new("KindleFetch"))
        local dialog = H.waitFor("the search dialog", 10, function()
            return H.find(function(widget)
                return widget.title == "Search Library Genesis" and widget.getInputText
            end)
        end)

        H.tapButton("Cancel", dialog)
        assert(not H.isShown(dialog), "search dialog is still open")
    end)

    it("changes settings", function()
        local Settings = require("settings.settings")
        H.openMainMenu({"Kindle Fetch", "Settings"})
        H.waitFor("the settings", 10, function()
            return H.find(function(widget)
                return widget.text == "Show Book Covers: ☑"
            end)
        end)
        H.shot("settings")

        H.tap(H.find(function(widget)
            return widget.text == "Show Book Covers: ☑" and widget.onTapSelect
        end))
        H.waitFor("book covers to be turned off", 10, function()
            return H.find(function(widget)
                return widget.text == "Show Book Covers: ☐"
            end)
        end)
        H.eq(false, Settings:getShowBookCovers(), "show book covers")

        H.tap(H.find(function(widget)
            return widget.text == "Show Book Covers: ☐" and widget.onTapSelect
        end))
        H.waitFor("book covers to be turned on", 10, function()
            return Settings:getShowBookCovers()
        end)
    end)

    it("checks for updates when asked", function()
        local since = #H.notifications
        H.asDevice(function()
            H.openMainMenu({"Kindle Fetch", "Check for updates"})
            H.waitForNotification("Checking for updates", 10, since)
        end)

        -- either up to date, or offering the latest release (which isn't installed here)
        local result = H.waitFor("the update check", 60, function()
            for i = since + 1, #H.notifications do
                if H.notifications[i]:find("up to date", 1, true) then
                    return "up to date"
                end
            end
            if H.findButton("Update") then
                return "update offered"
            end
        end)
        H.shot("update-check")

        -- never update curl or the plugin from the tests
        assert(not H.find(function(widget)
            return widget.title == "Update curl?"
        end), "offered to update curl, which is recent enough in KOReader")
        if result == "update offered" then
            H.tapButton("Cancel")
        end
    end)
end)
