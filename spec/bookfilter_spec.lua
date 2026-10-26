local helper = require("helper")

describe("BookFilter", function()
    local BookFilter, offered

    before_each(function()
        helper.reset()
        helper.stub("api.sites", {
            zlib = { NAME = "Z-Library" },
            libgen = { NAME = "Library Genesis" },
            archive = { NAME = "Internet Archive" },
            library_1 = { NAME = "Home library" },
        })
        offered = { "zlib", "libgen", "archive" }
        helper.stub("api.multisearch", {
            sources = function()
                return offered
            end,
        })
        BookFilter = require("ui.bookfilter")
    end)

    after_each(helper.cleanup)

    local function filter(id)
        for _, found in ipairs(BookFilter.FILTERS) do
            if found.id == id then
                return found
            end
        end
        error("no filter " .. id)
    end

    local function notDownloaded()
        return false
    end

    -- each value's text and how many books have it, in the order they're listed
    local function counted(books, id, is_downloaded)
        local result = {}
        for _, value in ipairs(BookFilter.values(books, filter(id), is_downloaded or notDownloaded)) do
            table.insert(result, string.format("%s (%d)", value.text, value.count))
        end
        return result
    end

    describe("values", function()
        it("lists the sites in the order they're offered", function()
            local books = { { source = "archive" }, { source = "zlib" }, { source = "archive" } }
            assert.are.same({ "Z-Library (1)", "Internet Archive (2)" }, counted(books, "site"))
        end)

        -- e.g. a library the user has added, which is offered first (see MultiSearch.addSite)
        it("lists a site added while KOReader runs where it's offered", function()
            offered = { "library_1", "zlib", "libgen", "archive" }
            local books = { { source = "archive" }, { source = "library_1" } }
            assert.are.same({ "Home library (1)", "Internet Archive (1)" }, counted(books, "site"))
        end)

        it("lists the most common first, then by name, with books that don't say last", function()
            local books = {
                { file_type = "pdf" },
                { file_type = "epub" },
                { file_type = "mobi" },
                { file_type = "pdf" },
                {},
            }
            assert.are.same({ "PDF (2)", "EPUB (1)", "MOBI (1)", "Unknown (1)" }, counted(books, "file_type"))
        end)

        -- as Z-Library writes them in small letters, and Internet Archive lists several
        it("counts each site's spelling of a language as the same, and each of a book's languages", function()
            local books = {
                { language = "english" },
                { language = "English, Latin" },
                { language = "French; english" },
            }
            assert.are.same({ "English (3)", "French (1)", "Latin (1)" }, counted(books, "language"))
        end)

        it("counts a book once, where it says a language twice", function()
            assert.are.same({ "English (1)" }, counted({ { language = "English, english" } }, "language"))
        end)

        it("lists the book types, which only Library Genesis has", function()
            local books = { { book_type = "Fiction" }, { book_type = "Comics issue" }, {} }
            assert.are.same({ "Comics issue (1)", "Fiction (1)", "Unknown (1)" }, counted(books, "book_type"))
        end)

        it("lists the decades the books are from, the latest first", function()
            local books = { { year = "1813" }, { year = "2005" }, { year = "2009" }, { year = "1990" }, {} }
            assert.are.same({ "2000s (2)", "1990s (1)", "1810s (1)", "Unknown (1)" }, counted(books, "year"))
        end)

        -- as Z-Library and Library Genesis say them
        it("lists how big the books are, the smallest first", function()
            local books = {
                { file_size = "2.06 MB" },
                { file_size = "752 kB" },
                { file_size = "1.2MB" },
                { file_size = "250 MB" },
                { file_size = "1 GB" },
                { file_size = "12 MiB" },
                -- which Library Genesis gives a book without a size
                { file_size = "0" },
                {},
            }
            assert.are.same(
                { "Under 1 MB (1)", "1 to 10 MB (2)", "10 to 100 MB (1)", "Over 100 MB (2)", "Unknown (2)" },
                counted(books, "size")
            )
        end)

        -- even where none of the books have one, as finding out means looking in the download folder
        it("always lists whether books have been downloaded", function()
            local books = { { id = "a" }, { id = "b" } }
            assert.are.same({ "Yes (0)", "No (2)" }, counted(books, "downloaded"))
            assert.are.same(
                { "Yes (1)", "No (1)" },
                counted(books, "downloaded", function(book)
                    return book.id == "a"
                end)
            )
        end)
    end)

    describe("isOffered", function()
        it("offers a filter where the books don't all have the same value", function()
            local books = { { file_type = "epub" }, { file_type = "epub" } }
            local file_type = filter("file_type")
            assert.is_false(BookFilter.isOffered(file_type, BookFilter.values(books, file_type)))
            table.insert(books, { file_type = "pdf" })
            assert.is_true(BookFilter.isOffered(file_type, BookFilter.values(books, file_type)))
            -- or that the books don't say
            assert.is_true(
                BookFilter.isOffered(
                    filter("language"),
                    BookFilter.values({ {}, { language = "English" } }, filter("language"))
                )
            )
        end)

        it("always offers whether books have been downloaded", function()
            local downloaded = filter("downloaded")
            assert.is_true(BookFilter.isOffered(downloaded, downloaded.fixed))
        end)
    end)

    describe("isShown", function()
        it("shows every book where nothing is hidden", function()
            assert.is_true(BookFilter.isShown({ source = "zlib" }, {}, notDownloaded))
        end)

        it("hides the books whose values are all hidden", function()
            local hidden = { site = { zlib = true }, file_type = { pdf = true } }
            assert.is_false(BookFilter.isShown({ source = "zlib", file_type = "epub" }, hidden, notDownloaded))
            assert.is_false(BookFilter.isShown({ source = "libgen", file_type = "pdf" }, hidden, notDownloaded))
            assert.is_true(BookFilter.isShown({ source = "libgen", file_type = "epub" }, hidden, notDownloaded))
        end)

        -- whose values weren't there to untick when what's hidden was chosen
        it("shows the books with other values than those hidden", function()
            assert.is_true(BookFilter.isShown({ source = "archive" }, { site = { zlib = true } }, notDownloaded))
        end)

        it("shows a book in several languages where any of them isn't hidden", function()
            local hidden = { language = { english = true } }
            assert.is_true(BookFilter.isShown({ language = "English, Latin" }, hidden, notDownloaded))
            assert.is_false(BookFilter.isShown({ language = "english" }, hidden, notDownloaded))
            -- and hides those that don't say, where Unknown is
            assert.is_false(BookFilter.isShown({}, { language = { [""] = true } }, notDownloaded))
        end)

        it("hides the books downloaded already, or those that haven't been", function()
            local function isDownloaded(book)
                return book.id == "a"
            end
            assert.is_false(BookFilter.isShown({ id = "a" }, { downloaded = { yes = true } }, isDownloaded))
            assert.is_true(BookFilter.isShown({ id = "b" }, { downloaded = { yes = true } }, isDownloaded))
        end)
    end)

    describe("hiding", function()
        it("hides the values that aren't ticked, or nothing where they all are", function()
            local values = BookFilter.values({ { source = "zlib" }, { source = "libgen" } }, filter("site"))
            assert.are.same({ libgen = true }, BookFilter.hiding(values, { "zlib" }))
            assert.is_nil(BookFilter.hiding(values, { "libgen", "zlib" }))
        end)
    end)

    describe("describe", function()
        it("says All where nothing is hidden, otherwise what's shown", function()
            local values = BookFilter.values(
                { { source = "zlib" }, { source = "libgen" }, { source = "archive" } },
                filter("site")
            )
            assert.are.equal("All", BookFilter.describe(values, nil))
            assert.are.equal("Z-Library, Internet Archive", BookFilter.describe(values, { libgen = true }))
        end)
    end)
end)
