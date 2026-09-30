local KindleFetchCache = require("cache.cache")
local KindleFetchSettings = require("settings.settings")

return KindleFetchCache:new{
    filename = "kindlefetch_urlcache.lua",
    expiry = function()
        return KindleFetchSettings:getMirrorCacheExpiryDays() * 24 * 60 * 60
    end
}
