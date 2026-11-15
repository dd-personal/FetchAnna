local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local FileUtil = require("fetchanna.util.fileutil")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local FetchAnnaCache = require("fetchanna.cache.cache")
local CurlUtil = require("fetchanna.util.curlutil")
local HttpDownload = require("fetchanna.util.httpdownload")
local FileCheck = require("fetchanna.util.filecheck")
local ProxyUtil = require("fetchanna.util.proxyutil")
local LogUtil = require("fetchanna.util.logutil")
local Guard = require("fetchanna.util.guard")

local CoverCache = {}

local CACHE_DIR = DataStorage:getSettingsDir() .. "/fetchanna_covers/"
local POLL_INTERVAL = 0.5
-- Covers are shown as they arrive, but at most every this many polls (a second), as each time refreshes the screen.
local PROGRESS_POLLS = 2
-- The cover is fetched before the download prompt shows, so don't wait long for it.
local COVER_MAX_TIME = 10
-- A cover with nothing arriving for this many seconds is given up on, so its placeholder goes and the next page's
-- covers aren't held up (nor the rest of its page, with a curl too old to report each cover).
local COVER_STALL_TIME = 10

-- Ids of covers being downloaded, so none is downloaded twice at once.
local downloading = {}
-- Ids of covers that couldn't be downloaded this session, so they aren't shown as coming.
local unavailable = {}

local persistent_cache = FetchAnnaCache:new {
    filename = "fetchanna_covercache.lua",
    expiry = nil, -- no expiry
    max_entries = 500, -- each cover image around 40KB, so around 20MB
    makeKey = function(id)
        return id
    end,
    -- Removes a cover's file once newer covers push it out.
    onEvict = function(_, path)
        FileUtil.removeFile(path)
    end,
}

local function ensureCacheDir()
    lfs.mkdir(CACHE_DIR)
end

-- Removes cover files that older versions left behind when the cache was full. Once per session.
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

-- Whether the file at path is an image, rather than e.g. a web page sent in its place, which would be kept for
-- good. Removes it if it isn't.
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
    -- Must agree with get, as covers are shown using the path it returns.
    return self:get(id) ~= nil
end

-- Library Genesis links to thumbnails ending in _small, with the full-size cover at the same path without it.
-- Returns that as a book of its own, or nil if there isn't one.
local function fullSizeCover(book)
    local url = book.image_url and book.image_url:gsub("_small(%.%w+)$", "%1")
    if not book.id or not url or url == book.image_url then
        return nil
    end
    return {
        id = book.id .. "_full",
        image_url = url,
    }
end

-- Returns the book's full-size cover, if it has downloaded.
function CoverCache:getFullSize(book)
    local cover = fullSizeCover(book)
    return cover and self:get(cover.id)
end

-- Downloads the book's full-size cover in the background. Returns false when there's nothing to download.
function CoverCache:downloadFullSize(book)
    local cover = fullSizeCover(book)
    return cover ~= nil and self:downloadMultiple({ cover }, 1)
end

-- Forgets every cover and removes the files, e.g. between end-to-end tests.
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

-- Whether the book's full-size cover is on its way.
function CoverCache:isFullSizeComing(book)
    local cover = fullSizeCover(book)
    return cover ~= nil and self:isComing(cover)
end

-- Whether a cover for the book is on its way, so worth a placeholder.
function CoverCache:isComing(book)
    return book.image_url ~= nil and not unavailable[book.id] and not self:cacheExists(book.id)
end

function CoverCache:get(id)
    local cached_path = persistent_cache:get(id)
    if cached_path and FileUtil.isValidFile(cached_path) then
        return cached_path
    end
    -- Forgets a cover whose file is gone.
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

-- Returns the paths that have downloaded, by curl's results so far and its exit code, if it has one.
local function downloadedPaths(results, filepaths, exit_code)
    local downloaded = {}
    for _, path in ipairs(filepaths) do
        if CurlUtil.isTransferComplete(results, path, exit_code) then
            table.insert(downloaded, path)
        end
    end
    return downloaded
end

-- Polls curl's background downloads. Calls on_progress with the paths downloaded so far (where curl reports each,
-- see CurlUtil.downloadMultiple), then on_done with those that downloaded.
local function pollDownloads(pid, exit_file, config_file, filepaths, on_progress, on_done)
    local results_file = CurlUtil.getResultsFile(config_file)
    local exit_code = CurlUtil.getExitCode(exit_file)
    if not exit_code then
        if CurlUtil.isPidRunning(pid) then
            on_progress(downloadedPaths(CurlUtil.getTransferResults(results_file), filepaths))
            -- If checking goes wrong, none of them count as downloaded (see Guard).
            Guard.scheduleIn(POLL_INTERVAL, "checking on covers' downloads", function()
                pollDownloads(pid, exit_file, config_file, filepaths, on_progress, on_done)
            end, function()
                on_done({})
            end)
            return
        end
        -- curl may have finished between checking for its exit code and whether it was running.
        exit_code = CurlUtil.getExitCode(exit_file)
    end

    local results = CurlUtil.getTransferResults(results_file)
    FileUtil.removeFile(config_file)
    FileUtil.removeFile(results_file)
    -- For when KOReader's own process downloaded them, not curl.
    HttpDownload.collect(pid)

    -- Removes partial files left by covers that failed.
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

-- Uses curl or, where it can't fetch (see CurlUtil.canFetch), KOReader's own HTTP, one at a time. A device may
-- have no curl, as a Kobo can (KindleFetch #63), which left every cover a placeholder.
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

    Guard.scheduleIn(POLL_INTERVAL, "checking on covers' downloads", function()
        pollDownloads(pid, exit_file, config_file, filepaths, on_progress, on_done)
    end, function()
        on_done({})
    end)
end

-- Downloads missing covers in the background. Broadcasts FetchAnnaCoversDownloaded as covers arrive and when all
-- are done, so open results and prompts can replace placeholders, then calls on_done(count). Returns false, without
-- calling on_done, when there's nothing to download. Otherwise true, though on_done may already have been called,
-- as when curl couldn't be started.
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

    -- Covers that have arrived and been added to the cache (in memory until all are done), or false for those that
    -- weren't images.
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

    -- Shows the covers that have arrived while others are still coming.
    local polls_since_shown = PROGRESS_POLLS
    local function onProgress(downloaded_paths)
        polls_since_shown = polls_since_shown + 1
        if polls_since_shown >= PROGRESS_POLLS and keep(downloaded_paths) > 0 then
            polls_since_shown = 0
            UIManager:broadcastEvent(Event:new("FetchAnnaCoversDownloaded"))
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
        -- Saved once, not for each cover.
        if count > 0 then
            persistent_cache:save()
        end

        -- Even when none downloaded, as their placeholders then need removing.
        UIManager:broadcastEvent(Event:new("FetchAnnaCoversDownloaded"))
        on_done(count)
    end

    startDownloads(download_urls, filepaths, parallel_jobs, onProgress, finish)

    return true
end

return CoverCache
