local helper = require("helper")

describe("KindleFetchCache", function()
    local data_dir, KindleFetchCache

    local function newCache(opts)
        opts = opts or {}
        opts.filename = opts.filename or "test_cache.lua"
        return KindleFetchCache:new(opts)
    end

    local function cacheFile()
        return helper.state.settings_files[data_dir .. "/settings/test_cache.lua"]
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.state.time = 1000000
        KindleFetchCache = require("cache.cache")
    end)

    after_each(helper.cleanup)

    it("stores and returns values", function()
        local cache = newCache()
        cache:set({"https://libgen.example"}, "libgen")

        assert.are.same({"https://libgen.example"}, cache:get("libgen"))
        assert.is_nil(cache:get("missing"))
    end)

    it("saves entries to its settings file", function()
        newCache():set("value", "key")
        assert.are.same({key = {timestamp = 1000000, value = "value"}}, cacheFile())
    end)

    it("loads entries saved by an earlier session", function()
        newCache():set("value", "key")
        assert.are.equal("value", newCache():get("key"))
    end)

    it("builds keys with makeKey", function()
        local cache = newCache{
            makeKey = function(query, page)
                return query .. "#" .. page
            end
        }
        cache:set("results", "dune", 2)

        assert.are.equal("results", cache:get("dune", 2))
        assert.is_nil(cache:get("dune", 1))
    end)

    it("expires entries older than the expiry", function()
        local cache = newCache{expiry = 60}
        cache:set("value", "key")

        helper.state.time = 1000060
        assert.are.equal("value", cache:get("key"))

        helper.state.time = 1000061
        assert.is_nil(cache:get("key"))
        assert.is_nil(cacheFile().key)
    end)

    it("can work out the expiry when checking an entry", function()
        local expiry = 60
        local cache = newCache{
            expiry = function()
                return expiry
            end
        }
        cache:set("value", "key")

        helper.state.time = 1000061
        expiry = 120
        assert.are.equal("value", cache:get("key"))
        expiry = 60
        assert.is_nil(cache:get("key"))
    end)

    it("keeps entries forever without an expiry", function()
        local cache = newCache()
        cache:set("value", "key")
        helper.state.time = 1000000 + 10 * 365 * 24 * 60 * 60
        assert.are.equal("value", cache:get("key"))
    end)

    it("removes the oldest entries once over the limit", function()
        local cache = newCache{max_entries = 2}
        cache:set("first", "a")
        helper.state.time = 1000001
        cache:set("second", "b")
        helper.state.time = 1000002
        cache:set("third", "c")

        assert.are.equal(2, cache:count())
        assert.is_nil(cache:get("a"))
        assert.are.equal("second", cache:get("b"))
        assert.are.equal("third", cache:get("c"))
    end)

    it("deletes and clears entries", function()
        local cache = newCache()
        cache:set("value", "a")
        cache:set("value", "b")

        cache:delete("a")
        assert.is_nil(cache:get("a"))

        cache:clear()
        assert.are.equal(0, cache:count())
        assert.are.same({}, cacheFile())
    end)

    describe("deleteValueFromKey", function()
        it("removes one value from a cached list", function()
            local cache = newCache()
            cache:set({"https://a.example", "https://b.example"}, "mirrors")

            cache:deleteValueFromKey("https://a.example", "mirrors")
            assert.are.same({"https://b.example"}, cache:get("mirrors"))
            assert.are.same({"https://b.example"}, cacheFile().mirrors.value)
        end)

        it("does not change lists already returned by get", function()
            local cache = newCache()
            cache:set({"https://a.example", "https://b.example"}, "mirrors")
            local mirrors = cache:get("mirrors")

            cache:deleteValueFromKey("https://a.example", "mirrors")
            assert.are.same({"https://a.example", "https://b.example"}, mirrors)
        end)

        it("removes the entry once the list is empty", function()
            local cache = newCache()
            cache:set({"https://a.example"}, "mirrors")

            cache:deleteValueFromKey("https://a.example", "mirrors")
            assert.is_nil(cache:get("mirrors"))
        end)

        it("ignores missing keys and values that are not lists", function()
            local cache = newCache()
            cache:set("https://a.example", "mirror")

            cache:deleteValueFromKey("https://a.example", "missing")
            cache:deleteValueFromKey("https://a.example", "mirror")
            assert.are.equal("https://a.example", cache:get("mirror"))
        end)
    end)
end)

describe("SearchCache", function()
    local SearchCache

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.time = 1000000
        SearchCache = require("cache.searchcache")
    end)

    after_each(helper.cleanup)

    it("keys results by query, page and filters", function()
        SearchCache:set({"book"}, "dune", 1, {"en"}, {"epub"}, {"fiction"})

        assert.are.same({"book"}, SearchCache:get("dune", 1, {"en"}, {"epub"}, {"fiction"}))
        assert.is_nil(SearchCache:get("dune", 2, {"en"}, {"epub"}, {"fiction"}))
        assert.is_nil(SearchCache:get("dune", 1, {"en", "fr"}, {"epub"}, {"fiction"}))
        assert.is_nil(SearchCache:get("dune", 1, {"en"}, {"pdf"}, {"fiction"}))
        assert.is_nil(SearchCache:get("dune", 1, {"en"}, {"epub"}, {"comics"}))
    end)

    it("expires results after two weeks", function()
        SearchCache:set({"book"}, "dune", 1, {"en"}, {"epub"}, {"fiction"})
        helper.state.time = 1000000 + 14 * 24 * 60 * 60 + 1
        assert.is_nil(SearchCache:get("dune", 1, {"en"}, {"epub"}, {"fiction"}))
    end)

    it("keeps searches for as long as set in the settings", function()
        require("settings.settings"):setSearchCacheExpiryDays(1)
        SearchCache:set({"book"}, "dune", 1, {"en"}, {"epub"}, {"fiction"})

        helper.state.time = 1000000 + 24 * 60 * 60 + 1
        assert.is_nil(SearchCache:get("dune", 1, {"en"}, {"epub"}, {"fiction"}))
    end)

    it("keeps at most 1000 searches", function()
        assert.are.equal(1000, SearchCache.max_entries)
    end)
end)

describe("UrlCache", function()
    local UrlCache

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.time = 1000000
        UrlCache = require("cache.urlcache")
    end)

    after_each(helper.cleanup)

    it("expires mirrors after a week", function()
        UrlCache:set({"https://libgen.example"}, "libgen")

        helper.state.time = 1000000 + 7 * 24 * 60 * 60
        assert.are.same({"https://libgen.example"}, UrlCache:get("libgen"))

        helper.state.time = 1000000 + 7 * 24 * 60 * 60 + 1
        assert.is_nil(UrlCache:get("libgen"))
    end)

    it("keeps mirrors for as long as set in the settings", function()
        UrlCache:set({"https://libgen.example"}, "libgen")
        helper.state.time = 1000000 + 7 * 24 * 60 * 60 + 1
        require("settings.settings"):setMirrorCacheExpiryDays(30)

        assert.are.same({"https://libgen.example"}, UrlCache:get("libgen"))
    end)
end)
