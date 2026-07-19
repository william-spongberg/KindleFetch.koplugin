local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local CurlUtil = require("util.curlutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local VersionUtil = require("util.versionutil")
local _ = require("gettext")

-- constants
local MIN_VERSION = "8.17.0"
local CURL_REPO_URL = "https://github.com/moparisthebest/static-curl"

local CurlUpdater = {}

-- get the installed curl version
local function getCurlVersion()
    local pipe = io.popen("curl --version 2>/dev/null", "r")
    if not pipe then
        return nil
    end

    local output = pipe:read("*l")
    pipe:close()

    if not output then
        return nil
    end

    -- curl version output format: "curl X.Y.Z (platform) ..."
    local version = output:match("^curl%s+([%d%.]+)")
    return version
end

-- update curl using static release from moparisthebest/static-curl
-- basically adds safe guards around the sh script given here https://github.com/justrals/KindleFetch/issues/40#issuecomment-4009774337
local function updateCurl()
    LogUtil.debug("attempting to install static curl v" .. MIN_VERSION)
    NotifyUtil.info("Updating curl...")

    -- download curl
    local curl_filename = "curl-armhf"
    local curl_path = VersionUtil.getTmpDir() .. "/" .. curl_filename
    local download_url = string.format(CURL_REPO_URL .. "/releases/download/v%s/%s", MIN_VERSION, curl_filename)

    LogUtil.debug("downloading static curl", download_url)
    local success, err = CurlUtil.download(download_url, curl_path, false, false)
    if not success then
        LogUtil.warn("failed to download static curl", err)
        NotifyUtil.info("Failed to download curl update")
        return false
    end

    -- make it executable
    local chmod_cmd = string.format("chmod +x %s", CurlUtil.shellQuote(curl_path))
    if os.execute(chmod_cmd) ~= 0 then
        os.remove(curl_path) -- remove downloaded file
        LogUtil.warn("failed to set executable permission")
        NotifyUtil.info("Failed to set file permissions")
        return false
    end

    -- backup system curl
    local system_curl = "/usr/bin/curl"
    local backup_curl = "/usr/bin/curl.system.bak"

    -- change perms to rw
    LogUtil.debug("remounting rootfs as read-write")
    if os.execute("mntroot rw 2>/dev/null") ~= 0 then
        LogUtil.warn("failed to remount rootfs as read-write")
        NotifyUtil.info("Failed to remount root as read-write")
        return false
    end

    -- backup original curl if not already backed up
    if os.execute(string.format("test -f %s", CurlUtil.shellQuote(backup_curl))) ~= 0 then
        LogUtil.debug("backing up system curl")
        if os.execute(string.format("cp %s %s 2>/dev/null", CurlUtil.shellQuote(system_curl),
            CurlUtil.shellQuote(backup_curl))) ~= 0 then
            LogUtil.warn("failed to backup curl to", backup_curl)
            NotifyUtil.info("Failed to create curl backup")
            return false
        end
    end

    -- install new curl
    LogUtil.debug("installing static curl to " .. system_curl)
    if os.execute(
        string.format("cp %s %s 2>/dev/null", CurlUtil.shellQuote(curl_path), CurlUtil.shellQuote(system_curl))) ~= 0 then
        LogUtil.warn("failed to install static curl")
        NotifyUtil.info("Failed to install new curl update")

        -- back to read only perms
        LogUtil.debug("remounting rootfs as read-only") 
        if os.execute("mntroot ro 2>/dev/null") ~= 0 then
            LogUtil.warn("failed to remount rootfs as read-only")
            NotifyUtil.info("Failed to remount root as read-only")
        end
        return false
    end

    -- set permissions
    if os.execute(string.format("chmod 755 %s", CurlUtil.shellQuote(system_curl))) ~= 0 then
        LogUtil.warn("failed to set curl permissions (continuing anyway)")
    end

    -- remount as read-only
    LogUtil.debug("remounting rootfs as read-only")
    if os.execute("mntroot ro 2>/dev/null") ~= 0 then
        LogUtil.warn("failed to remount rootfs as read-only")
        NotifyUtil.info("Failed to remount root as read-only")
        return false
    end

    LogUtil.debug("static curl installation completed successfully")
    NotifyUtil.info("Updated curl to v" .. MIN_VERSION)
    return true
end

-- prompt for curl update
local function promptCurlUpdate(current_version, min_version)
    local message = string.format("curl v%s is installed.\nMinimum required: v%s\n\nUpdate curl now? This will avoid potential TLS issues.", current_version,
        min_version)

    local confirm_dialog
    confirm_dialog = InputDialog:new{
        title = _("Update curl?"),
        input_type = "text",
        input = message,
        readonly = true,
        buttons = {{{
            text = _("Cancel"),
            callback = function()
                UIManager:close(confirm_dialog)
                LogUtil.debug("user declined curl update")
            end
        }, {
            text = _("Update"),
            callback = function()
                UIManager:close(confirm_dialog)
                updateCurl()
            end
        }}}
    }

    UIManager:show(confirm_dialog)
    UIManager:setDirty(confirm_dialog, "full")
end

-- check curl is available and at least MIN_VERSION, update if necessary
function CurlUpdater.checkVersion()
    if Device:isSDL() then
        LogUtil.debug("running in emulator, skipping curl version check")
        return true
    end
    LogUtil.debug("checking curl version")

    local current_version_str = getCurlVersion()
    if not current_version_str then
        LogUtil.warn("curl not found or version could not be determined")
        return false
    end

    local current_version = VersionUtil.parseVersion(current_version_str)
    local min_version_parsed = VersionUtil.parseVersion(MIN_VERSION)

    if not current_version or not min_version_parsed then
        LogUtil.warn("could not parse curl versions", {
            current = current_version_str,
            minimum = MIN_VERSION
        })
        return false
    end

    LogUtil.debug("curl version check", {
        current = current_version_str,
        minimum = MIN_VERSION
    })

    local cmp = VersionUtil.compareVersions(current_version, min_version_parsed)
    if cmp >= 0 then
        LogUtil.debug("curl is up to date")
        return true
    end

    LogUtil.warn("curl version is below minimum")
    return promptCurlUpdate(current_version_str, MIN_VERSION)
end

return CurlUpdater
