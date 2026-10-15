local helper = require("helper")

describe("ProxyUtil", function()
    local ProxyUtil

    before_each(function()
        helper.reset()
        ProxyUtil = require("util.proxyutil")
    end)

    -- as it's in use, whether turned on in KOReader's network settings or Kindle Fetch's, or set in its defaults
    it("goes through KOReader's HTTP proxy, where it's on", function()
        assert.is_nil(ProxyUtil.get())
        helper.stubs.http.PROXY = ""
        assert.is_nil(ProxyUtil.get())

        helper.stubs.http.PROXY = "http://koreader.example:3128"
        assert.are.equal("http://koreader.example:3128", ProxyUtil.get())
    end)

    -- which can have a password in it
    it("says which proxy it is without who it's logged into as", function()
        assert.are.equal("http://proxy.example:8080", ProxyUtil.describe("http://reader:secret@proxy.example:8080"))
        assert.are.equal("socks5h://proxy.example", ProxyUtil.describe("socks5h://proxy.example"))
    end)
end)
