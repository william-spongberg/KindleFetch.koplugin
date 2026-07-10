local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")

local SearchCache = {}

-- constants
local CACHE_EXPIRY = 72 * 60 * 60 -- 72 hours
local MAX_ENTRIES = 100

-- actual cache
local cache = nil

local function getCacheFile()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/kindlefetch_cache.lua")
end

local function load()
    if cache then
        return
    end

    local settings = getCacheFile()
    cache = settings.data or {}
end

local function countEntries()
    local count = 0

    for _ in pairs(cache) do
        count = count + 1
    end

    return count
end

local function removeOldestEntry()
    local oldest_key
    local oldest_timestamp

    for key, entry in pairs(cache) do
        if entry.timestamp then
            if oldest_timestamp == nil or entry.timestamp < oldest_timestamp then
                oldest_timestamp = entry.timestamp
                oldest_key = key
            end
        end
    end

    if oldest_key then
        cache[oldest_key] = nil
    end
end

local function save()
    -- remove old entries to ensure not using too much memory
    while countEntries() > MAX_ENTRIES do
        removeOldestEntry()
    end

    local settings = getCacheFile()
    settings.data = cache
    settings:flush()
end

local function makeKey(query, page, languages, file_types, book_types)
    return table.concat({query, tostring(page), table.concat(languages, ","), table.concat(file_types, ","),
                         table.concat(book_types, ",")}, "|")
end

function SearchCache:get(query, page, languages, file_types, book_types)
    load()

    local key = makeKey(query, page, languages, file_types, book_types)

    local entry = cache[key]

    if not entry then
        return nil
    end

    -- if found entry has expired, delete it and return nil
    if os.time() - entry.timestamp > CACHE_EXPIRY then
        cache[key] = nil
        save()
        return nil
    end

    return entry.results
end

function SearchCache:set(query, page, languages, file_types, book_types, results)
    load()

    local key = makeKey(query, page, languages, file_types, book_types)

    cache[key] = {
        timestamp = os.time(),
        results = results
    }

    save()
end

function SearchCache:clear()
    cache = {}
    save()
end

return SearchCache
