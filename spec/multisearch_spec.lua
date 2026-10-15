local helper = require("helper")

describe("MultiSearch", function()
    local MultiSearch, sites, searches, results, statuses, done, can_cancel

    -- a site whose searches wait, as curl's do (see Trapper:dismissablePopen), until answered (see answer) or called
    -- off with the stand-in they wait with
    local function fakeSite(name, scopes)
        local site = { NAME = name, SCOPES = scopes }
        function site:search(query, page, scope)
            local waiting = coroutine.running()
            local trap = require("util.httputil").getTrapWidget()
            table.insert(searches, { site = name, query = query, page = page, scope = scope, trap = trap })
            trap.dismiss_callback = function()
                coroutine.resume(waiting, false)
            end
            site.answer = function(...)
                coroutine.resume(waiting, true, ...)
            end
            if site.status then
                trap:setStatus(site.status)
            end
            local answered, books, err, next_page, results_read = coroutine.yield()
            if not answered then
                return site.found_by_then, site.found_by_then == nil and "request cancelled" or nil
            end
            if site.fails then
                error("site went wrong")
            end
            return books, err, next_page, results_read
        end
        return site
    end

    local handlers = {
        on_result = function(source, books, err, next_page, results_read)
            table.insert(results, {
                source = source,
                books = books,
                err = err,
                next_page = next_page,
                results_read = results_read,
            })
        end,
        on_done = function()
            done = done + 1
        end,
        on_status = function(text)
            table.insert(statuses, text)
        end,
    }

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        searches, results, statuses, done, can_cancel = {}, {}, {}, 0, true
        -- each search in a coroutine of its own, as KOReader's Trapper runs them
        helper.stub("ui/trapper", {
            wrap = function(_, fn)
                assert(coroutine.resume(coroutine.create(fn)))
                return true
            end,
            isWrapped = function()
                return coroutine.running() ~= nil
            end,
        })
        local trap_widgets = {}
        helper.stub("util.httputil", {
            CANCELLED = "request cancelled",
            canCancel = function()
                return can_cancel
            end,
            setTrapWidget = function(widget)
                trap_widgets[coroutine.running() or "main"] = widget
            end,
            getTrapWidget = function()
                return trap_widgets[coroutine.running() or "main"]
            end,
        })
        sites = {
            libgen = fakeSite("Library Genesis", { "title", "author" }),
            archive = fakeSite("Internet Archive", { "title", "author" }),
            zlib = fakeSite("Z-Library"),
        }
        helper.stub("api.sources", sites)
        MultiSearch = require("api.multisearch")
    end)

    after_each(helper.cleanup)

    local function searched(name)
        local found = {}
        for _, search in ipairs(searches) do
            if search.site == name then
                table.insert(found, search)
            end
        end
        return found
    end

    it("searches each site at once, passing on each one's books as soon as it has them", function()
        MultiSearch.start("dune", { libgen = 1, archive = 2 }, nil, handlers)
        assert.are.equal(0, #searches)
        helper.runScheduled()
        assert.are.equal(1, #searched("Library Genesis"))
        assert.are.equal(2, searched("Internet Archive")[1].page)

        sites.archive.answer({ "Dune" }, nil, 3, 50)
        assert.are.same({
            { source = "archive", books = { "Dune" }, next_page = 3, results_read = 50 },
        }, results)
        assert.are.equal(0, done)

        sites.libgen.answer({}, nil, nil, 25)
        assert.are.equal(2, #results)
        assert.are.equal("libgen", results[2].source)
        assert.are.equal(1, done)
    end)

    -- e.g. only the books' authors, while a site that can't still searches everything
    it("narrows the search down on the sites that can be", function()
        MultiSearch.start("herbert", { libgen = 1, zlib = 1 }, "author", handlers)
        helper.runScheduled()
        assert.are.equal("author", searched("Library Genesis")[1].scope)
        assert.is_nil(searched("Z-Library")[1].scope)
    end)

    it("calls off the sites still being searched, each saying so", function()
        local search = MultiSearch.start("dune", { libgen = 1, archive = 1 }, nil, handlers)
        helper.runScheduled()
        sites.archive.answer({ "Dune" })

        search:cancel()
        assert.are.equal("request cancelled", results[2].err)
        assert.is_true(searched("Library Genesis")[1].trap.cancelled)
        assert.are.equal(1, done)
        assert.is_true(search:isDone())
        -- and isn't called off again
        search:cancel()
        assert.are.equal(2, #results)
    end)

    -- as Library Genesis does, from the pages it had read
    it("passes on what a site had found by the time it was called off", function()
        local search = MultiSearch.start("dune", { libgen = 1 }, nil, handlers)
        helper.runScheduled()
        sites.libgen.found_by_then = { "Dune" }

        search:cancel()
        assert.are.same({ "Dune" }, results[1].books)
        assert.is_nil(results[1].err)
    end)

    -- where waiting for one would hold KOReader up, as with its own HTTP
    describe("one after another, where they can't be waited for at once", function()
        before_each(function()
            can_cancel = false
        end)

        it("starts the next site once the one before has finished", function()
            MultiSearch.start("dune", { libgen = 1, archive = 1, zlib = 1 }, nil, handlers)
            helper.runScheduled()
            assert.are.same({ "Library Genesis" }, { searches[1].site })
            assert.are.equal(1, #searches)

            sites.libgen.answer({ "Dune" })
            assert.are.equal(1, #results)
            helper.runScheduled()
            assert.are.equal("Internet Archive", searches[2].site)
        end)

        it("doesn't start the sites not started yet once called off", function()
            local search = MultiSearch.start("dune", { libgen = 1, archive = 1 }, nil, handlers)
            helper.runScheduled()
            search:cancel()
            helper.runScheduled()

            assert.are.equal(1, #searches)
            assert.are.equal("request cancelled", results[2].err)
            assert.are.equal("archive", results[2].source)
            assert.are.equal(1, done)
        end)
    end)

    it("says which sites are still being searched", function()
        local search = MultiSearch.start("dune", { zlib = 1, libgen = 1, archive = 1 }, nil, handlers)
        helper.runScheduled()
        assert.are.same({ "libgen", "archive", "zlib" }, search:pendingSources())
        sites.archive.answer({})
        assert.are.same({ "libgen", "zlib" }, search:pendingSources())
    end)

    -- e.g. which of Library Genesis' mirrors it's trying
    it("passes on what a site's search says it's waiting for", function()
        sites.libgen.status = "Trying libgen.li (mirror 1 of 5)..."
        MultiSearch.start("dune", { libgen = 1 }, nil, handlers)
        helper.runScheduled()
        assert.are.same({ "Trying libgen.li (mirror 1 of 5)..." }, statuses)
    end)

    it("says a site's search failed when something goes wrong in it", function()
        sites.libgen.fails = true
        MultiSearch.start("dune", { libgen = 1 }, nil, handlers)
        helper.runScheduled()
        sites.libgen.answer({})

        assert.are.equal(require("util.errors").UNEXPECTED, results[1].err)
        assert.are.equal(1, done)
    end)

    it("finishes straight away when there are no sites to search", function()
        MultiSearch.start("dune", {}, nil, handlers)
        helper.runScheduled()
        assert.are.equal(0, #results)
        assert.are.equal(1, done)
    end)
end)
