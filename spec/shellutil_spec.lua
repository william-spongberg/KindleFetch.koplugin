local helper = require("helper")

describe("ShellUtil", function()
    local ShellUtil

    before_each(function()
        helper.reset()
        ShellUtil = require("util.shellutil")
    end)

    it("quotes strings for the shell", function()
        assert.are.equal("'plain'", ShellUtil.quote("plain"))
        assert.are.equal("'it'\\''s'", ShellUtil.quote("it's"))
        assert.are.equal("'; rm -rf /'", ShellUtil.quote("; rm -rf /"))
    end)
end)
