local helper = require("helper")

describe("ZlibLogin", function()
    local logins, login_result, ZlibLogin, ZlibAccount, logged_in

    -- the login dialog, as the last one shown
    local function dialog()
        for i = #helper.state.shown, 1, -1 do
            if helper.state.shown[i].fields then
                return helper.state.shown[i]
            end
        end
    end

    local function button(text)
        for _, b in ipairs(dialog().buttons[1]) do
            if b.text == text then
                return b
            end
        end
        error("no button " .. text)
    end

    -- type the email and password into the dialog, and tap Log in
    local function logIn(email, password)
        dialog().fields[1].text = email
        dialog().fields[2].text = password
        button("Log in").callback()
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        logins, login_result = {}, { true }
        logged_in = 0
        ZlibAccount = {
            email = nil,
            getEmail = function(self)
                return self.email
            end,
            login = function(_, email, password)
                table.insert(logins, { email, password })
                table.insert(logins, require("util.httputil").getTrapWidget() or false)
                if type(login_result) == "function" then
                    return login_result()
                end
                return login_result[1], login_result[2]
            end,
        }
        helper.stub("api.zlibaccount", ZlibAccount)
        local trap_widget
        helper.stub("util.httputil", {
            CANCELLED = "request cancelled",
            canCancel = function()
                return true
            end,
            setTrapWidget = function(widget)
                trap_widget = widget
            end,
            getTrapWidget = function()
                return trap_widget
            end,
        })
        ZlibLogin = require("ui.zliblogin")
    end)

    after_each(helper.cleanup)

    local function onLoggedIn()
        logged_in = logged_in + 1
    end

    it("asks for the email and password, hiding the password", function()
        ZlibLogin.show(onLoggedIn)

        assert.are.equal("Log in to Z-Library", dialog().title)
        assert.are.equal("Email", dialog().fields[1].hint)
        assert.are.equal("Password", dialog().fields[2].hint)
        assert.are.equal("password", dialog().fields[2].text_type)
        assert.is_true(dialog().keyboard_shown)
        assert.is_true(button("Log in").is_enter_default)
    end)

    it("logs in, saying so while it waits, with a button to call it off", function()
        ZlibLogin.show(onLoggedIn)
        local login_dialog = dialog()
        logIn("  reader@example.com ", "p4ss word")

        assert.are.same({ "reader@example.com", "p4ss word" }, logins[1])
        -- shown until Z-Library has answered
        local message = logins[2]
        assert.are.equal("Logging in to Z-Library...", message.title)
        assert.are.equal("Cancel", message.buttons[1][1].text)
        assert.is_true(helper.wasClosed(message))
        assert.is_true(helper.wasClosed(login_dialog))

        assert.are.equal(1, logged_in)
        assert.are.equal("Logged in to Z-Library", helper.lastNotification())
    end)

    it("asks for both the email and the password", function()
        ZlibLogin.show(onLoggedIn)
        logIn("reader@example.com", "")

        assert.are.same({}, logins)
        assert.are.equal("Enter the email and password of your Z-Library account", helper.lastNotification())
        assert.is_false(helper.wasClosed(dialog()))
    end)

    it("says why it couldn't log in, and offers the email again", function()
        login_result = { false, "Z-Library says: Incorrect email or password" }
        ZlibLogin.show(onLoggedIn)
        logIn("reader@example.com", "wrong")

        assert.are.equal(0, logged_in)
        assert.are.equal(
            "Couldn't log in to Z-Library: Z-Library says: Incorrect email or password",
            helper.lastError()
        )

        ZlibLogin.show(onLoggedIn)
        assert.are.equal("reader@example.com", dialog().fields[1].text)
        assert.are.equal("", dialog().fields[2].text)
    end)

    it("offers the email of the account logged into", function()
        ZlibAccount.email = "reader@example.com"
        ZlibLogin.show(onLoggedIn)
        assert.are.equal("reader@example.com", dialog().fields[1].text)
    end)

    it("does nothing more once it's called off", function()
        login_result = { false, "request cancelled" }
        ZlibLogin.show(onLoggedIn)
        logIn("reader@example.com", "p4ssword")

        assert.are.equal(0, logged_in)
        assert.is_nil(helper.lastError())
        assert.is_truthy(helper.logged("info", "^logging in to Z%-Library was called off$"))
    end)

    -- which was lost, as Trapper drops what goes wrong once its function has waited on something
    it("says when what's done once logged in goes wrong", function()
        ZlibLogin.show(function()
            error("unexpected")
        end)
        logIn("reader@example.com", "secret")

        assert.are.equal("Kindle Fetch: something went wrong, see crash.log", helper.lastError())
        assert.is_truthy(helper.logged("err", "^logging in to Z%-Library went wrong:.*unexpected"))
    end)

    it("says when something went wrong, rather than leaving the message up", function()
        login_result = function()
            error("boom")
        end
        ZlibLogin.show(onLoggedIn)
        logIn("reader@example.com", "p4ssword")

        assert.is_true(helper.wasClosed(logins[2]))
        assert.are.equal("Couldn't log in to Z-Library: something went wrong, see crash.log", helper.lastError())
    end)

    it("turns wifi on first if need be", function()
        helper.stubs.network.connected = false
        ZlibLogin.show(onLoggedIn)
        logIn("reader@example.com", "p4ssword")
        assert.are.same({}, logins)

        helper.stubs.network.connected = true
        helper.stubs.network.when_connected()
        assert.are.same({ "reader@example.com", "p4ssword" }, logins[1])
        assert.are.equal(1, logged_in)
    end)
end)
