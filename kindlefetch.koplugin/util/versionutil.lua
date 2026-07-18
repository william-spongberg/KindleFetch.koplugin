local lfs = require("libs/libkoreader-lfs")

-- constants
local TMP_DIR = lfs.currentdir() .. "/bin"

local VersionUtil = {}

function VersionUtil.ensureTmpDir()
    lfs.mkdir(TMP_DIR)
end

function VersionUtil.getTmpDir()
    VersionUtil.ensureTmpDir()
    return TMP_DIR
end

-- parse a version string like "7.68.0", "0.2", or "1" into a table {major, minor, patch}
function VersionUtil.parseVersion(version_str)
    if not version_str then
        return nil
    end
    
    local major, minor, patch = version_str:match("^(%d+)%.?(%d*)%.?(%d*)")
    if not major or major == "" then
        return nil
    end
    
    return {
        major = tonumber(major),
        minor = tonumber(minor) or 0,
        patch = tonumber(patch) or 0,
        str = version_str
    }
end

-- compare two version tables: returns -1 if v1 < v2, 0 if equal, 1 if v1 > v2
function VersionUtil.compareVersions(v1, v2)
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

return VersionUtil
