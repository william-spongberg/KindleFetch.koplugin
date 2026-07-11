local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local UrlCache = {}

-- constants
local CACHE_EXPIRY = 7 * 24 * 60 * 60 -- one week

-- actual cache
local cache = nil

local function getCacheFile()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/kindlefetch_urlcache.lua")
end

local function load()
    -- return immediately if already loaded
    if cache then
        return
    end

    -- load from cache file if data/file exists
    local file = getCacheFile()
    cache = file.data or {}
end

local function save()
    -- write cache to file
    local file = getCacheFile()
    file.data = cache
    file:flush()
end

local function delete(key)
    logger.info("KindleFetch: deleting URL cache entry:", key)

    cache[key] = nil
end

function UrlCache:get(key)
    load()

    logger.info("KindleFetch: checking URL cache for key:", key)

    local entry = cache[key]
    if not entry then
        logger.info("KindleFetch: URL cache miss for key:", key)
        return nil
    end

    local age = os.time() - entry.timestamp
    if age > CACHE_EXPIRY then
        logger.info("KindleFetch: URL cache expired for key:", key, "age:", age, "seconds")

        delete(key)
        save()
        return nil
    end

    logger.info("KindleFetch: URL cache hit for key:", key)
    return entry.value
end

function UrlCache:set(key, value)
    load()
    cache[key] = {
        timestamp = os.time(),
        value = value
    }

    logger.info("KindleFetch: stored URL cache entry:", key)
    save()
end

function UrlCache:clear()
    logger.info("KindleFetch: clearing URL cache")

    cache = {}
    save()
end

return UrlCache
