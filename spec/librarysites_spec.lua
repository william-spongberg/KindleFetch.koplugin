local helper = require("helper")

describe("LibrarySites", function()
    local LibrarySites

    before_each(function()
        helper.reset()
        LibrarySites = require("util.librarysites")
    end)

    it("knows a library's login on its own site alone", function()
        LibrarySites.add("http://nas:8080/opds", { username = "will", password = "secret" })

        assert.is_true(LibrarySites.isLibrary("http://NAS:8080/get/epub/1"))
        assert.are.same(
            { username = "will", password = "secret" },
            LibrarySites.loginFor("http://nas:8080/opds/search")
        )
        -- another port, scheme or host is another site
        assert.is_nil(LibrarySites.loginFor("http://nas:8083/opds"))
        assert.is_nil(LibrarySites.loginFor("https://nas:8080/opds"))
        assert.is_nil(LibrarySites.loginFor("https://covers.example/1.jpg"))
        assert.is_false(LibrarySites.isLibrary("https://covers.example/1.jpg"))
    end)

    -- e.g. so that a certificate problem on it isn't passed over (see HttpUtil.requestBody)
    it("knows a library's site that needs no login", function()
        LibrarySites.add("http://nas:8080/opds")
        assert.is_true(LibrarySites.isLibrary("http://nas:8080/opds"))
        assert.is_nil(LibrarySites.loginFor("http://nas:8080/opds"))

        LibrarySites.add("http://nas:8083/opds", { username = "", password = "secret" })
        assert.is_nil(LibrarySites.loginFor("http://nas:8083/opds"))
    end)

    it("puts a site added again in place of what it had, and forgets them all when cleared", function()
        LibrarySites.add("http://nas:8080/opds", { username = "will", password = "old" })
        LibrarySites.add("http://nas:8080/", { username = "will", password = "new" })
        assert.are.equal("new", LibrarySites.loginFor("http://nas:8080/opds").password)

        LibrarySites.clear()
        assert.is_false(LibrarySites.isLibrary("http://nas:8080/opds"))
    end)

    it("doesn't add what isn't a web address", function()
        assert.is_false(LibrarySites.add("nas:8080", { username = "will", password = "secret" }))
    end)

    it("never logs a password", function()
        LibrarySites.add("http://nas:8080/opds", { username = "will", password = "hunter22" })
        require("util.logutil").warn("could not log in with hunter22")
        assert.are.same({ "warn", "KindleFetch:", "could not log in with ***" }, helper.state.logs[1])
    end)
end)
