local helper = require("helper")

-- trimmed down response from https://api.github.com/repos/william-spongberg/KindleFetch.koplugin/releases/latest
local LATEST_RELEASE = [[{
  "html_url": "https://github.com/william-spongberg/KindleFetch.koplugin/releases/tag/%s",
  "tag_name": "%s",
  "name": "%s",
  "body": "Bug fixes\r\n- fixed updates on android"
}]]

-- where KOReader keeps its data and user plugins on each kind of device
local LAYOUTS = {{
    name = "kindle/kobo",
    absolute = false, -- data dir is "."
    plugins_dir = "/plugins/"
}, {
    name = "android",
    absolute = true, -- data dir is "/sdcard/koreader", plugins are found through "<data dir>/plugins/"
    plugins_dir = "/plugins//"
}}

for _, layout in ipairs(LAYOUTS) do
    describe("PluginUpdater on " .. layout.name, function()
        local data_dir, plugin_path, CurlUtil, PluginUpdater

        local function latestRelease(tag)
            helper.stubCommand("/releases/latest", LATEST_RELEASE:format(tag, tag, tag))
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

            CurlUtil = require("util.curlutil")
            PluginUpdater = require("updater.pluginupdater")
        end)

        after_each(helper.cleanup)

        describe("checkForUpdates", function()
            it("does nothing when the installed version is the latest", function()
                latestRelease("v0.3")
                assert.is_true(PluginUpdater.checkForUpdates())
                assert.are.equal(0, #helper.state.shown)
            end)

            it("does nothing when the installed version is newer", function()
                helper.writeFile(plugin_path .. "/version.txt", "0.10\n")
                latestRelease("v0.9")
                assert.is_true(PluginUpdater.checkForUpdates())
                assert.are.equal(0, #helper.state.shown)
            end)

            it("offers newer releases along with their release notes", function()
                latestRelease("v0.4")
                PluginUpdater.checkForUpdates()

                local dialog = helper.state.shown[1]
                assert.are.equal("Update KindleFetch?", dialog.title)
                assert.matches("KindleFetch v0.3 is installed.", dialog.input, 1, true)
                assert.matches("New version available: v0.4", dialog.input, 1, true)
                assert.matches("Bug fixes\n- fixed updates on android", dialog.input, 1, true)
            end)

            it("offers updates without release notes", function()
                helper.stubCommand("/releases/latest", '{"tag_name": "v0.4", "body": ""}')
                PluginUpdater.checkForUpdates()

                assert.matches("New version available: v0.4", helper.state.shown[1].input, 1, true)
            end)

            it("treats a missing version file as 0.0.0", function()
                os.remove(plugin_path .. "/version.txt")
                latestRelease("v0.3")
                PluginUpdater.checkForUpdates()

                assert.matches("KindleFetch v0.0.0 is installed.", helper.state.shown[1].input, 1, true)
            end)

            it("quietly gives up when the latest release cannot be fetched", function()
                helper.stubCommand("/releases/latest", "")
                assert.is_false(PluginUpdater.checkForUpdates(false))
                assert.are.equal(0, #helper.state.notifications)
            end)

            it("reports when the latest release cannot be fetched, if the user asked", function()
                helper.stubCommand("/releases/latest", "")
                assert.is_false(PluginUpdater.checkForUpdates(true))
                assert.are.equal("Failed to fetch updates for KindleFetch", helper.lastNotification())
            end)

            it("says it is up to date, if the user asked", function()
                latestRelease("v0.3")
                assert.is_true(PluginUpdater.checkForUpdates(true))
                assert.are.equal("KindleFetch is up to date", helper.lastNotification())

                helper.state.notifications = {}
                PluginUpdater.checkForUpdates(false)
                assert.are.equal(0, #helper.state.notifications)
            end)

            it("ignores release tags that are not version numbers", function()
                latestRelease("nightly")
                assert.is_false(PluginUpdater.checkForUpdates())
                assert.are.equal(0, #helper.state.shown)
            end)

            it("skips the check in the emulator", function()
                helper.stubs.device.sdl = true
                assert.is_true(PluginUpdater.checkForUpdates())
                assert.are.equal(0, #helper.state.popen_calls)
            end)
        end)

        describe("updating", function()
            local release_zip, downloaded_url

            local function acceptUpdate()
                PluginUpdater.checkForUpdates()
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
                helper.run(string.format("cd %s && zip -qr %s kindlefetch.koplugin", helper.quote(build_dir),
                    helper.quote(release_zip)))

                downloaded_url = nil
                CurlUtil.download = function(url, filepath)
                    downloaded_url = url
                    helper.run(string.format("cp %s %s", helper.quote(release_zip), helper.quote(filepath)))
                    return true
                end

                latestRelease("v0.4")
            end)

            it("downloads the release asset for the new version", function()
                acceptUpdate()
                assert.are.equal(
                    "https://github.com/william-spongberg/KindleFetch.koplugin/releases/download/v0.4/kindlefetch.koplugin.zip",
                    downloaded_url)
            end)

            it("replaces the installed plugin with the new release", function()
                acceptUpdate()

                assert.are.equal("-- v0.4\n", helper.readFile(plugin_path .. "/main.lua"))
                assert.are.equal("0.4", helper.readFile(plugin_path .. "/version.txt"))
                assert.is_false(helper.exists(plugin_path .. "/util/pathutil.lua"))
                assert.are.equal("Plugin updated. Please restart KOReader to apply changes.",
                    helper.lastNotification())
            end)

            it("cleans up the backup and downloaded files", function()
                acceptUpdate()

                assert.is_false(helper.exists(plugin_path .. ".backup"))
                assert.is_false(helper.exists(data_dir .. "/cache/kindlefetch"))
            end)

            it("does nothing when the user cancels", function()
                PluginUpdater.checkForUpdates()
                local dialog = helper.state.shown[1]
                dialog.buttons[1][1].callback()

                assert.is_true(helper.wasClosed(dialog))
                assert.is_nil(downloaded_url)
            end)

            it("keeps the installed plugin when the release has no plugin folder", function()
                local build_dir = helper.tmpdir("bad-release")
                helper.writeFile(build_dir .. "/KindleFetch-main/main.lua", "-- v0.4\n")
                local bad_zip = helper.abs(build_dir) .. "/release.zip"
                helper.run(string.format("cd %s && zip -qr %s KindleFetch-main", helper.quote(build_dir),
                    helper.quote(bad_zip)))
                release_zip = bad_zip
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to install update", helper.lastNotification())
            end)

            it("keeps the installed plugin when it cannot be moved aside", function()
                helper.stubExecute(string.format("mv '%s' '%s.backup'", plugin_path, plugin_path), function()
                    return 256
                end)
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to install update", helper.lastNotification())
            end)

            it("restores the installed plugin when the new one cannot be moved into place", function()
                helper.stubExecute("/cache/kindlefetch/kindlefetch.koplugin' '" .. plugin_path .. "'", function()
                    return 256
                end)
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.is_false(helper.exists(plugin_path .. ".backup"))
                assert.are.equal("Failed to install update", helper.lastNotification())
            end)

            it("keeps the installed plugin when the download leaves no file", function()
                CurlUtil.download = function()
                    return true
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to download update", helper.lastNotification())
            end)

            it("keeps the installed plugin when the download fails", function()
                CurlUtil.download = function()
                    return false, "request timed out"
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to download update", helper.lastNotification())
            end)

            it("keeps the installed plugin when the download is not a valid zip", function()
                CurlUtil.download = function(_, filepath)
                    helper.writeFile(filepath, "<html>rate limited</html>")
                    return true
                end
                acceptUpdate()

                assert.are.equal("0.3\n", helper.readFile(plugin_path .. "/version.txt"))
                assert.are.equal("Failed to install update", helper.lastNotification())
            end)
        end)
    end)
end
