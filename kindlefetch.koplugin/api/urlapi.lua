local HttpUtil = require("util.httputil")
local UrlCache = require("cache.urlcache")
local LogUtil = require("util.logutil")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

local UrlApi = {}

-- when neither the mirrors nor Wikipedia answer at all, as when the device isn't connected to the internet
UrlApi.NO_CONNECTION_ERROR = Errors.NO_CONNECTION

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
local ZLIB_KEY = "zlib"
local ZLIB_URL = "https://en.wikipedia.org/wiki/Z-Library"
-- the address Wikipedia listed when this was written, for the same reason
local ZLIB_FALLBACK_URLS = {
    "https://z-lib.sk",
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

-- whether a site's name is one Z-Library's addresses have had, e.g. z-lib.sk, z-library.sk, zlibrary-global.se,
-- 1lib.sk or singlelogin.re. as anyone can edit the page they're looked up on, and the account's password is sent
-- to them when logging in, an address that's named after something else isn't taken to be Z-Library's
local function isZlibName(domain)
    local name = domain:match("^([%w%-]+)%.%a+$")
    if not name then
        return false
    end
    name = name:lower()
    return name:find("z%-?lib") ~= nil or name:find("1lib", 1, true) ~= nil or name:find("singlelogin", 1, true) ~= nil
end

-- Z-Library's addresses on the web, from the website row of the page's infobox, which lists those on Tor and I2P too
-- (which need software of their own to reach): only the names of sites, linked to as they are, rather than to a
-- page on them
local function parseZlibUrls(html)
    local row = html:match('class="infobox%-label"[^>]*>%s*Website%s*</th>(.-)</tr>')
    if not row then
        return nil
    end

    local urls, seen = {}, {}
    for domain in row:gmatch('href="https://([%w%.%-]+)/?"') do
        domain = domain:lower()
        if not seen[domain] and isZlibName(domain) then
            seen[domain] = true
            table.insert(urls, "https://" .. domain)
            LogUtil.debug("new Z-Library URL", domain)
        end
    end

    return #urls > 0 and urls or nil
end

-- the urls listed on a page, cached, or looked up again when refresh is set. without them, also returns why, and
-- whether the page answered at all (it doesn't without an internet connection). name is the site they're for, to
-- say what's being looked up
function UrlApi:getUrls(key, url, parse, refresh, name)
    if not refresh then
        local cached = UrlCache:get(key)
        if cached then
            return cached
        end
    end

    -- this takes a while, especially on the first search, so say what's happening, where what's waiting can
    LogUtil.info("looking up", name or "Library Genesis", "mirrors on", LogUtil.site(url))
    HttpUtil.sayStatus(T(_("Looking up %1 mirrors..."), name or "Library Genesis"))
    local html, err, status = HttpUtil.getBody(url)
    HttpUtil.sayStatus(nil)
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
    return nil, _("no mirrors listed"), true
end

-- a site's urls, looked up on its Wikipedia page again when refresh is set (see getUrls), or the ones known when
-- KindleFetch was written when the page answers without any
function UrlApi:getSiteUrls(key, url, parse, fallback, refresh, name)
    local urls, err, answered = self:getUrls(key, url, parse, refresh, name)
    if urls or not answered then
        return urls, err, answered
    end

    -- Wikipedia answered, but not with the mirrors. they're kept like any others, so Wikipedia is asked again
    -- once they stop working or are due to be looked up again, rather than for every page of every search
    LogUtil.warn("using the mirrors known when KindleFetch was written, as Wikipedia didn't list any:", err)
    local fallback_urls = {}
    for __, fallback_url in ipairs(fallback) do
        table.insert(fallback_urls, fallback_url)
    end
    UrlCache:set(fallback_urls, key)
    return fallback_urls
end

-- Library Genesis' mirrors, looked up on Wikipedia again when refresh is set (see getUrls)
function UrlApi:getLibgenUrls(refresh)
    return self:getSiteUrls(LIBGEN_KEY, LIBGEN_URL, parseLibgenUrls, FALLBACK_URLS, refresh, "Library Genesis")
end

-- try this mirror first from now on, as it has just answered, when the ones before it may have been too busy
function UrlApi:preferLibgenUrl(url)
    return UrlCache:moveValueToFront(url, LIBGEN_KEY)
end

function UrlApi:deleteLibgenUrl(url)
    LogUtil.info("dropping mirror", LogUtil.site(url), "as it failed")
    return UrlCache:deleteValueFromKey(url, LIBGEN_KEY)
end

-- Z-Library's addresses, which it moves between as they're taken down, looked up on Wikipedia again when refresh is
-- set (see getUrls)
function UrlApi:getZlibUrls(refresh)
    return self:getSiteUrls(ZLIB_KEY, ZLIB_URL, parseZlibUrls, ZLIB_FALLBACK_URLS, refresh, "Z-Library")
end

-- try this address first from now on, as it has just answered
function UrlApi:preferZlibUrl(url)
    return UrlCache:moveValueToFront(url, ZLIB_KEY)
end

function UrlApi:deleteZlibUrl(url)
    LogUtil.info("dropping Z-Library's address", LogUtil.site(url), "as it failed")
    return UrlCache:deleteValueFromKey(url, ZLIB_KEY)
end

return UrlApi
