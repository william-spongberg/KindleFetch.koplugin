local util = require("util")
local KindleFetchSettings = require("settings.settings")
local Sites = require("api.sites")
local Book = require("api.book")
local BookFilter = require("ui.bookfilter")
local StringUtil = require("util.stringutil")
local FileUtil = require("util.fileutil")

-- a search and what it has found: its books, each site's next page, and which of the books are shown
local SearchSession = {}
SearchSession.__index = SearchSession

-- a search for query of the sites in sources, each book shown with its site where there are several
function SearchSession.new(query, sources)
    return setmetatable({
        query = query,
        -- the books found, or nil until the first are
        books = nil,
        -- the page to carry on from on each site with more, by its name (see MultiSearch.start)
        next_pages = {},
        several_sites = #sources > 1,
        -- the text looked for in the books (see isShown), and the values of theirs hidden, by filter (see BookFilter)
        filter = nil,
        hidden = {},
        -- whether each book has been downloaded, by id, as naming it reads the file systems mounted
        downloaded = {},
    }, SearchSession)
end

-- add the books a site has found, returning whether they're the first
function SearchSession:addBooks(books)
    local first = self.books == nil
    self.books = self.books or {}
    for __, book in ipairs(books) do
        table.insert(self.books, book)
    end
    return first
end

-- the next page of each site with more (see next_pages), but for sites whose books are hidden
function SearchSession:pagesToLoad()
    local pages = {}
    local hidden_sites = self.hidden.site or {}
    for source, page in pairs(self.next_pages) do
        if not hidden_sites[source] then
            pages[source] = page
        end
    end
    return pages
end

-- whether any site whose books are shown has more results to load (see pagesToLoad)
function SearchSession:hasMore()
    return next(self:pagesToLoad()) ~= nil
end

-- a book's title, authors and file type, for looking through the books and Go to letter (which exited on no text)
local function bookText(book)
    return StringUtil.joinDetails(
        book.display_title or book.title,
        book.authors,
        book.file_type and book.file_type:upper()
    )
end

-- the book's text in the results (see bookText), with the site it was found on, where several were searched
function SearchSession:bookItemText(book)
    local text = bookText(book)
    if self.several_sites and Sites[book.source] then
        text = StringUtil.joinDetails(text, Sites[book.source].NAME)
    end
    return text
end

-- whether it's downloaded already, remembered until forgetDownloaded, as naming it reads the file systems mounted
function SearchSession:isDownloaded(book)
    if self.downloaded[book.id] == nil then
        self.downloaded[book.id] = FileUtil.isValidFile(Book.path(book, KindleFetchSettings:getDownloadDir())) or false
    end
    return self.downloaded[book.id]
end

-- look again whether the books are downloaded, as one has finished
function SearchSession:forgetDownloaded()
    self.downloaded = {}
end

-- whether it's shown: having the text looked for (see filter), and not only values hidden (see hidden)
function SearchSession:isShown(book)
    local filter = self.filter and util.stringLower(self.filter)
    if filter and not util.stringLower(self:bookItemText(book)):find(filter, 1, true) then
        return false
    end
    return BookFilter.isShown(book, self.hidden, function(b)
        return self:isDownloaded(b)
    end)
end

-- whether only some of the books found are shown (see isShown)
function SearchSession:isFiltering()
    return self.filter ~= nil or BookFilter.isHiding(self.hidden)
end

-- how many of the books found are shown (see isShown), from the from'th on, where given
function SearchSession:countShown(from)
    local count = 0
    local books = self.books or {}
    for i = from or 1, #books do
        if self:isShown(books[i]) then
            count = count + 1
        end
    end
    return count
end

-- show all the books found again
function SearchSession:showAll()
    self.filter = nil
    self.hidden = {}
end

return SearchSession
