local helper = require("helper")

describe("Book", function()
    local Book

    before_each(function()
        helper.reset()
        Book = require("api.book")
    end)

    after_each(helper.cleanup)

    describe("new", function()
        it("keeps the site's fields, naming the file after the title without what's in brackets", function()
            assert.are.same(
                {
                    source = "archive",
                    id = "archive_dune",
                    title = "Dune- Messiah",
                    display_title = "Dune: Messiah",
                    authors = "Frank Herbert",
                    file_type = "epub",
                },
                Book.new("archive", {
                    id = "archive_dune",
                    title = "Dune: Messiah (Book 2)",
                    authors = "Frank Herbert",
                    file_type = "epub",
                })
            )
        end)

        it("names the file after fallback_title where nothing's left of the title, or nothing without one", function()
            assert.are.equal("archive_1", Book.new("archive", { title = "..." }, "archive_1").title)
            assert.are.equal("", Book.new("libgen", {}).title)
            assert.are.equal("", Book.new("libgen", {}).display_title)
        end)

        it("says the author is unknown where the site doesn't say", function()
            assert.are.equal("Unknown author", Book.new("libgen", { title = "Dune", authors = "" }).authors)
            assert.are.equal("Unknown author", Book.new("libgen", { title = "Dune" }).authors)
        end)
    end)

    it("writes sizes as the sites do, and reads them back", function()
        assert.is_nil(Book.formatSize(nil))
        assert.is_nil(Book.formatSize(0))
        assert.are.equal("1 kB", Book.formatSize(100))
        assert.are.equal("752 kB", Book.formatSize(752 * 1024))
        assert.are.equal("2.1 MB", Book.formatSize(2.1 * 1024 * 1024))

        assert.are.equal(752 * 1024, Book.parseSize("752 kB"))
        assert.are.equal(2.06 * 1024 * 1024, Book.parseSize("2.06 MB"))
        assert.are.equal(1024 * 1024 * 1024, Book.parseSize("1 GiB"))
        assert.is_nil(Book.parseSize("0"))
        assert.is_nil(Book.parseSize(nil))
        assert.is_nil(Book.parseSize("unknown"))
    end)

    it("downloads to a file named after its title and file type, in the folder", function()
        local book = { title = "Dune/Messiah", file_type = "epub" }
        assert.are.equal("Dune_Messiah.epub", Book.fileName(book, "/mnt/us/documents"))
        assert.are.equal("/mnt/us/documents/Dune_Messiah.epub", Book.path(book, "/mnt/us/documents"))
    end)
end)
