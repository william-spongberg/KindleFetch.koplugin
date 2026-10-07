local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local FileUtil = require("util.fileutil")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local KindleFetchCache = require("cache.cache")
local CurlUtil = require("util.curlutil")
local LogUtil = require("util.logutil")

local CoverCache = {}

-- constants
local CACHE_DIR = DataStorage:getSettingsDir() .. "/kindlefetch_covers/"
local POLL_INTERVAL = 0.5
-- covers are shown as they arrive, but at most once in this many polls (a second), as each time the screen is
-- refreshed
local PROGRESS_POLLS = 2
-- the cover is fetched before the download prompt shows, so don't wait long for it
local COVER_MAX_TIME = 10
-- a cover that nothing has arrived of for this many seconds is given up on, rather than keeping its placeholder
-- showing, and the next page's covers from being fetched ahead, for as long as it can take (and with a curl too old
-- to say as each cover arrives, keeping the rest of its page waiting)
local COVER_STALL_TIME = 10

-- md5s of covers being downloaded, so they aren't downloaded twice at once
local downloading = {}
-- md5s of covers that couldn't be downloaded this session, so they aren't shown as coming
local unavailable = {}

local persistent_cache = KindleFetchCache:new {
    filename = "kindlefetch_covercache.lua",
    expiry = nil, -- no expiry
    max_entries = 500, -- each cover image around 40KB, so around 20MB
    makeKey = function(md5)
        return md5
    end,
    -- remove a cover's file once newer covers push it out, or it would be left behind for good
    onEvict = function(_, path)
        FileUtil.removeFile(path)
    end,
}

local function ensureCacheDir()
    lfs.mkdir(CACHE_DIR)
end

-- covers that fail to download are retried through PROXY_URL, like searches and books
local function hasProxy()
    local proxy_url = os.getenv("PROXY_URL")
    return proxy_url ~= nil and proxy_url ~= ""
end

-- remove the covers that older versions left behind, having forgotten them once the cache was full without
-- removing their files. once per session, as there are only more to find after an update
local orphans_removed = false
local function removeOrphans()
    if orphans_removed then
        return
    end
    orphans_removed = true
    if lfs.attributes(CACHE_DIR, "mode") ~= "directory" then
        return
    end

    local orphans = {}
    for file in lfs.dir(CACHE_DIR) do
        local md5 = file:match("^(.+)%.jpg$")
        if md5 and not downloading[md5] and not persistent_cache:get(md5) then
            table.insert(orphans, file)
        end
    end
    for _, file in ipairs(orphans) do
        FileUtil.removeFile(CACHE_DIR .. file)
    end
    if #orphans > 0 then
        LogUtil.info("removed", #orphans, "covers that were no longer in the cache")
    end
end

function CoverCache:getPath(md5)
    ensureCacheDir()
    return CACHE_DIR .. md5 .. ".jpg"
end

function CoverCache:cacheExists(md5)
    -- must agree with get, as covers are shown using the path it returns
    return self:get(md5) ~= nil
end

-- Library Genesis links to thumbnails ending in _small, with the full-size cover at the same path without it.
-- returns the full-size cover as a book of its own, stored alongside the thumbnail, or nil if there isn't one
local function fullSizeCover(book)
    local url = book.image_url and book.image_url:gsub("_small(%.%w+)$", "%1")
    if not book.md5 or not url or url == book.image_url then
        return nil
    end
    return {
        md5 = book.md5 .. "_full",
        image_url = url,
    }
end

-- the book's full-size cover, if it has downloaded
function CoverCache:getFullSize(book)
    local cover = fullSizeCover(book)
    return cover and self:get(cover.md5)
end

-- download the book's full-size cover in the background, for showing larger than in search results. returns
-- false when there's nothing to download
function CoverCache:downloadFullSize(book)
    local cover = fullSizeCover(book)
    return cover ~= nil and self:downloadMultiple({ cover }, 1)
end

-- forget every cover, removing their files, e.g. so each end-to-end test starts afresh
function CoverCache:clear()
    persistent_cache:clear()
    downloading = {}
    unavailable = {}
    if lfs.attributes(CACHE_DIR, "mode") == "directory" then
        for file in lfs.dir(CACHE_DIR) do
            if file ~= "." and file ~= ".." then
                FileUtil.removeFile(CACHE_DIR .. file)
            end
        end
    end
end

-- whether the book's full-size cover is still on its way, once asked for
function CoverCache:isFullSizeComing(book)
    local cover = fullSizeCover(book)
    return cover ~= nil and self:isComing(cover)
end

-- whether a cover for the book is on its way, so worth showing a placeholder for
function CoverCache:isComing(book)
    return book.image_url ~= nil and not unavailable[book.md5] and not self:cacheExists(book.md5)
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

    local success = CurlUtil.download(url, path, false, false, COVER_MAX_TIME)
    if not success and hasProxy() then
        LogUtil.debug("retrying cover download through proxy", md5)
        success = CurlUtil.download(url, path, true, false, COVER_MAX_TIME)
    end
    if success then
        persistent_cache:set(path, md5)
        return path
    end

    return nil
end

-- the paths that have downloaded, going by curl's results so far and its exit code once it has one
local function downloadedPaths(results, filepaths, exit_code)
    local downloaded = {}
    for _, path in ipairs(filepaths) do
        if CurlUtil.isTransferComplete(results, path, exit_code) then
            table.insert(downloaded, path)
        end
    end
    return downloaded
end

-- wait for curl's background downloads to finish, calling on_progress with the paths that have downloaded so far
-- while it's still going (where curl says as each finishes, see CurlUtil.downloadMultiple), and on_done with the
-- paths that downloaded once it has finished
local function pollDownloads(pid, exit_file, config_file, filepaths, on_progress, on_done)
    local results_file = CurlUtil.getResultsFile(config_file)
    local exit_code = CurlUtil.getExitCode(exit_file)
    if not exit_code then
        if CurlUtil.isPidRunning(pid) then
            on_progress(downloadedPaths(CurlUtil.getTransferResults(results_file), filepaths))
            UIManager:scheduleIn(POLL_INTERVAL, function()
                pollDownloads(pid, exit_file, config_file, filepaths, on_progress, on_done)
            end)
            return
        end
        -- curl may have finished between checking for its exit code and whether it was running
        exit_code = CurlUtil.getExitCode(exit_file)
    end

    local results = CurlUtil.getTransferResults(results_file)
    FileUtil.removeFile(config_file)
    FileUtil.removeFile(results_file)

    -- keep the covers that downloaded, removing any partial files left by ones that failed
    local downloaded = downloadedPaths(results, filepaths, exit_code)
    local kept = {}
    for _, path in ipairs(downloaded) do
        kept[path] = true
    end
    for _, path in ipairs(filepaths) do
        if not kept[path] then
            FileUtil.removeFile(path)
        end
    end
    if #downloaded < #filepaths then
        LogUtil.warn(
            string.format(
                "%d of %d covers didn't download: curl exit code %s (%s)",
                #filepaths - #downloaded,
                #filepaths,
                tostring(exit_code),
                CurlUtil.getErrorMeaning(exit_code)
            )
        )
    end

    on_done(downloaded)
end

local function startDownloads(download_urls, filepaths, use_proxy, parallel_jobs, on_progress, on_done)
    local pid, exit_file, config_file, err =
        CurlUtil.downloadMultiple(download_urls, filepaths, use_proxy, true, parallel_jobs, false, 15, {
            stall_time = COVER_STALL_TIME,
        })
    if not pid then
        LogUtil.warn("could not start curl to download", #download_urls, "covers:", err)
        on_done({})
        return
    end

    UIManager:scheduleIn(POLL_INTERVAL, function()
        pollDownloads(pid, exit_file, config_file, filepaths, on_progress, on_done)
    end)
end

-- download missing covers in the background, calling on_done with the number downloaded once finished, and
-- letting open search results and download prompts know with a KindleFetchCoversDownloaded event, so they
-- can replace the placeholders: as covers arrive, rather than once the slowest has, and once they've all
-- finished. returns false when there was nothing to download.
function CoverCache:downloadMultiple(books, parallel_jobs, on_done)
    ensureCacheDir()
    removeOrphans()
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
            unavailable[book.md5] = nil
        end
    end

    if #md5s == 0 then
        return false
    end

    local md5_of = {}
    for i, path in ipairs(filepaths) do
        md5_of[path] = md5s[i]
    end

    -- the covers that have arrived, as they're added to the cache (in memory, until they've all finished)
    local kept = {}
    local count = 0
    local function keep(paths)
        local added = 0
        for _, path in ipairs(paths) do
            if md5_of[path] and not kept[path] then
                kept[path] = true
                downloading[md5_of[path]] = nil
                persistent_cache:put(path, md5_of[path])
                added = added + 1
            end
        end
        count = count + added
        return added
    end

    -- show the covers that have arrived while others are still coming
    local polls_since_shown = PROGRESS_POLLS
    local function onProgress(downloaded_paths)
        polls_since_shown = polls_since_shown + 1
        if polls_since_shown >= PROGRESS_POLLS and keep(downloaded_paths) > 0 then
            polls_since_shown = 0
            UIManager:broadcastEvent(Event:new("KindleFetchCoversDownloaded"))
        end
    end

    local function finish(downloaded_paths)
        keep(downloaded_paths)
        for i, md5 in ipairs(md5s) do
            if not kept[filepaths[i]] then
                downloading[md5] = nil
                unavailable[md5] = true
            end
        end
        -- once for all of them, rather than writing the cache out for each cover
        if count > 0 then
            persistent_cache:save()
        end

        -- even when none downloaded, as their placeholders then need removing
        UIManager:broadcastEvent(Event:new("KindleFetchCoversDownloaded"))
        on_done(count)
    end

    startDownloads(download_urls, filepaths, false, parallel_jobs, onProgress, function(downloaded_paths)
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
        startDownloads(retry_urls, retry_paths, true, parallel_jobs, onProgress, function(retried_paths)
            for _, path in ipairs(retried_paths) do
                table.insert(downloaded_paths, path)
            end
            finish(downloaded_paths)
        end)
    end)

    return true
end

return CoverCache
