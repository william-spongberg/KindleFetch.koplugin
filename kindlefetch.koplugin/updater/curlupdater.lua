local Device = require("device")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local VersionUtil = require("util.versionutil")
local PathUtil = require("util.pathutil")
local ShellUtil = require("util.shellutil")
local KindleFetchSettings = require("settings.settings")
local sha2 = require("ffi/sha2")
local T = require("ffi/util").template
local _ = require("gettext")

-- constants
local MIN_VERSION = CurlUtil.MIN_VERSION
local CURL_REPO_URL = "https://github.com/moparisthebest/static-curl"
-- the Kindle's own curl, which is kept as BACKUP_CURL to put back by hand (see the README), and NEW_CURL, where the new
-- one is copied to before it replaces the old one, once it's all there and runs, so a curl that runs is always there
local SYSTEM_CURL = "/usr/bin/curl"
local BACKUP_CURL = "/usr/bin/curl.system.bak"
local NEW_CURL = "/usr/bin/curl.new"

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

-- remount root as read-only, returning true, or nil and what went wrong
local function remountReadOnly()
    LogUtil.debug("remounting rootfs as read-only")
    return ShellUtil.run("make the root file system read-only again", "mntroot ro")
end

-- copy the new curl into place as the Kindle's, keeping its own (once) to put back by hand. returns true, or nil and
-- what went wrong, leaving the Kindle's own curl as it was
local function install(curl_path)
    -- copied whole before it's kept, as a backup cut short by the storage filling up was taken to be the Kindle's curl
    if not FileUtil.isValidFile(BACKUP_CURL) then
        LogUtil.debug("backing up system curl")
        local ok, err = ShellUtil.run(
            "back up the Kindle's own curl",
            string.format(
                "cp %s %s && mv %s %s",
                CurlUtil.shellQuote(SYSTEM_CURL),
                CurlUtil.shellQuote(BACKUP_CURL .. ".new"),
                CurlUtil.shellQuote(BACKUP_CURL .. ".new"),
                CurlUtil.shellQuote(BACKUP_CURL)
            )
        )
        if not ok then
            ShellUtil.run("remove the backup cut short", "rm -f " .. CurlUtil.shellQuote(BACKUP_CURL .. ".new"))
            return nil, T(_("the Kindle's own curl couldn't be backed up (%1)"), err)
        end
    end

    -- next to the old one, which is only replaced once the new one is all there and runs: copying over it directly
    -- left it cut short, and nothing would run, when the storage filled up
    LogUtil.debug("copying static curl to", NEW_CURL)
    local ok, err = ShellUtil.run(
        "copy the new curl into place",
        string.format("cp %s %s", CurlUtil.shellQuote(curl_path), CurlUtil.shellQuote(NEW_CURL))
    )
    if not ok then
        ShellUtil.run("remove the new curl cut short", "rm -f " .. CurlUtil.shellQuote(NEW_CURL))
        return nil, T(_("the new curl couldn't be copied into place (%1)"), err)
    end
    if not ShellUtil.run("set the new curl's permissions", "chmod 755 " .. CurlUtil.shellQuote(NEW_CURL)) then
        LogUtil.warn("carrying on without setting the new curl's permissions")
    end

    local installed_version, said = runVersion(NEW_CURL)
    if installed_version ~= MIN_VERSION then
        LogUtil.warn("the new curl doesn't run on this Kindle, saying", said, "so keeping the old one")
        ShellUtil.run("remove the new curl", "rm -f " .. CurlUtil.shellQuote(NEW_CURL))
        return nil, _("the new curl doesn't run on this Kindle, so the old one has been kept")
    end

    -- in one go, so there's always a curl there
    ok, err = ShellUtil.run(
        "replace the old curl",
        string.format("mv %s %s", CurlUtil.shellQuote(NEW_CURL), CurlUtil.shellQuote(SYSTEM_CURL))
    )
    if not ok then
        ShellUtil.run("remove the new curl", "rm -f " .. CurlUtil.shellQuote(NEW_CURL))
        return nil, T(_("the old curl couldn't be replaced (%1)"), err)
    end
    return true
end

-- update curl using static release from moparisthebest/static-curl
-- basically adds safe guards around the sh script given here:
-- https://github.com/justrals/KindleFetch/issues/40#issuecomment-4009774337
-- returns true, or nil and what went wrong, leaving the Kindle's own curl as it was
local function updateCurl()
    LogUtil.info("installing static curl " .. MIN_VERSION)

    -- download curl, with KOReader's own HTTP, as the Kindle's own curl can be too old to connect to GitHub (#57). that
    -- holds KOReader up until it has downloaded, so say what it's waiting for
    local curl_filename = "curl-armhf"
    local curl_path = PathUtil.getTmpPath() .. "/" .. curl_filename
    local download_url = string.format(CURL_REPO_URL .. "/releases/download/v%s/%s", MIN_VERSION, curl_filename)

    LogUtil.debug("downloading static curl", download_url)
    local message = InfoMessage:new {
        text = T(_("Downloading curl %1..."), MIN_VERSION),
    }
    UIManager:show(message)
    UIManager:forceRePaint()
    local success, err = HttpUtil.downloadFile(download_url, curl_path)
    -- it's run as root once installed, so only the build that was released, not anything sent in its place
    if success and sha256(curl_path) ~= CurlUpdater.SHA256 then
        success, err = nil, T(_("what downloaded isn't the curl %1 that was released"), MIN_VERSION)
    end
    UIManager:close(message)
    if not success then
        LogUtil.warn("could not download static curl from", download_url, "error:", err)
        FileUtil.removeFile(curl_path)
        return nil, T(_("curl couldn't be downloaded (%1)"), err)
    end

    local ok
    ok, err = ShellUtil.run("make the new curl executable", "chmod +x " .. CurlUtil.shellQuote(curl_path))
    if not ok then
        FileUtil.removeFile(curl_path)
        return nil, T(_("the new curl couldn't be made executable (%1)"), err)
    end

    LogUtil.debug("remounting rootfs as read-write")
    ok, err = ShellUtil.run("make the root file system writable", "mntroot rw")
    if not ok then
        FileUtil.removeFile(curl_path)
        return nil, T(_("the Kindle's system files couldn't be made writable (%1)"), err)
    end

    local installed, install_err = install(curl_path)
    -- once it has, whether or not it installed: a root file system left writable is only said in crash.log, as
    -- a curl that installed has
    local remounted, remount_err = remountReadOnly()
    FileUtil.removeFile(curl_path)
    -- whichever is there now
    CurlUtil.forgetVersion()
    if not installed then
        return nil, install_err
    end
    if not remounted then
        LogUtil.warn("installed static curl, but the root file system is still writable:", remount_err)
    end

    LogUtil.info("installed static curl " .. MIN_VERSION)
    -- ask again if it's ever out of date again, e.g. once a Kindle update puts the old one back
    KindleFetchSettings:setCurlUpdateDeclined(nil)
    return true
end

-- prompt for curl update
local function promptCurlUpdate(current_version, min_version)
    local message = T(
        _(
            "curl v%1 is installed.\nMinimum required: v%2\n\nUntil curl is updated, searches are slower and can't be "
                .. "called off, and books and their covers may not download.\n\nUpdate curl now?"
        ),
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
                        -- so it isn't offered again every day, only when asked to check for updates, until there's a
                        -- newer one to update to
                        KindleFetchSettings:setCurlUpdateDeclined(min_version)
                    end,
                },
                {
                    text = _("Update"),
                    callback = function()
                        UIManager:close(confirm_dialog)
                        local ok, err = updateCurl()
                        if ok then
                            NotifyUtil.info(T(_("Updated curl to v%1"), MIN_VERSION))
                        else
                            NotifyUtil.error(T(_("Updating curl failed: %1"), err))
                        end
                    end,
                },
            },
        },
    }

    UIManager:show(confirm_dialog)
end

-- check curl is available and at least MIN_VERSION, offering to update it if not (again after it was turned down
-- only if the user asked for the check, or there's a newer one to update to)
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

    -- which older versions saved as true, rather than the version turned down, taken to be this one
    local declined = KindleFetchSettings:getCurlUpdateDeclined()
    if declined == true then
        declined = MIN_VERSION
        KindleFetchSettings:setCurlUpdateDeclined(declined)
    end
    if not user_requested and declined == MIN_VERSION then
        LogUtil.warn("curl", current_version_str, "is older than", MIN_VERSION .. ", but updating it was turned down")
        return false
    end

    LogUtil.warn("curl", current_version_str, "is older than", MIN_VERSION .. ", asking to update it")
    return promptCurlUpdate(current_version_str, MIN_VERSION)
end

return CurlUpdater
