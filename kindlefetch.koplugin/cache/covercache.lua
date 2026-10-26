local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local FileUtil = require("util.fileutil")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local KindleFetchCache = require("cache.cache")
local CurlUtil = require("util.curlutil")
local HttpDownload = require("util.httpdownload")
local BackgroundProcess = require("util.backgroundprocess")
local FileCheck = require("util.filecheck")
local ProxyUtil = require("util.proxyutil")
local LibrarySites = require("util.librarysites")
local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")
local Guard = require("util.guard")

local CoverCache = {}

-- constants
local CACHE_DIR = DataStorage:getSettingsDir() .. "/kindlefetch_covers/"
local POLL_INTERVAL = 0.5
-- covers are shown as they arrive, but at most once in this many polls (a second), as each refreshes the screen
local PROGRESS_POLLS = 2
-- the cover is fetched before the download prompt shows, so don't wait long for it
local COVER_MAX_TIME = 10
-- give up on a cover nothing has arrived of for this long, rather than keep its placeholder and hold up the next page
local COVER_STALL_TIME = 10

-- ids of the books whose covers are being downloaded, so they aren't downloaded twice at once
local downloading = {}
-- ids of the books whose covers couldn't be downloaded this session, so they aren't shown as coming
local unavailable = {}

local persistent_cache = KindleFetchCache:new {
    filename = "kindlefetch_covercache.lua",
    expiry = nil, -- no expiry
    max_entries = 500, -- each cover image around 40KB, so around 20MB
    makeKey = function(id)
        return id
    end,
    -- remove a cover's file once newer covers push it out, or it would be left behind for good
    onEvict = function(_, path)
        FileUtil.removeFile(path)
    end,
}

local function ensureCacheDir()
    lfs.mkdir(CACHE_DIR)
end

-- remove covers older versions forgot without removing their files, once per session, as only an update leaves more
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
    for _, file in ipairs(FileUtil.listDir(CACHE_DIR) or {}) do
        local id = file:match("^(.+)%.jpg$")
        if id and not downloading[id] and not persistent_cache:get(id) then
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

-- whether the cover at path is an image, not a web page sent instead that would be kept for good, removing it if not
local function isImage(id, path)
    local head = FileCheck.head(path) or ""
    if FileCheck.isImage(head) then
        return true
    end
    LogUtil.warn(
        "left out the cover of",
        id,
        "as it isn't an image:",
        FileCheck.pageTitle(head) or (head:sub(1, 40):gsub("[^%w%p ]", "?"))
    )
    FileUtil.removeFile(path)
    return false
end

function CoverCache:getPath(id)
    ensureCacheDir()
    return CACHE_DIR .. id .. ".jpg"
end

function CoverCache:cacheExists(id)
    -- must agree with get, as covers are shown using the path it returns
    return self:get(id) ~= nil
end

-- the book's full-size cover as a book of its own, or nil: the site's, or Library Genesis' thumbnail without _small
local function fullSizeCover(book)
    local url = book.full_image_url or book.image_url and book.image_url:gsub("_small(%.%w+)$", "%1")
    if not book.id or not url or url == book.image_url then
        return nil
    end
    return {
        id = book.id .. "_full",
        image_url = url,
    }
end

-- the book's full-size cover, if it has downloaded
function CoverCache:getFullSize(book)
    local cover = fullSizeCover(book)
    return cover and self:get(cover.id)
end

-- download the book's full-size cover in the background, for showing larger than in results, or false if there's none
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
        for _, file in ipairs(FileUtil.listDir(CACHE_DIR) or {}) do
            FileUtil.removeFile(CACHE_DIR .. file)
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
    return book.image_url ~= nil and not unavailable[book.id] and not self:cacheExists(book.id)
end

function CoverCache:get(id)
    -- check persistent cache first
    local cached_path = persistent_cache:get(id)
    if cached_path and FileUtil.isValidFile(cached_path) then
        return cached_path
    end
    -- if cache says exists but file is gone, invalidate
    if cached_path then
        persistent_cache:delete(id)
        persistent_cache:save()
    end
    return nil
end

function CoverCache:download(id, url)
    ensureCacheDir()
    local path = self:getPath(id)

    local success = CurlUtil.download(url, path, COVER_MAX_TIME)
    if success and isImage(id, path) then
        persistent_cache:set(path, id)
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

-- wait for curl's downloads, calling on_progress with the paths downloaded so far, then on_done with those that did
local function pollDownloads(process, config_file, filepaths, on_progress, on_done)
    local results_file = CurlUtil.getResultsFile(config_file)
    local exit_code, running = process:poll()
    if running then
        on_progress(downloadedPaths(CurlUtil.getTransferResults(results_file), filepaths))
        -- once something goes wrong, as having none of them (see Guard)
        Guard.scheduleIn(POLL_INTERVAL, "checking on covers' downloads", function()
            pollDownloads(process, config_file, filepaths, on_progress, on_done)
        end, function()
            on_done({})
        end)
        return
    end

    local results = CurlUtil.getTransferResults(results_file)
    FileUtil.removeFile(config_file)
    FileUtil.removeFile(results_file)
    -- where it was KOReader's own process that downloaded them, rather than curl
    process:collect()

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

-- with curl, or KOReader's own HTTP where it can't (see CurlUtil.canFetch), as a Kobo may have no curl at all (#63)
local function startDownloads(download_urls, filepaths, parallel_jobs, on_progress, on_done)
    local pid, exit_file, config_file, err
    if CurlUtil.canFetch() then
        pid, exit_file, config_file, err =
            CurlUtil.downloadMultiple(download_urls, filepaths, true, parallel_jobs, false, 15, {
                stall_time = COVER_STALL_TIME,
            })
    else
        pid, exit_file, config_file, err = HttpDownload.startMultiple(download_urls, filepaths, {
            stall_time = COVER_STALL_TIME,
            max_time = COVER_MAX_TIME,
            proxy = ProxyUtil.get(),
        })
    end
    if not pid then
        LogUtil.warn("could not start curl to download", #download_urls, "covers:", err)
        on_done({})
        return
    end

    local process = BackgroundProcess.new(pid, exit_file)
    Guard.scheduleIn(POLL_INTERVAL, "checking on covers' downloads", function()
        pollDownloads(process, config_file, filepaths, on_progress, on_done)
    end, function()
        on_done({})
    end)
end

-- the covers' urls and paths split up by library site (see LibrarySites), as curl is given one login per download
local function bySite(download_urls, filepaths)
    local groups, by_site = {}, {}
    for i, url in ipairs(download_urls) do
        local site = LibrarySites.isLibrary(url) and StringUtil.siteOf(url) or ""
        if not by_site[site] then
            by_site[site] = { urls = {}, paths = {} }
            table.insert(groups, by_site[site])
        end
        table.insert(by_site[site].urls, url)
        table.insert(by_site[site].paths, filepaths[i])
    end
    return groups
end

-- download missing covers in the background, shown as they arrive, then on_done(count), or return false if none are
function CoverCache:downloadMultiple(books, parallel_jobs, on_done)
    ensureCacheDir()
    removeOrphans()
    on_done = on_done or function() end

    local download_urls = {}
    local filepaths = {}
    local ids = {}

    for _, book in ipairs(books) do
        if book.id and book.image_url and not self:get(book.id) and not downloading[book.id] then
            table.insert(download_urls, book.image_url)
            table.insert(filepaths, self:getPath(book.id))
            table.insert(ids, book.id)
            downloading[book.id] = true
            unavailable[book.id] = nil
        end
    end

    if #ids == 0 then
        return false
    end

    local id_of = {}
    for i, path in ipairs(filepaths) do
        id_of[path] = ids[i]
    end

    -- the covers that have arrived (false if not images), put in the cache in memory until they've all finished
    local kept = {}
    local count = 0
    local function keep(paths)
        local added = 0
        for _, path in ipairs(paths) do
            if id_of[path] and kept[path] == nil then
                kept[path] = isImage(id_of[path], path)
                if kept[path] then
                    downloading[id_of[path]] = nil
                    persistent_cache:put(path, id_of[path])
                    added = added + 1
                end
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
        for i, id in ipairs(ids) do
            if not kept[filepaths[i]] then
                downloading[id] = nil
                unavailable[id] = true
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

    -- the covers on each library's site apart from the rest (see bySite), finishing once they all have
    local groups = bySite(download_urls, filepaths)
    local remaining, downloaded = #groups, {}
    for __, group in ipairs(groups) do
        startDownloads(group.urls, group.paths, parallel_jobs, onProgress, function(paths)
            for __, path in ipairs(paths) do
                table.insert(downloaded, path)
            end
            remaining = remaining - 1
            if remaining == 0 then
                finish(downloaded)
            end
        end)
    end

    return true
end

return CoverCache
