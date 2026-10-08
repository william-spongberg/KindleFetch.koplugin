local HttpUtil = require("util.httputil")
local UrlCache = require("cache.urlcache")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local _ = require("gettext")

local UrlApi = {}

-- when neither the mirrors nor Wikipedia answer at all, as when the device isn't connected to the internet
UrlApi.NO_CONNECTION_ERROR = "no internet connection"

-- constants
local LIBGEN_KEY = "libgen"
local LIBGEN_URL = "https://en.wikipedia.org/wiki/Library_Genesis"
-- the mirrors Wikipedia listed when this was written, for when it answers without them, e.g. once its page has
-- been rearranged. without them, nothing could be searched for until the plugin was updated
local FALLBACK_URLS = {
    "https://libgen.vg",
    "https://libgen.la",
    "https://libgen.bz",
    "https://libgen.gl",
    "https://libgen.li",
}

local function parseLibgenUrls(html)
    local urls = {}

    -- only the names of sites, as anyone can edit the page: not a name followed by a path, or anything else
    for domain in html:gmatch("<li>%s*(libgen%.[%w%.%-]+)%s*</li>") do
        local url = "https://" .. domain
        table.insert(urls, url)
        LogUtil.debug("new LibGen URL", domain)
    end

    return #urls > 0 and urls or nil
end

-- the urls listed on a page, cached, or looked up again when refresh is set. without them, also returns why, and
-- whether the page answered at all (it doesn't without an internet connection)
function UrlApi:getUrls(key, url, parse, refresh)
    if not refresh then
        local cached = UrlCache:get(key)
        if cached then
            return cached
        end
    end

    -- this takes a while, especially on the first search, so say what's happening
    NotifyUtil.info(_("Looking up Library Genesis mirrors..."))
    local html, err, status = HttpUtil.getBody(url)
    if not html then
        if err ~= HttpUtil.CANCELLED then
            LogUtil.warn("could not look up mirrors on", url, "error:", err)
        end
        return nil, err, status ~= nil
    end

    local urls = parse(html)

    if urls then
        LogUtil.info("found mirrors on", LogUtil.site(url) .. ":", table.concat(urls, ", "))
        UrlCache:set(urls, key)
        return urls
    end

    LogUtil.warn("found no mirrors on", url, "(" .. #html .. " bytes)")
    return nil, "no mirrors listed", true
end

-- Library Genesis' mirrors, looked up on Wikipedia again when refresh is set (see getUrls)
function UrlApi:getLibgenUrls(refresh)
    local urls, err, answered = self:getUrls(LIBGEN_KEY, LIBGEN_URL, parseLibgenUrls, refresh)
    if urls or not answered then
        return urls, err, answered
    end

    -- Wikipedia answered, but not with the mirrors. they're kept like any others, so Wikipedia is asked again
    -- once they stop working or are due to be looked up again, rather than for every page of every search
    LogUtil.warn("using the mirrors known when KindleFetch was written, as Wikipedia didn't list any:", err)
    local fallback_urls = {}
    for _, url in ipairs(FALLBACK_URLS) do
        table.insert(fallback_urls, url)
    end
    UrlCache:set(fallback_urls, LIBGEN_KEY)
    return fallback_urls
end

-- try this mirror first from now on, as it has just answered, when the ones before it may have been too busy
function UrlApi:preferLibgenUrl(url)
    return UrlCache:moveValueToFront(url, LIBGEN_KEY)
end

function UrlApi:deleteLibgenUrl(url)
    LogUtil.info("dropping mirror", LogUtil.site(url), "as it failed")
    return UrlCache:deleteValueFromKey(url, LIBGEN_KEY)
end

return UrlApi
