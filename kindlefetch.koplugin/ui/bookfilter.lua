local Sites = require("api.sites")
local Book = require("api.book")
local MultiSearch = require("api.multisearch")
local StringUtil = require("util.stringutil")
local T = require("ffi/util").template
local _ = require("gettext")

-- what the books found can be shown by (see ResultsView.chooseShown), hiding values unticked, so new ones still show
local BookFilter = {}

-- the value of a book that doesn't say, e.g. one without a language
local UNKNOWN = ""
local function unknown()
    return { code = UNKNOWN, text = _("Unknown") }
end

-- where the site is among those offered, for listing them in that order
local function siteRank(code)
    local sources = MultiSearch.sources()
    for i, source in ipairs(sources) do
        if source == code then
            return i
        end
    end
    return #sources + 1
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

-- those listed first, then Unknown, for the values whose order is in their codes (see before)
local function inOrder(first)
    return function(a, b)
        if (a.code == UNKNOWN) ~= (b.code == UNKNOWN) then
            return b.code == UNKNOWN
        end
        return first(a.code, b.code)
    end
end

-- the sizes the books are grouped by, each smaller than below, but for the last
local SIZES = {
    { code = "1", below = Book.parseSize("1 MB"), text = _("Under 1 MB") },
    { code = "2", below = Book.parseSize("10 MB"), text = _("1 to 10 MB") },
    { code = "3", below = Book.parseSize("100 MB"), text = _("10 to 100 MB") },
    { code = "4", text = _("Over 100 MB") },
}

-- a name field's value as it's shown, each site's spelling of a name (e.g. "english") being one value, or Unknown
local function named(text)
    text = text and StringUtil.trim(text)
    if not text or text == "" then
        return unknown()
    end
    return { code = text:lower(), text = (text:gsub("^%l", string.upper)) }
end

-- each with its id, name, a book's values (one with several is shown where any is) and their order, where not byCount
BookFilter.FILTERS = {
    {
        id = "site",
        name = _("Sites"),
        valuesOf = function(book)
            local site = Sites[book.source]
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
        id = "year",
        name = _("Years"),
        -- by the decade, e.g. the 1990s
        valuesOf = function(book)
            local year = tonumber(tostring(book.year or ""):match("^%d%d%d%d$"))
            if not year or year == 0 then
                return { unknown() }
            end
            local decade = tostring(year - year % 10)
            return { { code = decade, text = T(_("%1s"), decade) } }
        end,
        -- the latest first
        before = inOrder(function(a, b)
            return a > b
        end),
    },
    {
        id = "size",
        name = _("Sizes"),
        -- which only Library Genesis, Z-Library and libraries' catalogues say
        valuesOf = function(book)
            local size = Book.parseSize(book.file_size)
            if not size then
                return { unknown() }
            end
            for __, band in ipairs(SIZES) do
                if not band.below or size < band.below then
                    return { band }
                end
            end
        end,
        -- the smallest first
        before = inOrder(function(a, b)
            return a < b
        end),
    },
    {
        id = "downloaded",
        name = _("Downloaded"),
        -- always both, as which each book has means looking in the download folder, only once asked (see values)
        fixed = { { code = "yes", text = _("Yes") }, { code = "no", text = _("No") } },
        valuesOf = function(book, is_downloaded)
            return { { code = is_downloaded(book) and "yes" or "no" } }
        end,
    },
}

-- the values the books have for the filter, in order, each with its code, text, and how many of the books have it
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

-- whether to offer the filter: where values differ, or always if fixed, as those take looking in the download folder
function BookFilter.isOffered(filter, values)
    return filter.fixed ~= nil or #values > 1
end

-- what's hidden of the filter's values once only those whose codes are in shown are ticked, or nil where nothing is
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
