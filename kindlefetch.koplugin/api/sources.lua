-- the sites books can be searched for and downloaded from, by the name a book's source is saved as. each has its NAME,
-- for saying so; SOURCE, that name, for saving its searches (see SearchCache); search and isCached, for searching it
-- (see LlgiSearch); findDownloadLink, for looking up the link a book downloads from (see Downloader), then nil, nil and
-- what the site lists its file as, where it does (its md5 and how many bytes it is, which what arrives is checked
-- against); HAS_BOOK_TYPES, when searches are narrowed down to the book types chosen in the settings; SCOPES, the
-- fields of its books a search can be narrowed to (e.g. "author"), which search and isCached are given after the page,
-- where it can; NEEDS_LOGIN, when it can only be searched once logged into (see ZlibLogin); and
-- NEW_LINK_WHEN_SERVER_FAILS, when a download link can be asked for again once its server fails (see Downloader)
return {
    libgen = require("api.lglisearch"),
    archive = require("api.iasearch"),
    zlib = require("api.zlibsearch"),
}
