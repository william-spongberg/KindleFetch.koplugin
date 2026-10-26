local LogUtil = require("util.logutil")
local VersionUtil = require("util.versionutil")
local Device = require("device")

-- which curl is installed, and what it can do: fetch pages (securely), ask for them compressed, use encrypted DNS
local CurlVersion = {}

-- the curl installed on Kindles, whose own is too old for Library Genesis: the latest static build, for security fixes
CurlVersion.MIN_VERSION = "8.21.0"

-- how the installed curl describes itself, or nil if it isn't there, looked up once a session as it means starting curl
local curl_description, curl_protocols
local function describeCurl()
    if curl_description == nil then
        local pipe = io.popen("curl --version 2>/dev/null", "r")
        local output = pipe and pipe:read("*a") or ""
        if pipe then
            pipe:close()
        end
        -- false when curl isn't there, so it isn't looked for again
        curl_description = output:match("^[^\n]+") or false
        -- the protocols it can use, where it says, which leave https out for a curl built without TLS
        curl_protocols = output:match("\nProtocols:%s*([^\n]*)")
    end
    return curl_description or nil
end

-- the installed curl's version, e.g. "8.17.0", or nil if curl isn't there
function CurlVersion.getVersion()
    local description = describeCurl()
    -- "curl X.Y.Z (platform) ..."
    return description and description:match("^curl%s+([%d%.]+)")
end

-- whether the installed curl is at least min_version, e.g. "7.68.0", for options older ones would fail on
function CurlVersion.isAtLeast(min_version)
    local version = VersionUtil.parseVersion(CurlVersion.getVersion())
    return version ~= nil and VersionUtil.compareVersions(version, VersionUtil.parseVersion(min_version)) >= 0
end

-- the first curl that can look sites' names up with DNS over HTTPS (see CurlUtil.applyEncryptedDns)
local DOH_MIN_VERSION = "7.62.0"

-- whether curl can fetch web pages and ask for them compressed, worked out once per session as it means running curl
local can_fetch, can_decompress
local function checkCurl()
    if can_fetch ~= nil then
        return
    end

    local description = describeCurl()
    local version = VersionUtil.parseVersion(description and description:match("^curl%s+([%d%.]+)"))
    -- every site is https, which a curl built without TLS can't fetch at all
    local has_tls = not curl_protocols or (" " .. curl_protocols .. " "):find(" https ", 1, true) ~= nil
    -- on a Kindle, only once it has been updated, as the curl it comes with can't connect to Library Genesis
    can_fetch = version ~= nil
        and has_tls
        and (
            not Device:isKindle()
            or VersionUtil.compareVersions(version, VersionUtil.parseVersion(CurlVersion.MIN_VERSION)) >= 0
        )
    can_decompress = description ~= nil and description:find("zlib", 1, true) ~= nil
    LogUtil.info(
        "fetching pages with",
        can_fetch and "curl"
            or version and not has_tls and "KOReader, as curl can't make secure connections,"
            or "KOReader, as curl is missing or too old,",
        can_fetch and can_decompress and "compressed" or "uncompressed"
    )
end

-- fetch pages with KOReader's own HTTP for the rest of the session, as curl has been found not to connect where it can
function CurlVersion.stopFetching(why)
    checkCurl()
    if can_fetch then
        LogUtil.warn("fetching pages with KOReader from now on, as", why)
        can_fetch = false
    end
end

function CurlVersion.canFetch()
    checkCurl()
    return can_fetch
end

-- whether curl can ask for pages compressed, which a curl built without zlib can't
function CurlVersion.canDecompress()
    checkCurl()
    return can_decompress
end

-- look curl up again when it's next needed, e.g. once a newer one has been installed
function CurlVersion.forgetVersion()
    curl_description = nil
    can_fetch, can_decompress = nil, nil
end

-- whether this is a Kindle whose curl is older than the oldest known to connect to Library Genesis
function CurlVersion.isOutdated()
    return Device:isKindle() and CurlVersion.getVersion() ~= nil and not CurlVersion.isAtLeast(CurlVersion.MIN_VERSION)
end

-- whether curl can look names up with encrypted DNS (see applyEncryptedDns)
function CurlVersion.canUseEncryptedDns()
    return CurlVersion.canFetch() and CurlVersion.isAtLeast(DOH_MIN_VERSION)
end

return CurlVersion
