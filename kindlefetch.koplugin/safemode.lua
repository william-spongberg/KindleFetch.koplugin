local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Rollback = require("updater.rollback")
local T = require("ffi/util").template
local _ = require("gettext")

-- what's left of Kindle Fetch when it can't be loaded or started (see main.lua): its menu, saying so and why, and
-- going back to the version installed before the last update, while one is kept (see Rollback). only KOReader itself
-- is used, as it may be Kindle Fetch's own modules that don't work
local SafeMode = {}

-- where the plugin is, from where this file was loaded, rather than asking PathUtil, which may be what doesn't work
local PLUGIN_PATH = debug.getinfo(1, "S").source:match("^@(.+)/safemode%.lua$")

-- swap back to the version before, once confirmed, then offer to restart KOReader, which loads it as it starts
local function goBack(previous_version)
    UIManager:show(ConfirmBox:new {
        text = T(_("Go back to Kindle Fetch v%1?"), previous_version),
        ok_text = _("Go back"),
        ok_callback = function()
            local ok, err = Rollback.goBack(PLUGIN_PATH)
            if not ok then
                UIManager:show(InfoMessage:new {
                    text = T(_("Going back failed: %1"), err),
                    icon = "notice-warning",
                })
                return
            end
            UIManager:askForRestart(
                T(_("Kindle Fetch has gone back to v%1, which KOReader will use once it restarts."), previous_version)
            )
        end,
    })
end

-- Kindle Fetch's menu, with only what's left, for the error it couldn't start with
function SafeMode.addToMainMenu(menu_items, err)
    local previous_version = PLUGIN_PATH and Rollback.previousVersion(PLUGIN_PATH)
    -- the error, without where it happened, which is in crash.log
    local reason = tostring(err):match("^[^\n]*")
    menu_items.kindlefetch = {
        text = _("Kindle Fetch"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Kindle Fetch couldn't start"),
                callback = function()
                    UIManager:show(InfoMessage:new {
                        text = T(_("Kindle Fetch couldn't start: %1\n\nSee crash.log for where."), reason),
                        icon = "notice-warning",
                    })
                end,
            },
            {
                text = previous_version and T(_("Go back to v%1"), previous_version)
                    or _("Go back to the version before"),
                -- one is only kept once Kindle Fetch has updated itself
                enabled = previous_version ~= nil,
                callback = function()
                    goBack(previous_version)
                end,
            },
        },
    }
end

-- Kindle Fetch, when it couldn't be loaded, as a plugin with only that menu
function SafeMode.new(err)
    local Plugin = WidgetContainer:extend {
        name = "kindlefetch",
        is_doc_only = false,
    }
    function Plugin:init()
        self.ui.menu:registerToMainMenu(self)
    end
    function Plugin:addToMainMenu(menu_items)
        SafeMode.addToMainMenu(menu_items, err)
    end
    return Plugin
end

-- show that menu in place of Kindle Fetch's own, when it couldn't start (registering it again, in case it went wrong
-- before it had, which, when it hadn't, only adds the same menu twice)
function SafeMode.takeOver(plugin, err)
    plugin.addToMainMenu = function(__, menu_items)
        SafeMode.addToMainMenu(menu_items, err)
    end
    if plugin.ui and plugin.ui.menu then
        plugin.ui.menu:registerToMainMenu(plugin)
    end
end

return SafeMode
