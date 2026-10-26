local helper = require("helper")

describe("BackgroundTask", function()
    local BackgroundTask, HttpUtil, Errors

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        BackgroundTask = require("ui.backgroundtask")
        HttpUtil = require("util.httputil")
        Errors = require("util.errors")
    end)

    after_each(helper.cleanup)

    describe("run", function()
        it("runs work with its trap, letting go of it before passing on what work returned", function()
            local trap, trapped, done = {}, nil, nil
            BackgroundTask.run("testing", trap, function()
                trapped = HttpUtil.getTrapWidget()
                return 1, nil, 3
            end, function(...)
                done = { n = select("#", ...), HttpUtil.getTrapWidget(), ... }
            end)
            assert.are.equal(trap, trapped)
            assert.are.same({ n = 3, nil, 1, nil, 3 }, done)
        end)

        it("says what went wrong, letting go of its trap, or has on_error say it", function()
            BackgroundTask.run("testing", {}, function()
                error("broken")
            end)
            assert.is_nil(HttpUtil.getTrapWidget())
            assert.is_truthy(helper.lastError():find(Errors.UNEXPECTED, 1, true))

            local said
            BackgroundTask.run("testing", {}, function() end, function()
                error("broken")
            end, function(err)
                said = err
            end)
            assert.are.equal(Errors.UNEXPECTED, said)
        end)
    end)

    describe("withMessage", function()
        it("says what's waited for until work is done, then closes it before on_done and finally", function()
            local message, steps = nil, {}
            BackgroundTask.withMessage("testing", "Waiting for the test...", function()
                message = helper.lastShown()
                table.insert(steps, "work")
                assert.are.equal(message, HttpUtil.getTrapWidget())
                return "done"
            end, function(result)
                table.insert(steps, result)
                assert.is_true(helper.wasClosed(message))
                assert.is_nil(HttpUtil.getTrapWidget())
            end, function()
                table.insert(steps, "finally")
            end)
            assert.are.same({ "work", "finally", "done" }, steps)
            assert.is_truthy(message)
            assert.is_true(message.closed)
        end)

        it("closes the message and says what went wrong, after finally", function()
            local message, finished
            BackgroundTask.withMessage("testing", "Waiting for the test...", function()
                message = helper.lastShown()
                error("broken")
            end, function()
                error("on_done shouldn't be called")
            end, function()
                finished = true
            end)
            assert.is_true(helper.wasClosed(message))
            assert.is_true(finished)
            assert.is_truthy(helper.lastError():find(Errors.UNEXPECTED, 1, true))
        end)

        -- as Cancel has closed it already
        it("leaves a message that was called off as it is", function()
            local message
            BackgroundTask.withMessage("testing", "Waiting for the test...", function()
                message = helper.lastShown()
                message.cancelled = true
                return nil, HttpUtil.CANCELLED
            end)
            assert.is_false(helper.wasClosed(message))
            assert.is_nil(message.closed)
        end)
    end)
end)
