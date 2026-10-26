local helper = require("helper")

describe("Request", function()
    local Request, LibrarySites, Settings

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.stubs.http.PROXY = "http://proxy.example:3128"
        Request = require("util.request")
        LibrarySites = require("util.librarysites")
        Settings = require("settings.settings")
        Settings:setEncryptedDns(true)
        LibrarySites.add("http://nas.local:8080/opds", { username = "reader", password = "secret" })
    end)

    after_each(helper.cleanup)

    it("goes through the proxy, with encrypted DNS, where they're on", function()
        local request = Request.new("https://libgen.example/index.php", { form = { { "req", "dune" } } })
        assert.are.equal("http://proxy.example:3128", request.proxy)
        assert.is_true(request.encrypted_dns)
        assert.is_false(request.library)
        assert.is_nil(request.login)
        assert.are.same({ { "req", "dune" } }, request.form)
        assert.are.equal(10, request:connectTimeout(10))

        Settings:setEncryptedDns(false)
        assert.is_false(Request.new("https://libgen.example/index.php").encrypted_dns)
    end)

    -- which only the network's own DNS knows, and a proxy on the internet can't reach, so it's given up on soon
    it("goes without the proxy and encrypted DNS on the local network, logging in to a library's site", function()
        local request = Request.new("http://nas.local:8080/opds/search/dune")
        assert.is_nil(request.proxy)
        assert.is_false(request.encrypted_dns)
        assert.is_true(request.library)
        assert.are.same({ username = "reader", password = "secret" }, request.login)
        assert.are.equal(Request.LOCAL_CONNECT_TIMEOUT, request:connectTimeout(15))
    end)

    describe("batch", function()
        it("gives a library's login only where every address is on its site", function()
            local covers = Request.batch({ "http://nas.local:8080/get/1", "http://nas.local:8080/get/2" })
            assert.are.same({ username = "reader", password = "secret" }, covers.login)
            assert.is_nil(covers.proxy)
            assert.is_false(covers.encrypted_dns)

            local mixed = Request.batch({ "http://nas.local:8080/get/1", "https://libgen.example/cover.jpg" })
            assert.is_nil(mixed.login)
            assert.are.equal("http://proxy.example:3128", mixed.proxy)
            assert.is_true(mixed.encrypted_dns)
            assert.is_truthy(helper.logged("warn", "^downloading files from several sites"))
        end)
    end)
end)
