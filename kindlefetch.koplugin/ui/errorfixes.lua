local NetworkMgr = require("ui/network/manager")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local ZlibLogin = require("ui.zliblogin")
local CurlUpdater = require("updater.curlupdater")
local CurlUtil = require("util.curlutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local Errors = require("util.errors")
local _ = require("gettext")

-- the buttons offered with an error for what fixes it (see Errors.fixOf), most then calling retry where given
local ErrorFixes = {}

-- each kind of fix, as the button that fixes it, or nil where it can't here and now
ErrorFixes.FIXES = {
    log_in = function(retry)
        return {
            text = _("Log in"),
            callback = function()
                ZlibLogin.show(retry)
            end,
        }
    end,
    update_curl = function()
        return {
            text = _("Update curl"),
            callback = function()
                CurlUpdater.checkVersion(true)
            end,
        }
    end,
    -- as the network's own DNS may be what's blocking the sites (#55)
    encrypted_dns = function(retry)
        if KindleFetchSettings:getEncryptedDns() or not CurlUtil.canUseEncryptedDns() then
            return nil
        end
        return {
            text = _("Use encrypted DNS"),
            callback = function()
                local ok, save_err = KindleFetchSettings:setEncryptedDns(true)
                if not ok then
                    NotifyUtil.error(save_err)
                    return
                end
                LogUtil.info("turned encrypted DNS on, as the network couldn't find the sites")
                if retry then
                    retry()
                end
            end,
        }
    end,
    libraries = function()
        return {
            text = _("Your Libraries…"),
            callback = function()
                SettingsPage:changeLibraries()
            end,
        }
    end,
    try_again = function(retry)
        return retry and { text = _("Try again"), callback = retry }
    end,
    -- with Wi-Fi on, trying again, as the internet may only have dropped
    connect = function(retry)
        if not retry then
            return nil
        end
        if not NetworkMgr:isWifiOn() then
            return {
                text = _("Turn on Wi-Fi"),
                callback = function()
                    NetworkMgr:runWhenConnected(retry)
                end,
            }
        end
        return { text = _("Try again"), callback = retry }
    end,
}

-- a row of buttons for what fixes err, empty where nothing does
function ErrorFixes.buttons(err, retry)
    local fix = ErrorFixes.FIXES[Errors.fixOf(err)]
    local button = fix and fix(retry)
    return button and { button } or {}
end

return ErrorFixes
