local helper = require("helper")

describe("CurlUpdater", function()
    local data_dir, CurlUtil, CurlUpdater

    local function installedCurl(version)
        helper.stubCommand("curl --version",
            string.format("curl %s (arm-kindle-linux-gnueabi) libcurl/%s OpenSSL/1.0.2\nRelease-Date: 2020-01-08\n",
                version, version))
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        CurlUtil = require("util.curlutil")
        CurlUpdater = require("updater.curlupdater")
    end)

    after_each(helper.cleanup)

    describe("checkVersion", function()
        it("skips the check in the emulator", function()
            helper.stubs.device.sdl = true
            assert.is_true(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.popen_calls)
        end)

        it("skips the check on android", function()
            helper.stubs.device.android = true
            assert.is_true(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.popen_calls)
        end)

        it("accepts curl at the minimum version", function()
            installedCurl("8.17.0")
            assert.is_true(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)

        it("accepts curl above the minimum version", function()
            installedCurl("8.20.1")
            assert.is_true(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)

        it("offers to update an older curl", function()
            installedCurl("7.68.0")
            CurlUpdater.checkVersion()

            local dialog = helper.state.shown[1]
            assert.are.equal("Update curl?", dialog.title)
            assert.matches("curl v7.68.0 is installed.\nMinimum required: v8.17.0", dialog.input, 1, true)
        end)

        it("fails when curl is not installed", function()
            helper.stubCommand("curl --version", "")
            assert.is_false(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)
    end)

    describe("updating", function()
        it("downloads the static curl build into the plugin's tmp dir", function()
            local download
            CurlUtil.download = function(url, filepath)
                download = {
                    url = url,
                    filepath = filepath
                }
                return false, "could not resolve host"
            end

            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            helper.state.shown[1].buttons[1][2].callback()

            assert.are.same({
                url = "https://github.com/moparisthebest/static-curl/releases/download/v8.17.0/curl-armhf",
                filepath = data_dir .. "/cache/kindlefetch/curl-armhf"
            }, download)
            assert.are.equal("Failed to download curl update", helper.lastNotification())
        end)
    end)
end)
