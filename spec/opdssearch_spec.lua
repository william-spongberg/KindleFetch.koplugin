local helper = require("helper")
local fixtures = require("fixtures")

describe("OpdsSearch", function()
    local web, OpdsSearch, Settings, Errors

    -- as Calibre's content server (9.13) sends its catalogue, and a search of it, here on 127.0.0.1:8089
    local CALIBRE_ROOT = [[<?xml version='1.0' encoding='utf-8'?>
<feed
    xmlns="http://www.w3.org/2005/Atom"
    xmlns:dc="http://purl.org/dc/terms/"
    xmlns:opds="http://opds-spec.org/2010/catalog">
  <title>calibre Library</title>
  <subtitle>Books in your library</subtitle>
  <author>
    <name>calibre</name>
    <uri>https://calibre-ebook.com</uri>
  </author>
  <id>urn:calibre:main</id>
  <link rel="search" title="Search" href="/opds/search/{searchTerms}?library_id=Books" type="application/atom+xml"/>
  <link
      href="/opds?library_id=Books"
      type="application/atom+xml;type=feed;profile=opds-catalog;kind=navigation"
      rel="start"
      title="Start"/>
  <entry>
    <title>By Newest</title>
    <id>calibre-navcatalog:9d6d15be328b5628a8d4e83da75fea59ba488754</id>
    <content type="text">Books sorted by Date</content>
    <link
        href="/opds/navcatalog/4f6e6577657374?library_id=Books"
        type="application/atom+xml;type=feed;profile=opds-catalog;kind=navigation"/>
  </entry>
  <entry>
    <title>Library: Books</title>
    <id>calibre-library:Books</id>
    <content type="text">Change calibre library to: Books</content>
    <link href="/opds?library_id=Books" type="application/atom+xml;type=feed;profile=opds-catalog;kind=navigation"/>
  </entry>
  <entry>
    <title>Library: Comics</title>
    <id>calibre-library:Comics</id>
    <content type="text">Change calibre library to: Comics</content>
    <link href="/opds?library_id=Comics" type="application/atom+xml;type=feed;profile=opds-catalog;kind=navigation"/>
  </entry>
</feed>
]]

    local CALIBRE_SEARCH = [[<?xml version='1.0' encoding='utf-8'?>
<feed
    xmlns="http://www.w3.org/2005/Atom"
    xmlns:dc="http://purl.org/dc/terms/"
    xmlns:opds="http://opds-spec.org/2010/catalog">
  <title>calibre Library</title>
  <author>
    <name>calibre</name>
    <uri>https://calibre-ebook.com</uri>
  </author>
  <id>calibre-search:austen</id>
  <link rel="search" title="Search" href="/opds/search/{searchTerms}?library_id=Books" type="application/atom+xml"/>
  <link
      href="/opds/search/%22austen%22?library_id=Books&amp;offset=1"
      type="application/atom+xml;type=feed;profile=opds-catalog;kind=acquisition"
      rel="next"
      title="Next"/>
  <entry>
    <title>Emma</title>
    <author>
      <name>Jane Austen</name>
    </author>
    <id>urn:uuid:62d51e5b-c053-46d1-9d13-085cce6c00ec</id>
    <updated>2026-10-26T00:34:14+00:00</updated>
    <published>2026-10-26T00:34:08+00:00</published>
    <dc:date>1994-07-31T14:00:00+00:00</dc:date>
    <content type="xhtml">
      <html:br xmlns:html="http://www.w3.org/1999/xhtml"/>
    </content>
    <link
        type="application/epub+zip"
        href="/get/epub/2/Books"
        rel="http://opds-spec.org/acquisition"
        length="494782"
        mtime="2026-10-26T00:34:08.196951+00:00"/>
    <link
        type="application/x-mobipocket-ebook"
        href="/get/mobi/2/Books"
        rel="http://opds-spec.org/acquisition"
        length="656423"
        mtime="2026-10-26T00:34:14.109038+00:00"/>
    <link type="image/jpeg" href="/get/cover/2/Books" rel="http://opds-spec.org/cover"/>
    <link type="image/jpeg" href="/get/thumb/2/Books" rel="http://opds-spec.org/thumbnail"/>
    <link type="image/jpeg" href="/get/cover/2/Books" rel="http://opds-spec.org/image"/>
    <link type="image/jpeg" href="/get/thumb/2/Books" rel="http://opds-spec.org/image/thumbnail"/>
  </entry>
  <entry>
    <title>Good Omens</title>
    <author>
      <name>Terry Pratchett &amp; Neil Gaiman</name>
    </author>
    <id>urn:uuid:054a3e22-c6f2-48e3-861d-d1e5a4cceb45</id>
    <published>2026-10-26T00:34:08+00:00</published>
    <link type="application/pdf" href="/get/pdf/7/Books" rel="http://opds-spec.org/acquisition" length="2202009"/>
  </entry>
</feed>
]]

    -- as Calibre-Web writes its catalogue (from its templates, feed.xml and osd.xml), here on nas:8083
    local CALIBRE_WEB_ROOT = [[<?xml version="1.0" encoding="UTF-8"?>
<feed
    xmlns="http://www.w3.org/2005/Atom"
    xmlns:dc="http://purl.org/dc/terms/"
    xmlns:dcterms="http://purl.org/dc/terms/">
  <id>urn:uuid:2853dacf-ed79-42f5-8e8a-a7bb3d1ae6a2</id>
  <link rel="start" href="/opds" type="application/atom+xml;profile=opds-catalog;type=feed;kind=navigation"/>
  <link rel="search" href="/opds/osd" type="application/opensearchdescription+xml"/>
  <link type="application/atom+xml" rel="search" title="Search" href="/opds/search/{searchTerms}" />
  <title>Will's Books</title>
  <author>
    <name>Will's Books</name>
    <uri>https://github.com/janeczku/calibre-web</uri>
  </author>
</feed>
]]

    local function calibreWebEntry(id, title, authors, languages, formats)
        local parts = { "<entry>", "<title>" .. title .. "</title>", "<id>urn:uuid:cw-" .. id .. "</id>" }
        for _, author in ipairs(authors) do
            table.insert(parts, "<author><name>" .. author .. "</name></author>")
        end
        table.insert(parts, "<published>1813-01-28T00:00:00+00:00</published>")
        for _, language in ipairs(languages) do
            table.insert(parts, "<dcterms:language>" .. language .. "</dcterms:language>")
        end
        table.insert(
            parts,
            '<link type="image/jpeg" href="/opds/cover/' .. id .. '" rel="http://opds-spec.org/image"/>'
        )
        table.insert(
            parts,
            '<link type="image/jpeg" href="/opds/cover/' .. id .. '" rel="http://opds-spec.org/image/thumbnail"/>'
        )
        for _, format in ipairs(formats) do
            table.insert(
                parts,
                string.format(
                    '<link rel="http://opds-spec.org/acquisition" href="/opds/download/%d/%s/" length="%d" '
                        .. 'title="%s" mtime="2026-10-20T10:00:00+00:00" type="%s"/>',
                    id,
                    format[1]:lower(),
                    format[2],
                    format[1],
                    format[3] or "application/octet-stream"
                )
            )
        end
        table.insert(parts, "</entry>")
        return table.concat(parts, "\n")
    end

    local function calibreWebFeed(entries)
        return CALIBRE_WEB_ROOT:gsub("</feed>", table.concat(entries, "\n") .. "\n</feed>")
    end

    local function calibreLibrary()
        return OpdsSearch.new("library_1", {
            name = "Books",
            kind = OpdsSearch.CALIBRE,
            url = "http://127.0.0.1:8089/opds?library_id=Books",
            search_url = "http://127.0.0.1:8089/opds/search/{searchTerms}?library_id=Books",
        })
    end

    local function calibreWebLibrary()
        return OpdsSearch.new("library_2", {
            name = "Will's Books",
            kind = OpdsSearch.CALIBRE_WEB,
            url = "http://nas:8083/opds",
            search_url = "http://nas:8083/opds/search/{searchTerms}",
        })
    end

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        helper.state.fs["/mnt/us/documents"] = false
        web = fixtures.fakeWeb(helper)
        OpdsSearch = require("api.opdssearch")
        Settings = require("settings.settings")
        Errors = require("util.errors")
        Settings:setPreferredLanguages({ "en" })
        Settings:setPreferredFileTypes({ "epub", "mobi", "pdf" })
    end)

    after_each(helper.cleanup)

    describe("searching Calibre's content server", function()
        it(
            "searches in its own search's syntax, each word in quotes, in the file types and languages chosen",
            function()
                assert.are.equal(
                    '("pride" and "1984:" and "\\"hi\\"") and (formats:"=EPUB" or formats:"=PDF") and '
                        .. '(languages:"=eng" or languages:"=fre" or languages:"=fra" or languages:false)',
                    OpdsSearch.calibreSearch('pride 1984: "hi"', nil, { "en", "fr" }, { "epub", "pdf" })
                )
            end
        )

        it("narrows the search down to the books' titles, authors or ISBNs", function()
            assert.matches(
                '^%(title:"pride" and title:"prejudice"%) and ',
                OpdsSearch.calibreSearch("pride prejudice", "title", { "en" }, { "epub" })
            )
            assert.matches(
                '^%(authors:"austen"%) and ',
                OpdsSearch.calibreSearch("austen", "author", { "en" }, { "epub" })
            )
            assert.matches(
                '^%(identifiers:"=isbn:978014143958X"%) and ',
                OpdsSearch.calibreSearch("978-0-14-143958-x", "isbn", { "en" }, { "epub" })
            )
            assert.is_nil(OpdsSearch.calibreSearch("no digits", "isbn", { "en" }, { "epub" }))
        end)

        -- which KOReader opens saved as an AZW, as it takes their MIME type to be that
        it("searches for books in AZW3 where AZW is chosen", function()
            assert.matches(
                ' and %(formats:"=EPUB" or formats:"=AZW" or formats:"=AZW3"%)',
                OpdsSearch.calibreSearch("emma", nil, { "en" }, { "epub", "azw" })
            )
        end)

        it("doesn't narrow the languages down when every one is chosen", function()
            local every = {}
            for _, language in ipairs(Settings:getAvailableLanguages()) do
                table.insert(every, language.code)
            end
            assert.is_nil(OpdsSearch.calibreSearch("emma", nil, every, { "epub" }):find("languages:", 1, true))
        end)

        it("can be narrowed down, as its search can", function()
            assert.are.same({ "title", "author", "isbn" }, calibreLibrary().SCOPES)
            assert.is_nil(calibreWebLibrary().SCOPES)
        end)

        it("finds the books in the file types chosen, the first chosen of those each is in", function()
            local site = calibreLibrary()
            local url = site:searchUrl({
                query = "austen",
                page = 1,
                languages = { "en" },
                file_types = { "mobi", "epub", "pdf" },
            })
            web.pages[url] = CALIBRE_SEARCH
            Settings:setPreferredFileTypes({ "mobi", "epub", "pdf" })

            local books, err, next_page, results = site:search("austen", 1)
            assert.is_nil(err)
            assert.are.equal(2, next_page)
            assert.are.equal(2, results)
            assert.are.same({
                source = "library_1",
                id = "library_1_urn_uuid_62d51e5b-c053-46d1-9d13-085cce6c00ec",
                title = "Emma",
                display_title = "Emma",
                authors = "Jane Austen",
                year = "1994",
                file_type = "mobi",
                file_size = "641 kB",
                bytes = 656423,
                download_url = "http://127.0.0.1:8089/get/mobi/2/Books",
                image_url = "http://127.0.0.1:8089/get/thumb/2/Books?sz=200x300",
                full_image_url = "http://127.0.0.1:8089/get/cover/2/Books",
            }, books[1])
            -- with each author, rather than all of them as one, and no year, where it only says when it was added
            assert.are.equal("Terry Pratchett, Neil Gaiman", books[2].authors)
            assert.is_nil(books[2].year)
            assert.are.equal("pdf", books[2].file_type)
            assert.are.equal("2.1 MB", books[2].file_size)
        end)

        it("asks for the next page at the address the one before links to", function()
            local site = calibreLibrary()
            web.pages[site:searchUrl({
                query = "austen",
                page = 1,
                languages = { "en" },
                file_types = { "epub", "mobi", "pdf" },
            })] =
                CALIBRE_SEARCH
            web.pages["http://127.0.0.1:8089/opds/search/%22austen%22?library_id=Books&offset=1"] =
                CALIBRE_SEARCH:gsub('<link%s[^>]*rel="next"[^>]*/>', "")
            site:search("austen", 1)

            local books, err, next_page = site:search("austen", 2)
            assert.is_nil(err)
            assert.are.equal(2, #books)
            assert.is_nil(next_page)
        end)

        -- which it answers a search that finds nothing with, as it does one it can't make sense of
        it("takes being told nothing was found (HTTP 404) as no books", function()
            local site = calibreLibrary()
            web.pages[site:searchUrl({
                query = "zzz",
                page = 1,
                languages = { "en" },
                file_types = { "epub", "mobi", "pdf" },
            })] = function()
                return "<html>No books found</html>", nil, 404
            end
            local books, err, next_page, results = site:search("zzz", 1)
            assert.are.same({}, books)
            assert.is_nil(err)
            assert.is_nil(next_page)
            assert.are.equal(0, results)
        end)

        it("asks at its search's address, with the search escaped", function()
            assert.are.equal(
                "http://127.0.0.1:8089/opds/search/%28%22dune%22%29%20and%20%28formats%3A%22%3DEPUB%22%29%20and%20"
                    .. "%28languages%3A%22%3Deng%22%20or%20languages%3Afalse%29?library_id=Books",
                calibreLibrary():searchUrl({ query = "dune", page = 1, languages = { "en" }, file_types = { "epub" } })
            )
        end)
    end)

    describe("searching Calibre-Web", function()
        it("finds the books in the languages chosen, or that don't say", function()
            local site = calibreWebLibrary()
            web.pages["http://nas:8083/opds/search/pride%20prejudice"] = calibreWebFeed({
                calibreWebEntry(1, "Pride and Prejudice", { "Jane Austen" }, { "eng" }, {
                    { "EPUB", 561102, "application/epub+zip" },
                }),
                calibreWebEntry(2, "Orgueil et préjugés", { "Jane Austen" }, { "fra" }, {
                    { "EPUB", 600000, "application/epub+zip" },
                }),
                calibreWebEntry(3, "Pride and Prejudice and Zombies", { "Jane Austen", "Seth Grahame-Smith" }, {}, {
                    -- its file type from its title, where its MIME type doesn't say
                    { "PDF", 3000000 },
                }),
            })

            local books, err, next_page, results = site:search("pride prejudice", 1)
            assert.is_nil(err)
            assert.is_nil(next_page)
            assert.are.equal(3, results)
            assert.are.equal(2, #books)
            assert.are.equal("English", books[1].language)
            assert.are.equal("1813", books[1].year)
            assert.are.equal("http://nas:8083/opds/download/1/epub/", books[1].download_url)
            -- the same address for both, so there's no full-size cover apart from the thumbnail
            assert.are.equal("http://nas:8083/opds/cover/1", books[1].image_url)
            assert.are.equal("Jane Austen, Seth Grahame-Smith", books[2].authors)
            assert.is_nil(books[2].language)
            assert.are.equal("pdf", books[2].file_type)
        end)

        -- as Calibre and Calibre-Web give an AZW3 (KF8), which KOReader opens saved as an AZW
        it("takes a book in AZW3 to be in AZW", function()
            Settings:setPreferredFileTypes({ "azw" })
            local site = calibreWebLibrary()
            web.pages["http://nas:8083/opds/search/emma"] = calibreWebFeed({
                calibreWebEntry(4, "Emma", { "Jane Austen" }, {}, { { "AZW3", 700000, "application/x-mobi8-ebook" } }),
                calibreWebEntry(5, "Persuasion", { "Jane Austen" }, {}, { { "AZW3", 500000 } }),
            })
            local books = site:search("emma", 1)
            assert.are.same({ "azw", "azw" }, { books[1].file_type, books[2].file_type })
            assert.are.equal("http://nas:8083/opds/download/4/azw3/", books[1].download_url)
        end)

        it("asks for the search as it's written, escaped", function()
            assert.are.equal(
                "http://nas:8083/opds/search/dune%20messiah",
                calibreWebLibrary():searchUrl({
                    query = "  dune messiah ",
                    page = 1,
                    languages = { "en" },
                    file_types = { "epub" },
                })
            )
        end)

        it("leaves out what's in the results that isn't a book, e.g. a series", function()
            local site = calibreWebLibrary()
            web.pages["http://nas:8083/opds/search/dune"] = calibreWebFeed({
                '<entry><title>Dune</title><id>/opds/series/3</id><link rel="subsection" '
                    .. 'type="application/atom+xml;profile=opds-catalog" href="/opds/series/3"/></entry>',
            })
            local books, err, _, results = site:search("dune", 1)
            assert.is_nil(err)
            assert.are.same({}, books)
            assert.are.equal(1, results)
        end)
    end)

    it("fills in the OpenSearch parameters a search's template has", function()
        local site = OpdsSearch.new("library_3", {
            name = "Comics",
            kind = OpdsSearch.OPDS,
            url = "https://books.example/opds",
            search_url = "https://books.example/search?q={searchTerms}&page={startPage}&n={count?}&l={language?}",
        })
        assert.are.equal(
            "https://books.example/search?q=watchmen&page=1&n=&l=",
            site:searchUrl({ query = "watchmen", page = 1, languages = { "en" }, file_types = { "cbz" } })
        )
    end)

    describe("when it can't search the library", function()
        local site, url

        before_each(function()
            site = calibreWebLibrary()
            url = "http://nas:8083/opds/search/dune"
        end)

        it("says the login was turned down", function()
            web.pages[url] = function()
                return "<html>Unauthorized</html>", nil, 401
            end
            assert.are.same({ nil, Errors.LIBRARY_LOGIN }, { site:search("dune", 1) })
        end)

        -- as Calibre's content server does once it's set up to, after too many logins that failed
        it("says it has stopped letting the device log in for a while", function()
            web.pages[url] = function()
                return "Too many login attempts", nil, 403
            end
            assert.are.same({ nil, Errors.LIBRARY_LOCKED_OUT }, { site:search("dune", 1) })
        end)

        it("says it can't be reached, as when the device isn't on its network", function()
            web.pages[url] = function()
                return nil, "failed to connect to server"
            end
            assert.are.same({ nil, Errors.LIBRARY_UNREACHABLE }, { site:search("dune", 1) })
        end)

        it("says what it answered with, where it isn't a catalogue", function()
            web.pages[url] = "<html>Login</html>"
            assert.are.same({ nil, "unexpected response from Will's Books" }, { site:search("dune", 1) })
            web.pages[url] = function()
                return "<html>Oops</html>", nil, 500
            end
            assert.are.same({ nil, "Will's Books answered with an error (HTTP 500)" }, { site:search("dune", 1) })
        end)
    end)

    it("downloads a book from its entry's link, checking it's as big as the catalogue says", function()
        local url, err, mirror_failed, listed = calibreLibrary():findDownloadLink({
            title = "Emma",
            file_type = "epub",
            bytes = 494782,
            download_url = "http://127.0.0.1:8089/get/epub/2/Books",
        })
        assert.are.equal("http://127.0.0.1:8089/get/epub/2/Books", url)
        assert.is_nil(err)
        assert.is_nil(mirror_failed)
        assert.are.same({ bytes = 494782 }, listed)
    end)

    it("doesn't save its searches, as its books change", function()
        assert.is_false(calibreLibrary():isCached("emma", 1))
    end)

    describe("finding a library's catalogue", function()
        it("finds Calibre's at /opds on its site, with its search and libraries", function()
            web.pages["http://127.0.0.1:8089"] = "<!DOCTYPE html><html><title>calibre</title></html>"
            web.pages["http://127.0.0.1:8089/opds"] = CALIBRE_ROOT

            local found = OpdsSearch.discover("http://127.0.0.1:8089")
            assert.are.same({
                url = "http://127.0.0.1:8089/opds",
                name = "calibre Library",
                kind = OpdsSearch.CALIBRE,
                search_url = "http://127.0.0.1:8089/opds/search/{searchTerms}?library_id=Books",
                libraries = {
                    { name = "Books", url = "http://127.0.0.1:8089/opds?library_id=Books" },
                    { name = "Comics", url = "http://127.0.0.1:8089/opds?library_id=Comics" },
                },
            }, found)
        end)

        it("names Calibre's after its one library, where it has one", function()
            web.pages["http://127.0.0.1:8089/opds"] =
                CALIBRE_ROOT:gsub("<entry>%s*<title>Library: Comics.-</entry>", "")
            assert.are.equal("Books", OpdsSearch.discover("http://127.0.0.1:8089/opds").name)
        end)

        it("finds Calibre-Web's, by the search its feed gives", function()
            web.pages["http://nas:8083/opds"] = CALIBRE_WEB_ROOT
            local found = OpdsSearch.discover("http://nas:8083/opds")
            assert.are.equal(OpdsSearch.CALIBRE_WEB, found.kind)
            assert.are.equal("Will's Books", found.name)
            assert.are.equal("http://nas:8083/opds/search/{searchTerms}", found.search_url)
        end)

        it("finds a catalogue's search in its OpenSearch description, where its feed only links to that", function()
            web.pages["https://books.example/opds"] = '<feed xmlns="http://www.w3.org/2005/Atom"><title>Shelf</title>'
                .. '<link rel="search" href="search.xml" type="application/opensearchdescription+xml"/></feed>'
            web.pages["https://books.example/search.xml"] = "<OpenSearchDescription "
                .. 'xmlns="http://a9.com/-/spec/opensearch/1.1/">'
                .. '<Url type="text/html" template="/search?q={searchTerms}"/>'
                .. "<Url type='application/atom+xml;profile=opds-catalog' template='/opds/search?q={searchTerms}'/>"
                .. "</OpenSearchDescription>"
            local found = OpdsSearch.discover("https://books.example/opds")
            assert.are.equal(OpdsSearch.OPDS, found.kind)
            assert.are.equal("https://books.example/opds/search?q={searchTerms}", found.search_url)
        end)

        it("says when it needs logging in to", function()
            web.pages["http://nas:8083/opds"] = function()
                return "<html>Unauthorized</html>", nil, 401
            end
            assert.are.same({ nil, Errors.LIBRARY_LOGIN }, { OpdsSearch.discover("http://nas:8083/opds") })
        end)

        it("says when there's no catalogue there, or it can't be searched", function()
            web.pages["http://nas:8083"] = "<html>Welcome</html>"
            web.pages["http://nas:8083/opds"] = "<html>Not here</html>"
            assert.are.same(
                { nil, "there's no OPDS catalogue at that address" },
                { OpdsSearch.discover("http://nas:8083") }
            )

            web.pages["http://nas:8083/opds"] = '<feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>'
            assert.are.same(
                { nil, "the OPDS catalogue at that address can't be searched" },
                { OpdsSearch.discover("http://nas:8083/opds") }
            )
        end)

        it("says when the site can't be reached", function()
            assert.are.same({ nil, Errors.LIBRARY_UNREACHABLE }, { OpdsSearch.discover("http://nas:8083/opds") })
        end)
    end)
end)
