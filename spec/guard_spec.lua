local helper = require("helper")

describe("Guard", function()
    local Guard

    before_each(function()
        helper.reset()
        Guard = require("util.guard")
    end)

    after_each(helper.cleanup)

    it("returns what the function returns when nothing goes wrong", function()
        local a, b, c = Guard.call("adding", function(x, y)
            return x + y, nil, "done"
        end, nil, 1, 2)
        assert.are.equal(3, a)
        assert.is_nil(b)
        assert.are.equal("done", c)
        assert.are.equal(0, #helper.state.logs)
    end)

    -- KOReader exited on errors in what it ran later, or lost them without a trace
    it("logs what went wrong with where it happened, says so, and returns nothing", function()
        local result = Guard.call("adding", function()
            local missing = nil
            return missing.value
        end)
        assert.is_nil(result)
        local logged = helper.logged("err", "^adding went wrong:")
        assert.matches("attempt to index", logged)
        assert.matches("stack traceback", logged)
        assert.are.equal("Kindle Fetch: something went wrong, see crash.log", helper.lastError())
    end)

    it("leaves cleaning up after it, and saying so, to what was going on", function()
        local cleaned = {}
        Guard.call("downloading", function()
            error("boom")
        end, function(err)
            table.insert(cleaned, err)
        end)
        assert.are.same({ "something went wrong, see crash.log" }, cleaned)
        assert.is_nil(helper.lastError())
    end)

    it("logs what goes wrong while cleaning up, rather than raising it", function()
        Guard.call("downloading", function()
            error("boom")
        end, function()
            error("bang")
        end)
        assert.matches("bang", helper.logged("err", "^cleaning up after downloading went wrong:"))
    end)

    it("only logs what went wrong when nothing needs saying", function()
        Guard.call("checking for updates", function()
            error("boom")
        end, Guard.quiet)
        assert.is_truthy(helper.logged("err", "^checking for updates went wrong:"))
        assert.is_nil(helper.lastError())
    end)

    it("is like pcall, but logs where it went wrong", function()
        assert.are.same({ true, 1, 2 }, {
            Guard.pcall("counting", function()
                return 1, 2
            end),
        })
        local ok, err = Guard.pcall("counting", function()
            error("boom")
        end)
        assert.is_false(ok)
        assert.matches("boom", err)
        assert.matches("stack traceback", helper.logged("err", "^counting went wrong:"))
    end)

    it("wraps a function for KOReader to call later, passing on what it's called with", function()
        local handler = Guard.wrap("handling", function(self, value)
            return self.name .. value
        end)
        assert.are.equal("menu!", handler({ name = "menu" }, "!"))
    end)

    it("schedules functions that are called as it calls them", function()
        local cleaned = 0
        Guard.scheduleIn(0.5, "polling", function()
            error("boom")
        end, function()
            cleaned = cleaned + 1
        end)
        Guard.nextTick("showing", function()
            error("bang")
        end)
        assert.are.equal(2, helper.tick())
        assert.are.equal(1, cleaned)
        assert.is_truthy(helper.logged("err", "^polling went wrong:"))
        assert.are.equal("Kindle Fetch: something went wrong, see crash.log", helper.lastError())
    end)
end)
