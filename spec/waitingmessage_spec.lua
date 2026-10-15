local helper = require("helper")

describe("WaitingMessage", function()
    local WaitingMessage, CurlUtil

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        CurlUtil = require("util.curlutil")
        WaitingMessage = require("ui.waitingmessage")
    end)

    after_each(helper.cleanup)

    -- e.g. which of a site's mirrors is being tried, so a wait that takes a while doesn't look stuck
    describe("says what's being waited for now beneath what it says", function()
        it("with a Cancel button, where the wait can be called off", function()
            CurlUtil.canFetch = function()
                return true
            end
            local message = WaitingMessage.new("Searching Library Genesis...")

            message:setStatus("Trying libgen.li (mirror 1 of 2)...")
            assert.are.equal("Searching Library Genesis...\n\nTrying libgen.li (mirror 1 of 2)...", message.title)
        end)

        it("without one, where it can't", function()
            CurlUtil.canFetch = function()
                return false
            end
            local message = WaitingMessage.new("Searching Library Genesis...")

            message:setStatus("Trying libgen.li (mirror 1 of 2)...")
            assert.are.equal("Searching Library Genesis...\n\nTrying libgen.li (mirror 1 of 2)...", message.text)
        end)
    end)

    -- as it's about to say something else or close, and laying it out again in between would only flash
    it("keeps saying the last, rather than going back to what it said before", function()
        CurlUtil.canFetch = function()
            return true
        end
        local message = WaitingMessage.new("Searching Library Genesis...")

        message:setStatus("Looking up Library Genesis mirrors...")
        message:setStatus(nil)
        assert.are.equal("Searching Library Genesis...\n\nLooking up Library Genesis mirrors...", message.title)
    end)

    it("says nothing more once it has closed", function()
        CurlUtil.canFetch = function()
            return true
        end
        local message = WaitingMessage.new("Searching Library Genesis...")
        message.closed = true

        message:setStatus("Trying libgen.li (mirror 1 of 2)...")
        assert.are.equal("Searching Library Genesis...", message.title)
    end)
end)
