local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local UrlCache = require("cache.urlcache")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local _ = require("gettext")

local UrlApi = {}

-- constants
local LIBGEN_KEY = "libgen"
local LIBGEN_URL = "https://en.wikipedia.org/wiki/Library_Genesis"

local function parseLibgenUrls(html)
    local urls = {}

    for domain in html:gmatch("<li>%s*(libgen%.[^<]+)%s*</li>") do
        local url = "https://" .. domain
        table.insert(urls, url)
        LogUtil.debug("new LibGen URL", domain)
    end

    return #urls > 0 and urls or nil
end

function UrlApi:getUrls(key, url, parse)
    local cached = UrlCache:get(key)
    if cached then
        return cached
    end

    -- this takes a while, especially on the first search, so say what's happening
    NotifyUtil.info(_("Looking up Library Genesis mirrors..."))
    local html, err = HttpUtil.getBody(url)
    if not html then
        LogUtil.warn("could not look up mirrors on", url, "error:", err)
        return nil, err
    end

    local urls = parse(html)

    if urls then
        LogUtil.info("found mirrors on", LogUtil.site(url) .. ":", table.concat(urls, ", "))
        UrlCache:set(urls, key)
        return urls
    end

    LogUtil.warn("found no mirrors on", url, "(" .. #html .. " bytes)")
    return nil
end

function UrlApi:getLibgenUrls()
    return self:getUrls(LIBGEN_KEY, LIBGEN_URL, parseLibgenUrls)
end

function UrlApi:deleteLibgenUrl(url)
    LogUtil.info("dropping mirror", LogUtil.site(url), "as it failed")
    return UrlCache:deleteValueFromKey(url, LIBGEN_KEY)
end

return UrlApi
