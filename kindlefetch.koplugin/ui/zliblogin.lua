local MultiInputDialog = require("ui/widget/multiinputdialog")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local NetworkMgr = require("ui/network/manager")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local StringUtil = require("util.stringutil")
local WaitingMessage = require("ui.waitingmessage")
local ZlibAccount = require("api.zlibaccount")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

local ZlibLogin = {}

-- the email last typed in, to type it in again after a password that didn't work
local last_email

-- log in with the email and password, turning wifi on first if need be (as KOReader is set up to), and saying so
-- until Z-Library has answered, with a button to call it off. calls on_logged_in once logged in
function ZlibLogin.login(email, password, on_logged_in)
    NetworkMgr:runWhenConnected(function()
        local message
        local function closeMessage()
            if message and not message.cancelled and not message.closed then
                message.closed = true
                UIManager:close(message)
            end
        end

        -- an error is passed on rather than left to Trapper, which would lose it and leave the message up, including
        -- one in what's done once logged in
        Trapper:wrap(Guard.wrap("logging in to Z-Library", function()
            message = WaitingMessage.new(_("Logging in to Z-Library..."))
            UIManager:show(message)
            UIManager:forceRePaint()

            HttpUtil.setTrapWidget(message)
            local ok, logged_in, err =
                Guard.pcall("logging in to Z-Library", ZlibAccount.login, ZlibAccount, email, password)
            HttpUtil.setTrapWidget(nil)
            closeMessage()
            if not ok then
                logged_in, err = false, Errors.UNEXPECTED
            end

            if err == HttpUtil.CANCELLED then
                LogUtil.info("logging in to Z-Library was called off")
                return
            end
            if not logged_in then
                NotifyUtil.error(T(_("Logging in to Z-Library failed: %1"), err))
                return
            end
            NotifyUtil.info(_("Logged in to Z-Library"))
            if on_logged_in then
                on_logged_in()
            end
        end, function(err)
            HttpUtil.setTrapWidget(nil)
            closeMessage()
            Guard.say(err)
        end))
    end)
end

-- ask for the email and password of the Z-Library account to log into, and log in (see login)
function ZlibLogin.show(on_logged_in)
    local dialog
    dialog = MultiInputDialog:new {
        title = _("Log in to Z-Library"),
        fields = {
            {
                text = last_email or ZlibAccount:getEmail() or "",
                hint = _("Email"),
            },
            {
                text = "",
                hint = _("Password"),
                text_type = "password",
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Log in"),
                    -- so the keyboard's enter key logs in too
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        local email, password = StringUtil.trim(fields[1]), fields[2] or ""
                        if email == "" or password == "" then
                            NotifyUtil.info(_("Enter the email and password of your Z-Library account"))
                            return
                        end
                        last_email = email
                        UIManager:close(dialog)
                        ZlibLogin.login(email, password, on_logged_in)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return ZlibLogin
