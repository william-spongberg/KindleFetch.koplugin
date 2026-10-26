local helper = require("helper")

describe("SearchSession", function()
    local SearchSession, data_dir

    local function book(id, title, source)
        return {
            id = id,
            title = title,
            display_title = title,
            authors = "Frank Herbert",
            file_type = "epub",
            source = source,
        }
    end

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        SearchSession = require("api.searchsession")
    end)

    after_each(helper.cleanup)

    it("keeps the books found, saying when they're the first", function()
        local session = SearchSession.new("dune", { "libgen" })
        assert.is_nil(session.books)
        assert.is_true(session:addBooks({ book("1", "Dune", "libgen") }))
        assert.is_false(session:addBooks({ book("2", "Dune Messiah", "libgen") }))
        assert.are.same({ "Dune", "Dune Messiah" }, { session.books[1].title, session.books[2].title })
    end)

    -- whose books wouldn't be shown anyway
    it("loads more from the sites with more, but not those whose books are hidden", function()
        local session = SearchSession.new("dune", { "libgen", "archive" })
        assert.is_false(session:hasMore())
        session.next_pages = { libgen = 2, archive = 3 }
        assert.are.same({ libgen = 2, archive = 3 }, session:pagesToLoad())

        session.hidden.site = { archive = true }
        assert.are.same({ libgen = 2 }, session:pagesToLoad())
        session.hidden.site = { archive = true, libgen = true }
        assert.is_false(session:hasMore())
    end)

    it("names each book's site where several were searched", function()
        assert.are.equal(
            "Dune · Frank Herbert · EPUB",
            SearchSession.new("dune", { "libgen" }):bookItemText(book("1", "Dune", "libgen"))
        )
        assert.are.equal(
            "Dune · Frank Herbert · EPUB · Library Genesis",
            SearchSession.new("dune", { "libgen", "archive" }):bookItemText(book("1", "Dune", "libgen"))
        )
    end)

    it("shows only the books with the text looked for, whatever its capitals, until all are shown again", function()
        local session = SearchSession.new("dune", { "libgen" })
        session:addBooks({ book("1", "Dune", "libgen"), book("2", "Dune Messiah", "libgen") })
        assert.is_false(session:isFiltering())

        session.filter = "MESSIAH"
        assert.is_true(session:isFiltering())
        assert.is_false(session:isShown(session.books[1]))
        assert.is_true(session:isShown(session.books[2]))
        assert.are.equal(1, session:countShown())
        assert.are.equal(1, session:countShown(2))

        session:showAll()
        assert.is_false(session:isFiltering())
        assert.are.equal(2, session:countShown())
    end)

    -- as naming it reads the file systems mounted
    it("remembers whether each book is downloaded until told to look again", function()
        local settings = require("settings.settings")
        settings:setDownloadDir(data_dir)
        local session = SearchSession.new("dune", { "libgen" })
        local dune = book("1", "Dune", "libgen")
        assert.is_false(session:isDownloaded(dune))

        helper.writeFile(data_dir .. "/Dune.epub", "PK")
        assert.is_false(session:isDownloaded(dune))
        session:forgetDownloaded()
        assert.is_true(session:isDownloaded(dune))
    end)
end)
