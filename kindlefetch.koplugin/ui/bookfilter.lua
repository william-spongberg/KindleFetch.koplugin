local Sources = require("api.sources")
local MultiSearch = require("api.multisearch")
local StringUtil = require("util.stringutil")
local _ = require("gettext")

-- what the books found can be shown by, without searching again: the site each was found on, its languages, file
-- type and book type, and whether it's in the download folder already. each lists the values the books found have,
-- to untick those whose books are hidden (see KindleFetch:chooseShown). what's hidden is kept as the values unticked,
-- by each filter's id (e.g. { language = { french = true } }), so the books that come with other values, from a site
-- that answers later or from loading more, are shown
local BookFilter = {}

-- the value of a book that doesn't say, e.g. one without a language
local UNKNOWN = ""
local function unknown()
    return { code = UNKNOWN, text = _("Unknown") }
end

-- where the site is among those offered, for listing them in that order
local function siteRank(code)
    for i, source in ipairs(MultiSearch.SOURCES) do
        if source == code then
            return i
        end
    end
    return #MultiSearch.SOURCES + 1
end

-- the values most of the books found have first, then by name, with Unknown last
local function byCount(a, b)
    if (a.code == UNKNOWN) ~= (b.code == UNKNOWN) then
        return b.code == UNKNOWN
    end
    if a.count ~= b.count then
        return a.count > b.count
    end
    return a.text < b.text
end

-- the value of a field that's a name, as it's shown (each site's spelling of the same name, e.g. Z-Library's
-- "english", being the same value), or Unknown where the book doesn't say
local function named(text)
    text = text and StringUtil.trim(text)
    if not text or text == "" then
        return unknown()
    end
    return { code = text:lower(), text = (text:gsub("^%l", string.upper)) }
end

-- each with its id, its name, the values a book has for it (a book that has several, e.g. its languages, is shown
-- where any of them is), and the order they're listed in, where it isn't byCount
BookFilter.FILTERS = {
    {
        id = "site",
        name = _("Sites"),
        valuesOf = function(book)
            local site = Sources[book.source]
            return { site and { code = book.source, text = site.NAME } or unknown() }
        end,
        before = function(a, b)
            return siteRank(a.code) < siteRank(b.code)
        end,
    },
    {
        id = "language",
        name = _("Languages"),
        -- e.g. Internet Archive's "English, Latin"
        valuesOf = function(book)
            local values = {}
            for name in (book.language or ""):gmatch("[^,;/]+") do
                if StringUtil.trim(name) ~= "" then
                    table.insert(values, named(name))
                end
            end
            return #values > 0 and values or { unknown() }
        end,
    },
    {
        id = "file_type",
        name = _("File types"),
        valuesOf = function(book)
            return { book.file_type and { code = book.file_type:lower(), text = book.file_type:upper() } or unknown() }
        end,
    },
    {
        id = "book_type",
        name = _("Book types"),
        -- which only Library Genesis sorts its books into
        valuesOf = function(book)
            return { named(book.book_type) }
        end,
    },
    {
        id = "downloaded",
        name = _("Downloaded"),
        -- the values it always has, as it takes looking in the download folder for each book to know which it has,
        -- which is only done once it's asked for (see values)
        fixed = { { code = "yes", text = _("Yes") }, { code = "no", text = _("No") } },
        valuesOf = function(book, is_downloaded)
            return { { code = is_downloaded(book) and "yes" or "no" } }
        end,
    },
}

-- the values the books have for the filter, in the order they're listed in, each with its code, text, and how many
-- of the books have it. is_downloaded(book) says whether a book is in the download folder already
function BookFilter.values(books, filter, is_downloaded)
    local values, by_code = {}, {}
    local function add(value)
        by_code[value.code] = { code = value.code, text = value.text, count = 0 }
        table.insert(values, by_code[value.code])
    end
    for __, value in ipairs(filter.fixed or {}) do
        add(value)
    end
    for __, book in ipairs(books) do
        local counted = {}
        for __, value in ipairs(filter.valuesOf(book, is_downloaded)) do
            if not counted[value.code] then
                counted[value.code] = true
                if not by_code[value.code] then
                    add(value)
                end
                by_code[value.code].count = by_code[value.code].count + 1
            end
        end
    end
    if not filter.fixed then
        table.sort(values, filter.before or byCount)
    end
    return values
end

-- whether the filter is worth offering for the books' values (see values): where they don't all have the same one,
-- or always, where its values are fixed, as working out which each has means looking in the download folder
function BookFilter.isOffered(filter, values)
    return filter.fixed ~= nil or #values > 1
end

-- what's hidden of the filter's values once those whose codes are in shown are all that's ticked, or nil where
-- nothing is
function BookFilter.hiding(values, shown)
    local ticked = {}
    for __, code in ipairs(shown) do
        ticked[code] = true
    end
    local hidden
    for __, value in ipairs(values) do
        if not ticked[value.code] then
            hidden = hidden or {}
            hidden[value.code] = true
        end
    end
    return hidden
end

-- whether the book is shown, with what's hidden (see BookFilter): where, for each filter, it has a value that isn't
function BookFilter.isShown(book, hidden, is_downloaded)
    for __, filter in ipairs(BookFilter.FILTERS) do
        local hidden_values = hidden[filter.id]
        if hidden_values then
            local shown = false
            for __, value in ipairs(filter.valuesOf(book, is_downloaded)) do
                if not hidden_values[value.code] then
                    shown = true
                    break
                end
            end
            if not shown then
                return false
            end
        end
    end
    return true
end

-- whether anything is hidden
function BookFilter.isHiding(hidden)
    return next(hidden) ~= nil
end

-- which of the filter's values (see values) are shown, for its button: All, or those that are, e.g. "English, French"
function BookFilter.describe(values, hidden_values)
    if not hidden_values then
        return _("All")
    end
    local names = {}
    for __, value in ipairs(values) do
        if not hidden_values[value.code] then
            table.insert(names, value.text)
        end
    end
    return table.concat(names, ", ")
end

return BookFilter
