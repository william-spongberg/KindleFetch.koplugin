local helper = require("helper")

describe("the transports", function()
    local HttpUtil, CurlVersion, CurlTransport, KoreaderTransport

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        HttpUtil = require("util.httputil")
        CurlVersion = require("util.curlversion")
        CurlTransport = require("util.curltransport")
        KoreaderTransport = require("util.koreadertransport")
    end)

    after_each(helper.cleanup)

    it("can each fetch a page, and download a file, or many in the background", function()
        for __, transport in ipairs({ CurlTransport, KoreaderTransport }) do
            for __, name in ipairs({ "fetchPage", "download", "startDownload", "startDownloadMany" }) do
                assert.is_function(transport[name], name)
            end
        end
    end)

    it("go by curl where it can fetch, otherwise by KOReader's own HTTP", function()
        local can_fetch = true
        CurlVersion.canFetch = function()
            return can_fetch
        end
        assert.are.equal(CurlTransport, HttpUtil.transport())
        can_fetch = false
        assert.are.equal(KoreaderTransport, HttpUtil.transport())
    end)
end)
