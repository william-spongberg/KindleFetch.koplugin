local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local logger = require("logger")

local SearchCache = {}

-- constants
local CACHE_EXPIRY = 72 * 60 * 60 -- 72 hours
local MAX_ENTRIES = 100

-- actual cache
local cache = nil

local function getCacheFile()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/kindlefetch_searchcache.lua")
end

local function count()
    local count = 0

    for _ in pairs(cache) do
        count = count + 1
    end

    return count
end

local function delete(key)
    logger.info("KindleFetch: deleting search cache entry:", key)

    cache[key] = nil
end

local function removeOldest()
    local oldest_key
    local oldest_timestamp

    -- read through all entries for oldest timestamp
    for key, entry in pairs(cache) do
        if entry.timestamp then
            if oldest_timestamp == nil or entry.timestamp < oldest_timestamp then
                oldest_timestamp = entry.timestamp
                oldest_key = key
            end
        end
    end

    -- delete oldest entry, if exists
    if oldest_key then
        delete(oldest_key)
    end
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
    local before = count()

    -- remove entries if past cache limit
    while count() > MAX_ENTRIES do
        removeOldest()
    end
    local removed = before - count()
    if removed > 0 then
        logger.info("KindleFetch: pruned", removed, "old search cache entries")
    end

    -- write cache to file
    local file = getCacheFile()
    file.data = cache
    file:flush()
end

local function makeKey(query, page, languages, file_types, book_types)
    -- concat query with | to create search key
    return table.concat({query, tostring(page), table.concat(languages, ","), table.concat(file_types, ","),
                         table.concat(book_types, ",")}, "|")
end

function SearchCache:get(query, page, languages, file_types, book_types)
    load()

    local key = makeKey(query, page, languages, file_types, book_types)
    logger.info("KindleFetch: checking search cache for key:", key)

    local entry = cache[key]
    if not entry then
        logger.info("KindleFetch: search cache miss for key:", key)
        return nil
    end

    local age = os.time() - entry.timestamp
    if age > CACHE_EXPIRY then
        logger.info("KindleFetch: search cache expired for key:", key, "age:", age, "seconds")

        delete(key)
        save()
        return nil
    end

    logger.info("KindleFetch: search cache hit for key:", key, "returned", #entry.results, "results")
    return entry.results
end

function SearchCache:set(query, page, languages, file_types, book_types, results)
    load()

    local key = makeKey(query, page, languages, file_types, book_types)
    cache[key] = {
        timestamp = os.time(),
        results = results
    }

    logger.info("KindleFetch: stored search cache entry:", key, "with", #results, "results")
    save()
end

function SearchCache:clear()
    logger.info("KindleFetch: clearing search cache")

    cache = {}
    save()
end

return SearchCache
