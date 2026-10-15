local Trapper = require("ui/trapper")
local Sources = require("api.sources")
local HttpUtil = require("util.httputil")
local Guard = require("util.guard")
local Errors = require("util.errors")

-- searches several of the sites at once (see Sources), each in a coroutine of its own (see Trapper), so that each one's
-- books can be shown as soon as it has found them, rather than once the slowest site has answered. where pages are
-- fetched with KOReader's own HTTP, which holds KOReader up until they've arrived, the sites are searched one after
-- another instead, with KOReader left to show what's been found in between
local MultiSearch = {}
MultiSearch.__index = MultiSearch

-- the sites, in the order they're offered, and searched in where it's one after another
MultiSearch.SOURCES = { "zlib", "libgen", "archive", "gutenberg" }

-- whether the site can narrow a search down to scope, e.g. "author" (see SCOPES in Sources)
function MultiSearch.canNarrow(source, scope)
    for __, site_scope in ipairs(Sources[source].SCOPES or {}) do
        if site_scope == scope then
            return true
        end
    end
    return false
end

-- whether every one of the sites' pages (see start) is saved from an earlier search, to be shown straight away, without
-- an internet connection (see isCached in Sources)
function MultiSearch.isCached(query, pages, scope)
    for source, page in pairs(pages) do
        if not Sources[source]:isCached(query, page, MultiSearch.canNarrow(source, scope) and scope or nil) then
            return false
        end
    end
    return true
end

-- search the sites in pages (the page of each one's results to search from, by its name, e.g. { libgen = 1,
-- archive = 1 }) for query, narrowed down to scope on those that can be (see canNarrow). as each site's search
-- finishes, handlers.on_result(source, books, err, next_page, results_read) is called with what it returned (see
-- LlgiSearch:search), and once every one has, handlers.on_done(). handlers.on_status(text), where given, is called with
-- what a site's search says it's waiting for (see HttpUtil.sayStatus). returns the search, to call off (see cancel)
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
    for __, source in ipairs(MultiSearch.SOURCES) do
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
    Guard.nextTick("starting a search of " .. Sources[source].NAME, function()
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
    local site = Sources[source]
    local handlers = self.handlers
    -- what calls off this site's search, and is told what it's waiting for: a stand-in for the message saying the
    -- search is going on, as Trapper gives each wait its own way to be called off, on the widget it waits with, and
    -- the message's Cancel calls them all (see cancel)
    local trap = {
        setStatus = function(__, status)
            if status and handlers.on_status then
                handlers.on_status(status)
            end
        end,
    }
    self.traps[source] = trap
    local what = string.format("search of %s for %q", site.NAME, self.query)
    Trapper:wrap(Guard.wrap(what, function()
        HttpUtil.setTrapWidget(trap)
        local scope = MultiSearch.canNarrow(source, self.scope) and self.scope or nil
        local ok, books, err, next_page, results_read =
            Guard.pcall(what, site.search, site, self.query, self.pages[source], scope)
        HttpUtil.setTrapWidget(nil)
        if not ok then
            books, err, next_page, results_read = nil, Errors.UNEXPECTED, nil, nil
        end
        self:finish(source, books, err, next_page, results_read)
    end, function(err)
        HttpUtil.setTrapWidget(nil)
        self:finish(source, nil, err)
    end))
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
    for __, source in ipairs(MultiSearch.SOURCES) do
        if self.pending[source] then
            table.insert(sources, source)
        end
    end
    return sources
end

function MultiSearch:isDone()
    return next(self.pending) == nil
end

-- call off the sites' searches that are still going, as a tap on the Cancel of the message saying the search is
-- going on does: each one says it was called off (HttpUtil.CANCELLED), or passes on what it had found by then (as
-- Library Genesis does, from the pages it had read), once it has stopped, as do those not started yet
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
