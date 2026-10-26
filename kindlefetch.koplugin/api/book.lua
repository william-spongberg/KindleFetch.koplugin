local util = require("util")
local StringUtil = require("util.stringutil")

-- the books sites find, kept as plain tables, as searches are saved with them (see Site:search)
local Book = {}

-- how many bytes are in each unit a size is written in
local UNITS = { [""] = 1, k = 1024, m = 1024 * 1024, g = 1024 * 1024 * 1024 }

-- a book on the site named source, from fields: its title as a file name (or fallback_title) and to show, and authors
function Book.new(source, fields, fallback_title)
    local book = { source = source }
    for key, value in pairs(fields) do
        book[key] = value
    end
    local file_title = StringUtil.cleanFileName(fields.title)
    book.title = file_title ~= "" and file_title or fallback_title or ""
    book.display_title = StringUtil.cleanTitle(fields.title)
    book.authors = StringUtil.assertValidString(fields.authors) and fields.authors or "Unknown author"
    return book
end

-- how big a file of this many bytes is, as the sites write it, e.g. "752 kB" or "2.1 MB", or nil where it isn't known
function Book.formatSize(bytes)
    if not bytes or bytes <= 0 then
        return nil
    end
    if bytes < 1024 * 1024 then
        return string.format("%d kB", math.max(1, math.floor(bytes / 1024 + 0.5)))
    end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

-- how many bytes a size is, as a site writes it, e.g. "2.06 MB" or "752 kB", or nil where it doesn't say
function Book.parseSize(size)
    local number, unit = tostring(size or ""):lower():match("^%s*([%d%.]+)%s*([kmg]?)i?b%s*$")
    number = tonumber(number)
    return number and number > 0 and number * UNITS[unit] or nil
end

-- the name the book downloads as in folder, unlike those of the files already there
function Book.fileName(book, folder)
    return util.getSafeFilename(book.title .. "." .. book.file_type, folder)
end

-- where the book downloads to in folder
function Book.path(book, folder)
    return folder .. "/" .. Book.fileName(book, folder)
end

return Book
