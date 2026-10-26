-- sites by source name; findDownloadLink returns a link, nil, nil and the file's listed md5 and bytes, or nil and why
return {
    libgen = require("api.libgensearch"),
    archive = require("api.iasearch"),
    gutenberg = require("api.gutenbergsearch"),
    zlib = require("api.zlibsearch"),
}
