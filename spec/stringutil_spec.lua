local helper = require("helper")

describe("StringUtil", function()
    local StringUtil

    before_each(function()
        helper.reset()
        StringUtil = require("util.stringutil")
    end)

    it("only accepts non-empty strings as valid", function()
        assert.is_true(StringUtil.assertValidString("a"))
        assert.is_false(StringUtil.assertValidString(""))
        assert.is_false(StringUtil.assertValidString(nil))
        assert.is_false(StringUtil.assertValidString(42))
    end)

    -- every helper returns an empty string for invalid input rather than erroring
    for _, name in ipairs({
        "trim",
        "collapseWhitespace",
        "collapseDots",
        "collapseDashes",
        "convertHtmlToText",
        "removeParentheses",
        "cleanTitle",
        "cleanFileName",
        "replaceCarriageReturns",
    }) do
        it(name .. " returns an empty string for invalid input", function()
            assert.are.equal("", StringUtil[name](nil))
            assert.are.equal("", StringUtil[name](""))
        end)
    end

    it("trims whitespace from both ends", function()
        assert.are.equal("dune", StringUtil.trim("  \tdune \n"))
    end)

    it("collapses repeated whitespace, dots and dashes", function()
        assert.are.equal("a b c", StringUtil.collapseWhitespace("a  \t b\n\nc"))
        assert.are.equal("a.b.c", StringUtil.collapseDots("a...b..c"))
        assert.are.equal("a-b-c", StringUtil.collapseDashes("a---b--c"))
    end)

    it("converts html entities to text", function()
        assert.are.equal("Pride & Prejudice", StringUtil.convertHtmlToText("Pride &amp; Prejudice"))
    end)

    it("removes parenthesised and bracketed text", function()
        assert.are.equal("Dune", StringUtil.removeParentheses("Dune (Dune Chronicles 1) [Ace, 1990]"))
    end)

    describe("cleanTitle", function()
        it("leaves a title as it's written, unlike a file name", function()
            assert.are.equal("Dune: Messiah / What if?", StringUtil.cleanTitle("Dune: Messiah / What if?"))
            assert.are.equal("Dune- Messiah - What if-", StringUtil.cleanFileName("Dune: Messiah / What if?"))
        end)

        it("leaves out what's in brackets, and the space around it", function()
            assert.are.equal("Dune", StringUtil.cleanTitle("  Dune (Dune Chronicles, Book 1) [1965] "))
            assert.are.equal("Dune - House Atreides", StringUtil.cleanTitle("Dune - House Atreides(Boom 2020)"))
        end)

        it("keeps a title that is all in brackets", function()
            assert.are.equal("[Untitled]", StringUtil.cleanTitle(" [Untitled] "))
        end)

        it("leaves titles in other alphabets whole", function()
            local title =
                "Мастер и Маргарита: роман в двух частях, с иллюстрациями"
            assert.are.equal(title, StringUtil.cleanTitle(title))
        end)
    end)

    -- an address is written to curl's config file, where a line break or quote would add options of its own
    describe("isSafeUrl", function()
        it("accepts web addresses", function()
            assert.is_true(StringUtil.isSafeUrl("https://libgen.example/fictioncovers/2509000/abc_small.jpg"))
            assert.is_true(StringUtil.isSafeUrl("http://covers.example/a%20b.jpg?size=small&v=2#top"))
        end)

        it("refuses addresses with line breaks, spaces, quotes or backslashes in them", function()
            assert.is_false(StringUtil.isSafeUrl("https://covers.example/a.jpg\noutput = /mnt/us/koreader/reader.lua"))
            assert.is_false(StringUtil.isSafeUrl("https://covers.example/a.jpg\r"))
            assert.is_false(StringUtil.isSafeUrl("https://covers.example/a b.jpg"))
            assert.is_false(StringUtil.isSafeUrl('https://covers.example/a.jpg"'))
            assert.is_false(StringUtil.isSafeUrl("https://covers.example/a.jpg\\"))
        end)

        it("refuses anything that isn't a web address", function()
            assert.is_false(StringUtil.isSafeUrl("file:///etc/passwd"))
            assert.is_false(StringUtil.isSafeUrl("covers.example/a.jpg"))
            assert.is_false(StringUtil.isSafeUrl("https://"))
            assert.is_false(StringUtil.isSafeUrl(""))
            assert.is_false(StringUtil.isSafeUrl(nil))
        end)
    end)

    it("makes titles safe to use as file names", function()
        assert.are.equal("Dune- Messiah", StringUtil.cleanFileName("Dune: Messiah (Book 2)"))
        -- which was left empty, naming the book's file only for its type, which hid it
        assert.are.equal("[Poems]", StringUtil.cleanFileName("[Poems]"))
        assert.are.equal("(Untitled) [2020]", StringUtil.cleanFileName(" (Untitled) [2020] "))
        -- unless there's nothing to name it after at all
        assert.are.equal("", StringUtil.cleanFileName("..."))
        assert.are.equal("AC-DC - The Story", StringUtil.cleanFileName("AC/DC -- The Story"))
        assert.are.equal("Title", StringUtil.cleanFileName("...Title... "))
        assert.are.equal("Mr. Mercedes", StringUtil.cleanFileName("Mr. Mercedes"))
    end)

    -- which a library's login is only ever sent to (see LibrarySites)
    describe("siteOf", function()
        it("gives an address's scheme, host and port, in small letters", function()
            assert.are.equal("http://192.168.1.10:8080", StringUtil.siteOf("http://192.168.1.10:8080/opds?x=1"))
            assert.are.equal("https://books.example:443", StringUtil.siteOf("HTTPS://Books.Example/calibre/opds"))
            assert.are.equal("http://nas.local:80", StringUtil.siteOf("http://nas.local"))
            assert.are.equal("http://[fd00::1]:8083", StringUtil.siteOf("http://[fd00::1]:8083/opds"))
        end)

        it("leaves out who an address logs into its site as", function()
            assert.are.equal("http://nas:8080", StringUtil.siteOf("http://will:secret@nas:8080/opds"))
        end)

        it("is nil for what isn't a web address", function()
            assert.is_nil(StringUtil.siteOf("ftp://nas/books"))
            assert.is_nil(StringUtil.siteOf("/opds"))
            assert.is_nil(StringUtil.siteOf("http://:8080/"))
            assert.is_nil(StringUtil.siteOf(nil))
        end)
    end)

    it("gives what's asked for at an address on its site", function()
        assert.are.equal("/opds/search/dune?offset=30", StringUtil.pathOf("http://nas:8080/opds/search/dune?offset=30"))
        assert.are.equal("/", StringUtil.pathOf("http://nas:8080"))
        assert.are.equal("/?q=1", StringUtil.pathOf("http://nas:8080?q=1#top"))
    end)

    -- which encrypted DNS can't look up, and a proxy on the internet can't reach
    describe("isLocalUrl", function()
        it("knows the addresses kept for a home network, and the device itself", function()
            for _, url in ipairs({
                "http://192.168.1.10:8080",
                "http://10.0.0.5/opds",
                "http://172.20.1.2",
                "http://127.0.0.1:8083",
                "http://169.254.3.4",
                "http://100.101.102.103",
                "http://[::1]:8080",
                "http://[fd12:3456::1]/",
                "http://[fe80::1]/",
            }) do
                assert.is_true(StringUtil.isLocalUrl(url), url)
            end
        end)

        it("knows the names a home network's DNS gives its devices", function()
            for _, url in ipairs({
                "http://nas:8080",
                "http://calibre.local",
                "https://books.lan/opds",
                "http://nas.home.arpa",
                "http://library.internal",
                "http://localhost:8083",
            }) do
                assert.is_true(StringUtil.isLocalUrl(url), url)
            end
        end)

        it("knows the rest are on the internet", function()
            for _, url in ipairs({
                "https://libgen.li",
                "https://books.example.com/calibre",
                "http://8.8.8.8",
                "http://172.32.0.1",
                "http://100.128.0.1",
                "https://[2001:db8::1]/",
                "not an address",
            }) do
                assert.is_false(StringUtil.isLocalUrl(url), url)
            end
        end)
    end)

    -- e.g. an OPDS catalogue's links, or where a site sends a request on to
    describe("absoluteUrl", function()
        local base = "http://nas:8080/opds/search/dune?offset=30"

        it("gives the address a link gives, as written on the page at an address", function()
            assert.are.equal("http://nas:8080/opds/search/x", StringUtil.absoluteUrl(base, "x"))
            assert.are.equal("http://nas:8080/opds/cover/1", StringUtil.absoluteUrl(base, "../cover/1"))
            assert.are.equal("http://nas:8080/get/epub/1", StringUtil.absoluteUrl(base, "/get/epub/1"))
            assert.are.equal("http://nas:8080/opds/search/dune?offset=60", StringUtil.absoluteUrl(base, "?offset=60"))
            assert.are.equal("http://covers.example/1.jpg", StringUtil.absoluteUrl(base, "//covers.example/1.jpg"))
            assert.are.equal("https://other.example/a", StringUtil.absoluteUrl(base, "https://other.example/a"))
            assert.are.equal("http://nas:8080/opds/x/", StringUtil.absoluteUrl(base, "./../x/"))
        end)

        it("is nil without a web address to go from", function()
            assert.is_nil(StringUtil.absoluteUrl("/opds", "x"))
            assert.is_nil(StringUtil.absoluteUrl(base, nil))
        end)
    end)

    it("turns the line breaks in github's release notes into new lines", function()
        assert.are.equal("line 1\nline 2\n", StringUtil.replaceCarriageReturns("line 1\r\nline 2\r\n"))
    end)
end)
