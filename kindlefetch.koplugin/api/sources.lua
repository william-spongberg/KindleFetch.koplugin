-- the sites books can be searched for and downloaded from, by the name a book's source is saved as. each has its
-- NAME, for saying so; search and isCached, for searching it (see LlgiSearch); findDownloadLink, for looking up the
-- link a book downloads from (see Downloader); and HAS_BOOK_TYPES, when searches are narrowed down to the book
-- types chosen in the settings
return {
    libgen = require("api.lglisearch"),
    archive = require("api.iasearch"),
}
