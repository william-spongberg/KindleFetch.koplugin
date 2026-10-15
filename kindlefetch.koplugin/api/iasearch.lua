local util = require("util")
local JSON = require("json")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches the books on Internet Archive that anyone can download, rather than only borrow, and finds their files'
-- download links (see Sources)
local IaSearch = {
    NAME = "Internet Archive",
    SOURCE = "archive",
}

-- constants
local SOURCE = IaSearch.SOURCE
local SITE = "https://archive.org"
local RESULTS_PER_PAGE = 50
-- Internet Archive's names for the formats it has each file type in, the best first: a PDF of a scan's text before
-- one of only its pictures, and a book's own text before the text read from a scan of it. they're matched exactly
-- (whatever their capitals), as a search for a format also finds those with its name in theirs, e.g. DjVu finds
-- Djvu XML, which every scan has
local FORMATS = {
    epub = { "EPUB" },
    mobi = { "MOBI" },
    pdf = { "Text PDF", "Image Container PDF" },
    djvu = { "DjVu" },
    txt = { "Text", "DjVuTXT" },
    cbz = { "Comic Book ZIP" },
    cbr = { "Comic Book RAR" },
}
-- Internet Archive's codes for each language the settings offer, as it has most books' languages (with the two
-- codes some languages have), besides its name and its code in the settings, which some books have instead
local LANGUAGE_CODES = {
    en = { "eng" },
    es = { "spa" },
    fr = { "fre", "fra" },
    de = { "ger", "deu" },
    it = { "ita" },
    pt = { "por" },
    ru = { "rus" },
    zh = { "chi", "zho" },
    ja = { "jpn" },
    nl = { "dut", "nld" },
    bg = { "bul" },
    pl = { "pol" },
    ar = { "ara" },
    la = { "lat" },
    he = { "heb" },
    ["zh-Hant"] = { "chi", "zho" },
    tr = { "tur" },
    hu = { "hun" },
    cs = { "cze", "ces" },
    sv = { "swe" },
    da = { "dan" },
    ko = { "kor" },
    uk = { "ukr" },
    id = { "ind" },
    el = { "gre", "ell" },
    ro = { "rum", "ron" },
    lt = { "lit" },
    bn = { "ben" },
    ca = { "cat" },
    no = { "nor" },
    af = { "afr" },
    fi = { "fin" },
    hr = { "hrv" },
    sr = { "srp" },
    th = { "tha" },
    hi = { "hin" },
    ga = { "gle" },
    lv = { "lav" },
    fa = { "per", "fas" },
    vi = { "vie" },
    sk = { "slo", "slk" },
    kn = { "kan" },
    bo = { "tib", "bod" },
    cy = { "wel", "cym" },
    jv = { "jav" },
    ur = { "urd" },
    yi = { "yid" },
    hy = { "arm", "hye" },
    be = { "bel" },
    rw = { "kin" },
    ta = { "tam" },
    kk = { "kaz" },
    sl = { "slv" },
    ml = { "mal" },
    shn = { "shn" },
    mn = { "mon" },
    ka = { "geo", "kat" },
    mr = { "mar" },
    eo = { "epo" },
    et = { "est" },
    te = { "tel" },
    fil = { "fil" },
    gu = { "guj" },
    gl = { "glg" },
    ky = { "kir" },
    ms = { "may", "msa" },
    az = { "aze" },
    sw = { "swa" },
    qu = { "que" },
    pa = { "pan" },
    ba = { "bak" },
    sq = { "alb", "sqi" },
    uz = { "uzb" },
    bs = { "bos" },
    eu = { "baq", "eus" },
    my = { "bur", "mya" },
    am = { "amh" },
    ku = { "kur" },
    fy = { "fry" },
    zu = { "zul" },
    ps = { "pus" },
    ne = { "nep" },
    so = { "som" },
    ug = { "uig" },
    om = { "orm" },
    mk = { "mac", "mkd" },
    ht = { "hat" },
    lo = { "lao" },
    tt = { "tat" },
    si = { "sin" },
    ckb = { "ckb" },
    tg = { "tgk" },
    sn = { "sna" },
    su = { "sun" },
    nb = { "nob" },
    mg = { "mlg" },
    xh = { "xho" },
    ha = { "hau" },
    sd = { "snd" },
    ny = { "nya" },
}

-- what Internet Archive calls a language, as each of its codes, its name and its code in the settings (all lower
-- case), with the language's name to show
local language_names
local function languageNames()
    if not language_names then
        language_names = {}
        for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
            for __, code in ipairs(LANGUAGE_CODES[language.code] or {}) do
                language_names[code] = language_names[code] or language.text
            end
            language_names[language.text:lower()] = language.text
            language_names[language.code:lower()] = language_names[language.code:lower()] or language.text
        end
    end
    return language_names
end

-- what Internet Archive calls the languages with these codes in the settings, for searching for books in them, or
-- nil when every language is chosen
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

-- a term to search for exactly, which Internet Archive's search would otherwise read some characters of as more
-- than what they are
local function quote(term)
    return '"' .. term:gsub('[\\"]', "\\%0") .. '"'
end

-- what a search can be narrowed to (see Sources): only the books' titles, the names of their authors, or their ISBNs
IaSearch.SCOPES = { "title", "author", "isbn" }
local SCOPE_FIELDS = {
    title = "title",
    author = "creator",
}

-- each word of the query in a book's title or the name of its author (or the one of them the search is narrowed to,
-- see SCOPES), e.g. "1984 orwell" finding 1984 by George Orwell, rather than in all that's been written about it,
-- which finds too much else. an ISBN's the digits of the query, as it's saved without its hyphens
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

-- the search for the query, in the formats the file types can be in and the languages, among the books that anyone
-- can download (Internet Archive lends most of its books instead, as files only its app can open), or nil if
-- there's nothing in the query to search for
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

-- the page of results for the search (see buildQuery), the most downloaded first, as most of what Internet Archive
-- has are scans of books few have read
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

-- the values of one of a book's fields, which Internet Archive gives as a list when there are several, as text.
-- anything else, such as JSON's null, is left out
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

-- the names of the people who wrote a book, from its creators as a library writes them, e.g. "Austen, Jane,
-- 1775-1817" and "Thomson, Hugh, 1860-1920, ill." as Jane Austen, Hugh Thomson
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
            local name = languageNames()[part:lower()] or part
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

    local authors = authorNames(doc.creator)
    local year = (values(doc.year)[1] or ""):match("^%d%d%d%d$")
    return {
        source = SOURCE,
        id = SOURCE .. "_" .. identifier,
        identifier = identifier,
        -- (or after the book's identifier, when there's nothing in its title to name its file after)
        title = StringUtil.cleanFileName(title) ~= "" and StringUtil.cleanFileName(title) or identifier,
        display_title = StringUtil.cleanTitle(title),
        authors = authors ~= "" and authors or "Unknown author",
        year = year ~= "0000" and year or nil,
        language = languageName(doc.language),
        file_type = file_type,
        image_url = string.format("%s/services/img/%s", SITE, identifier),
    }
end

-- the books in the preferred file types (most of what Internet Archive has is in several), the number of results
-- on the page, and how many there are altogether, from the JSON it answers a search with. nil if it isn't that
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

-- what went wrong when Internet Archive answered with body, or didn't answer
local function explainFailure(body, err, status)
    if body and status and status >= 400 then
        return T(_("%1 answered with an error (HTTP %2), try again later"), IaSearch.NAME, status)
    end
    if body then
        return T(_("unexpected response from %1"), IaSearch.NAME)
    end
    return T(_("%1 didn't answer (%2)"), IaSearch.NAME, err)
end

-- whether there are results saved from an earlier search, which can be shown without an internet connection
function IaSearch:isCached(query, page, scope)
    return SearchCache:hasPage(self, query, page, scope)
end

-- the books on a page of Internet Archive's results, as search returns them
local function fetchResults(query, page, scope, languages, file_types)
    if #formatTerms(file_types) == 0 then
        LogUtil.warn(IaSearch.NAME, "has none of the file types chosen")
        return nil, Errors.NO_FILE_TYPES
    end
    local search = IaSearch.buildQuery(query, languages, file_types, scope)
    if not search then
        return {}, nil, nil, 0
    end

    local body, err, status = HttpUtil.getBody(SITE .. "/advancedsearch.php?" .. IaSearch.buildParams(search, page))
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    local books, results, total
    if body and not (status and status >= 400) then
        books, results, total = IaSearch.parseResults(body, file_types)
    end
    if not books then
        if body then
            LogUtil.warn(
                "unexpected search results from",
                IaSearch.NAME .. ": HTTP",
                status,
                #body,
                "bytes:",
                LogUtil.excerpt(body)
            )
        end
        return nil, explainFailure(body, err, status)
    end

    local next_page = page * RESULTS_PER_PAGE < total and page + 1 or nil
    LogUtil.info(
        string.format(
            "page %d of %s's %d results: kept %d of its %d%s",
            page,
            IaSearch.NAME,
            total,
            #books,
            results,
            next_page and "" or ", the last"
        )
    )
    return books, nil, next_page, results
end

-- search the given page of Internet Archive's results, returning the books found, the page to carry on from (or
-- nil once there are no more results), and how many results were read to find them, narrowed down by scope, where
-- given (as LlgiSearch:search does)
function IaSearch:search(query, page, scope)
    return SearchCache:search(self, query, page, scope, function(languages, file_types)
        return fetchResults(query, page, scope, languages, file_types)
    end)
end

-- a file's path in a book's folder, for its address: each folder's name and the file's name escaped as need be
local function encodePath(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        table.insert(parts, util.urlEncode(part))
    end
    return table.concat(parts, "/")
end

-- the file of the book in its file type, from the list of the files in its folder. the best of its formats (see
-- FORMATS), and the first file in that, when there are several (e.g. a book with and without its pictures)
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

-- the book's download link, from the list of the files in its folder on Internet Archive, then nil, nil and what it
-- lists the file as (see Sources). otherwise nil, and why not (HttpUtil.CANCELLED when called off)
function IaSearch.findDownloadLink(book)
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
                IaSearch.NAME .. ": HTTP",
                tostring(status),
                #body,
                "bytes,",
                not ok and data and "which couldn't be read (" .. tostring(data) .. "):" or "which isn't a list:",
                LogUtil.excerpt(body)
            )
        end
        return nil, explainFailure(body, err, status)
    end

    -- none when it has been taken down since it was found, which leaves its folder empty
    local file = pickFile(type(data.result) == "table" and data.result or {}, book.file_type)
    if not file then
        LogUtil.warn(string.format("found no %s file of %s", book.file_type, book.identifier))
        return nil, T(_("%1 no longer has this book as %2"), IaSearch.NAME, book.file_type:upper())
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
