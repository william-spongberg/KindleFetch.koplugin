local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local FileUtil = require("util.fileutil")
local UIManager = require("ui/uimanager")
local KindleFetchCache = require("cache.cache")
local CurlUtil = require("util.curlutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")

local CoverCache = {}

-- constants
local CACHE_DIR = DataStorage:getSettingsDir() .. "/kindlefetch_covers/"

local persistent_cache = KindleFetchCache:new{
    filename = "kindlefetch_covercache.lua",
    expiry = nil, -- no expiry
    max_entries = 500, -- each cover image around 40KB, so around 20MB
    makeKey = function(md5)
        return md5
    end
}

local function ensureCacheDir()
    lfs.mkdir(CACHE_DIR)
end

function CoverCache:getPath(md5)
    ensureCacheDir()
    return CACHE_DIR .. md5 .. ".jpg"
end

function CoverCache:cacheExists(md5)
    return FileUtil.isValidFile(self:getPath(md5))
end

function CoverCache:get(md5)
    -- check persistent cache first
    local cached_path = persistent_cache:get(md5)
    if cached_path and FileUtil.isValidFile(cached_path) then
        return cached_path
    end
    -- if cache says exists but file is gone, invalidate
    if cached_path then
        persistent_cache:delete(md5)
        persistent_cache:save()
    end
    return nil
end

function CoverCache:download(md5, url)
    ensureCacheDir()
    local path = self:getPath(md5)
    
    local success = CurlUtil.download(url, path, false, false)
    if success then
        persistent_cache:set(path, md5)
        return path
    end
    
    return nil
end

function CoverCache:downloadMultiple(books, parallel_jobs)
    ensureCacheDir()
    
    local download_urls = {}
    local filepaths = {}
    local count = 0
    
    for _, book in ipairs(books) do
        if book.md5 and book.image_url and not self:get(book.md5) then
            local path = self:getPath(book.md5)
            table.insert(download_urls, book.image_url)
            table.insert(filepaths, path)
            count = count + 1
        end
    end
    
    if count == 0 then
        return 0
    end
    
    NotifyUtil.info("Getting book covers...")
        
    local successful_count = CurlUtil.downloadMultiple(download_urls, filepaths, false, false, parallel_jobs, false, 5)
    
    for _, book in ipairs(books) do
        if book.md5 then
            local path = self:getPath(book.md5)
            if FileUtil.isValidFile(path) then
                persistent_cache:set(path, book.md5)
            end
        end
    end
    
    persistent_cache:save()
    
    return successful_count
end

return CoverCache
