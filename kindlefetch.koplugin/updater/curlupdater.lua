local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local CurlUtil = require("util.curlutil")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local VersionUtil = require("util.versionutil")
local PathUtil = require("util.pathutil")
local KindleFetchSettings = require("settings.settings")
local sha2 = require("ffi/sha2")
local _ = require("gettext")

-- constants
local MIN_VERSION = CurlUtil.MIN_VERSION
local CURL_REPO_URL = "https://github.com/moparisthebest/static-curl"

local CurlUpdater = {
    -- the SHA-256 of that release's curl-armhf, as GitHub lists it, so nothing else is installed as the Kindle's
    -- curl: to change along with CurlUtil.MIN_VERSION
    SHA256 = "e34d59a37903cdfc1d7807ae3b8659f708d1f44eff68790f716d33e257b101b7",
}

-- the SHA-256 of the file at path, or nil if it can't be read
local function sha256(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return sha2.sha256(content)
end

-- the version the curl at path says it is, and what it said, which when it can't run says why
local function runVersion(path)
    local pipe = io.popen(CurlUtil.shellQuote(path) .. " --version 2>&1")
    local said = pipe and pipe:read("*l")
    if pipe then
        pipe:close()
    end
    return said and said:match("^curl%s+([%d%.]+)"), said
end

-- remount root as read-only, returning false if it could not be
local function remountReadOnly()
    LogUtil.debug("remounting rootfs as read-only")
    if os.execute("mntroot ro 2>/dev/null") ~= 0 then
        LogUtil.warn("failed to remount rootfs as read-only")
        NotifyUtil.error("Failed to remount root as read-only")
        return false
    end
    return true
end

-- update curl using static release from moparisthebest/static-curl
-- basically adds safe guards around the sh script given here:
-- https://github.com/justrals/KindleFetch/issues/40#issuecomment-4009774337
local function updateCurl()
    LogUtil.info("installing static curl " .. MIN_VERSION)

    -- download curl, with KOReader's own HTTP, as the Kindle's own curl can be too old to connect to GitHub (#57). that
    -- holds KOReader up until it has downloaded, so say what it's waiting for
    local curl_filename = "curl-armhf"
    local curl_path = PathUtil.getTmpPath() .. "/" .. curl_filename
    local download_url = string.format(CURL_REPO_URL .. "/releases/download/v%s/%s", MIN_VERSION, curl_filename)

    LogUtil.debug("downloading static curl", download_url)
    local message = InfoMessage:new {
        text = string.format(_("Downloading curl %s..."), MIN_VERSION),
    }
    UIManager:show(message)
    UIManager:forceRePaint()
    local success, err = HttpUtil.downloadFile(download_url, curl_path)
    -- it's run as root once installed, so only the build that was released, not anything sent in its place
    if success and sha256(curl_path) ~= CurlUpdater.SHA256 then
        os.remove(curl_path)
        success, err = false, "what downloaded isn't the curl " .. MIN_VERSION .. " that was released"
    end
    UIManager:close(message)
    if not success then
        LogUtil.warn("could not download static curl from", download_url, "error:", err)
        NotifyUtil.error("Failed to download curl update: " .. tostring(err))
        return false
    end

    -- make it executable
    local chmod_cmd = string.format("chmod +x %s", CurlUtil.shellQuote(curl_path))
    if os.execute(chmod_cmd) ~= 0 then
        os.remove(curl_path) -- remove downloaded file
        LogUtil.warn("could not make", curl_path, "executable")
        NotifyUtil.error("Failed to set file permissions")
        return false
    end

    -- backup system curl
    local system_curl = "/usr/bin/curl"
    local backup_curl = "/usr/bin/curl.system.bak"

    -- change perms to rw
    LogUtil.debug("remounting rootfs as read-write")
    if os.execute("mntroot rw 2>/dev/null") ~= 0 then
        LogUtil.warn("failed to remount rootfs as read-write")
        NotifyUtil.error("Failed to remount root as read-write")
        return false
    end

    -- backup original curl if not already backed up
    if os.execute(string.format("test -f %s", CurlUtil.shellQuote(backup_curl))) ~= 0 then
        LogUtil.debug("backing up system curl")
        if
            os.execute(
                string.format(
                    "cp %s %s 2>/dev/null",
                    CurlUtil.shellQuote(system_curl),
                    CurlUtil.shellQuote(backup_curl)
                )
            ) ~= 0
        then
            LogUtil.warn("could not back up", system_curl, "to", backup_curl)
            NotifyUtil.error("Failed to create curl backup")
            remountReadOnly()
            return false
        end
    end

    -- install new curl
    LogUtil.debug("installing static curl to " .. system_curl)
    if
        os.execute(
            string.format("cp %s %s 2>/dev/null", CurlUtil.shellQuote(curl_path), CurlUtil.shellQuote(system_curl))
        ) ~= 0
    then
        LogUtil.warn("could not copy", curl_path, "to", system_curl)
        NotifyUtil.error("Failed to install new curl update")
        remountReadOnly()
        return false
    end

    -- set permissions
    if os.execute(string.format("chmod 755 %s", CurlUtil.shellQuote(system_curl))) ~= 0 then
        LogUtil.warn("failed to set curl permissions (continuing anyway)")
    end

    -- check it runs on this Kindle, putting the old one back if not, so there's still a curl that does
    local installed_version, said = runVersion(system_curl)
    if installed_version ~= MIN_VERSION then
        LogUtil.warn("the new curl doesn't run on this Kindle, saying", said, "so putting the old one back")
        local restored = os.execute(
            string.format("cp %s %s 2>/dev/null", CurlUtil.shellQuote(backup_curl), CurlUtil.shellQuote(system_curl))
        ) == 0
        remountReadOnly()
        -- whichever is there now
        CurlUtil.forgetVersion()
        if restored then
            NotifyUtil.error("The new curl doesn't run on this Kindle, so the old one has been put back")
        else
            LogUtil.err("could not put the old curl back from", backup_curl)
            NotifyUtil.error(
                "The new curl doesn't run on this Kindle, and the old one couldn't be put back from " .. backup_curl
            )
        end
        return false
    end

    if not remountReadOnly() then
        return false
    end

    LogUtil.info("installed static curl " .. MIN_VERSION)
    -- so searches use the new curl straight away, rather than once KOReader has restarted
    CurlUtil.forgetVersion()
    NotifyUtil.info("Updated curl to v" .. MIN_VERSION)
    -- ask again if it's ever out of date again, e.g. once a Kindle update puts the old one back
    KindleFetchSettings:setCurlUpdateDeclined(false)
    return true
end

-- prompt for curl update
local function promptCurlUpdate(current_version, min_version)
    local message = string.format(
        "curl v%s is installed.\nMinimum required: v%s\n\nUntil curl is updated, searches are slower and can't be "
            .. "called off, and books and their covers may not download.\n\nUpdate curl now?",
        current_version,
        min_version
    )

    local confirm_dialog
    confirm_dialog = InputDialog:new {
        title = _("Update curl?"),
        input_type = "text",
        input = message,
        readonly = true,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        LogUtil.info("curl update declined")
                        -- so it isn't offered again every day, only when asked to check for updates
                        KindleFetchSettings:setCurlUpdateDeclined(true)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        updateCurl()
                    end,
                },
            },
        },
    }

    UIManager:show(confirm_dialog)
end

-- check curl is available and at least MIN_VERSION, offering to update it if not (again after it was turned down
-- only if the user asked for the check)
function CurlUpdater.checkVersion(user_requested)
    -- installing curl relies on mntroot, so is only possible on a Kindle
    if not Device:isKindle() then
        LogUtil.debug("not running on a kindle, skipping curl version check")
        return true
    end
    LogUtil.debug("checking curl version")

    local current_version_str = CurlUtil.getVersion()
    if not current_version_str then
        LogUtil.warn("curl not found or version could not be determined")
        return false
    end

    local current_version = VersionUtil.parseVersion(current_version_str)
    local min_version_parsed = VersionUtil.parseVersion(MIN_VERSION)

    if not current_version or not min_version_parsed then
        LogUtil.warn("could not parse curl versions", {
            current = current_version_str,
            minimum = MIN_VERSION,
        })
        return false
    end

    LogUtil.info("curl is version", current_version_str, "and needs at least", MIN_VERSION)

    local cmp = VersionUtil.compareVersions(current_version, min_version_parsed)
    if cmp >= 0 then
        LogUtil.debug("curl is up to date")
        return true
    end

    if not user_requested and KindleFetchSettings:getCurlUpdateDeclined() then
        LogUtil.warn("curl", current_version_str, "is older than", MIN_VERSION .. ", but updating it was turned down")
        return false
    end

    LogUtil.warn("curl", current_version_str, "is older than", MIN_VERSION .. ", asking to update it")
    return promptCurlUpdate(current_version_str, MIN_VERSION)
end

return CurlUpdater
