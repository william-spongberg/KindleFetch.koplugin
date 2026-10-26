local BackgroundTask = require("ui.backgroundtask")
local Sites = require("api.sites")
local HttpUtil = require("util.httputil")
local Guard = require("util.guard")
local Errors = require("util.errors")

-- searches sites at once in coroutines, to show each one's books when found, or in turn where KOReader's HTTP blocks
local MultiSearch = {}
MultiSearch.__index = MultiSearch

-- the sites Kindle Fetch knows, in the order they're offered, and those added since KOReader started, offered first
local KNOWN_SOURCES = { "zlib", "libgen", "archive", "gutenberg" }
local added_sources = {}

-- the sites by name, in the order they're offered and searched in turn: those added, then those Kindle Fetch knows
function MultiSearch.sources()
    local sources = {}
    for __, list in ipairs({ added_sources, KNOWN_SOURCES }) do
        for __, source in ipairs(list) do
            table.insert(sources, source)
        end
    end
    return sources
end

-- offer site to search as source (its name in Sites) before those Kindle Fetch knows, replacing any site added as it
function MultiSearch.addSite(source, site)
    Sites[source] = site
    for __, added in ipairs(added_sources) do
        if added == source then
            return
        end
    end
    table.insert(added_sources, source)
end

-- stop offering the site added as source, but keep it in Sites, so books already found on it can still be downloaded
function MultiSearch.removeSite(source)
    for i, added in ipairs(added_sources) do
        if added == source then
            table.remove(added_sources, i)
            return
        end
    end
end

-- whether the site can narrow a search down to scope, e.g. "author" (see SCOPES in Site)
function MultiSearch.canNarrow(source, scope)
    for __, site_scope in ipairs(Sites[source].SCOPES or {}) do
        if site_scope == scope then
            return true
        end
    end
    return false
end

-- whether each site's page (see start) is saved from an earlier search, to show straight away, even offline
function MultiSearch.isCached(query, pages, scope)
    for source, page in pairs(pages) do
        if not Sites[source]:isCached(query, page, MultiSearch.canNarrow(source, scope) and scope or nil) then
            return false
        end
    end
    return true
end

-- search each site in pages from its page; handlers.on_result as each finishes, then on_done; returns it, to cancel
function MultiSearch.start(query, pages, scope, handlers)
    local search = setmetatable({
        query = query,
        pages = pages,
        scope = scope,
        handlers = handlers,
        -- the sites still being searched, those not started yet, and what calls each one's off (see searchSite)
        pending = {},
        queue = {},
        traps = {},
    }, MultiSearch)
    for __, source in ipairs(MultiSearch.sources()) do
        if pages[source] then
            search.pending[source] = true
            table.insert(search.queue, source)
        end
    end
    if #search.queue == 0 then
        Guard.nextTick("finishing a search of no sites", handlers.on_done)
        return search
    end
    -- all at once, where waiting for them doesn't hold KOReader up, otherwise one after another (see finish)
    repeat
        search:startNext()
    until #search.queue == 0 or not HttpUtil.canCancel()
    return search
end

-- start searching the next site not started yet, once KOReader has shown what's been found so far
function MultiSearch:startNext()
    local source = table.remove(self.queue, 1)
    if not source then
        return
    end
    Guard.nextTick("starting a search of " .. Sites[source].NAME, function()
        self:searchSite(source)
    end, function(err)
        self:finish(source, nil, err)
    end)
end

function MultiSearch:searchSite(source)
    if self.cancelled then
        self:finish(source, nil, HttpUtil.CANCELLED)
        return
    end
    local site = Sites[source]
    local handlers = self.handlers
    -- a stand-in for the search's message, as Trapper gives each wait its own way to be called off (see cancel)
    local trap = {
        setStatus = function(__, status)
            if status and handlers.on_status then
                handlers.on_status(status)
            end
        end,
    }
    self.traps[source] = trap
    local what = string.format("search of %s for %q", site.NAME, self.query)
    local scope = MultiSearch.canNarrow(source, self.scope) and self.scope or nil
    BackgroundTask.run(what, trap, function()
        return Guard.pcall(what, site.search, site, self.query, self.pages[source], scope)
    end, function(ok, books, err, next_page, results_read)
        if not ok then
            books, err, next_page, results_read = nil, Errors.UNEXPECTED, nil, nil
        end
        self:finish(source, books, err, next_page, results_read)
    end, function(err)
        self:finish(source, nil, err)
    end)
end

-- pass on what the site's search found, or why it didn't, starting the next where they're searched one after another
function MultiSearch:finish(source, books, err, next_page, results_read)
    if not self.pending[source] then
        return
    end
    self.pending[source] = nil
    -- its wait is over, so it mustn't be called off again: Trapper leaves its way to on the stand-in it waited with
    if self.traps[source] then
        self.traps[source].dismiss_callback = nil
    end
    Guard.call("showing what a search found", self.handlers.on_result, nil, source, books, err, next_page, results_read)
    if next(self.pending) == nil then
        Guard.call("finishing a search", self.handlers.on_done)
    else
        self:startNext()
    end
end

-- the sites still being searched, in the order they're offered
function MultiSearch:pendingSources()
    local sources = {}
    for __, source in ipairs(MultiSearch.sources()) do
        if self.pending[source] then
            table.insert(sources, source)
        end
    end
    return sources
end

function MultiSearch:isDone()
    return next(self.pending) == nil
end

-- call off the searches still going (the message's Cancel): each says so once it stops, or passes on what it had found
function MultiSearch:cancel()
    if self.cancelled then
        return
    end
    self.cancelled = true
    for source, trap in pairs(self.traps) do
        if self.pending[source] then
            trap.cancelled = true
            if trap.dismiss_callback then
                trap.dismiss_callback()
            end
        end
    end
end

return MultiSearch
