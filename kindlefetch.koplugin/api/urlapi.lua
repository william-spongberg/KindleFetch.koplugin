local StringUtil = require("util.stringutil")
local HttpUtil = require("util.httputil")
local UrlCache = require("cache.urlcache")
local logger = require("logger")

local UrlApi = {}

-- constants
local ANNAS_URL = "https://en.wikipedia.org/wiki/Anna%27s_Archive"
local LIBGEN_URL = "https://en.wikipedia.org/wiki/Library_Genesis"

local function parseAnnasUrls(html)
    local urls = {}

    for href in html:gmatch('<a[^>]-href="(https://annas%-archive%.[^"/]+/?[^"]*)"') do
        table.insert(urls, href)
        logger.dbg("KindleFetch: new Anna's Archive URL", href)
    end

    return #urls > 0 and urls or nil
end

local function parseLibgenUrls(html)
    local urls = {}

    for domain in html:gmatch("<li>%s*(libgen%.[^<]+)%s*</li>") do
        local url = "https://" .. domain
        table.insert(urls, url)
        logger.dbg("KindleFetch: new LibGen URL", domain)
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

function UrlApi:getAnnasUrls()
    return UrlApi:getUrls("annas-archive", ANNAS_URL, parseAnnasUrls)
end

function UrlApi:getLibgenUrls()
    return UrlApi:getUrls("libgen", LIBGEN_URL, parseLibgenUrls)
end

return UrlApi
