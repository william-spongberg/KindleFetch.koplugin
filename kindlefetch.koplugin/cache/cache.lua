local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local KindleFetchCache = {}

function KindleFetchCache:new(opts)
    local obj = {
        filename = opts.filename,
        expiry = opts.expiry,
        max_entries = opts.max_entries,
        makeKey = opts.makeKey or function(key)
            return key
        end,
        cache = nil
    }

    setmetatable(obj, self)
    self.__index = self
    return obj
end

function KindleFetchCache:getCacheFile()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. self.filename)
end

function KindleFetchCache:count()
    local count = 0

    for _ in pairs(self.cache) do
        count = count + 1
    end

    return count
end

function KindleFetchCache:delete(key)
    logger.dbg("KindleFetch: deleting cache entry:", key)

    self.cache[key] = nil
end

function KindleFetchCache:removeOldest()
    local oldest_key
    local oldest_timestamp

    -- read through all entries for oldest timestamp
    for key, entry in pairs(self.cache) do
        if entry.timestamp then
            if oldest_timestamp == nil or entry.timestamp < oldest_timestamp then
                oldest_timestamp = entry.timestamp
                oldest_key = key
            end
        end
    end

    -- delete oldest entry, if exists
    if oldest_key then
        self:delete(oldest_key)
    end
end

function KindleFetchCache:load()
    -- return immediately if already loaded
    if self.cache then
        return
    end

    -- load from cache file if data/file exists
    local file = self:getCacheFile()
    self.cache = file.data or {}
end

function KindleFetchCache:save()
    if self.max_entries then
        -- remove entries if past cache limit
        while self:count() > self.max_entries do
            self:removeOldest()
        end
    end

    -- write cache to file
    local file = self:getCacheFile()
    file.data = self.cache
    file:flush()
end

function KindleFetchCache:get(...)
    self:load()

    local key = self.makeKey(...)
    logger.dbg("KindleFetch: checking cache for key:", key)

    local entry = self.cache[key]
    if not entry then
        return nil
    end

    local age = os.time() - entry.timestamp
    if self.expiry and age > self.expiry then
        logger.dbg("KindleFetch: cache expired for key:", key, "age:", age, "seconds")

        self:delete(key)
        self:save()
        return nil
    end

    logger.dbg("KindleFetch: cache hit for key:", key, "returned", entry.value)
    return entry.value
end

function KindleFetchCache:set(value, ...)
    self:load()

    local key = self.makeKey(...)

    self.cache[key] = {
        timestamp = os.time(),
        value = value
    }

    logger.dbg("KindleFetch: stored cache entry:", key, "with", value)
    self:save()
end

function KindleFetchCache:clear()
    logger.dbg("KindleFetch: clearing cache")

    self.cache = {}
    self:save()
end

return KindleFetchCache
