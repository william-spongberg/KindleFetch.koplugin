local KindleFetchCache = require("cache.cache")
local KindleFetchSettings = require("settings.settings")

return KindleFetchCache:new {
    filename = "kindlefetch_urlcache.lua",
    expiry = function()
        return KindleFetchSettings:getMirrorCacheExpiryDays() * 24 * 60 * 60
    end,
    -- to fall back on when they're due to be looked up again, but Wikipedia can't be reached (see UrlApi)
    keep_expired = true,
}
