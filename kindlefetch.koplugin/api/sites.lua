-- the sites (see Site) by the name their books' source is saved as, and those added while it runs (see MultiSearch)
return {
    libgen = require("api.libgensearch"),
    archive = require("api.iasearch"),
    gutenberg = require("api.gutenbergsearch"),
    zlib = require("api.zlibsearch"),
}
