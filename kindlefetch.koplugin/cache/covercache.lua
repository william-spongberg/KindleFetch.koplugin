local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local FileUtil = require("util.fileutil")

local CoverCache = {}

-- constants
local CACHE_DIR = DataStorage:getSettingsDir() .. "/kindlefetch_covers/"

local function ensureCacheDir()
    lfs.mkdir(CACHE_DIR)
end

function CoverCache:getPath(md5)
    ensureCacheDir()
    return CACHE_DIR .. md5 .. ".jpg"
end

function CoverCache:get(md5)
    local path = self:getPath(md5)

    if FileUtil.isValidFile(path) then
        return path
    end

    return nil
end

function CoverCache:set(md5, image_data)
    local path = self:getPath(md5)
    FileUtil.createFile(path, image_data)
    return path
end

return CoverCache
