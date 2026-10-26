local helper = require("helper")

describe("Libraries", function()
    local Libraries, Settings, MultiSearch, Sites, LibrarySites

    local CALIBRE = {
        url = "http://nas:8080/opds?library_id=Books",
        name = "Books",
        kind = "calibre",
        search_url = "http://nas:8080/opds/search/{searchTerms}?library_id=Books",
    }
    local CALIBRE_WEB = {
        url = "https://books.example/opds",
        name = "Will's Books",
        kind = "calibre-web",
        search_url = "https://books.example/opds/search/{searchTerms}",
    }

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        Settings = require("settings.settings")
        Settings:setSearchSources({ "libgen", "archive" })
        Libraries = require("api.libraries")
        MultiSearch = require("api.multisearch")
        Sites = require("api.sites")
        LibrarySites = require("util.librarysites")
    end)

    after_each(helper.cleanup)

    it("adds a library, offering it to search before the other sites, and ticking it in the search box", function()
        local library = Libraries.add(CALIBRE, { username = "will", password = "secret" })

        local source = Libraries.source(library)
        assert.are.equal(source, MultiSearch.sources()[1])
        assert.are.equal("Books", Sites[source].NAME)
        assert.are.same({ "title", "author", "isbn" }, Sites[source].SCOPES)
        assert.are.same({ "libgen", "archive", source }, Settings:getSearchSources())
        -- logging in to its site, and only there
        assert.are.same({ username = "will", password = "secret" }, LibrarySites.loginFor("http://nas:8080/get/epub/1"))
        assert.are.equal("will", Settings:getLibraries()[1].username)
    end)

    it("names a library as it's given, or what it calls itself", function()
        assert.are.equal("Home", Libraries.add(CALIBRE_WEB, nil, "  Home ").name)
        assert.are.equal("Will's Books", Libraries.add(CALIBRE_WEB, nil, "").name)
    end)

    it("gives each library an id of its own", function()
        local first = Libraries.add(CALIBRE)
        local second = Libraries.add(CALIBRE)
        assert.are_not.equal(first.id, second.id)
        assert.are.equal(2, #MultiSearch.sources() - 4)
    end)

    it("offers the libraries in the settings once registered, as when KOReader starts", function()
        Settings:setLibraries({
            {
                id = "a1",
                name = "Books",
                url = CALIBRE.url,
                kind = CALIBRE.kind,
                search_url = CALIBRE.search_url,
                username = "",
                password = "",
            },
        })
        Libraries.register()
        assert.are.same({ "library_a1", "zlib", "libgen", "archive", "gutenberg" }, MultiSearch.sources())
        assert.is_true(LibrarySites.isLibrary("http://nas:8080/opds"))
        assert.is_nil(LibrarySites.loginFor("http://nas:8080/opds"))
    end)

    -- so the pages its results link to are kept (see OpdsSearch)
    it("keeps a library's site while it hasn't changed", function()
        local library = Libraries.add(CALIBRE)
        local source = Libraries.source(library)
        local site = Sites[source]
        Libraries.register()
        assert.are.equal(site, Sites[source])

        library.name = "My Books"
        assert.is_true(Libraries.update(library))
        assert.are_not.equal(site, Sites[source])
        assert.are.equal("My Books", Sites[source].NAME)
        assert.are.equal("My Books", Libraries.find(library.id).name)
    end)

    it("removes a library, which is no longer offered, logged into, or ticked", function()
        local library = Libraries.add(CALIBRE, { username = "will", password = "secret" })
        local other = Libraries.add(CALIBRE_WEB)
        assert.is_true(Libraries.remove(library.id))

        assert.are.same({ Libraries.source(other), "zlib", "libgen", "archive", "gutenberg" }, MultiSearch.sources())
        assert.is_false(LibrarySites.isLibrary("http://nas:8080/opds"))
        assert.are.same({ "libgen", "archive", Libraries.source(other) }, Settings:getSearchSources())
        assert.is_nil(Libraries.find(library.id))
    end)

    it("says when a library couldn't be saved", function()
        helper.state.settings_unwritable = true
        local library, err = Libraries.add(CALIBRE)
        assert.is_nil(library)
        assert.are.equal("Kindle Fetch's settings couldn't be saved", err)
        assert.are.same({ "zlib", "libgen", "archive", "gutenberg" }, MultiSearch.sources())
    end)
end)
