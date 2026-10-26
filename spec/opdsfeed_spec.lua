local helper = require("helper")

describe("OpdsFeed", function()
    local OpdsFeed

    before_each(function()
        helper.reset()
        OpdsFeed = require("util.opdsfeed")
    end)

    it("reads a feed's title, who wrote it, and its links, apart from its entries'", function()
        local feed = OpdsFeed.parse([[<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Will's Books</title>
  <author><name>Will's Books</name><uri>https://github.com/janeczku/calibre-web</uri></author>
  <link rel="next" href="/opds/new?offset=30"/>
  <entry><title>Emma</title><link rel="http://opds-spec.org/acquisition" href="/opds/download/2/epub/"/></entry>
</feed>]])
        assert.are.equal("Will's Books", feed.title)
        assert.are.equal("https://github.com/janeczku/calibre-web", feed.author_uri)
        assert.are.equal(1, #feed.links)
        assert.are.equal("next", feed.links[1].rel)
        assert.are.equal(1, #feed.entries)
    end)

    -- as the servers each write them their own way
    it("reads entries with prefixes before the names of things, quotes of either kind, and text in CDATA", function()
        local feed =
            OpdsFeed.parse([=[<atom:feed xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">
<atom:entry>
  <atom:title type="html"><![CDATA[Pride & Prejudice <i>(illustrated)</i>]]></atom:title>
  <atom:id>urn:uuid:1</atom:id>
  <atom:author><atom:name>Jane Austen</atom:name></atom:author>
  <atom:author><atom:name>Hugh Thomson</atom:name></atom:author>
  <dc:language>en</dc:language>
  <dc:issued>1813</dc:issued>
  <atom:link rel='http://opds-spec.org/acquisition' type='application/epub+zip' href='/b/1.epub?a=1&amp;b=2'
      length='561102'/>
</atom:entry>
</atom:feed>]=])
        local entry = feed.entries[1]
        assert.are.equal("Pride & Prejudice (illustrated)", entry.title)
        assert.are.equal("urn:uuid:1", entry.id)
        assert.are.same({ "Jane Austen", "Hugh Thomson" }, entry.authors)
        assert.are.same({ "en" }, entry.languages)
        assert.are.equal("1813", entry.issued)
        assert.are.same({
            rel = "http://opds-spec.org/acquisition",
            type = "application/epub+zip",
            href = "/b/1.epub?a=1&b=2",
            length = 561102,
        }, entry.links[1])
    end)

    it("takes a title escaped as HTML, or with an entity in it, as the text it is", function()
        local feed =
            OpdsFeed.parse('<feed><entry><title type="html">&lt;b&gt;Dune&lt;/b&gt; &#38; more</title></entry></feed>')
        assert.are.equal("Dune & more", feed.entries[1].title)
    end)

    it("leaves out what's in comments", function()
        local feed = OpdsFeed.parse(
            "<feed><!-- <entry><title>Hidden</title></entry> --><entry><title>Shown</title></entry></feed>"
        )
        assert.are.equal(1, #feed.entries)
        assert.are.equal("Shown", feed.entries[1].title)
    end)

    it("is nil for what isn't a feed", function()
        assert.is_nil(OpdsFeed.parse("<!DOCTYPE html><html><title>calibre</title></html>"))
        assert.is_nil(OpdsFeed.parse(nil))
    end)

    it("finds the search an OpenSearch description gives for results as a feed", function()
        assert.are.equal(
            "/opds/search?query={searchTerms}",
            OpdsFeed.searchTemplate([[<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
   <Url type="text/html" template="/opds/search/{searchTerms}"/>
   <Url type="application/atom+xml" template="/opds/search?query={searchTerms}"/>
</OpenSearchDescription>]])
        )
        assert.is_nil(OpdsFeed.searchTemplate('<OpenSearchDescription><Url type="text/html" template="/s"/>'))
    end)
end)

describe("LanguageCodes", function()
    local LanguageCodes, languages

    before_each(function()
        helper.reset()
        helper.state.data_dir = helper.tmpdir("data")
        LanguageCodes = require("util.languagecodes")
        languages = require("settings.settings"):getAvailableLanguages()
    end)

    after_each(helper.cleanup)

    it("finds a language by the codes and names sites give it", function()
        for _, value in ipairs({ "eng", "en", "en-GB", "English", " ENG " }) do
            assert.are.same({ text = "English", code = "en" }, LanguageCodes.find(value, languages), value)
        end
        assert.are.equal("German", LanguageCodes.find("ger", languages).text)
        assert.are.equal("German", LanguageCodes.find("deu", languages).text)
    end)

    it("doesn't find one the settings don't offer", function()
        assert.is_nil(LanguageCodes.find("xyz", languages))
        assert.is_nil(LanguageCodes.find(nil, languages))
    end)
end)
