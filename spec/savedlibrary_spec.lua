local helper = require("helper")

describe("SavedLibrary", function()
    local SavedLibrary

    -- as Libraries.add saves one
    local function saved()
        return {
            id = "a1",
            name = "Books",
            url = "http://nas:8080/opds?library_id=Books",
            kind = "calibre",
            search_url = "http://nas:8080/opds/search/{searchTerms}?library_id=Books",
            username = "will",
            password = "secretpassword",
        }
    end

    before_each(function()
        helper.reset()
        SavedLibrary = require("settings.savedlibrary")
    end)

    after_each(helper.cleanup)

    it("is the library as it was saved", function()
        assert.are.same(saved(), SavedLibrary.fromTable(saved()):toTable())
    end)

    -- which is what's saved, and handed to what searches it
    it("is given as a plain table of its own, without anything else it was saved with", function()
        local library = saved()
        library.extra = "left out"
        local record = SavedLibrary.fromTable(library)
        local plain = record:toTable()
        assert.is_nil(getmetatable(plain))
        assert.is_nil(plain.extra)
        plain.name = "Comics"
        assert.are.equal("Books", record.name)
    end)

    -- where it needs none
    it("has no login where none was saved, or one that isn't text", function()
        local library = saved()
        library.username, library.password = nil, 1234
        local plain = SavedLibrary.fromTable(library):toTable()
        assert.are.equal("", plain.username)
        assert.are.equal("", plain.password)
    end)

    -- e.g. edited by hand, which what reads it would fail on
    it("isn't one without its id, name, kind and search, each as text", function()
        for _, field in ipairs({ "id", "name", "kind", "search_url" }) do
            for _, value in ipairs({ "", 7, false }) do
                local library = saved()
                library[field] = value
                assert.is_nil(SavedLibrary.fromTable(library), field)
            end
            local library = saved()
            library[field] = nil
            assert.is_nil(SavedLibrary.fromTable(library), field)
        end
    end)

    it("isn't one at an address that isn't a web page's", function()
        for _, url in ipairs({ "javascript:alert(1)", "ftp://nas/opds", "http://nas/my books", 'http://nas/"opds' }) do
            local library = saved()
            library.url = url
            assert.is_nil(SavedLibrary.fromTable(library), url)
        end
        local library = saved()
        library.url = nil
        assert.is_nil(SavedLibrary.fromTable(library))
    end)

    it("isn't one where what's saved isn't a table", function()
        assert.is_nil(SavedLibrary.fromTable("not a library"))
        assert.is_nil(SavedLibrary.fromTable(7))
        assert.is_nil(SavedLibrary.fromTable(nil))
    end)
end)
