local util = require("util")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches Project Gutenberg's free ebooks, which anyone can download, with its own catalogue's search (its OPDS
-- feed), and finds their files in the catalogue (see Sources)
local GutenbergSearch = {
    NAME = "Project Gutenberg",
    SOURCE = "gutenberg",
}

-- constants
local SOURCE = GutenbergSearch.SOURCE
local SITE = "https://www.gutenberg.org"
local RESULTS_PER_PAGE = 25
-- the files each file type a book can be downloaded as is in, as the catalogue lists them, the best first: an EPUB3
-- with its pictures, a MOBI as older Kindles read (rather than its KF8s, which KOReader can't open), and the text in
-- UTF-8. matched by the end of their addresses
local FILES = {
    epub = { "%.epub3%.images$", "%.epub%.images$", "%.epub%.noimages$" },
    mobi = { "%.kindle%.images$", "%.kindle%.noimages$" },
    txt = { "%.txt%.utf%-8$", "%.txt$" },
}

-- whether Project Gutenberg has books in any of the file types, which it doesn't for most (e.g. PDF)
function GutenbergSearch.hasFileTypes(file_types)
    for __, file_type in ipairs(file_types) do
        if FILES[file_type] then
            return true
        end
    end
    return false
end

-- the first of the file types Project Gutenberg has books in, which its books are taken to be in, as nearly all are
-- (those that aren't, such as its audiobooks, are said not to be once chosen, see findDownloadLink)
local function preferredFileType(file_types)
    for __, file_type in ipairs(file_types) do
        if FILES[file_type] then
            return file_type
        end
    end
end

-- the language a title says a book is in, as the catalogue adds after the titles of those not in English, e.g.
-- "Oliver Twist (German)", with the title without it, or English and the title as it is
local function titleLanguage(title)
    local name, said = title:match("^(.-)%s*%(([^()]+)%)$")
    if name then
        for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
            if language.text == said then
                return language, name
            end
        end
    end
    for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
        if language.code == "en" then
            return language, title
        end
    end
end

-- the search, as the address it's asked at: for the books with the words searched for in their titles or authors'
-- names, from the given page of results. in the one language chosen, where only one is, as the catalogue can't be
-- asked for several at once (and the books found are kept to those otherwise, see parseResults)
function GutenbergSearch.buildUrl(query, page, languages)
    local search = query
    if #languages == 1 and languages[1]:find("^%a%a%a?$") then
        search = search .. " l." .. languages[1]
    end
    local params = { "query=" .. util.urlEncode(search) }
    if page > 1 then
        table.insert(params, "start_index=" .. (page - 1) * RESULTS_PER_PAGE + 1)
    end
    return SITE .. "/ebooks/search.opds/?" .. table.concat(params, "&")
end

local function text(value)
    return value and StringUtil.trim(StringUtil.convertHtmlToText(value)) or ""
end

-- the books in the languages chosen, in the first of the file types chosen it has (see preferredFileType), the
-- number of books on the page (rather than the entries for authors it lists too, for a search that names one), and
-- whether there are more pages of them, from the catalogue's search feed. nil if it isn't that
function GutenbergSearch.parseResults(body, languages, file_types)
    if not body:find("<feed", 1, true) then
        return nil
    end
    local file_type = preferredFileType(file_types)
    local wanted = {}
    for __, code in ipairs(languages) do
        wanted[code] = true
    end

    local books, results = {}, 0
    for entry in body:gmatch("<entry>(.-)</entry>") do
        local id = tonumber(entry:match("<id>https?://www%.gutenberg%.org/ebooks/(%d+)%.opds</id>"))
        local title = text(entry:match("<title>(.-)</title>"))
        if id and title ~= "" then
            results = results + 1
            local language, name = titleLanguage(title)
            if language and wanted[language.code] and file_type then
                local authors = text(entry:match("<content[^>]*>(.-)</content>"))
                table.insert(books, {
                    source = SOURCE,
                    id = SOURCE .. "_" .. id,
                    gutenberg_id = id,
                    -- (or after the book's id, when there's nothing in its title to name its file after)
                    title = StringUtil.cleanFileName(name) ~= "" and StringUtil.cleanFileName(name)
                        or SOURCE .. "_" .. id,
                    display_title = StringUtil.cleanTitle(name),
                    authors = authors ~= "" and authors or "Unknown author",
                    language = language.text,
                    file_type = file_type,
                    image_url = string.format("%s/cache/epub/%d/pg%d.cover.medium.jpg", SITE, id, id),
                })
            end
        end
    end
    return books, results, body:find('rel="next"', 1, true) ~= nil
end

-- what went wrong when Project Gutenberg answered with body, or didn't answer
local function explainFailure(body, err, status)
    if body and status and status >= 400 then
        return T(_("%1 answered with an error (HTTP %2), try again later"), GutenbergSearch.NAME, status)
    end
    if body then
        return T(_("unexpected response from %1"), GutenbergSearch.NAME)
    end
    return T(_("%1 didn't answer (%2)"), GutenbergSearch.NAME, err)
end

-- whether there are results saved from an earlier search, which can be shown without an internet connection
function GutenbergSearch:isCached(query, page)
    return SearchCache:hasPage(self, query, page)
end

-- the books on a page of the catalogue's results, as search returns them
local function fetchResults(query, page, languages, file_types)
    if not GutenbergSearch.hasFileTypes(file_types) then
        LogUtil.warn(GutenbergSearch.NAME, "has none of the file types chosen")
        return nil, Errors.NO_FILE_TYPES
    end

    local body, err, status = HttpUtil.getBody(GutenbergSearch.buildUrl(query, page, languages))
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    local books, results, more
    if body and not (status and status >= 400) then
        books, results, more = GutenbergSearch.parseResults(body, languages, file_types)
    end
    if not books then
        if body then
            LogUtil.warn(
                "unexpected search results from",
                GutenbergSearch.NAME .. ": HTTP",
                status,
                #body,
                "bytes:",
                LogUtil.excerpt(body)
            )
        end
        return nil, explainFailure(body, err, status)
    end

    local next_page = more and page + 1 or nil
    LogUtil.info(
        string.format(
            "page %d of %s's results: kept %d of its %d%s",
            page,
            GutenbergSearch.NAME,
            #books,
            results,
            next_page and "" or ", the last"
        )
    )
    return books, nil, next_page, results
end

-- search the given page of Project Gutenberg's results, returning the books found, the page to carry on from (or nil
-- once there are no more results), and how many results were read to find them (as LlgiSearch:search does). it can't
-- be narrowed down to the books' titles or authors, so searches both
function GutenbergSearch:search(query, page)
    return SearchCache:search(self, query, page, nil, function(languages, file_types)
        return fetchResults(query, page, languages, file_types)
    end)
end

-- the address of the best of the book's files in its file type (see FILES), from its entry in the catalogue, which
-- lists them with how many bytes each is, or nil when it isn't in that file type
function GutenbergSearch.findFile(body, file_type)
    local files = {}
    for link in body:gmatch("<link [^>]*>") do
        if link:find('rel="http://opds%-spec%.org/acquisition"') then
            local href = link:match('href="([^"]+)"')
            if href then
                table.insert(files, { url = href, bytes = tonumber(link:match('length="(%d+)"')) })
            end
        end
    end
    for __, pattern in ipairs(FILES[file_type] or {}) do
        for __, file in ipairs(files) do
            if file.url:find(pattern) and StringUtil.isSafeUrl(file.url) then
                return file.url, file.bytes
            end
        end
    end
end

-- the book's download link, from its entry in the catalogue, then nil, nil and how many bytes the catalogue lists the
-- file as (which what arrives is checked against). otherwise nil, and why not (HttpUtil.CANCELLED when called off),
-- e.g. that it isn't in the book's file type, as Project Gutenberg's audiobooks aren't in any
function GutenbergSearch.findDownloadLink(book)
    local body, err, status = HttpUtil.getBody(string.format("%s/ebooks/%d.opds", SITE, book.gutenberg_id))
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    if not body or (status and status >= 400) then
        return nil, explainFailure(body, err, status)
    end
    local url, bytes = GutenbergSearch.findFile(body, book.file_type)
    if not url then
        LogUtil.warn(GutenbergSearch.NAME, "lists no", book.file_type, "file for", book.gutenberg_id)
        return nil, T(_("%1 doesn't have this book as %2"), GutenbergSearch.NAME, book.file_type:upper())
    end
    return url, nil, nil, { bytes = bytes }
end

return GutenbergSearch
