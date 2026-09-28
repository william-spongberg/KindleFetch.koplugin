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
local POLL_INTERVAL = 0.5

-- md5s of covers being downloaded, so they aren't downloaded twice at once
local downloading = {}

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

-- covers that fail to download are retried through PROXY_URL, like searches and books
local function hasProxy()
    local proxy_url = os.getenv("PROXY_URL")
    return proxy_url ~= nil and proxy_url ~= ""
end

function CoverCache:getPath(md5)
    ensureCacheDir()
    return CACHE_DIR .. md5 .. ".jpg"
end

function CoverCache:cacheExists(md5)
    -- must agree with get, as covers are shown using the path it returns
    return self:get(md5) ~= nil
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
    if not success and hasProxy() then
        LogUtil.debug("retrying cover download through proxy", md5)
        success = CurlUtil.download(url, path, true, false)
    end
    if success then
        persistent_cache:set(path, md5)
        return path
    end
    
    return nil
end

-- download curl's background downloads into the cover cache once it has finished, calling on_done with
-- the paths that downloaded
local function pollDownloads(pid, exit_file, config_file, filepaths, on_done)
    local exit_code = CurlUtil.getExitCode(exit_file)
    if not exit_code and CurlUtil.isPidRunning(pid) then
        UIManager:scheduleIn(POLL_INTERVAL, function()
            pollDownloads(pid, exit_file, config_file, filepaths, on_done)
        end)
        return
    end

    FileUtil.removeFile(config_file)

    -- a failed transfer may have left partial files, so only keep covers when every download succeeded
    local downloaded = {}
    for _, path in ipairs(filepaths) do
        if exit_code == 0 and FileUtil.getSize(path) > 0 then
            table.insert(downloaded, path)
        else
            FileUtil.removeFile(path)
        end
    end
    if exit_code ~= 0 then
        LogUtil.warn("cover downloads failed", CurlUtil.getErrorMeaning(exit_code))
    end

    on_done(downloaded)
end

local function startDownloads(download_urls, filepaths, use_proxy, parallel_jobs, on_done)
    local pid, exit_file, config_file, err = CurlUtil.downloadMultiple(download_urls, filepaths, use_proxy, true,
        parallel_jobs, false, 15)
    if not pid then
        LogUtil.warn("could not start cover downloads", err)
        on_done({})
        return
    end

    UIManager:scheduleIn(POLL_INTERVAL, function()
        pollDownloads(pid, exit_file, config_file, filepaths, on_done)
    end)
end

-- download missing covers in the background, calling on_done with the number downloaded once finished.
-- returns false when there was nothing to download.
function CoverCache:downloadMultiple(books, parallel_jobs, on_done)
    ensureCacheDir()
    on_done = on_done or function() end

    local download_urls = {}
    local filepaths = {}
    local md5s = {}

    for _, book in ipairs(books) do
        if book.md5 and book.image_url and not self:get(book.md5) and not downloading[book.md5] then
            table.insert(download_urls, book.image_url)
            table.insert(filepaths, self:getPath(book.md5))
            table.insert(md5s, book.md5)
            downloading[book.md5] = true
        end
    end

    if #md5s == 0 then
        return false
    end

    NotifyUtil.info("Getting book covers...")

    local function finish(downloaded_paths)
        local downloaded = {}
        for _, path in ipairs(downloaded_paths) do
            downloaded[path] = true
        end

        local count = 0
        for i, md5 in ipairs(md5s) do
            downloading[md5] = nil
            if downloaded[filepaths[i]] then
                persistent_cache:set(filepaths[i], md5)
                count = count + 1
            end
        end

        on_done(count)
    end

    startDownloads(download_urls, filepaths, false, parallel_jobs, function(downloaded_paths)
        if #downloaded_paths == #filepaths or not hasProxy() then
            finish(downloaded_paths)
            return
        end

        -- retry the covers that failed through the proxy
        local downloaded = {}
        for _, path in ipairs(downloaded_paths) do
            downloaded[path] = true
        end
        local retry_urls = {}
        local retry_paths = {}
        for i, path in ipairs(filepaths) do
            if not downloaded[path] then
                table.insert(retry_urls, download_urls[i])
                table.insert(retry_paths, path)
            end
        end

        LogUtil.debug("retrying", #retry_urls, "cover downloads through proxy")
        startDownloads(retry_urls, retry_paths, true, parallel_jobs, function(retried_paths)
            for _, path in ipairs(retried_paths) do
                table.insert(downloaded_paths, path)
            end
            finish(downloaded_paths)
        end)
    end)

    return true
end

return CoverCache
