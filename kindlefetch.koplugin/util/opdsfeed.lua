local StringUtil = require("util.stringutil")

-- reads an OPDS catalogue's Atom feed, e.g. Calibre's or Calibre-Web's, however it's written (prefixes, quotes, CDATA)
local OpdsFeed = {}

-- text as it's shown, from what's between an element's tags, which can be escaped HTML, or have tags of its own
local function text(value)
    if not value then
        return nil
    end
    value = value:gsub("<[^>]*>", "")
    value = StringUtil.convertHtmlToText(value):gsub("<[^>]*>", "")
    value = StringUtil.trim(StringUtil.collapseWhitespace(value))
    return value ~= "" and value or nil
end

-- the pattern that finds what's between the tags of an element named name (and not one whose name only starts with it)
local function elementPattern(name)
    return "<" .. name .. "%f[%s>][^>]*>(.-)</" .. name .. ">"
end

-- what's between the tags of the first of the elements named name in xml, or nil where there's none
local function element(xml, name)
    return xml:match(elementPattern(name))
end

-- what's between the tags of each of the elements named name in xml
local function elements(xml, name)
    local found = {}
    for value in xml:gmatch(elementPattern(name)) do
        table.insert(found, value)
    end
    return found
end

-- the attributes of a tag, by their names (in small letters, without their prefixes), as text
local function attributes(tag)
    local found = {}
    for name, __, value in tag:gmatch("([%w_.:-]+)%s*=%s*([\"'])(.-)%2") do
        found[(name:gsub("^.*:", "")):lower()] = StringUtil.convertHtmlToText(value)
    end
    return found
end

-- the links in xml, each its rel, href, type and title, and how many bytes what it links to is (its length)
local function links(xml)
    local found = {}
    for tag in xml:gmatch("<link%s[^>]*>") do
        local attrs = attributes(tag)
        if attrs.href then
            table.insert(found, {
                rel = attrs.rel,
                href = StringUtil.trim(attrs.href),
                type = attrs.type and attrs.type:lower(),
                title = attrs.title,
                length = tonumber(attrs.length),
            })
        end
    end
    return found
end

-- the feed in body, or nil if not one; an entry's published is when Calibre added it, but Calibre-Web's when published
function OpdsFeed.parse(body)
    if type(body) ~= "string" then
        return nil
    end
    -- without comments, CDATA (its text escaped instead) or prefixes before names (as in atom:entry or dc:language)
    body = body:gsub("<!%-%-.-%-%->", "")
    body = body:gsub("<!%[CDATA%[(.-)%]%]>", function(cdata)
        return (cdata:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
    end)
    body = body:gsub("<(/?)[%w_.-]+:([%w_.-]+)", "<%1%2")
    if not body:find("<feed[%s>]") then
        return nil
    end

    local feed = { entries = {} }
    -- the feed's own, without its entries'
    local head = body:gsub("<entry%f[%s>].-</entry>", "")
    feed.title = text(element(head, "title"))
    local author = element(head, "author")
    feed.author_uri = author and text(element(author, "uri"))
    feed.links = links(head)

    for entry_xml in body:gmatch("<entry%f[%s>].-</entry>") do
        local entry = {
            id = text(element(entry_xml, "id")),
            title = text(element(entry_xml, "title")),
            authors = {},
            languages = {},
            issued = text(element(entry_xml, "issued") or element(entry_xml, "date")),
            published = text(element(entry_xml, "published")),
            links = links(entry_xml),
        }
        for __, author_xml in ipairs(elements(entry_xml, "author")) do
            local name = text(element(author_xml, "name"))
            if name then
                table.insert(entry.authors, name)
            end
        end
        for __, language in ipairs(elements(entry_xml, "language")) do
            table.insert(entry.languages, text(language))
        end
        table.insert(feed.entries, entry)
    end
    return feed
end

-- the search template for Atom results that an OpenSearch description in body gives, or nil where it has none
function OpdsFeed.searchTemplate(body)
    if type(body) ~= "string" then
        return nil
    end
    body = body:gsub("<(/?)[%w_.-]+:([%w_.-]+)", "<%1%2")
    for tag in body:gmatch("<Url%s[^>]*>") do
        local attrs = attributes(tag)
        if attrs.template and attrs.type and attrs.type:lower():find("application/atom+xml", 1, true) then
            return StringUtil.trim(attrs.template)
        end
    end
end

return OpdsFeed
