local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local FileUtil = require("util.fileutil")
local CurlUtil = require("util.curlutil")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local VersionUtil = require("util.versionutil")
local StringUtil = require("util.stringutil")
local PathUtil = require("util.pathutil")
local ShellUtil = require("util.shellutil")
local KindleFetchSettings = require("settings.settings")
local Guard = require("util.guard")
local T = require("ffi/util").template
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

-- the check for updates going on, if there is one, so another isn't started meanwhile (they wrote the same file)
local checking

-- the version and release notes in github's description of the latest release, or nil and why not
local function parseUpdateInfo(output)
    local ok, release = pcall(JSON.decode, output)
    if not ok or type(release) ~= "table" or type(release.tag_name) ~= "string" then
        -- e.g. GitHub's rate limit, which says so
        LogUtil.warn("could not read the latest release from GitHub:", output:gsub("%s+", " "):sub(1, 300))
        local message = ok and type(release) == "table" and type(release.message) == "string" and release.message
        return nil, message and T(_("GitHub says: %1"), message) or _("GitHub didn't answer with the latest release")
    end
    local tag = release.tag_name:gsub("^v", "")

    local version = VersionUtil.parseVersion(tag)
    if not version then
        LogUtil.warn("could not read the version of the latest release, tagged", tag)
        return nil, T(_("the latest release's version can't be read (%1)"), tag)
    end

    return {
        version = version,
        -- a release without notes has null here, which isn't a string once read
        notes = type(release.body) == "string" and release.body or nil,
    }
end

-- look up the latest release on github in the background, as KOReader is in use and it can take a while. calls
-- callback with its version and release notes, or nil and why it couldn't be looked up
local function fetchUpdateInfo(callback)
    -- with KOReader's own HTTP where curl can't fetch, as a Kindle's own curl can be too old to connect to GitHub
    -- (#57), which holds KOReader up until GitHub has answered (so it's only asked when checking for updates is)
    if not CurlUtil.canFetch() then
        local body, err = HttpUtil.getBody(REPO_VERSION_URL .. "/releases/latest")
        if not body then
            LogUtil.warn("could not look up the latest release on GitHub:", err)
            callback(nil, err)
            return
        end
        callback(parseUpdateInfo(body))
        return
    end

    local release_file = PathUtil.getTmpPath() .. "/latest_release.json"
    local pid, exit_file =
        CurlUtil.startDownload(REPO_VERSION_URL .. "/releases/latest", release_file, false, CHECK_MAX_TIME)
    if not pid then
        -- (which is then why not)
        LogUtil.warn("could not start curl to look up the latest release:", exit_file)
        callback(nil, exit_file)
        return
    end

    -- as if it couldn't be looked up, once something goes wrong (see Guard)
    local function failed(err)
        callback(nil, err)
    end
    local function poll()
        local exit_code = CurlUtil.getExitCode(exit_file)
        if not exit_code then
            if CurlUtil.isPidRunning(pid) then
                Guard.scheduleIn(POLL_INTERVAL, "looking up the latest release", poll, failed)
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
            callback(nil, exit_code and CurlUtil.explainExitCode(exit_code) or _("GitHub didn't answer"))
            return
        end

        callback(parseUpdateInfo(output))
    end
    Guard.scheduleIn(POLL_INTERVAL, "looking up the latest release", poll, failed)
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

-- download plugin release from github, returning where it downloaded to, or nil and what went wrong
local function downloadPluginRelease(version_str)
    LogUtil.info("downloading KindleFetch", version_str)
    local download_url = string.format(REPO_DOWNLOAD_URL .. "/releases/download/v%s/%s.zip", version_str, PLUGIN_NAME)
    local zip_path = PathUtil.getTmpPath() .. "/" .. PLUGIN_NAME .. ".zip"

    LogUtil.debug("plugin download url", download_url)

    -- download the release zip (with KOReader's own HTTP where curl can't fetch, as when looking the release up)
    local success, err = HttpUtil.downloadFile(download_url, zip_path)
    if not success then
        LogUtil.warn("could not download KindleFetch", version_str, "from", download_url, "error:", err)
        return nil, T(_("it couldn't be downloaded (%1)"), err)
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
        return nil, _("nothing downloaded")
    end

    LogUtil.debug("plugin release downloaded successfully", zip_path)
    return zip_path
end

-- unzip the release into folder, with KOReader's own archiver where it has one, as not every device has unzip (stock
-- Android before 9 doesn't, so updating failed there every time), otherwise unzip. returns true, or nil and why not
local function extract(zip_path, folder)
    local has_archiver, Archiver = pcall(require, "ffi/archiver")
    if has_archiver and type(Archiver) == "table" and Archiver.Reader then
        local archive = Archiver.Reader:new()
        if not archive:open(zip_path) then
            LogUtil.warn("could not open", zip_path, "to unzip it:", archive.err)
            return nil, T(_("it couldn't be opened (%1)"), tostring(archive.err))
        end
        local extracted = true
        for entry in archive:iterate() do
            if not archive:extractToPath(entry.path, folder .. "/" .. entry.path) then
                extracted = false
                break
            end
        end
        local err = archive.err
        archive:close()
        if not extracted or err then
            LogUtil.warn("could not unzip", zip_path, err)
            return nil, T(_("it couldn't be unzipped (%1)"), tostring(err))
        end
        return true
    end

    local ok, err = ShellUtil.run(
        "unzip the release",
        string.format("unzip -q -o %s -d %s", CurlUtil.shellQuote(zip_path), CurlUtil.shellQuote(folder))
    )
    if not ok then
        return nil, T(_("it couldn't be unzipped (%1)"), err)
    end
    return true
end

-- install the release from the zip in place of the installed plugin, keeping the installed one until the new one is
-- in place, and putting it back if it couldn't be. returns true, or nil and what went wrong
local function installPluginRelease(plugin_path, zip_path, version_str)
    LogUtil.info("installing KindleFetch from", zip_path, "to", plugin_path)

    -- unzipped next to the plugin, rather than in KOReader's cache, so it can be moved into place by renaming it, which
    -- only works within a file system (KOReader only loads plugins from folders whose names end in .koplugin). anything
    -- left there by an install that didn't finish is removed first, rather than unzipped over
    local staging = plugin_path .. ".new"
    local backup = plugin_path .. ".backup"
    FileUtil.removeDir(staging)
    lfs.mkdir(staging)

    local ok, err = extract(zip_path, staging)
    local extracted = staging .. "/" .. PLUGIN_NAME
    if ok and not FileUtil.isValidFile(extracted .. "/main.lua") then
        LogUtil.warn("the release has no", PLUGIN_NAME, "folder with a main.lua in it")
        ok, err = nil, _("it has no Kindle Fetch in it")
    end

    if ok then
        -- the version it is, in case the release doesn't say (while it's still apart, so that failing to write it
        -- doesn't fail an install that worked)
        local written, write_err = FileUtil.writeFile(extracted .. "/version.txt", version_str)
        if not written then
            LogUtil.warn("could not write", extracted .. "/version.txt:", write_err)
        end

        FileUtil.removeDir(backup)
        local moved, move_err = os.rename(plugin_path, backup)
        if not moved then
            LogUtil.warn("could not move", plugin_path, "aside to", backup .. ":", move_err)
            ok, err = nil, T(_("the installed version couldn't be moved aside (%1)"), move_err)
        else
            moved, move_err = os.rename(extracted, plugin_path)
            if moved then
                FileUtil.removeDir(backup)
            else
                LogUtil.warn("could not move", extracted, "to", plugin_path .. ":", move_err)
                local restored, restore_err = os.rename(backup, plugin_path)
                if restored then
                    ok, err = nil, T(_("the new version couldn't be moved into place (%1)"), move_err)
                else
                    -- which leaves Kindle Fetch out of KOReader's menu, so where it is is said
                    LogUtil.err("could not put the installed version back from", backup .. ":", restore_err)
                    ok, err =
                        nil,
                        T(
                            _(
                                "the new version couldn't be moved into place (%1), and the installed version couldn't "
                                    .. "be put back from %2"
                            ),
                            move_err,
                            backup
                        )
                end
            end
        end
    end

    -- what's left of the release, whether or not it installed
    FileUtil.removeDir(staging)
    FileUtil.removeDir(PathUtil.getTmpPath())
    if ok then
        LogUtil.info("installed KindleFetch", version_str)
    end
    return ok, err
end

-- download and install new plugin version, returning true, or nil and what went wrong
local function updatePlugin(plugin_path, version_str)
    LogUtil.debug("updating plugin to version", version_str)
    NotifyUtil.info(T(_("Downloading Kindle Fetch v%1..."), version_str))

    local zip_path, err = downloadPluginRelease(version_str)
    if not zip_path then
        FileUtil.removeDir(PathUtil.getTmpPath())
        return nil, err
    end
    return installPluginRelease(plugin_path, zip_path, version_str)
end

local function promptPluginUpdate(plugin_path, installed_version, available_update)
    local message = T(
        _("Kindle Fetch v%1 is installed.\nNew version available: v%2\n\n%3\n\nUpdate Kindle Fetch now?"),
        installed_version,
        available_update.version.str,
        StringUtil.replaceCarriageReturns(available_update.notes)
    )

    LogUtil.debug("showing update message:", message)

    local confirm_dialog
    confirm_dialog = InputDialog:new {
        title = _("Update Kindle Fetch?"),
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
                        local version_str = available_update.version.str
                        local ok, err = updatePlugin(plugin_path, version_str)
                        if not ok then
                            NotifyUtil.error(T(_("Updating Kindle Fetch failed: %1"), err))
                            return
                        end
                        -- KOReader loads plugins as it starts, so the new version is used once it restarts, which it
                        -- offers to do now where it can restart itself (rather than a notification that's gone after a
                        -- couple of seconds)
                        UIManager:askForRestart(
                            T(
                                _("Kindle Fetch has updated to v%1, which KOReader will use once it restarts."),
                                version_str
                            )
                        )
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
    -- without a curl that can look it up in the background, it's only looked up when asked to be, as KOReader's own
    -- HTTP would hold KOReader up while it's in use (see fetchUpdateInfo)
    if not user_requested and not CurlUtil.canFetch() then
        LogUtil.info("only looking up the latest release when asked to check, as curl can't look it up")
        return
    end
    LogUtil.debug("checking for plugin updates from", REPO_VERSION_URL)

    -- the one going on says how it went once it's over, when that's asked for meanwhile
    if checking then
        LogUtil.info("already checking for updates")
        checking.user_requested = checking.user_requested or user_requested
        return
    end
    local check = { user_requested = user_requested }
    checking = check

    local plugin_path = PathUtil.getPluginPath()

    local installed_version = getInstalledVersion(plugin_path)
    if not installed_version then
        LogUtil.warn("could not determine installed version, setting to 0.0.0")
        installed_version = VersionUtil.parseVersion("0.0.0")
    end

    fetchUpdateInfo(function(repo_update, err)
        checking = nil
        user_requested = check.user_requested
        if not repo_update then
            LogUtil.warn("could not check for KindleFetch updates")
            if user_requested then
                NotifyUtil.error(T(_("Checking for updates failed: %1"), err or _("GitHub didn't answer")))
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
                NotifyUtil.info(_("Kindle Fetch is up to date"))
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
