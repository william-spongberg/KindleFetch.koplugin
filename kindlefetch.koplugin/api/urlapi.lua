local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local UrlCache = require("cache.urlcache")
local LogUtil = require("util.logutil")

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

    local html, err = HttpUtil.getBody(url)
    if not html then
        return nil, err
    end

    local urls = parse(html)

    if urls then
        UrlCache:set(urls, key)
        return urls
    end

    return nil
end

function UrlApi:getLibgenUrls()
    return self:getUrls(LIBGEN_KEY, LIBGEN_URL, parseLibgenUrls)
end

function UrlApi:deleteLibgenUrl(url)
    return UrlCache:deleteValueFromKey(url, LIBGEN_KEY)
end

return UrlApi
