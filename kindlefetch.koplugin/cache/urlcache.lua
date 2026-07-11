local KindleFetchCache = require("cache.cache")

return KindleFetchCache:new{
    filename = "kindlefetch_urlcache.lua",
    expiry = 7 * 24 * 60 * 60 -- one week
}
