local helper = require("helper")

describe("ErrorFixes", function()
    local ErrorFixes, Errors, logins

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        logins = {}
        helper.stub("ui.zliblogin", {
            show = function(on_logged_in)
                table.insert(logins, on_logged_in)
            end,
        })
        ErrorFixes = require("ui.errorfixes")
        Errors = require("util.errors")
    end)

    after_each(helper.cleanup)

    it("has a fix of every kind an error says fixes it", function()
        for name, err in pairs(Errors) do
            if type(err) == "string" and Errors.fixOf(err) then
                assert.is_function(ErrorFixes.FIXES[Errors.fixOf(err)], name)
            end
        end
    end)

    it("offers what fixes an error, which then tries again", function()
        local retry = function() end
        local buttons = ErrorFixes.buttons(Errors.LOGGED_OUT, retry)
        assert.are.equal(1, #buttons)
        assert.are.equal("Log in", buttons[1].text)
        buttons[1].callback()
        assert.are.same({ retry }, logins)
    end)

    it("offers nothing for an error nothing fixes, or a fix that needs trying again without a way to", function()
        assert.are.same({}, ErrorFixes.buttons(Errors.BUSY, function() end))
        assert.are.same({}, ErrorFixes.buttons("the site said no", function() end))
        assert.are.same({}, ErrorFixes.buttons(nil))
        assert.are.same({}, ErrorFixes.buttons(Errors.LIBRARY_UNREACHABLE))
    end)

    it("turns Wi-Fi on before trying again, where it's off", function()
        local retry = function() end
        assert.are.equal("Try again", ErrorFixes.buttons(Errors.NO_CONNECTION, retry)[1].text)
        require("ui/network/manager").wifi_on = false
        assert.are.equal("Turn on Wi-Fi", ErrorFixes.buttons(Errors.NO_CONNECTION, retry)[1].text)
    end)
end)
