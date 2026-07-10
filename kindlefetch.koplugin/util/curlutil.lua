local logger = require("logger")
local FileUtil = require("util.fileutil")
local Notification = require("ui/widget/notification")

local CurlUtil = {}

-- shell-escape a string for safe inclusion in a shell command
function CurlUtil.shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- parse a version string like "7.68.0" into a table {major, minor, patch}
local function parseVersion(version_str)
    if not version_str then
        return nil
    end
    local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then
        return nil
    end
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        str = version_str
    }
end

-- compare two version tables: returns -1 if v1 < v2, 0 if equal, 1 if v1 > v2
local function compareVersions(v1, v2)
    if not v1 or not v2 then
        return nil
    end
    if v1.major ~= v2.major then
        return v1.major < v2.major and -1 or 1
    end
    if v1.minor ~= v2.minor then
        return v1.minor < v2.minor and -1 or 1
    end
    if v1.patch ~= v2.patch then
        return v1.patch < v2.patch and -1 or 1
    end
    return 0
end

-- TODO
function CurlUtil.getRepoVersion()
    -- curl -s https://api.github.com/repos/william-spongberg/KindleFetch.koplugin/releases/latest | grep '"tag_name":'
end

-- get the installed curl version
function CurlUtil.getCurlVersion()
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

-- check if the installed curl version is at least the minimum required version
function CurlUtil.isCurlVersionOk(min_version)
    local current_version_str = CurlUtil.getCurlVersion()
    if not current_version_str then
        logger.warn("KindleFetch: curl not found or version could not be determined")
        return false
    end

    local current_version = parseVersion(current_version_str)
    local min_version_parsed = parseVersion(min_version)

    if not current_version or not min_version_parsed then
        logger.warn("KindleFetch: could not parse curl versions", {
            current = current_version_str,
            minimum = min_version
        })
        return false
    end

    local cmp = compareVersions(current_version, min_version_parsed)
    local is_ok = cmp >= 0

    logger.info("KindleFetch: curl version check", {
        current = current_version_str,
        minimum = min_version,
        is_ok = is_ok
    })

    return is_ok
end

-- install static curl from moparisthebest/static-curl releases
-- basically adds safe guards around the sh script given here https://github.com/justrals/KindleFetch/issues/40#issuecomment-4009774337
function CurlUtil.installStaticCurl(target_version)
    logger.info("KindleFetch: attempting to install static curl v" .. target_version)

    -- create staging directory
    local staging_dir = "/mnt/us/bin"
    local mkdir_cmd = string.format("mkdir -p %s", CurlUtil.shellQuote(staging_dir))
    logger.dbg("KindleFetch: creating staging directory", mkdir_cmd)
    if os.execute(mkdir_cmd .. " 2>/dev/null") ~= 0 then
        logger.error("KindleFetch: failed to create staging directory", staging_dir)
        return false
    end

    -- download static curl
    local curl_filename = "curl-static-armhf"
    local curl_path = staging_dir .. "/" .. curl_filename
    local download_url = string.format(
        "https://github.com/moparisthebest/static-curl/releases/download/v%s/%s",
        target_version, curl_filename)

    logger.info("KindleFetch: downloading static curl", download_url)

    local download_cmd = string.format(
        "curl -fL -o %s %s",
        CurlUtil.shellQuote(curl_path), CurlUtil.shellQuote(download_url))

    if os.execute(download_cmd .. " 2>/dev/null") ~= 0 then
        logger.error("KindleFetch: failed to download static curl", download_url)
        os.remove(curl_path)
        return false
    end

    -- make it executable
    local chmod_cmd = string.format("chmod +x %s", CurlUtil.shellQuote(curl_path))
    if os.execute(chmod_cmd) ~= 0 then
        logger.error("KindleFetch: failed to set executable permission", curl_path)
        os.remove(curl_path)
        return false
    end

    -- backup system curl
    local system_curl = "/usr/bin/curl"
    local backup_curl = "/usr/bin/curl.system.bak"

    logger.info("KindleFetch: remounting rootfs as read-write")
    if os.execute("mntroot rw 2>/dev/null") ~= 0 then
        logger.error("KindleFetch: failed to remount rootfs as read-write")
        return false
    end

    -- backup original curl if not already backed up
    if os.execute(string.format("test -f %s", CurlUtil.shellQuote(backup_curl))) ~= 0 then
        logger.info("KindleFetch: backing up system curl")
        if os.execute(string.format("cp %s %s 2>/dev/null", CurlUtil.shellQuote(system_curl), CurlUtil.shellQuote(backup_curl))) ~= 0 then
            logger.warn("KindleFetch: failed to backup system curl (continuing anyway)")
        end
    end

    -- install new curl
    logger.info("KindleFetch: installing static curl to " .. system_curl)
    if os.execute(string.format("cp %s %s 2>/dev/null", CurlUtil.shellQuote(curl_path), CurlUtil.shellQuote(system_curl))) ~= 0 then
        logger.error("KindleFetch: failed to install static curl")
        os.execute("mntroot ro 2>/dev/null")
        return false
    end

    -- set permissions
    if os.execute(string.format("chmod 755 %s", CurlUtil.shellQuote(system_curl))) ~= 0 then
        logger.warn("KindleFetch: failed to set curl permissions (continuing anyway)")
    end

    -- remount as read-only
    logger.info("KindleFetch: remounting rootfs as read-only")
    if os.execute("mntroot ro 2>/dev/null") ~= 0 then
        logger.error("KindleFetch: failed to remount rootfs as read-only")
        return false
    end

    logger.info("KindleFetch: static curl installation completed successfully")
    return true
end

-- check curl is available and at least min_version, update if necessary
function CurlUtil.checkCurlVersion()
    local min_version = "8.17.0"

    if CurlUtil.isCurlVersionOk(min_version) then
        logger.info("KindleFetch: curl version is sufficient", min_version)
        return true
    end

    logger.warn("KindleFetch: curl version is below " .. min_version .. ", attempting installation")
    Notification:notify("curl is outdated, updating curl...", Notification.SOURCE_ALWAYS_SHOW)
    local install_success = CurlUtil.installStaticCurl(min_version)

    if not install_success then
        logger.error("KindleFetch: failed to install static curl v" .. min_version)
        Notification:notify("Failed to update curl", Notification.SOURCE_ALWAYS_SHOW)
        return false
    end

    -- verify the installation was successful
    if CurlUtil.isCurlVersionOk(min_version) then
        Notification:notify("Successfully updated curl to v" .. min_version, Notification.SOURCE_ALWAYS_SHOW)
        return true
    else
        return false
    end
end

-- get the remote file size in bytes from a URL's Content-Length header
function CurlUtil.getRemoteFileSize(url)
    local cmd = string.format("curl -s -L -I %s", CurlUtil.shellQuote(url))

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil
    end

    local headers = pipe:read("*a")
    pipe:close()

    if not headers then
        return nil
    end

    -- get content length from first 200 response
    local file_size = nil
    for block in headers:gmatch("HTTP[/%d%.]+.-\r?\n\r?\n") do
        local size = block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if size then
            file_size = tonumber(size)
        end
    end

    return file_size
end

-- spawn a curl download process in the background
function CurlUtil.spawnDownload(download_url, filepath, use_proxy)
    local exit_file = filepath .. ".exitcode"
    FileUtil.removeFile(exit_file)
    FileUtil.removeFile(filepath)

    local proxy_flag = ""
    if use_proxy then
        local proxy_url = os.getenv("PROXY_URL")
        if proxy_url and proxy_url ~= "" then
            proxy_flag = "-x " .. CurlUtil.shellQuote(proxy_url) .. " "
        end
    end

    local cmd = string.format(
        "(curl -sL -f %s-A 'Mozilla/5.0' --retry 2 --retry-delay 2 --connect-timeout 15 -o %s %s; echo $? > %s) >/dev/null 2>&1 & echo $!",
        proxy_flag, CurlUtil.shellQuote(filepath), CurlUtil.shellQuote(download_url), CurlUtil.shellQuote(exit_file))

    logger.info("KindleFetch: curl command", cmd)

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, nil, "unable to launch curl"
    end

    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        return nil, nil, "unable to determine curl pid"
    end

    return pid, exit_file
end

-- check if a process with the given PID is still running
function CurlUtil.isPidRunning(pid)
    if not pid then
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

-- kill a process with the given PID
function CurlUtil.killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

return CurlUtil
