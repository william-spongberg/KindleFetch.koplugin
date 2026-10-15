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
        -- whether entries are kept once they've expired, for when there's nothing newer (see peek), rather than
        -- deleted
        keep_expired = opts.keep_expired,
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
    if type(entry) == "table" and self.onEvict then
        self.onEvict(key, entry.value)
    end
end

-- how long ago an entry was stored, in seconds, or nil when that can't be known: it was saved without a time (e.g.
-- by hand, or by a file that was cut short), or the time is still to come, as the clock has been put back since, as
-- an e-reader's can be when its battery runs flat. those are taken to have expired, as they may have long ago
local function age(entry, now)
    local timestamp = type(entry) == "table" and tonumber(entry.timestamp)
    if not timestamp or timestamp > now then
        return nil
    end
    return now - timestamp
end

-- the order each entry was stored in, which, unlike the time it was stored, doesn't go back when the clock does:
-- covers stored after it had, as the oldest, were pushed out by the next ones
function KindleFetchCache:lastSeq()
    if not self.last_seq then
        self.last_seq = 0
        for _, entry in pairs(self.cache) do
            local seq = type(entry) == "table" and tonumber(entry.seq)
            if seq and seq > self.last_seq then
                self.last_seq = seq
            end
        end
    end
    return self.last_seq
end

-- push out the entry stored before the others, those that can't be told apart (stored by older versions, or saved
-- wrongly) first
function KindleFetchCache:removeOldest()
    local oldest_key, oldest_seq, oldest_timestamp
    for key, entry in pairs(self.cache) do
        local seq = type(entry) == "table" and tonumber(entry.seq) or 0
        local timestamp = type(entry) == "table" and tonumber(entry.timestamp) or -math.huge
        if oldest_key == nil or seq < oldest_seq or (seq == oldest_seq and timestamp < oldest_timestamp) then
            oldest_key, oldest_seq, oldest_timestamp = key, seq, timestamp
        end
    end

    if oldest_key ~= nil then
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
    self.cache = type(file.data) == "table" and file.data or {}
end

function KindleFetchCache:save()
    self:load()

    -- drop expired entries, which would otherwise stay until they're looked up again
    local expiry = self:getExpiry()
    if expiry and not self.keep_expired then
        local now = os.time()
        local expired = {}
        for key, entry in pairs(self.cache) do
            local entry_age = age(entry, now)
            if not entry_age or entry_age > expiry then
                table.insert(expired, key)
            end
        end
        for _, key in ipairs(expired) do
            self:evict(key)
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
    if entry == nil then
        return nil
    end

    local entry_age = age(entry, os.time())
    local expiry = self:getExpiry()
    if type(entry) ~= "table" or (expiry and (not entry_age or entry_age > expiry)) then
        LogUtil.debug("cache expired for key:", key, "age:", entry_age, "seconds")

        if type(entry) ~= "table" or not self.keep_expired then
            self:evict(key)
            self:save()
        end
        return nil
    end

    LogUtil.debug("cache hit for key:", key, "returned", entry.value)
    return entry.value
end

-- what's stored for the key, however long ago, where entries are kept once they've expired (see keep_expired), e.g.
-- the mirrors looked up before, for when they can't be looked up again
function KindleFetchCache:peek(...)
    self:load()
    local entry = self.cache[self.makeKey(...)]
    return type(entry) == "table" and entry.value or nil
end

-- store an entry without saving the cache, so that several can be stored and then saved together
function KindleFetchCache:put(value, ...)
    self:load()

    local key = self.makeKey(...)

    self.last_seq = self:lastSeq() + 1
    self.cache[key] = {
        timestamp = os.time(),
        seq = self.last_seq,
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
    self.last_seq = nil
    self:save()
end

function KindleFetchCache:deleteValueFromKey(value, ...)
    self:load()
    local key = self.makeKey(...)
    local entry = self.cache[key]

    if type(entry) ~= "table" then
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
    if type(entry) ~= "table" or type(entry.value) ~= "table" or entry.value[1] == value then
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

-- put value last in the list cached under the key, as moveValueToFront puts it first
function KindleFetchCache:moveValueToBack(value, ...)
    self:load()
    local entry = self.cache[self.makeKey(...)]
    if type(entry) ~= "table" or type(entry.value) ~= "table" or entry.value[#entry.value] == value then
        return
    end

    local reordered = {}
    for _, v in ipairs(entry.value) do
        if v ~= value then
            table.insert(reordered, v)
        end
    end
    if #reordered == #entry.value then
        return
    end
    table.insert(reordered, value)
    entry.value = reordered

    self:save()
end

return KindleFetchCache
