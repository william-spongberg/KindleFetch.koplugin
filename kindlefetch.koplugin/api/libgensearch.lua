local util = require("util")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local KindleFetchSettings = require("settings.settings")
local SearchCache = require("cache.searchcache")
local UrlApi = require("api.urlapi")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- searches Library Genesis, and finds its books' download links (see Sites)
local LibgenSearch = {
    NAME = "Library Genesis",
    -- searches are narrowed down to the book types chosen in the settings, which are Library Genesis' topics
    HAS_BOOK_TYPES = true,
    SOURCE = "libgen",
}

-- constants
local SOURCE = LibgenSearch.SOURCE
-- the results asked for on each page, though Library Genesis sends 25 however many are asked for (see hasMorePages)
local RESULTS_PER_PAGE = 100
-- as many results as Library Genesis sends on a page, on every page but its last
local FULL_PAGE = 25
-- Library Genesis can't filter by language or file type, so searches read pages until they have this many books...
local MIN_BOOKS = 10
-- ...or have read this many pages
local MAX_PAGES = 5
-- Library Genesis topics for each preferred book type
local TOPICS = {
    fiction = "f",
    nonfiction = "l",
    comics = "c",
    magazines = "m",
    articles = "a",
    standards = "s",
}
local BLOCKED_ERROR = Errors.BLOCKED
local BUSY_ERROR = Errors.BUSY
local BUSY_SEARCH_ERROR = Errors.BUSY_SEARCH
local UNFOUND_ERROR = Errors.UNFOUND

local function stripTags(html)
    return StringUtil.trim(StringUtil.collapseWhitespace(html:gsub("<[^>]+>", " ")))
end

-- the title is the first edition link with text, after the series and issue links
local function parseTitle(cell)
    for text in cell:gmatch('href="edition%.php%?id=%d+"%s*>(.-)</a>') do
        text = stripTags(text:gsub("<i>.-</i>", ""))
        if text ~= "" then
            return text
        end
    end

    -- comic issues can leave the link blank, with the title only in its tooltip (after when it was added and its ID)
    for tooltip in cell:gmatch('title="([^"]*)"%s+href="edition%.php%?id=%d+"') do
        local text = stripTags(tooltip:match(".*<br>(.*)$") or "")
        if text ~= "" then
            return text
        end
    end

    -- or failing that, the series it's an issue of
    local series = stripTags(cell:match('href="series%.php%?id=%d+"%s*>(.-)</a>') or "")
    if series ~= "" then
        return series
    end
end

local function parseBook(row, base_url)
    local cells = {}
    for cell in row:gmatch("<td[^>]*>(.-)</td>") do
        table.insert(cells, cell)
    end

    -- cover, title, authors, publisher, year, language, pages, size, extension, mirrors
    if #cells < 10 then
        LogUtil.debug("skipped row with missing cells, e.g. the table's header")
        return nil
    end

    -- the file's md5, which is how Library Genesis finds it again for downloading
    local book = {
        source = SOURCE,
    }
    book.id = cells[10]:match("md5=(%x+)")
    book.id = book.id and book.id:lower()

    local image_path = cells[1]:match('src="([^"]+)"')
    if image_path then
        book.image_url = image_path:match("^https?://") and image_path or base_url .. "/" .. image_path:gsub("^/", "")
        -- the book is shown without a cover rather than asking curl for an address that isn't just an address
        if not StringUtil.isSafeUrl(book.image_url) then
            LogUtil.warn("left out a cover whose address can't be used:", book.image_url)
            book.image_url = nil
        end
    end

    -- the title to name the book's file after, and as it's written, for the screen (what shows it shortens it to fit)
    local raw_title = parseTitle(cells[2])
    if raw_title then
        book.title = StringUtil.cleanFileName(raw_title)
        book.display_title = StringUtil.cleanTitle(raw_title)
    end

    local authors = stripTags(cells[3]):gsub("[,;%s]+$", "")
    book.authors = StringUtil.assertValidString(authors) and authors or "Unknown author"

    local year = stripTags(cells[5])
    book.year = year ~= "" and year ~= "0" and year or nil
    local language = stripTags(cells[6])
    book.language = language ~= "" and language or nil
    book.book_type = cells[2]:match('badge%-primary"><a[^>]-title="([^"]+)">%w+</a>')
    local file_type = stripTags(cells[9]):lower()
    book.file_type = file_type ~= "" and file_type or nil
    local file_size = stripTags(cells[8])
    book.file_size = file_size ~= "" and file_size or "0"

    -- at minimum need title + id + file type for a valid book
    if not (book.title and book.title ~= "" and book.id and book.file_type) then
        LogUtil.warn("skipped book with missing features")
        return nil
    end

    return book
end

-- whether the book matches the preferred languages and file types, which Library Genesis can't filter by
local function isPreferred(book, language_names, file_types)
    local file_type_ok = false
    for __, file_type in ipairs(file_types) do
        if book.file_type == file_type:lower() then
            file_type_ok = true
            break
        end
    end
    if not file_type_ok then
        return false
    end

    -- keep books with an unknown language
    if not book.language then
        return true
    end
    local language = book.language:lower()
    for __, name in ipairs(language_names) do
        if language:find(name:lower(), 1, true) then
            return true
        end
    end
    return false
end

local function languageNames(codes)
    local names = {}
    for __, code in ipairs(codes) do
        for __, language in ipairs(KindleFetchSettings:getAvailableLanguages()) do
            if language.code == code then
                table.insert(names, language.text)
            end
        end
    end
    return names
end

-- the preferred books, how many results the page had, and how many rows couldn't be read, which aren't results
function LibgenSearch.parseResults(html, base_url, languages, file_types)
    local books = {}
    local tbody = html:match('id="tablelibgen".-<tbody>(.-)</tbody>')
    if not tbody then
        return books, 0, 0
    end

    local language_names = languageNames(languages)
    local results, unreadable = 0, 0
    for row in tbody:gmatch("<tr[^>]*>(.-)</tr>") do
        local book = parseBook(StringUtil.convertHtmlToText(row), base_url)
        if book then
            results = results + 1
            if isPreferred(book, language_names, file_types) then
                table.insert(books, book)
                LogUtil.debug("new book found", book)
            end
        else
            unreadable = unreadable + 1
        end
    end
    if unreadable > 0 then
        LogUtil.warn(unreadable, "of the page's", results + unreadable, "rows couldn't be read as books")
    end

    return books, results, unreadable
end

-- whether there are more pages: as its page links say, else if this one was full, as it sends 25 whatever's asked (#56)
function LibgenSearch.hasMorePages(html, page, results)
    local pages = tonumber(html:match('new Paginator%(%s*"paginator_example_top"%s*,%s*(%d+)'))
    if pages then
        return page < pages
    end
    return results >= FULL_PAGE
end

-- what a search can be narrowed to (see Sites): only its box ticked on the search page, not titles, authors and series
LibgenSearch.SCOPES = { "title", "author", "isbn" }
local SCOPE_COLUMNS = {
    title = { "t" },
    author = { "a" },
    isbn = { "i" },
}
local COLUMNS = { "t", "a", "s" }

function LibgenSearch.buildParams(query, page, book_types, scope)
    local params = {
        "req=" .. util.urlEncode(query),
        "res=" .. RESULTS_PER_PAGE,
    }
    for __, column in ipairs(SCOPE_COLUMNS[scope] or COLUMNS) do
        table.insert(params, "columns%5B%5D=" .. column)
    end
    table.insert(params, "objects%5B%5D=f")
    for __, book_type in ipairs(book_types) do
        if TOPICS[book_type] then
            table.insert(params, "topics%5B%5D=" .. TOPICS[book_type])
        end
    end
    table.insert(params, "covers=on")
    table.insert(params, "filesuns=all")
    table.insert(params, "page=" .. tostring(page))
    return table.concat(params, "&")
end

local function isBlocked(html)
    return html:find("DDoS%-Guard") or html:find("Checking your browser", 1, true) or html:find("cf-chl", 1, true)
end

-- whether a mirror's database is refusing connections, as while very busy; the mirrors share it, so all say so at once
local function isBusy(html)
    return html:find("Could not connect to the database", 1, true) ~= nil
        or html:find("max_user_connections", 1, true) ~= nil
end

-- say which mirror is being tried, after how the last one went, so a slow search or download doesn't look stuck
local function sayTrying(url, index, count, before)
    local trying = T(_("Trying %1 (mirror %2 of %3)..."), LogUtil.site(url), index, count)
    HttpUtil.sayStatus(before and before .. "\n" .. trying or trying)
end

-- what went wrong with a mirror, in a sentence to show while trying the next; unexpected says it sent some other page
local function mirrorFailure(url, html, err, status, unexpected)
    local site = LogUtil.site(url)
    if html and isBlocked(html) then
        return T(_("%1 is blocking automated requests right now."), site)
    elseif html and isBusy(html) then
        return T(_("%1 says Library Genesis is too busy."), site)
    elseif status and status >= 400 then
        return T(_("%1 answered with an error (HTTP %2)."), site, status)
    elseif html then
        return T(unexpected, site)
    elseif err == HttpUtil.UNRESOLVED then
        return T(_("%1 couldn't be found."), site)
    end
    return T(_("%1 didn't answer."), site)
end

-- when no mirror's name could be looked up but Wikipedia's could, the network's likely blocking them (#55), else nil
local function explainUnfound(unresolved, tried)
    if tried > 0 and unresolved == tried then
        LogUtil.warn("none of the mirrors' names could be looked up, though Wikipedia's could")
        return UNFOUND_ERROR
    end
end

-- whether the page is Library Genesis' results: a table of them or, when there are none, the number of files it found
local function isResultsPage(html)
    return html:find('id="tablelibgen"', 1, true) ~= nil or html:find(">%s*Files%s*<span[^>]*>%s*%d+%s*</span>") ~= nil
end

-- fetch a page of results from the first mirror that works, returning its html and the mirror
local function fetchResults(params)
    local last_err
    -- mirrors already asked, skipped once they're looked up again, as they've just failed (some only after a minute)
    local tried = {}
    local tried_count, unresolved = 0, 0
    -- whether a mirror found the database too busy or was blocked by DDoS protection, said whichever answered last
    local busy = false
    local blocked = false
    -- mirrors that didn't answer at all, which may be down, or the device may be offline
    local unanswered = {}
    -- what happened with the mirror tried last (see sayTrying)
    local before
    -- the mirrors known, then, once they've all failed, those looked up again, in case they've moved
    for __, refresh in ipairs({ false, true }) do
        local base_urls, urls_err = UrlApi:getLibgenUrls(refresh)
        if not base_urls then
            return nil, UrlApi.explainLookupFailure(urls_err)
        end
        if refresh then
            LogUtil.info("every mirror failed, looking them up again")
        end

        local answered = false
        local to_try = {}
        for __, url in ipairs(base_urls) do
            if not tried[url] then
                table.insert(to_try, url)
            end
        end
        for index, url in ipairs(to_try) do
            tried[url] = true
            tried_count = tried_count + 1
            sayTrying(url, index, #to_try, before)
            local html, err, status = HttpUtil.getBody(string.format("%s/index.php?%s", url, params))
            -- the search was called off, which says nothing about the mirrors
            if err == HttpUtil.CANCELLED then
                return nil, err
            end
            answered = answered or html ~= nil or status ~= nil

            if html and isResultsPage(html) then
                for __, unanswered_url in ipairs(unanswered) do
                    UrlApi:restLibgenUrl(unanswered_url)
                end
                UrlApi:preferLibgenUrl(url)
                return html, nil, url
            end
            before = mirrorFailure(url, html, err, status, _("%1 sent a page that isn't Library Genesis' results."))

            if html and isBlocked(html) then
                LogUtil.warn(
                    "searching",
                    LogUtil.site(url),
                    "was blocked by its DDoS protection (HTTP",
                    status,
                    #html,
                    "bytes)"
                )
                blocked = true
            elseif html and isBusy(html) then
                LogUtil.warn(
                    "searching",
                    LogUtil.site(url),
                    "found Library Genesis' database too busy (HTTP",
                    tostring(status) .. ")"
                )
                busy = true
            elseif html or status then
                -- it answered, but not with results: e.g. an error page, or one whose layout has changed
                if html then
                    LogUtil.warn(
                        "unexpected search page from",
                        LogUtil.site(url) .. ": HTTP",
                        status,
                        #html,
                        "bytes:",
                        LogUtil.excerpt(html)
                    )
                end
                -- with the status it answered with, as for the other sites
                last_err = status
                        and status >= 400
                        and T(_("Library Genesis answered with an error (HTTP %1), try again later"), status)
                    or err
                    or _("unexpected response from Library Genesis")
                UrlApi:deleteLibgenUrl(url)
            else
                table.insert(unanswered, url)
                last_err = err
                if err == HttpUtil.UNRESOLVED then
                    unresolved = unresolved + 1
                end
            end
        end

        -- if another answered or they were just looked up, the silent ones may be down; else the device may be offline
        if answered or refresh then
            for __, url in ipairs(unanswered) do
                UrlApi:restLibgenUrl(url)
            end
            unanswered = {}
        end

        -- they answered that they can't search right now, which looking them up again won't change
        if busy then
            return nil, BUSY_SEARCH_ERROR
        end
        if blocked then
            return nil, BLOCKED_ERROR
        end
    end

    -- none of their names could be looked up, though Wikipedia's could just now (see explainUnfound)
    return nil, explainUnfound(unresolved, tried_count) or last_err or _("all Library Genesis mirrors failed")
end

-- whether there are results saved from an earlier search, which can be shown without an internet connection
function LibgenSearch:isCached(query, page, scope)
    return SearchCache:hasPage(self, query, page, scope)
end

-- the books on Library Genesis' results from page on, as search returns them, reading pages until enough are found
local function searchPages(query, page, scope, languages, file_types, book_types)
    local books = {}
    -- Library Genesis can list the same file more than once, e.g. for each edition it's in
    local seen = {}
    local next_page = page
    local results_read = 0
    for __ = 1, MAX_PAGES do
        local html, err, url = fetchResults(LibgenSearch.buildParams(query, next_page, book_types, scope))
        if not html then
            -- show what earlier pages found, carrying on from the page that failed, rather than throwing it away
            if #books > 0 or (results_read > 0 and err ~= HttpUtil.CANCELLED) then
                if err == HttpUtil.CANCELLED then
                    LogUtil.info("search called off on page", next_page, "so showing the", #books, "books found before")
                else
                    LogUtil.warn(
                        string.format(
                            "page %d of the search failed (%s), so showing the %d books found in the %d results before",
                            next_page,
                            tostring(err),
                            #books,
                            results_read
                        )
                    )
                end
                break
            end
            return nil, err
        end

        local page_books, results, unreadable = LibgenSearch.parseResults(html, url, languages, file_types)
        -- nothing on the page could be read, as when Library Genesis has changed it
        if results == 0 and unreadable > 0 and #books == 0 and results_read == 0 then
            return nil, Errors.UNREADABLE
        end
        LogUtil.info(
            string.format(
                "page %d from %s: kept %d of its %d results",
                next_page,
                LogUtil.site(url),
                #page_books,
                results
            )
        )
        results_read = results_read + results
        for __, book in ipairs(page_books) do
            if not seen[book.id] then
                seen[book.id] = true
                table.insert(books, book)
            end
        end

        if not LibgenSearch.hasMorePages(html, next_page, results) then
            next_page = nil
            break
        end
        next_page = next_page + 1
        if #books >= MIN_BOOKS then
            break
        end
    end

    LogUtil.info(
        string.format(
            "found %d books for %q%s",
            #books,
            query,
            next_page and ", and more from page " .. next_page or ""
        )
    )
    return books, nil, next_page, results_read
end

-- search from page on, returning the books, the next page or nil, and how many results were read (nil when cached)
function LibgenSearch:search(query, page, scope)
    return SearchCache:search(self, query, page, scope, function(languages, file_types, book_types)
        return searchPages(query, page, scope, languages, file_types, book_types)
    end)
end

-- the book's download link from the first mirror with one, or nil, why not, and whether a mirror failed
function LibgenSearch.findDownloadLink(book, retrying)
    -- get urls from cache, or scrape them from wikipedia again when retrying
    local base_urls, urls_err = UrlApi:getLibgenUrls(retrying)
    if not base_urls then
        return nil, UrlApi.explainLookupFailure(urls_err)
    end

    -- try each libgen url
    local download_url, found_on
    local last_err
    -- mirrors that didn't answer at all (maybe down, or the device offline), and how many names couldn't be looked up
    local unanswered = {}
    local unresolved = 0
    local answered = false
    local mirror_failed = false
    local busy = false
    local blocked = false
    -- what happened with the mirror tried last (see sayTrying)
    local before
    for index, url in ipairs(base_urls) do
        sayTrying(url, index, #base_urls, before)
        -- load ads page (to get key for download page) by the book's id, its md5
        local ads_page = string.format("%s/ads.php?md5=%s", url, book.id)
        local html, err, status = HttpUtil.getBody(ads_page)
        -- called off, which says nothing about the mirrors
        if err == HttpUtil.CANCELLED then
            return nil, err
        end
        answered = answered or html ~= nil or status ~= nil
        before = mirrorFailure(url, html, err, status, _("%1 had no download link for the book."))

        -- find download url with key in ads page; an error or DDoS page is a mirror failing, not one without the book
        local download_path = html and html:match('href="([^"]*get%.php[^"]*)"')
        if download_path and download_path ~= "" then
            download_url = url .. "/" .. download_path:gsub("^/", "")
            -- as with covers, only what's just an address is passed on to curl, as what a mirror sends can't be trusted
            if StringUtil.isSafeUrl(download_url) then
                found_on = url
                LogUtil.info("found the download link on", LogUtil.site(url))
                break
            end
            LogUtil.warn("left out a download link from", LogUtil.site(url), "that isn't just an address")
            download_url = nil
            last_err = _("no Library Genesis download link found")
        elseif html and isBlocked(html) then
            LogUtil.warn("looking up the download link on", LogUtil.site(url), "was blocked by its DDoS protection")
            blocked = true
        elseif html and isBusy(html) then
            LogUtil.warn("found Library Genesis' database too busy on", LogUtil.site(url))
            busy = true
        elseif html and status and status >= 400 then
            LogUtil.warn(
                "error page from",
                LogUtil.site(url) .. "'s download page: HTTP",
                status,
                LogUtil.excerpt(html)
            )
            last_err = T(_("Library Genesis answered with an error (HTTP %1), try again later"), status)
            mirror_failed = true
            UrlApi:deleteLibgenUrl(url)
        elseif html then
            LogUtil.warn(
                "no download link on",
                LogUtil.site(url) .. "'s download page (" .. #html .. " bytes):",
                LogUtil.excerpt(html)
            )
            last_err = _("no Library Genesis download link found")
        elseif status then
            -- it answered with an error
            last_err = err
            mirror_failed = true
            UrlApi:deleteLibgenUrl(url)
        else
            table.insert(unanswered, url)
            last_err = err
            mirror_failed = true
            if err == HttpUtil.UNRESOLVED then
                unresolved = unresolved + 1
            end
        end
    end

    -- if another answered or they were just looked up, the silent ones may be down; else the device may be offline
    if answered or retrying then
        for __, url in ipairs(unanswered) do
            UrlApi:restLibgenUrl(url)
        end
    end

    if download_url then
        UrlApi:preferLibgenUrl(found_on)
        -- whose file is the one with the book's id as its md5
        return download_url, nil, nil, { md5 = book.id }
    end
    return nil,
        explainUnfound(unresolved, retrying and #base_urls or 0)
            or busy and BUSY_ERROR
            or blocked and Errors.BLOCKED_DOWNLOAD
            or last_err
            or _("all Library Genesis mirrors failed"),
        mirror_failed
end

return LibgenSearch
