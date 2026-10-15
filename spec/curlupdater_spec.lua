local helper = require("helper")

describe("CurlUpdater", function()
    local data_dir, CurlUtil, HttpUtil, CurlUpdater

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
        HttpUtil = require("util.httputil")
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
            installedCurl("8.21.0")
            assert.is_true(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)

        it("accepts curl above the minimum version", function()
            installedCurl("8.22.1")
            assert.is_true(CurlUpdater.checkVersion())
            assert.are.equal(0, #helper.state.shown)
        end)

        it("offers to update an older curl", function()
            installedCurl("7.68.0")
            CurlUpdater.checkVersion()

            local dialog = helper.state.shown[1]
            assert.are.equal("Update curl?", dialog.title)
            assert.matches("curl v7.68.0 is installed.\nMinimum required: v8.21.0", dialog.input, 1, true)
            -- saying what it's needed for
            assert.matches("searches are slower", dialog.input, 1, true)
        end)

        describe("once updating curl is turned down", function()
            before_each(function()
                installedCurl("7.68.0")
                CurlUpdater.checkVersion()
                helper.state.shown[1].buttons[1][1].callback()
            end)

            -- it was asked on every start before (#25)
            it("doesn't offer it again", function()
                assert.is_true(require("settings.settings"):getCurlUpdateDeclined())

                assert.is_false(CurlUpdater.checkVersion())
                assert.are.equal(1, #helper.state.shown)
                assert.is_truthy(
                    helper.logged("warn", "^curl 7.68.0 is older than 8.21.0, but updating it was turned down")
                )
            end)

            it("offers it again when the user asks to check for updates", function()
                CurlUpdater.checkVersion(true)
                assert.are.equal(2, #helper.state.shown)
                assert.are.equal("Update curl?", helper.state.shown[2].title)
            end)
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

        -- record the install commands instead of running them, failing the ones listed in failures as the storage
        -- filling up would
        local function stubInstall(failures)
            failures = failures or {}
            commands = {}
            local steps = {
                chmod = "chmod +x",
                remount_rw = "mntroot rw",
                remount_ro = "mntroot ro",
                backup = "cp '/usr/bin/curl' '/usr/bin/curl.system.bak.new' && mv",
                remove_backup = "rm -f '/usr/bin/curl.system.bak.new'",
                copy = "/curl-armhf' '/usr/bin/curl.new'",
                permissions = "chmod 755 '/usr/bin/curl.new'",
                remove_new = "rm -f '/usr/bin/curl.new'",
                replace = "mv '/usr/bin/curl.new' '/usr/bin/curl'",
            }
            for step, pattern in pairs(steps) do
                helper.stubCommand(pattern, function()
                    table.insert(commands, step)
                    return failures[step] and "cp: write error: No space left on device\nexit 1\n" or "exit 0\n"
                end)
            end
        end

        local function acceptUpdate()
            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            helper.lastShown().buttons[1][2].callback()
        end

        -- what the new curl says when asked its version, before it replaces the old one
        local function newCurlSays(output)
            helper.stubCommand("'/usr/bin/curl.new' --version", output)
        end

        before_each(function()
            HttpUtil.downloadFile = function(_, filepath)
                helper.writeFile(filepath, "curl binary")
                return true
            end
            -- as if this were the build that was released, which runs
            CurlUpdater.SHA256 = require("ffi/sha2").sha256("curl binary")
            newCurlSays("curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n")
            -- the Kindle's own curl hasn't been backed up yet
            helper.state.fs["/usr/bin/curl.system.bak"] = false
        end)

        it("backs up the system curl, then installs the static build", function()
            stubInstall()
            acceptUpdate()

            assert.are.same(
                { "chmod", "remount_rw", "backup", "copy", "permissions", "replace", "remount_ro" },
                commands
            )
            assert.are.equal("Updated curl to v8.21.0", helper.lastNotification())
            assert.is_false(helper.exists(data_dir .. "/cache/kindlefetch/curl-armhf"))
        end)

        it("keeps an existing backup of the system curl", function()
            helper.state.fs["/usr/bin/curl.system.bak"] = "file"
            stubInstall()
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw", "copy", "permissions", "replace", "remount_ro" }, commands)
        end)

        -- e.g. once a Kindle update has put the old curl back
        it("offers to update again later, even if it was turned down before", function()
            stubInstall()
            require("settings.settings"):setCurlUpdateDeclined(true)
            installedCurl("7.68.0")
            CurlUpdater.checkVersion(true)
            helper.lastShown().buttons[1][2].callback()

            assert.is_false(require("settings.settings"):getCurlUpdateDeclined())
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
            assert.are.equal(
                "Updating curl failed: the new curl couldn't be made executable (cp: write error: No space left on "
                    .. "device)",
                helper.lastError()
            )
        end)

        it("stops when the root filesystem cannot be made writable", function()
            stubInstall({ remount_rw = true })
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw" }, commands)
            assert.matches(
                "^Updating curl failed: the Kindle's system files couldn't be made writable",
                helper.lastError()
            )
            assert.is_false(helper.exists(data_dir .. "/cache/kindlefetch/curl-armhf"))
        end)

        -- which was trusted once it was there, though it may have been cut short
        it("keeps no backup that was cut short, making the root filesystem read-only again", function()
            stubInstall({ backup = true })
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw", "backup", "remove_backup", "remount_ro" }, commands)
            assert.are.equal(
                "Updating curl failed: the Kindle's own curl couldn't be backed up (cp: write error: No space left on "
                    .. "device)",
                helper.lastError()
            )
        end)

        -- which left the old one cut short, and no curl that would run, when copied straight over it
        it("leaves the old curl as it was when the new one can't be copied into place", function()
            stubInstall({ copy = true })
            acceptUpdate()

            assert.are.same({ "chmod", "remount_rw", "backup", "copy", "remove_new", "remount_ro" }, commands)
            assert.are.equal(
                "Updating curl failed: the new curl couldn't be copied into place (cp: write error: No space left on "
                    .. "device)",
                helper.lastError()
            )
            assert.is_nil(helper.lastNotification())
        end)

        it("leaves the old curl as it was when it can't be replaced", function()
            stubInstall({ replace = true })
            acceptUpdate()

            assert.are.same(
                { "chmod", "remount_rw", "backup", "copy", "permissions", "replace", "remove_new", "remount_ro" },
                commands
            )
            assert.matches("^Updating curl failed: the old curl couldn't be replaced", helper.lastError())
        end)

        -- as it had, rather than that it hadn't, and with one message, rather than two
        it("says curl has updated when only making the root filesystem read-only again fails", function()
            stubInstall({ remount_ro = true })
            acceptUpdate()
            assert.are.equal("Updated curl to v8.21.0", helper.lastNotification())
            assert.is_nil(helper.lastError())
            assert.is_truthy(
                helper.logged("warn", "^installed static curl, but the root file system is still writable")
            )
        end)

        it("says only why it failed when making the root filesystem read-only again fails too", function()
            stubInstall({ copy = true, remount_ro = true })
            acceptUpdate()
            local errors = 0
            for _, widget in ipairs(helper.state.shown) do
                errors = errors + (widget.icon == "notice-warning" and 1 or 0)
            end
            assert.are.equal(1, errors)
            assert.matches("^Updating curl failed: the new curl couldn't be copied", helper.lastError())
        end)

        -- so searches use it straight away, rather than KOReader's own HTTP until KOReader restarts
        it("looks up curl's version again once it has installed the new one", function()
            stubInstall()
            acceptUpdate()

            helper.stubCommand(
                "curl --version",
                "curl 8.21.0 (arm-unknown-linux-musleabihf) libcurl/8.21.0 OpenSSL/3.5.7 zlib/1.3.1\n"
            )
            assert.is_true(CurlUtil.canFetch())
            assert.are.equal("8.21.0", CurlUtil.getVersion())
        end)

        -- as it's run as root once installed
        it("only installs the build that was released", function()
            stubInstall()
            HttpUtil.downloadFile = function(_, filepath)
                helper.writeFile(filepath, "something else")
                return true
            end
            acceptUpdate()

            assert.are.same({}, commands)
            assert.is_false(helper.exists(data_dir .. "/cache/kindlefetch/curl-armhf"))
            assert.are.equal(
                "Updating curl failed: curl couldn't be downloaded (what downloaded isn't the curl 8.21.0 that was "
                    .. "released)",
                helper.lastError()
            )
        end)

        -- so there's still a curl that runs, rather than putting the old one back once it has been replaced
        it("keeps the old curl when the new one doesn't run on this Kindle", function()
            stubInstall()
            newCurlSays("/usr/bin/curl.new: line 1: syntax error: unexpected word\n")
            acceptUpdate()

            assert.are.same(
                { "chmod", "remount_rw", "backup", "copy", "permissions", "remove_new", "remount_ro" },
                commands
            )
            assert.are.equal(
                "Updating curl failed: the new curl doesn't run on this Kindle, so the old one has been kept",
                helper.lastError()
            )
            -- saying what it said instead, for crash.log
            assert.is_truthy(helper.logged("warn", "^the new curl doesn't run on this Kindle, saying .*syntax error"))
            assert.is_nil(helper.lastNotification())
        end)

        it("carries on when the new curl's permissions cannot be set", function()
            stubInstall({ permissions = true })
            acceptUpdate()
            assert.are.equal("Updated curl to v8.21.0", helper.lastNotification())
        end)
    end)

    describe("updating", function()
        -- with KOReader's own HTTP, as the Kindle's own curl is too old to connect to GitHub (#57)
        it("downloads the static curl build into the plugin's tmp dir, saying why it couldn't", function()
            local download
            HttpUtil.downloadFile = function(url, filepath)
                download = {
                    url = url,
                    filepath = filepath,
                }
                return nil, "could not resolve host"
            end

            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            helper.state.shown[1].buttons[1][2].callback()

            assert.are.same({
                url = "https://github.com/moparisthebest/static-curl/releases/download/v8.21.0/curl-armhf",
                filepath = data_dir .. "/cache/kindlefetch/curl-armhf",
            }, download)
            assert.are.equal(
                "Updating curl failed: curl couldn't be downloaded (could not resolve host)",
                helper.lastError()
            )
        end)

        -- so a newer curl isn't asked for without its SHA-256, which no Kindle would then install
        it("knows the SHA-256 of the static curl build on GitHub", function()
            helper.stubs.http.request = helper.useLiveHttp().request
            local path = data_dir .. "/curl-armhf"
            local url = string.format(
                "https://github.com/moparisthebest/static-curl/releases/download/v%s/curl-armhf",
                CurlUtil.MIN_VERSION
            )

            assert.is_true(HttpUtil.downloadFile(url, path))
            assert.are.equal(CurlUpdater.SHA256, require("ffi/sha2").sha256(helper.readFile(path)))
        end)

        -- which holds KOReader up until it has
        it("says it's downloading curl until it has", function()
            local message
            HttpUtil.downloadFile = function()
                message = helper.lastShown()
                return nil, "request timed out"
            end

            installedCurl("7.68.0")
            CurlUpdater.checkVersion()
            helper.state.shown[1].buttons[1][2].callback()

            assert.are.equal("Downloading curl 8.21.0...", message.text)
            assert.is_true(helper.wasClosed(message))
        end)
    end)
end)
