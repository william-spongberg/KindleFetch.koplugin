local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local VersionUtil = require("util.versionutil")
local _ = require("gettext")

-- constants
local REPO_NAME = "william-spongberg/KindleFetch.koplugin"
local PLUGIN_NAME = "kindlefetch.koplugin"
local GITHUB_API_URL = "https://api.github.com/repos/"
local GITHUB_URL = "https://github.com/"
local REPO_VERSION_URL = GITHUB_API_URL .. REPO_NAME
local REPO_DOWNLOAD_URL = GITHUB_URL .. REPO_NAME

local PluginUpdater = {}

-- read latest repo version from github
local function getRepoVersion()
    local cmd = "curl -s " .. REPO_VERSION_URL .. "/releases/latest" .. " | grep '\"tag_name\"'"
    local handle = io.popen(cmd)
    if not handle then
        return nil
    end

    local output = handle:read("*a")
    handle:close()

    -- output:  "tag_name": "v0.1"
    local tag = output:match('"tag_name"%s*:%s*"([^"]+)"')
    if not tag then
        LogUtil.debug(output)
        return nil
    end

    tag = tag:gsub("^v", "")
    local major, minor, patch = tag:match("(%d+)%.(%d+)%.?(%d*)")

    return {
        major = tonumber(major) or 0,
        minor = tonumber(minor) or 0,
        patch = tonumber(patch) or 0,
        str = tag
    }
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
    LogUtil.debug("downloading plugin release", version_str)
    local download_url = string.format(REPO_DOWNLOAD_URL .. "/releases/download/v%s/%s.zip", version_str, PLUGIN_NAME)
    local zip_path = VersionUtil.getTmpDir() .. "/" .. PLUGIN_NAME .. ".zip"

    LogUtil.debug("plugin download url", download_url)

    -- download the release zip
    local success, err = CurlUtil.download(download_url, zip_path, false, false)
    if not success then
        LogUtil.warn("failed to download plugin release", download_url, version_str)
        return nil, err
    end

    if not FileUtil.isValidFile(zip_path) then
        LogUtil.warn("downloaded plugin file is invalid")
        return nil, "downloaded plugin file is invalid"
    end

    LogUtil.debug("plugin release downloaded successfully", zip_path)
    return zip_path
end

-- extract and install plugin from zip
local function installPluginRelease(plugin_path, zip_path, version_str)
    LogUtil.debug("installing plugin release from", zip_path)

    -- extract zip to temp directory
    local extract_cmd = string.format("cd %s && unzip -q -o %s", CurlUtil.shellQuote(VersionUtil.getTmpDir()),
        CurlUtil.shellQuote(zip_path))
    if os.execute(extract_cmd .. " 2>/dev/null") ~= 0 then
        LogUtil.warn("failed to extract plugin zip")
        return false
    end

    -- find extracted directory
    local extracted_dir = VersionUtil.getTmpDir() .. "/" .. PLUGIN_NAME
    if not FileUtil.isValidDirectory(extracted_dir) then
        LogUtil.warn("extracted plugin directory not found", extracted_dir)
        return false
    end

    -- backup current plugin
    local backup_dir = plugin_path .. ".backup"
    if FileUtil.isValidDirectory(plugin_path) then
        LogUtil.debug("backing up current plugin to", backup_dir)
        if os.execute(string.format("mv %s %s 2>/dev/null", CurlUtil.shellQuote(plugin_path),
            CurlUtil.shellQuote(backup_dir))) ~= 0 then
            LogUtil.warn("failed to backup current plugin")
            return false
        end
    end

    -- move extracted plugin to plugin directory
    LogUtil.debug("installing new plugin to", plugin_path)
    if os.execute(string.format("mv %s %s 2>/dev/null", CurlUtil.shellQuote(extracted_dir),
        CurlUtil.shellQuote(plugin_path))) ~= 0 then
        LogUtil.warn("failed to move extracted plugin to plugin directory")
        -- restore backup
        if FileUtil.isValidDirectory(backup_dir) then
            os.execute(string.format("mv %s %s 2>/dev/null", CurlUtil.shellQuote(backup_dir),
                CurlUtil.shellQuote(plugin_path)))
        end
        return false
    end

    -- remove backup after successful install
    os.execute(string.format("rm -rf %s 2>/dev/null", CurlUtil.shellQuote(backup_dir)))

    -- write new version to version file
    if not FileUtil.writeFile(plugin_path .. "/version.txt", version_str) then
        LogUtil.warn("failed to write version file")
        return false
    end

    -- cleanup temp directory
    os.execute(string.format("rm -rf %s 2>/dev/null", CurlUtil.shellQuote(VersionUtil.getTmpDir())))

    LogUtil.debug("plugin installation completed successfully")
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

local function promptPluginUpdate(plugin_path, installed_version, available_version)
    local message = string.format("KindleFetch v%s is installed.\nNew version available: v%s\n\nUpdate plugin now?",
        installed_version, available_version)

    LogUtil.debug("showing", message)

    local confirm_dialog
    confirm_dialog = InputDialog:new{
        title = _("Update KindleFetch?"),
        input_type = "text",
        input = message,
        readonly = true,
        buttons = {{{
            text = _("Cancel"),
            callback = function()
                UIManager:close(confirm_dialog)
                LogUtil.debug("user declined plugin update")
            end
        }, {
            text = _("Update"),
            callback = function()
                UIManager:close(confirm_dialog)
                updatePlugin(plugin_path, available_version)
            end
        }}}
    }

    UIManager:show(confirm_dialog)
    UIManager:setDirty(confirm_dialog, "full")
end

-- check plugin version and update if new version available
function PluginUpdater.checkForUpdates(plugin_path)
    if Device:isSDL() then
        LogUtil.debug("running in emulator, skipping plugin version check")
        return true
    end
    LogUtil.debug("checking for plugin updates")

    local installed_version = getInstalledVersion(plugin_path)
    if not installed_version then
        LogUtil.warn("could not determine installed version, setting to 0.0.0")
        installed_version = VersionUtil.parseVersion("0.0.0")
    end

    local repo_version = getRepoVersion()
    if not repo_version then
        LogUtil.warn("failed to fetch repo version")
        NotifyUtil.info("Failed to fetch updates for KindleFetch")
        return false
    end

    LogUtil.debug("KindleFetch:", "plugin version check", {
        installed = installed_version.str,
        available = repo_version.str
    })

    local cmp = VersionUtil.compareVersions(installed_version, repo_version)
    if cmp >= 0 then
        LogUtil.debug("plugin is up to date")
        return true
    end

    -- update available
    LogUtil.debug("new plugin version available", repo_version.str)
    return promptPluginUpdate(plugin_path, installed_version.str, repo_version.str)
end

return PluginUpdater
