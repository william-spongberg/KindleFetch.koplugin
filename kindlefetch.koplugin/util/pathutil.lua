local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local PathUtil = {}

-- constants
local DATA_DIR = DataStorage:getDataDir()
local PLUGIN_NAME = "kindlefetch.koplugin"
-- plugins can live in several places, so the plugin root is worked out from where this file was loaded
local LOADED_PLUGIN_PATH = debug.getinfo(1, "S").source:match("^@(.+)/util/pathutil%.lua$")

function PathUtil.getPluginPath()
    return LOADED_PLUGIN_PATH or DATA_DIR .. "/plugins/" .. PLUGIN_NAME
end

-- scratch directory for downloads, removed after a plugin update so it must only ever hold our own files
function PathUtil.getTmpPath()
    local cachePath = DATA_DIR .. "/cache"
    local tmpPath = cachePath .. "/kindlefetch"
    lfs.mkdir(cachePath)
    lfs.mkdir(tmpPath)

    return tmpPath
end

return PathUtil
