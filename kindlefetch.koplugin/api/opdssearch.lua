local util = require("util")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local CurlUtil = require("util.curlutil")
local OpdsFeed = require("util.opdsfeed")
local LanguageCodes = require("util.languagecodes")
local KindleFetchSettings = require("settings.settings")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches the OPDS catalogue of a library the user has added (see Libraries) with its own search, and finds its files
local OpdsSearch = {}
OpdsSearch.__index = OpdsSearch

-- the kinds of catalogue, each searched its own way (see kindOf): Calibre's, Calibre-Web's (Automated's too), others
OpdsSearch.CALIBRE = "calibre"
OpdsSearch.CALIBRE_WEB = "calibre-web"
OpdsSearch.OPDS = "opds"

-- constants: the file types of the files a catalogue links to, by their MIME types, as KOReader opens them
local MIME_TYPES = {
    ["application/epub+zip"] = "epub",
    ["application/epub"] = "epub",
    ["application/x-mobipocket-ebook"] = "mobi",
    -- (and an AZW3, which KOReader opens saved as an AZW, see FILE_TYPE_NAMES)
    ["application/x-mobi8-ebook"] = "azw",
    ["application/vnd.amazon.mobi8-ebook"] = "azw",
    ["application/vnd.amazon.ebook"] = "azw",
    ["application/pdf"] = "pdf",
    ["application/x-fictionbook+xml"] = "fb2",
    ["application/fb2"] = "fb2",
    ["text/fb2+xml"] = "fb2",
    ["application/x-cbz"] = "cbz",
    ["application/vnd.comicbook+zip"] = "cbz",
    ["application/x-cbr"] = "cbr",
    ["application/vnd.comicbook-rar"] = "cbr",
    ["text/plain"] = "txt",
    ["application/rtf"] = "rtf",
    ["text/rtf"] = "rtf",
    ["application/msword"] = "doc",
    ["application/vnd.openxmlformats-officedocument.wordprocessingml.document"] = "docx",
    ["application/vnd.oasis.opendocument.text"] = "odt",
    ["image/vnd.djvu"] = "djvu",
    ["image/x-djvu"] = "djvu",
    ["application/vnd.ms-htmlhelp"] = "chm",
    ["application/x-chm"] = "chm",
    ["text/html"] = "html",
    ["application/html+zip"] = "htmlz",
    ["application/vnd.palm"] = "pdb",
    ["application/x-palm-database"] = "pdb",
}
-- the settings' file types for formats Calibre names otherwise: an AZW3 (KF8), which KOReader opens saved as an AZW
local FILE_TYPE_NAMES = { azw3 = "azw" }
-- and the formats each of those file types is to Calibre, for searching for books in them (see calibreSearch)
local CALIBRE_FORMATS = { azw = { "AZW", "AZW3" } }
-- what a link to a book's file is (rather than to buying or borrowing it, which can't be done here)
local ACQUISITIONS = {
    ["http://opds-spec.org/acquisition"] = true,
    ["http://opds-spec.org/acquisition/open-access"] = true,
}
-- what a link to a book's cover is, the thumbnail and the cover itself, as the specification and others say
local THUMBNAILS = {
    ["http://opds-spec.org/image/thumbnail"] = true,
    ["http://opds-spec.org/thumbnail"] = true,
    ["x-stanza-cover-image-thumbnail"] = true,
}
local IMAGES = {
    ["http://opds-spec.org/image"] = true,
    ["http://opds-spec.org/cover"] = true,
    ["x-stanza-cover-image"] = true,
}
-- how big a thumbnail to ask Calibre's content server for (whose own are 60 by 80), for the covers in the results
local CALIBRE_THUMBNAIL_SIZE = "200x300"

-- a library's site as source, from its name, url, kind and search_url (see discover); only Calibre's can be narrowed
function OpdsSearch.new(source, library)
    local site = setmetatable({
        NAME = library.name,
        SOURCE = source,
        SCOPES = library.kind == OpdsSearch.CALIBRE and { "title", "author", "isbn" } or nil,
        library = library,
        -- the addresses of later pages of results, by search (see searchKey), as each page links to the next
        next_urls = {},
    }, OpdsSearch)
    -- which is called by itself (see Downloader), rather than as the site's
    site.findDownloadLink = function(book)
        return site:downloadLink(book)
    end
    return site
end

-- what kind of catalogue a feed is from (see CALIBRE), by who it says wrote it
function OpdsSearch.kindOf(feed)
    local uri = (feed.author_uri or ""):lower()
    if uri:find("calibre-ebook.com", 1, true) then
        return OpdsSearch.CALIBRE
    elseif uri:find("calibre-web", 1, true) then
        return OpdsSearch.CALIBRE_WEB
    end
    return OpdsSearch.OPDS
end

-- a word as Calibre's search takes it, in quotes, as it is (rather than e.g. "1984:" searching a field of that name)
local function calibreQuoted(word)
    return '"' .. word:gsub('[\\"]', "\\%0") .. '"'
end

-- the Calibre search for query, narrowed to scope, in the file types and languages chosen (or unknown), or nil
function OpdsSearch.calibreSearch(query, scope, languages, file_types)
    local search
    if scope == "isbn" then
        local isbn = query:upper():gsub("[^%dX]", "")
        if isbn == "" then
            return nil
        end
        search = string.format('identifiers:"=isbn:%s"', isbn)
    else
        local field = ({ title = "title:", author = "authors:" })[scope] or ""
        local terms = {}
        for word in query:gmatch("%S+") do
            table.insert(terms, field .. calibreQuoted(word))
        end
        if #terms == 0 then
            return nil
        end
        search = table.concat(terms, " and ")
    end
    local clauses = { "(" .. search .. ")" }

    local formats = {}
    for __, file_type in ipairs(file_types) do
        for __, format in ipairs(CALIBRE_FORMATS[file_type] or { file_type:upper() }) do
            table.insert(formats, string.format('formats:"=%s"', format))
        end
    end
    table.insert(clauses, "(" .. table.concat(formats, " or ") .. ")")
    if #languages < #KindleFetchSettings:getAvailableLanguages() then
        local terms = {}
        for __, code in ipairs(languages) do
            for __, marc_code in ipairs(LanguageCodes.CODES[code] or {}) do
                table.insert(terms, string.format('languages:"=%s"', marc_code))
            end
        end
        table.insert(terms, "languages:false")
        table.insert(clauses, "(" .. table.concat(terms, " or ") .. ")")
    end
    return table.concat(clauses, " and ")
end

-- the search's address from its OpenSearch template: the words and first page filled in, the rest left empty, or nil
function OpdsSearch:searchUrl(query, scope, languages, file_types)
    local terms
    if self.library.kind == OpdsSearch.CALIBRE then
        terms = OpdsSearch.calibreSearch(query, scope, languages, file_types)
    else
        terms = StringUtil.trim(query)
    end
    if not terms or terms == "" then
        return nil
    end
    return (
        self.library.search_url:gsub("{([^}]*)}", function(param)
            local optional = param:find("%?$") ~= nil
            local name = param:gsub("%?$", ""):gsub("^.*:", "")
            if name == "searchTerms" then
                return util.urlEncode(terms)
            elseif (name == "startPage" or name == "startIndex") and not optional then
                return "1"
            end
            return ""
        end)
    )
end

-- the file type of a file a link's title says it is, as Calibre-Web's say, e.g. "EPUB", where its MIME type doesn't
local function titleFileType(title)
    local file_type = type(title) == "string" and title:lower():match("^%s*(%w+)%s*$")
    file_type = FILE_TYPE_NAMES[file_type] or file_type
    for __, known in ipairs(KindleFetchSettings:getPreferredFileTypes()) do
        if known == file_type then
            return file_type
        end
    end
end

-- how big a file of this many bytes is, as the sites say it (see BookFilter), e.g. "752 kB" or "2.1 MB"
local function formatSize(bytes)
    if not bytes or bytes <= 0 then
        return nil
    end
    if bytes < 1024 * 1024 then
        return string.format("%d kB", math.max(1, math.floor(bytes / 1024 + 0.5)))
    end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

-- the year a book was published: its issued date, or published date (not Calibre's, which is when it was added)
local function yearOf(kind, entry)
    local date = entry.issued or (kind ~= OpdsSearch.CALIBRE and entry.published) or ""
    local year = tonumber(date:match("^(%d%d%d%d)"))
    -- (rather than the year 101, as Calibre-Web says when it isn't known)
    return year and year >= 1000 and tostring(year) or nil
end

-- the book in a feed entry, in the first file type chosen it's in and a language wanted, where it says, or nil
function OpdsSearch:parseBook(entry, base_url, wanted, file_types)
    local files, thumbnail, image = {}, nil, nil
    for __, link in ipairs(entry.links) do
        local url = StringUtil.absoluteUrl(base_url, link.href)
        if url and StringUtil.isSafeUrl(url) then
            if ACQUISITIONS[link.rel] then
                local file_type = MIME_TYPES[(link.type or ""):match("^[^;%s]+") or ""] or titleFileType(link.title)
                if file_type and not files[file_type] then
                    files[file_type] = { url = url, bytes = link.length }
                end
            elseif THUMBNAILS[link.rel] then
                thumbnail = thumbnail or url
            elseif IMAGES[link.rel] then
                image = image or url
            end
        end
    end
    local file_type
    for __, chosen in ipairs(file_types) do
        if files[chosen] then
            file_type = chosen
            break
        end
    end
    if not (file_type and entry.title) then
        return nil
    end

    -- leaving out a book only in other languages, where it says (Calibre's search does so, see calibreSearch)
    local languages, seen, in_chosen = {}, {}, false
    for __, value in ipairs(entry.languages) do
        local language = LanguageCodes.find(value)
        if language and not seen[language.text] then
            seen[language.text] = true
            table.insert(languages, language.text)
            in_chosen = in_chosen or wanted[language.code] == true
        end
    end
    if #languages > 0 and not in_chosen then
        return nil
    end

    local kind = self.library.kind
    -- Calibre gives the authors' names as one, e.g. "Terry Pratchett & Neil Gaiman"
    local authors = table.concat(entry.authors, ", ")
    if kind == OpdsSearch.CALIBRE then
        authors = authors:gsub(" & ", ", ")
    end
    if thumbnail and kind == OpdsSearch.CALIBRE and thumbnail:find("/get/thumb/", 1, true) then
        thumbnail = thumbnail .. (thumbnail:find("?", 1, true) and "&" or "?") .. "sz=" .. CALIBRE_THUMBNAIL_SIZE
    end
    local file = files[file_type]
    -- named after its entry's id, as its cover is (see CoverCache), or its file's address, where it has none
    local id = (entry.id or file.url):gsub("[^%w%-]", "_"):sub(1, 100)
    local title = StringUtil.cleanFileName(entry.title)
    return {
        source = self.SOURCE,
        id = self.SOURCE .. "_" .. id,
        title = title ~= "" and title or self.SOURCE .. "_" .. id,
        display_title = StringUtil.cleanTitle(entry.title),
        authors = authors ~= "" and authors or "Unknown author",
        year = yearOf(kind, entry),
        language = #languages > 0 and table.concat(languages, ", ") or nil,
        file_type = file_type,
        file_size = formatSize(file.bytes),
        bytes = file.bytes,
        download_url = file.url,
        image_url = thumbnail or image,
        full_image_url = image,
    }
end

-- the feed's books in the file types and languages chosen, its number of entries and next page's address, or nil
function OpdsSearch:parseResults(body, url, languages, file_types)
    local feed = OpdsFeed.parse(body)
    if not feed then
        return nil
    end
    local wanted = {}
    for __, code in ipairs(languages) do
        wanted[code] = true
    end
    local books = {}
    for __, entry in ipairs(feed.entries) do
        local book = self:parseBook(entry, url, wanted, file_types)
        if book then
            table.insert(books, book)
        end
    end
    local next_url
    for __, link in ipairs(feed.links) do
        if link.rel == "next" and not next_url then
            next_url = StringUtil.absoluteUrl(url, link.href)
        end
    end
    return books, #feed.entries, StringUtil.isSafeUrl(next_url) and next_url or nil
end

-- whether curl's err means the library's site couldn't be reached at all, as when the device isn't on its network
local function isUnreachable(err)
    for __, exit_code in ipairs({ 6, 7, 28 }) do
        if err == CurlUtil.getErrorMeaning(exit_code) then
            return true
        end
    end
    return false
end

-- what went wrong when the library answered with body, or didn't answer (err)
local function explainFailure(name, body, err, status)
    if status == 401 then
        return Errors.LIBRARY_LOGIN
    elseif status == 403 and body and body:find("Too many login attempts", 1, true) then
        -- as Calibre's content server says, once it's set up to
        return Errors.LIBRARY_LOCKED_OUT
    elseif body and status and status >= 400 then
        return T(_("%1 answered with an error (HTTP %2)"), name, status)
    elseif body then
        return T(_("unexpected response from %1"), name)
    elseif isUnreachable(err) then
        return Errors.LIBRARY_UNREACHABLE
    end
    return T(_("%1 didn't answer (%2)"), name, err)
end

-- library searches aren't saved, as a library's books change, and they can only be downloaded once connected anyway
function OpdsSearch:isCached()
    return false
end

-- what's searched for, for the address of the page after (see next_urls in new)
local function searchKey(query, scope, page)
    return table.concat({ query, scope or "", tostring(page) }, "\n")
end

-- search a page of the library's results, narrowed down by scope where given, as LibgenSearch:search does
function OpdsSearch:search(query, page, scope)
    local languages = KindleFetchSettings:getPreferredLanguages()
    local file_types = KindleFetchSettings:getPreferredFileTypes()
    LogUtil.info(
        string.format(
            "searching %s for %q%s from page %d, in %s, as %s",
            self.NAME,
            query,
            scope and " by " .. scope or "",
            page,
            table.concat(languages, "/"),
            table.concat(file_types, "/")
        )
    )
    local url
    if page == 1 then
        url = self:searchUrl(query, scope, languages, file_types)
        if not url then
            return {}, nil, nil, 0
        end
    else
        url = self.next_urls[searchKey(query, scope, page)]
        if not url then
            LogUtil.warn("there's no address for page", page, "of", self.NAME .. "'s results")
            return nil, Errors.UNEXPECTED
        end
    end

    local body, err, status = HttpUtil.getBody(url)
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    -- which Calibre's content server answers a search that finds nothing with, as it does one it can't make sense of
    if status == 404 and self.library.kind == OpdsSearch.CALIBRE then
        LogUtil.info(string.format("%s found no books for %q", self.NAME, query))
        return {}, nil, nil, 0
    end
    local books, results, next_url
    if body and not (status and status >= 400) then
        books, results, next_url = self:parseResults(body, url, languages, file_types)
    end
    if not books then
        if body then
            LogUtil.warn(
                "unexpected search results from",
                self.NAME .. ": HTTP",
                status,
                #body,
                "bytes:",
                LogUtil.excerpt(body)
            )
        end
        return nil, explainFailure(self.NAME, body, err, status)
    end

    local next_page
    if next_url then
        next_page = page + 1
        self.next_urls[searchKey(query, scope, next_page)] = next_url
    end
    LogUtil.info(
        string.format(
            "page %d of %s's results: kept %d of its %d%s",
            page,
            self.NAME,
            #books,
            results,
            next_page and "" or ", the last"
        )
    )
    return books, nil, next_page, results
end

-- the book's download link from its catalogue entry, then nil, nil and its listed size, as Sites says
function OpdsSearch:downloadLink(book)
    if not StringUtil.isSafeUrl(book.download_url) then
        return nil, T(_("%1 doesn't have this book as %2"), self.NAME, tostring(book.file_type):upper())
    end
    LogUtil.info(
        string.format(
            "downloading %q's %s file from %s, %s bytes",
            book.title,
            book.file_type,
            self.NAME,
            tostring(book.bytes or "unknown")
        )
    )
    return book.download_url, nil, nil, { bytes = book.bytes }
end

-- the feed at url, or nil and why not where known (a login needed, or no answer), or nil alone for e.g. a web page
local function fetchFeed(url)
    local body, err, status = HttpUtil.getBody(url)
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    if status == 401 or status == 403 then
        return nil, explainFailure(_("The library"), body, err, status)
    end
    if not body then
        return nil, explainFailure(LogUtil.site(url), body, err, status)
    end
    local feed = not (status and status >= 400) and OpdsFeed.parse(body)
    if not feed then
        LogUtil.info(LogUtil.site(url), "answered with something other than an OPDS catalogue: HTTP", status)
        return nil
    end
    return feed
end

-- the catalogue's search address: the template its feed gives, or failing that, its OpenSearch description's, or nil
local function findSearch(feed, url)
    for __, link in ipairs(feed.links) do
        if
            link.rel == "search"
            and link.href:find("{searchTerms}", 1, true)
            and (link.type or ""):find("application/atom+xml", 1, true)
        then
            return StringUtil.absoluteUrl(url, link.href)
        end
    end
    for __, link in ipairs(feed.links) do
        if link.rel == "search" and (link.type or ""):find("opensearchdescription", 1, true) then
            local description_url = StringUtil.absoluteUrl(url, link.href)
            local body = description_url and HttpUtil.getBody(description_url)
            local template = OpdsFeed.searchTemplate(body)
            if template then
                return StringUtil.absoluteUrl(description_url, template)
            end
        end
    end
end

-- the catalogue at url (or its /opds) as it's searched, or nil and why not, logging in as LibrarySites says
function OpdsSearch.discover(url)
    local feed, err = fetchFeed(url)
    if not feed and not err and not url:find("/opds", 1, true) then
        url = url:gsub("/*$", "") .. "/opds"
        feed, err = fetchFeed(url)
    end
    if not feed then
        return nil, err or _("there's no OPDS catalogue at that address")
    end
    local search_url = findSearch(feed, url)
    if not search_url or not StringUtil.isSafeUrl((search_url:gsub("[{}]", ""))) then
        return nil, _("the OPDS catalogue at that address can't be searched")
    end

    local kind = OpdsSearch.kindOf(feed)
    local found = {
        url = url,
        name = feed.title or LogUtil.site(url),
        kind = kind,
        search_url = search_url,
        libraries = {},
    }
    -- each library Calibre's content server lists, even when there's only one, by the name it's given there
    if kind == OpdsSearch.CALIBRE then
        for __, entry in ipairs(feed.entries) do
            local library_id = entry.id and entry.id:match("^calibre%-library:(.+)$")
            local library_url = entry.links[1] and StringUtil.absoluteUrl(url, entry.links[1].href)
            if library_id and StringUtil.isSafeUrl(library_url) then
                table.insert(found.libraries, {
                    name = entry.title and entry.title:match(":%s*(.-)%s*$") or library_id,
                    url = library_url,
                })
            end
        end
        if #found.libraries == 1 then
            found.name = found.libraries[1].name
        end
    end
    LogUtil.info(
        string.format(
            "found %s's %s catalogue at %s, searched at %s",
            found.name,
            kind,
            LogUtil.site(url),
            LogUtil.site(search_url)
        )
    )
    return found
end

return OpdsSearch
