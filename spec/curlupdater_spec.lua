local helper = require("helper")

describe("CurlUpdater", function()
    local data_dir, CurlUtil, CurlUpdater

    local function installedCurl(version)
        helper.stubCommand(
            "curl --version",
            string.format(
                "curl %s (arm-kindle-linux-gnueabi) libcurl/%s OpenSSL/1.0.2\nRelease-Date: 2020-01-08\n",
                version,
                version
            )
        )
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
        -- installing curl uses mntroot, which only Kindles have (#1)
        it("skips the check on devices other than Kindles", function()
            helper.stubs.device.kindle = false
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

        it("fails when the curl version cannot be read", function()
            helper.stubCommand("curl --version", "curl . (unknown)\n")
            assert.is_false(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)

        it("fails when curl is not installed", function()
            helper.stubCommand("curl --version", "")
            assert.is_false(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)
    end)

    describe("installing", function()
        local commands

        -- record the install commands instead of running them, failing the ones listed in failures
        -- (find_backup failing means the system curl has not been backed up yet)
        local function stubInstall(failures)
            failures = failures or {}
            commands = {}
            local steps = {
                chmod = "chmod +x",
                remount_rw = "mntroot rw",
                remount_ro = "mntroot ro",
                find_backup = "test -f '/usr/bin/curl.system.bak'",
                backup = "cp '/usr/bin/curl' '/usr/bin/curl.system.bak'",
                install = "/curl-armhf' '/usr/bin/curl'",
                permissions = "chmod 755 '/usr/bin/curl'",
            }
            for step, pattern in pairs(steps) do
                helper.stubExecute(pattern, function()
                    table.insert(commands, step)
                    return failures[step] and 256 or 0
                end)
            end
        end

        local function acceptUpdate()
            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            helper.lastShown().buttons[1][2].callback()
        end

        before_each(function()
            CurlUtil.download = function(_, filepath)
                helper.writeFile(filepath, "curl binary")
                return true
            end
        end)

        it("backs up the system curl, then installs the static build", function()
            stubInstall({ find_backup = true })
            acceptUpdate()

            assert.are.same(
                { "chmod", "remount_rw", "find_backup", "backup", "install", "permissions", "remount_ro" },
                commands
            )
            assert.are.equal("Updated curl to v8.17.0", helper.lastNotification())
        end)

        it("keeps an existing backup of the system curl", function()
            stubInstall()
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw", "find_backup", "install", "permissions", "remount_ro" }, commands)
        end)

        it("does nothing when the user cancels", function()
            stubInstall()
            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            local dialog = helper.lastShown()
            dialog.buttons[1][1].callback()

            assert.is_true(helper.wasClosed(dialog))
            assert.are.same({}, commands)
        end)

        it("removes the download when it cannot be made executable", function()
            stubInstall({ chmod = true })
            acceptUpdate()

            assert.are.same({ "chmod" }, commands)
            assert.is_false(helper.exists(data_dir .. "/cache/kindlefetch/curl-armhf"))
            assert.are.equal("Failed to set file permissions", helper.lastNotification())
        end)

        it("stops when the root filesystem cannot be made writable", function()
            stubInstall({ remount_rw = true })
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw" }, commands)
            assert.are.equal("Failed to remount root as read-write", helper.lastNotification())
        end)

        it("makes the root filesystem read-only again when the backup fails", function()
            stubInstall({ find_backup = true, backup = true })
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw", "find_backup", "backup", "remount_ro" }, commands)
            assert.are.equal("Failed to create curl backup", helper.lastNotification())
        end)

        it("makes the root filesystem read-only again when installing fails", function()
            stubInstall({ install = true })
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw", "find_backup", "install", "remount_ro" }, commands)
            assert.are.equal("Failed to install new curl update", helper.lastNotification())
        end)

        it("reports when the root filesystem cannot be made read-only again", function()
            stubInstall({ install = true, remount_ro = true })
            acceptUpdate()
            assert.are.equal("Failed to remount root as read-only", helper.lastNotification())

            stubInstall({ remount_ro = true })
            acceptUpdate()
            assert.are.equal("Failed to remount root as read-only", helper.lastNotification())
        end)

        it("carries on when the installed curl's permissions cannot be set", function()
            stubInstall({ permissions = true })
            acceptUpdate()
            assert.are.equal("Updated curl to v8.17.0", helper.lastNotification())
        end)
    end)

    describe("updating", function()
        it("downloads the static curl build into the plugin's tmp dir", function()
            local download
            CurlUtil.download = function(url, filepath)
                download = {
                    url = url,
                    filepath = filepath,
                }
                return false, "could not resolve host"
            end

            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            helper.state.shown[1].buttons[1][2].callback()

            assert.are.same({
                url = "https://github.com/moparisthebest/static-curl/releases/download/v8.17.0/curl-armhf",
                filepath = data_dir .. "/cache/kindlefetch/curl-armhf",
            }, download)
            assert.are.equal("Failed to download curl update", helper.lastNotification())
        end)
    end)
end)
