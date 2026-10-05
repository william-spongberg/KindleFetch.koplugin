local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local VersionUtil = require("util.versionutil")
local StringUtil = require("util.stringutil")
local PathUtil = require("util.pathutil")
local KindleFetchSettings = require("settings.settings")
local _ = require("gettext")

-- constants
local REPO_NAME = "william-spongberg/KindleFetch.koplugin"
local PLUGIN_NAME = "kindlefetch.koplugin"
local GITHUB_API_URL = "https://api.github.com/repos/"
local GITHUB_URL = "https://github.com/"
local REPO_VERSION_URL = GITHUB_API_URL .. REPO_NAME
local REPO_DOWNLOAD_URL = GITHUB_URL .. REPO_NAME
local POLL_INTERVAL = 0.5
-- KOReader is in use while the latest release is looked up, so don't keep at it for long
local CHECK_MAX_TIME = 15

local PluginUpdater = {}

-- the version and release notes in github's description of the latest release
local function parseUpdateInfo(output)
    local ok, release = pcall(JSON.decode, output)
    if not ok or type(release) ~= "table" or type(release.tag_name) ~= "string" then
        -- e.g. GitHub's rate limit
        LogUtil.warn("could not read the latest release from GitHub:", output:gsub("%s+", " "):sub(1, 300))
        return nil
    end
    local tag = release.tag_name:gsub("^v", "")

    local version = VersionUtil.parseVersion(tag)
    if not version then
        LogUtil.warn("could not read the version of the latest release, tagged", tag)
        return nil
    end

    return {
        version = version,
        -- a release without notes has null here, which isn't a string once read
        notes = type(release.body) == "string" and release.body or nil,
    }
end

-- look up the latest release on github in the background, as KOReader is in use and it can take a while. calls
-- callback with its version and release notes, or with nothing if it couldn't be looked up
local function fetchUpdateInfo(callback)
    local release_file = PathUtil.getTmpPath() .. "/latest_release.json"
    local pid, exit_file, err =
        CurlUtil.download(REPO_VERSION_URL .. "/releases/latest", release_file, false, true, CHECK_MAX_TIME)
    if not pid then
        LogUtil.warn("could not start curl to look up the latest release:", err)
        callback(nil)
        return
    end

    local function poll()
        local exit_code = CurlUtil.getExitCode(exit_file)
        if not exit_code then
            if CurlUtil.isPidRunning(pid) then
                UIManager:scheduleIn(POLL_INTERVAL, poll)
                return
            end
            -- curl may have finished between checking for its exit code and whether it was running
            exit_code = CurlUtil.getExitCode(exit_file)
        end

        local output = FileUtil.readFile(release_file)
        FileUtil.removeFile(release_file)
        if exit_code ~= 0 or not output then
            -- e.g. GitHub's rate limit, or no connection
            LogUtil.warn(
                "could not look up the latest release on GitHub: curl exit code",
                tostring(exit_code),
                "(" .. CurlUtil.getErrorMeaning(exit_code) .. ")"
            )
            callback(nil)
            return
        end

        callback(parseUpdateInfo(output))
    end
    UIManager:scheduleIn(POLL_INTERVAL, poll)
end

-- read installed plugin version from version.txt
local function getInstalledVersion(plugin_path)
    local version_file = plugin_path .. "/version.txt"
    if not FileUtil.isValidFile(version_file) then
        return nil
    end

    local version_str = FileUtil.readFile(version_file)
    if not version_str then
        return nil
    end

    return VersionUtil.parseVersion(version_str)
end

-- download plugin release from github
local function downloadPluginRelease(version_str)
    LogUtil.info("downloading KindleFetch", version_str)
    local download_url = string.format(REPO_DOWNLOAD_URL .. "/releases/download/v%s/%s.zip", version_str, PLUGIN_NAME)
    local zip_path = PathUtil.getTmpPath() .. "/" .. PLUGIN_NAME .. ".zip"

    LogUtil.debug("plugin download url", download_url)

    -- download the release zip
    local success, err = CurlUtil.download(download_url, zip_path, false, false)
    if not success then
        LogUtil.warn("could not download KindleFetch", version_str, "from", download_url, "error:", err)
        return nil, err
    end

    if not FileUtil.isValidFile(zip_path) then
        LogUtil.warn(
            "downloaded KindleFetch",
            version_str,
            "is not a valid file:",
            zip_path,
            FileUtil.getSize(zip_path),
            "bytes"
        )
        return nil, "downloaded plugin file is invalid"
    end

    LogUtil.debug("plugin release downloaded successfully", zip_path)
    return zip_path
end

-- extract and install plugin from zip
local function installPluginRelease(plugin_path, zip_path, version_str)
    LogUtil.info("installing KindleFetch from", zip_path, "to", plugin_path)

    -- extract zip to temp directory (use -d rather than cd, as paths may be relative to the koreader dir)
    local tmp_path = PathUtil.getTmpPath()
    local extract_cmd =
        string.format("unzip -q -o %s -d %s", CurlUtil.shellQuote(zip_path), CurlUtil.shellQuote(tmp_path))
    if os.execute(extract_cmd .. " 2>/dev/null") ~= 0 then
        LogUtil.warn("could not unzip", zip_path)
        return false
    end

    -- find extracted directory
    local extracted_dir = tmp_path .. "/" .. PLUGIN_NAME
    if not FileUtil.isValidDirectory(extracted_dir) then
        LogUtil.warn("extracted plugin directory not found", extracted_dir)
        return false
    end

    -- backup current plugin
    local backup_dir = plugin_path .. ".backup"
    if FileUtil.isValidDirectory(plugin_path) then
        LogUtil.debug("backing up current plugin to", backup_dir)
        if
            os.execute(
                string.format("mv %s %s 2>/dev/null", CurlUtil.shellQuote(plugin_path), CurlUtil.shellQuote(backup_dir))
            ) ~= 0
        then
            LogUtil.warn("could not back up the installed plugin to", backup_dir)
            return false
        end
    end

    -- move extracted plugin to plugin directory
    LogUtil.debug("installing new plugin to", plugin_path)
    if
        os.execute(
            string.format("mv %s %s 2>/dev/null", CurlUtil.shellQuote(extracted_dir), CurlUtil.shellQuote(plugin_path))
        ) ~= 0
    then
        LogUtil.warn("could not move", extracted_dir, "to", plugin_path)
        -- restore backup
        if FileUtil.isValidDirectory(backup_dir) then
            os.execute(
                string.format("mv %s %s 2>/dev/null", CurlUtil.shellQuote(backup_dir), CurlUtil.shellQuote(plugin_path))
            )
        end
        return false
    end

    -- remove backup after successful install
    os.execute(string.format("rm -rf %s 2>/dev/null", CurlUtil.shellQuote(backup_dir)))

    -- write new version to version file
    if not FileUtil.writeFile(plugin_path .. "/version.txt", version_str) then
        LogUtil.warn("could not write", plugin_path .. "/version.txt")
        return false
    end

    -- cleanup temp directory
    os.execute(string.format("rm -rf %s 2>/dev/null", CurlUtil.shellQuote(tmp_path)))

    LogUtil.info("installed KindleFetch", version_str)
    return true
end

-- download and install new plugin version
local function updatePlugin(plugin_path, version_str)
    LogUtil.debug("updating plugin to version", version_str)
    NotifyUtil.info("Downloading KindleFetch v" .. version_str .. "...")

    -- download the release
    local zip_path, err = downloadPluginRelease(version_str)
    if not zip_path then
        LogUtil.warn("failed to dowload plugin update", err)
        NotifyUtil.info("Failed to download update")
        return false
    end

    -- install the plugin
    if not installPluginRelease(plugin_path, zip_path, version_str) then
        LogUtil.warn("failed to install plugin release from zip:", zip_path)
        NotifyUtil.info("Failed to install update")
        return false
    end

    NotifyUtil.info("Successfully updated KindleFetch to v" .. version_str)
    LogUtil.debug("plugin update completed successfully")

    -- notify user that plugin needs restart
    NotifyUtil.info("Plugin updated. Please restart KOReader to apply changes.")

    return true
end

local function promptPluginUpdate(plugin_path, installed_version, available_update)
    local message = string.format(
        "KindleFetch v%s is installed.\nNew version available: v%s\n\n%s\n\nUpdate plugin now?",
        installed_version,
        available_update.version.str,
        StringUtil.replaceCarriageReturns(available_update.notes)
    )

    LogUtil.debug("showing update message:", message)

    local confirm_dialog
    confirm_dialog = InputDialog:new {
        title = _("Update KindleFetch?"),
        input_type = "text",
        input = message,
        readonly = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        LogUtil.info("KindleFetch update declined")
                        -- so this release isn't offered again every day, only when asked to check
                        KindleFetchSettings:setSkippedVersion(available_update.version.str)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        updatePlugin(plugin_path, available_update.version.str)
                    end,
                },
            },
        },
    }

    UIManager:show(confirm_dialog)
end

-- check plugin version and offer to update if a new version is available, reporting the result if the user asked
-- for the check. the latest release is looked up in the background, so this returns before the check is over
function PluginUpdater.checkForUpdates(user_requested)
    if Device:isSDL() then
        LogUtil.debug("running in emulator, skipping plugin version check")
        return
    end
    LogUtil.debug("checking for plugin updates from", REPO_VERSION_URL)

    local plugin_path = PathUtil.getPluginPath()

    local installed_version = getInstalledVersion(plugin_path)
    if not installed_version then
        LogUtil.warn("could not determine installed version, setting to 0.0.0")
        installed_version = VersionUtil.parseVersion("0.0.0")
    end

    fetchUpdateInfo(function(repo_update)
        if not repo_update then
            LogUtil.warn("could not check for KindleFetch updates")
            if user_requested then
                NotifyUtil.info("Failed to fetch updates for KindleFetch")
            end
            return
        end
        -- automatic checks wait a day from here
        KindleFetchSettings:setLastUpdateCheck(os.time())

        LogUtil.info(
            "KindleFetch",
            installed_version.str,
            "is installed, and the latest release is",
            repo_update.version.str
        )

        local cmp = VersionUtil.compareVersions(installed_version, repo_update.version)
        if cmp >= 0 then
            LogUtil.debug("plugin is up to date")
            if user_requested then
                NotifyUtil.info("KindleFetch is up to date")
            end
            return
        end

        -- update available, but not offered again once turned down, unless asked to check
        if not user_requested and repo_update.version.str == KindleFetchSettings:getSkippedVersion() then
            LogUtil.info("KindleFetch", repo_update.version.str, "was turned down before, so not offering it again")
            return
        end

        LogUtil.info("offering to update KindleFetch to", repo_update.version.str)
        promptPluginUpdate(plugin_path, installed_version.str, repo_update)
    end)
end

return PluginUpdater
