local helper = require("helper")

-- trimmed down response from https://api.github.com/repos/william-spongberg/KindleFetch.koplugin/releases/latest
local LATEST_RELEASE = [[{
  "html_url": "https://github.com/william-spongberg/KindleFetch.koplugin/releases/tag/%s",
  "tag_name": "%s",
  "name": "%s",
  "body": "Bug fixes\r\n- fixed updates on android"
}]]

-- where KOReader keeps its data and user plugins on each kind of device
local LAYOUTS = {
    {
        name = "kindle/kobo",
        absolute = false, -- data dir is "."
        plugins_dir = "/plugins/",
    },
    {
        name = "android",
        absolute = true, -- data dir is "/sdcard/koreader", plugins are found through "<data dir>/plugins/"
        plugins_dir = "/plugins//",
    },
}

for _, layout in ipairs(LAYOUTS) do
    describe("PluginUpdater on " .. layout.name, function()
        local data_dir, plugin_path, CurlUtil, PluginUpdater, Settings
        -- github's answer when asked for the latest release (nil when it can't be reached), and each time it was asked
        local release_response, release_lookups
        -- how the release itself is downloaded, set by the specs about updating
        local downloadRelease

        local function latestRelease(tag)
            release_response = LATEST_RELEASE:format(tag, tag, tag)
        end

        -- check for updates, and wait for the latest release to be looked up in the background
        local function checkForUpdates(user_requested)
            PluginUpdater.checkForUpdates(user_requested)
            helper.runScheduled()
        end

        before_each(function()
            helper.reset()
            data_dir = helper.tmpdir("data")
            if layout.absolute then
                data_dir = helper.abs(data_dir)
            end
            helper.state.data_dir = data_dir

            -- load PathUtil from an installed copy of the plugin, so updates never touch this repository
            plugin_path = data_dir .. layout.plugins_dir .. "kindlefetch.koplugin"
            helper.stub("util.pathutil", helper.loadPluginFileFrom(plugin_path, "util/pathutil.lua"))
            helper.writeFile(plugin_path .. "/version.txt", "0.3\n")

            helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))

            CurlUtil = require("util.curlutil")
            Settings = require("settings.settings")
            PluginUpdater = require("updater.pluginupdater")

            -- pretend to be curl, which looks up the latest release in the background and has finished by the
            -- time it's checked on
            release_response, release_lookups = nil, {}
            downloadRelease = function(url)
                error("unexpected download of " .. url)
            end
            CurlUtil.download = function(url, filepath, use_proxy, background, max_time)
                if not url:find("/releases/latest", 1, true) then
                    return downloadRelease(url, filepath)
                end
                table.insert(release_lookups, {
                    url = url,
                    background = background,
                    max_time = max_time,
                })
                local exit_file = CurlUtil.createExitFile()
                if release_response then
                    helper.writeFile(filepath, release_response)
                end
                helper.writeFile(exit_file, release_response and "0" or "6")
                return 4000, exit_file
            end
            CurlUtil.isPidRunning = function()
                return false
            end
        end)

        after_each(helper.cleanup)

        describe("checkForUpdates", function()
            it("does nothing when the installed version is the latest", function()
                latestRelease("v0.3")
                checkForUpdates()
                assert.are.equal(0, #helper.state.shown)
            end)

            it("does nothing when the installed version is newer", function()
                helper.writeFile(plugin_path .. "/version.txt", "0.10\n")
                latestRelease("v0.9")
                checkForUpdates()
                assert.are.equal(0, #helper.state.shown)
            end)

            it("offers newer releases along with their release notes", function()
                latestRelease("v0.4")
                checkForUpdates()

                local dialog = helper.state.shown[1]
                assert.are.equal("Update KindleFetch?", dialog.title)
                assert.matches("KindleFetch v0.3 is installed.", dialog.input, 1, true)
                assert.matches("New version available: v0.4", dialog.input, 1, true)
                assert.matches("Bug fixes\n- fixed updates on android", dialog.input, 1, true)
            end)

            -- KOReader is in use while it checks, e.g. just after starting
            it("looks up the latest release in the background, for at most 15 seconds", function()
                latestRelease("v0.4")
                PluginUpdater.checkForUpdates()

                assert.are.same({
                    {
                        url = "https://api.github.com/repos/william-spongberg/KindleFetch.koplugin/releases/latest",
                        background = true,
                        max_time = 15,
                    },
                }, release_lookups)
                assert.are.equal(0, #helper.state.shown)

                helper.runScheduled()
                assert.are.equal("Update KindleFetch?", helper.state.shown[1].title)
            end)

            it("waits for curl to finish looking up the latest release", function()
                local exit_file, release_file
                CurlUtil.download = function(_, filepath)
                    release_file = filepath
                    exit_file = CurlUtil.createExitFile()
                    return 4000, exit_file
                end
                CurlUtil.isPidRunning = function()
                    return true
                end
                PluginUpdater.checkForUpdates()

                helper.tick()
                helper.tick()
                assert.are.equal(0, #helper.state.shown)

                helper.writeFile(release_file, LATEST_RELEASE:format("v0.4", "v0.4", "v0.4"))
                helper.writeFile(exit_file, "0")
                helper.runScheduled()
                assert.are.equal("Update KindleFetch?", helper.state.shown[1].title)
                assert.is_false(helper.exists(release_file))
            end)

            it("reads release notes with quotes in them", function()
                release_response = [[{"tag_name": "v0.4", "body": "Fixed \"Load more\"\r\n- and \"Read now\""}]]
                checkForUpdates()

                assert.matches('Fixed "Load more"\n- and "Read now"', helper.state.shown[1].input, 1, true)
            end)

            it("offers updates without release notes", function()
                release_response = '{"tag_name": "v0.4", "body": ""}'
                checkForUpdates()
                assert.matches("New version available: v0.4", helper.state.shown[1].input, 1, true)

                release_response = '{"tag_name": "v0.4", "body": null}'
                checkForUpdates()
                assert.matches("New version available: v0.4", helper.state.shown[2].input, 1, true)
            end)

            it("treats a missing version file as 0.0.0", function()
                os.remove(plugin_path .. "/version.txt")
                latestRelease("v0.3")
                checkForUpdates()

                assert.matches("KindleFetch v0.0.0 is installed.", helper.state.shown[1].input, 1, true)
            end)

            it("quietly gives up when the latest release cannot be fetched", function()
                checkForUpdates(false)
                assert.are.equal(0, #helper.state.shown)
                assert.are.equal(0, #helper.state.notifications)
                assert.is_nil(helper.lastError())
                assert.matches(
                    "curl exit code 6 %(could not resolve host%)",
                    helper.logged("warn", "^could not look up")
                )
            end)

            it("reports when the latest release cannot be fetched, if the user asked", function()
                checkForUpdates(true)
                assert.are.equal("Failed to fetch updates for KindleFetch", helper.lastError())
            end)

            it("gives up when curl cannot be started", function()
                CurlUtil.download = function()
                    return nil, nil, "unable to launch curl"
                end
                checkForUpdates(true)
                assert.are.equal("Failed to fetch updates for KindleFetch", helper.lastError())
            end)

            -- e.g. when github limits how often it can be asked
            it("gives up when the answer isn't a release", function()
                release_response = '{"message": "API rate limit exceeded for 203.0.113.7."}'
                checkForUpdates(true)

                -- and nothing else, such as an offer to update
                assert.are.equal(1, #helper.state.shown)
                assert.are.equal("Failed to fetch updates for KindleFetch", helper.lastError())
                assert.matches("API rate limit exceeded", helper.logged("warn", "^could not read the latest release"))
            end)

            it("gives up when the answer can't be read at all", function()
                release_response = "<html>Bad gateway</html>"
                checkForUpdates(true)
                assert.are.equal("Failed to fetch updates for KindleFetch", helper.lastError())

                -- KOReader's json gives an error rather than nothing
                helper.stub("json", {
                    decode = function()
                        error("invalid json")
                    end,
                })
                package.loaded["updater.pluginupdater"] = nil
                PluginUpdater = require("updater.pluginupdater")
                helper.state.shown = {}
                checkForUpdates(true)
                assert.are.equal("Failed to fetch updates for KindleFetch", helper.lastError())
            end)

            it("says it is up to date, if the user asked", function()
                latestRelease("v0.3")
                checkForUpdates(true)
                assert.are.equal("KindleFetch is up to date", helper.lastNotification())

                helper.state.notifications = {}
                checkForUpdates(false)
                assert.are.equal(0, #helper.state.notifications)
            end)

            it("ignores release tags that are not version numbers", function()
                latestRelease("nightly")
                checkForUpdates()
                assert.are.equal(0, #helper.state.shown)
            end)

            it("skips the check in the emulator", function()
                helper.stubs.device.sdl = true
                checkForUpdates()
                assert.are.equal(0, #release_lookups)
                assert.are.equal(0, #helper.state.popen_calls)
            end)

            -- so that automatic checks can wait a day before the next one
            it("remembers when the latest release was last looked up", function()
                helper.state.time = 1234567
                latestRelease("v0.3")
                checkForUpdates()
                assert.are.equal(1234567, Settings:getLastUpdateCheck())
            end)

            it("doesn't count a check that couldn't reach github", function()
                checkForUpdates()
                assert.is_nil(Settings:getLastUpdateCheck())
            end)

            describe("once an update is turned down", function()
                before_each(function()
                    latestRelease("v0.4")
                    checkForUpdates()
                    helper.state.shown[1].buttons[1][1].callback()
                end)

                it("doesn't offer that release again", function()
                    assert.are.equal("0.4", Settings:getSkippedVersion())

                    checkForUpdates(false)
                    assert.are.equal(1, #helper.state.shown)
                    assert.matches("was turned down before", helper.logged("info", "^KindleFetch 0.4"))
                end)

                it("offers it again when the user asks to check for updates", function()
                    checkForUpdates(true)
                    assert.are.equal(2, #helper.state.shown)
                    assert.matches("New version available: v0.4", helper.state.shown[2].input, 1, true)
                end)

                it("offers the release after it", function()
                    latestRelease("v0.5")
                    checkForUpdates(false)
                    assert.are.equal(2, #helper.state.shown)
                    assert.matches("New version available: v0.5", helper.state.shown[2].input, 1, true)
                end)
            end)
        end)

        describe("updating", function()
            local release_zip, downloaded_url

            local function acceptUpdate()
                checkForUpdates()
                local update_button = helper.state.shown[1].buttons[1][2]
                assert.are.equal("Update", update_button.text)
                update_button.callback()
            end

            before_each(function()
                -- build a release zip laid out like the ones published on github
                local build_dir = helper.tmpdir("release")
                helper.writeFile(build_dir .. "/kindlefetch.koplugin/main.lua", "-- v0.4\n")
                helper.writeFile(build_dir .. "/kindlefetch.koplugin/version.txt", "0.4\n")
                release_zip = helper.abs(build_dir) .. "/kindlefetch.koplugin.zip"
                helper.run(
                    string.format(
                        "cd %s && zip -qr %s kindlefetch.koplugin",
                        helper.quote(build_dir),
                        helper.quote(release_zip)
                    )
                )

                downloaded_url = nil
                downloadRelease = function(url, filepath)
                    downloaded_url = url
                    helper.run(string.format("cp %s %s", helper.quote(release_zip), helper.quote(filepath)))
                    return true
                end

                latestRelease("v0.4")
            end)

            it("downloads the release asset for the new version", function()
                acceptUpdate()
                assert.are.equal(
                    "https://github.com/william-spongberg/KindleFetch.koplugin/releases/download/v0.4/"
                        .. "kindlefetch.koplugin.zip",
                    downloaded_url
                )
            end)

            it("replaces the installed plugin with the new release", function()
                acceptUpdate()

                assert.are.equal("-- v0.4\n", helper.readFile(plugin_path .. "/main.lua"))
                assert.are.equal("0.4", helper.readFile(plugin_path .. "/version.txt"))
                assert.is_false(helper.exists(plugin_path .. "/util/pathutil.lua"))
                -- offering to restart KOReader, which uses the new version once it has
                assert.are.same(
                    { "Kindle Fetch has updated to v0.4, which KOReader will use once it restarts." },
                    helper.state.restart_prompts
                )
            end)

            it("cleans up the backup and downloaded files", function()
                acceptUpdate()

                assert.is_false(helper.exists(plugin_path .. ".backup"))
                assert.is_false(helper.exists(data_dir .. "/cache/kindlefetch"))
            end)

            it("does nothing when the user cancels", function()
                checkForUpdates()
                local dialog = helper.state.shown[1]
                dialog.buttons[1][1].callback()

                assert.is_true(helper.wasClosed(dialog))
                assert.is_nil(downloaded_url)
            end)

            it("keeps the installed plugin when the release has no plugin folder", function()
                local build_dir = helper.tmpdir("bad-release")
                helper.writeFile(build_dir .. "/KindleFetch-main/main.lua", "-- v0.4\n")
                local bad_zip = helper.abs(build_dir) .. "/release.zip"
                helper.run(
                    string.format(
                        "cd %s && zip -qr %s KindleFetch-main",
                        helper.quote(build_dir),
                        helper.quote(bad_zip)
                    )
                )
                release_zip = bad_zip
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to install update", helper.lastError())
            end)

            it("keeps the installed plugin when it cannot be moved aside", function()
                helper.stubExecute(string.format("mv '%s' '%s.backup'", plugin_path, plugin_path), function()
                    return 256
                end)
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to install update", helper.lastError())
            end)

            it("restores the installed plugin when the new one cannot be moved into place", function()
                helper.stubExecute("/cache/kindlefetch/kindlefetch.koplugin' '" .. plugin_path .. "'", function()
                    return 256
                end)
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.is_false(helper.exists(plugin_path .. ".backup"))
                assert.are.equal("Failed to install update", helper.lastError())
            end)

            it("keeps the installed plugin when the download leaves no file", function()
                downloadRelease = function()
                    return true
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to download update", helper.lastError())
            end)

            it("keeps the installed plugin when the download fails", function()
                downloadRelease = function()
                    return false, "request timed out"
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to download update", helper.lastError())
            end)

            it("keeps the installed plugin when the download is not a valid zip", function()
                downloadRelease = function(_, filepath)
                    helper.writeFile(filepath, "<html>rate limited</html>")
                    return true
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to install update", helper.lastError())
            end)
        end)
    end)
end
