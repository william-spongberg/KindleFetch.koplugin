local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local LogUtil = require("util.logutil")

local KindleFetchCache = {}

function KindleFetchCache:new(opts)
    local obj = {
        filename = opts.filename,
        expiry = opts.expiry,
        max_entries = opts.max_entries,
        makeKey = opts.makeKey or function(key)
            return key
        end,
        -- optionally called with the key and value of an entry that has expired or been pushed out by newer ones
        onEvict = opts.onEvict,
        cache = nil,
    }

    setmetatable(obj, self)
    self.__index = self
    return obj
end

-- opened once and kept, rather than reading the whole file again every time the cache is saved
function KindleFetchCache:getCacheFile()
    if not self.file then
        self.file = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. self.filename)
    end
    return self.file
end

function KindleFetchCache:getExpiry()
    return type(self.expiry) == "function" and self.expiry() or self.expiry
end

function KindleFetchCache:count()
    local count = 0

    for _ in pairs(self.cache) do
        count = count + 1
    end

    return count
end

function KindleFetchCache:delete(key)
    LogUtil.debug("deleting cache entry:", key)

    self.cache[key] = nil
end

-- delete an entry that has expired, or been pushed out by newer ones, letting the cache's owner clean up after it
function KindleFetchCache:evict(key)
    local entry = self.cache[key]
    self:delete(key)
    if entry and self.onEvict then
        self.onEvict(key, entry.value)
    end
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
        self:evict(oldest_key)
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
    self:load()

    -- drop expired entries, which would otherwise stay until they're looked up again
    local expiry = self:getExpiry()
    if expiry then
        local now = os.time()
        for key, entry in pairs(self.cache) do
            if entry.timestamp and now - entry.timestamp > expiry then
                self:evict(key)
            end
        end
    end

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
    LogUtil.debug("checking cache for key:", key)

    local entry = self.cache[key]
    if not entry then
        return nil
    end

    local age = os.time() - entry.timestamp
    local expiry = self:getExpiry()
    if expiry and age > expiry then
        LogUtil.debug("cache expired for key:", key, "age:", age, "seconds")

        self:evict(key)
        self:save()
        return nil
    end

    LogUtil.debug("cache hit for key:", key, "returned", entry.value)
    return entry.value
end

-- store an entry without saving the cache, so that several can be stored and then saved together
function KindleFetchCache:put(value, ...)
    self:load()

    local key = self.makeKey(...)

    self.cache[key] = {
        timestamp = os.time(),
        value = value,
    }

    LogUtil.debug("stored cache entry:", key, "with", value)
end

function KindleFetchCache:set(value, ...)
    self:put(value, ...)
    self:save()
end

function KindleFetchCache:clear()
    LogUtil.debug("clearing cache")

    self.cache = {}
    self:save()
end

function KindleFetchCache:deleteValueFromKey(value, ...)
    self:load()
    local key = self.makeKey(...)
    local entry = self.cache[key]

    if not entry then
        LogUtil.debug("cache key not found:", key)
        return
    end

    local values = entry.value
    if type(values) ~= "table" then
        LogUtil.debug("cached value is not a table for key:", key)
        return
    end

    -- build a new list rather than removing in place, as callers may still be looping over the old one
    local remaining = {}
    for _, v in ipairs(values) do
        if v ~= value then
            table.insert(remaining, v)
        else
            LogUtil.debug("removing url from cache:", value)
        end
    end
    entry.value = remaining

    -- delete cache key if no values remain
    if #remaining == 0 then
        self:delete(key)
    end

    self:save()
end

-- put value first in the list cached under the key, keeping when it was cached, so it expires when it would have
function KindleFetchCache:moveValueToFront(value, ...)
    self:load()
    local entry = self.cache[self.makeKey(...)]
    if not entry or type(entry.value) ~= "table" or entry.value[1] == value then
        return
    end

    -- build a new list rather than reordering in place, as callers may still be looping over the old one
    local reordered = { value }
    for _, v in ipairs(entry.value) do
        if v ~= value then
            table.insert(reordered, v)
        end
    end
    if #reordered > #entry.value then
        return
    end
    entry.value = reordered

    self:save()
end

return KindleFetchCache
