local util = require("util")
local JSON = require("json")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local Site = require("api.site")
local Book = require("api.book")
local LanguageCodes = require("util.languagecodes")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches the books on Internet Archive that anyone can download, rather than only borrow, and finds their files
local IaSearch = Site:extend {
    NAME = "Internet Archive",
    SOURCE = "archive",
}

-- constants
local SOURCE = IaSearch.SOURCE
local SITE = "https://archive.org"
local RESULTS_PER_PAGE = 50
-- Internet Archive's formats for each file type, best first, matched exactly, as a search for DjVu also finds Djvu XML
local FORMATS = {
    epub = { "EPUB" },
    mobi = { "MOBI" },
    pdf = { "Text PDF", "Image Container PDF" },
    djvu = { "DjVu" },
    txt = { "Text", "DjVuTXT" },
    cbz = { "Comic Book ZIP" },
    cbr = { "Comic Book RAR" },
}
-- Internet Archive's codes for each language the settings offer (see LanguageCodes), as it has most books' languages
local LANGUAGE_CODES = LanguageCodes.CODES

-- what Internet Archive calls the languages with these codes in the settings, or nil when every language is chosen
local function languageTerms(codes)
    if #codes >= #KindleFetchSettings:getAvailableLanguages() then
        return nil
    end
    local terms, seen = {}, {}
    local function add(term)
        if not seen[term:lower()] then
            seen[term:lower()] = true
            table.insert(terms, term)
        end
    end
    for __, code in ipairs(codes) do
        for __, marc_code in ipairs(LANGUAGE_CODES[code] or {}) do
            add(marc_code)
        end
        for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
            if language.code == code then
                add(language.text)
            end
        end
        add(code)
    end
    return terms
end

-- Internet Archive's names for the formats the file types can be in, for searching for books in them
local function formatTerms(file_types)
    local terms = {}
    for __, file_type in ipairs(file_types) do
        for __, format in ipairs(FORMATS[file_type] or {}) do
            table.insert(terms, format)
        end
    end
    return terms
end

-- a term to search for exactly, rather than Internet Archive reading some of its characters as more than they are
local function quote(term)
    return '"' .. term:gsub('[\\"]', "\\%0") .. '"'
end

-- what a search can be narrowed to (see Site): only the books' titles, the names of their authors, or their ISBNs
IaSearch.SCOPES = { "title", "author", "isbn" }
local SCOPE_FIELDS = {
    title = "title",
    author = "creator",
}

-- each word in the title or author (or the one narrowed to), as searching all finds too much; ISBNs without hyphens
local function wordClauses(query, scope)
    if scope == "isbn" then
        local isbn = query:upper():gsub("[^%dX]", "")
        return isbn ~= "" and { "isbn:" .. quote(isbn) } or {}
    end
    local clauses = {}
    for word in query:gmatch("%S+") do
        -- leaving out what's only punctuation, as there's nothing in it to find
        if word:find("[%w\128-\255]") then
            local field = SCOPE_FIELDS[scope]
            table.insert(
                clauses,
                field and string.format("%s:%s", field, quote(word))
                    or string.format("(title:%s OR creator:%s)", quote(word), quote(word))
            )
        end
    end
    return clauses
end

local function orTerms(terms)
    local quoted = {}
    for __, term in ipairs(terms) do
        table.insert(quoted, quote(term))
    end
    return "(" .. table.concat(quoted, " OR ") .. ")"
end

-- the search among the books anyone can download (most are only lent), or nil if there's nothing in the query to find
function IaSearch.buildQuery(query, languages, file_types, scope)
    local clauses = wordClauses(query, scope)
    if #clauses == 0 then
        return nil
    end
    table.insert(clauses, "mediatype:texts")
    table.insert(clauses, "NOT access-restricted-item:true")
    table.insert(clauses, "format:" .. orTerms(formatTerms(file_types)))
    local language_terms = languageTerms(languages)
    if language_terms then
        -- or books whose language isn't known
        table.insert(
            clauses,
            string.format("(language:%s OR (mediatype:texts AND NOT language:[* TO *]))", orTerms(language_terms))
        )
    end
    return table.concat(clauses, " AND ")
end

-- the page of results, most downloaded first, as most of what Internet Archive has are scans of books few have read
function IaSearch.buildParams(search, page)
    local params = { "q=" .. util.urlEncode(search) }
    for __, field in ipairs({ "identifier", "title", "creator", "year", "language", "format" }) do
        table.insert(params, "fl%5B%5D=" .. field)
    end
    table.insert(params, "sort%5B%5D=downloads%20desc")
    table.insert(params, "rows=" .. RESULTS_PER_PAGE)
    table.insert(params, "page=" .. tostring(page))
    table.insert(params, "output=json")
    return table.concat(params, "&")
end

-- the values of a book's field, which can be one or a list, as text, leaving out anything else, e.g. JSON's null
local function values(field)
    local list = {}
    for __, value in ipairs(type(field) == "table" and field or { field }) do
        if type(value) == "number" then
            value = tostring(value)
        end
        if type(value) == "string" then
            value = StringUtil.trim(StringUtil.collapseWhitespace(StringUtil.convertHtmlToText(value)))
            if value ~= "" then
                table.insert(list, value)
            end
        end
    end
    return list
end

-- the first of the file types that the formats include one of, i.e. the one most preferred
local function preferredFileType(formats, file_types)
    local has = {}
    for __, format in ipairs(formats) do
        has[format:lower()] = true
    end
    for __, file_type in ipairs(file_types) do
        for __, format in ipairs(FORMATS[file_type] or {}) do
            if has[format:lower()] then
                return file_type
            end
        end
    end
end

-- what the people who made a book did, which a library writes after their names
local ROLES = {
    author = true,
    ["joint author"] = true,
    editor = true,
    ed = true,
    illustrator = true,
    ill = true,
    translator = true,
    tr = true,
    trans = true,
    contributor = true,
    compiler = true,
    comp = true,
}

-- the names of a book's authors, from its creators as a library writes them (surname first, with dates and roles)
local function authorNames(field)
    local names, seen = {}, {}
    for __, creator in ipairs(values(field)) do
        for name in creator:gmatch("[^;]+") do
            name = StringUtil.trim(StringUtil.collapseWhitespace(StringUtil.removeParentheses(name)))
            -- leaving out when they lived and what they did
            while true do
                local rest, last = name:match("^(.-),%s*([^,]*)$")
                if not (rest and (last:find("%d") or ROLES[last:lower():gsub("%.$", "")])) then
                    break
                end
                name = rest
            end
            -- with their surname last
            local surname, forenames = name:match("^([^,]+),%s*([^,]+)$")
            if surname then
                name = StringUtil.trim(forenames) .. " " .. StringUtil.trim(surname)
            end
            if name ~= "" and not seen[name] then
                seen[name] = true
                table.insert(names, name)
            end
        end
    end
    return table.concat(names, ", ")
end

-- the names of the languages Internet Archive says a book is in, e.g. "eng" or "ger;lat"
local function languageName(field)
    local names, seen = {}, {}
    for __, value in ipairs(values(field)) do
        for part in value:gmatch("[^;,/]+") do
            part = StringUtil.trim(part)
            local name = LanguageCodes.names()[part:lower()] or part
            if part ~= "" and not seen[name] then
                seen[name] = true
                table.insert(names, name)
            end
        end
    end
    return #names > 0 and table.concat(names, ", ") or nil
end

local function parseBook(doc, file_types)
    if type(doc) ~= "table" then
        return nil
    end
    local identifier = values(doc.identifier)[1]
    local title = values(doc.title)[1]
    -- its address is made from its identifier, which is only ever letters, digits, dots, dashes and underscores
    if not (identifier and identifier:find("^[%w%._%-]+$") and title) then
        LogUtil.warn("skipped a book without an identifier or a title")
        return nil
    end
    local file_type = preferredFileType(values(doc.format), file_types)
    if not file_type then
        LogUtil.debug("skipped", identifier, "as it isn't in a preferred format")
        return nil
    end

    local year = (values(doc.year)[1] or ""):match("^%d%d%d%d$")
    -- (named after its identifier where there's nothing in its title to name its file after)
    return Book.new(SOURCE, {
        id = SOURCE .. "_" .. identifier,
        identifier = identifier,
        title = title,
        authors = authorNames(doc.creator),
        year = year ~= "0000" and year or nil,
        language = languageName(doc.language),
        file_type = file_type,
        image_url = string.format("%s/services/img/%s", SITE, identifier),
    }, identifier)
end

-- the books in the preferred file types, the number of results on the page and in all, from the search's JSON, or nil
function IaSearch.parseResults(body, file_types)
    local ok, data = pcall(JSON.decode, body)
    local response = ok and type(data) == "table" and data.response
    if type(response) ~= "table" or type(response.docs) ~= "table" then
        return nil
    end

    local books = {}
    for __, doc in ipairs(response.docs) do
        local book = parseBook(doc, file_types)
        if book then
            table.insert(books, book)
            LogUtil.debug("new book found", book)
        end
    end
    return books, #response.docs, tonumber(response.numFound) or 0
end

-- the search's address, or nil where there's nothing in the query to find, or nil and why not
function IaSearch:searchUrl(search)
    if #formatTerms(search.file_types) == 0 then
        LogUtil.warn(self.NAME, "has none of the file types chosen")
        return nil, Errors.NO_FILE_TYPES
    end
    local terms = IaSearch.buildQuery(search.query, search.languages, search.file_types, search.scope)
    return terms and SITE .. "/advancedsearch.php?" .. IaSearch.buildParams(terms, search.page)
end

-- the books on a page of results, how many it had, the page after (or nil) and how many in all, or nil if it isn't one
function IaSearch:parsePage(body, __, search)
    local books, results, total = IaSearch.parseResults(body, search.file_types)
    if not books then
        return nil
    end
    return books, results, search.page * RESULTS_PER_PAGE < total and search.page + 1 or nil, total
end

-- a file's path in a book's folder, for its address: each folder's name and the file's name escaped as need be
local function encodePath(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, util.urlEncode(part))
    end
    return table.concat(parts, "/")
end

-- the book's file in its file type from those in its folder: the first in the best of its formats (see FORMATS)
local function pickFile(files, file_type)
    for __, format in ipairs(FORMATS[file_type] or {}) do
        for __, file in ipairs(files) do
            if
                type(file) == "table"
                and type(file.format) == "string"
                and file.format:lower() == format:lower()
                and type(file.name) == "string"
                and file.name ~= ""
                -- which only those who can borrow it can download, so it would fail
                and file.private ~= "true"
                and file.private ~= true
            then
                return file
            end
        end
    end
end

-- the book's download link from its folder's list of files, and what it lists it as (see Site), or nil and why not
function IaSearch:findDownloadLink(book)
    local body, err, status = HttpUtil.getBody(string.format("%s/metadata/%s/files", SITE, book.identifier))
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    local ok, data = false, nil
    if body and not (status and status >= 400) then
        ok, data = pcall(JSON.decode, body)
    end
    if not ok or type(data) ~= "table" then
        if body then
            LogUtil.warn(
                "unexpected list of files from",
                self.NAME .. ": HTTP",
                tostring(status),
                #body,
                "bytes,",
                not ok and data and "which couldn't be read (" .. tostring(data) .. "):" or "which isn't a list:",
                LogUtil.excerpt(body)
            )
        end
        return nil, self:explainFailure(body, err, status)
    end

    -- none when it has been taken down since it was found, which leaves its folder empty
    local file = pickFile(type(data.result) == "table" and data.result or {}, book.file_type)
    if not file then
        LogUtil.warn(string.format("found no %s file of %s", book.file_type, book.identifier))
        return nil, T(_("%1 no longer has this book as %2"), self.NAME, book.file_type:upper())
    end
    LogUtil.info(
        string.format(
            "downloading %s's %s file %q, %s bytes",
            book.identifier,
            file.format,
            file.name,
            tostring(file.size or "unknown")
        )
    )
    return string.format("%s/download/%s/%s", SITE, book.identifier, encodePath(file.name)),
        nil,
        nil,
        { md5 = file.md5, bytes = file.size }
end

return IaSearch
