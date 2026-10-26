local HttpUtil = require("util.httputil")
local CurlUtil = require("util.curlutil")
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
-- the mirrors Wikipedia listed when this was written, for when it lists none, so searching needn't wait for an update
local FALLBACK_URLS = {
    "https://libgen.vg",
    "https://libgen.la",
    "https://libgen.bz",
    "https://libgen.gl",
    "https://libgen.li",
}
-- how long a mirror that didn't answer is tried after the others for (see restUrl), even once they're looked up again
local REST_TIME = 60 * 60
-- when each mirror that didn't answer last didn't, this session
local failed_at = {}
local ZLIB_KEY = "zlib"
local ZLIB_URL = "https://en.wikipedia.org/wiki/Z-Library"
-- the address Wikipedia listed when this was written, for the same reason
local ZLIB_FALLBACK_URLS = {
    "https://z-lib.sk",
}

-- Wikipedia's page Library Genesis' mirrors are looked up on, e.g. to test connecting to it (see Diagnostics)
UrlApi.LIBGEN_PAGE = LIBGEN_URL

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

-- whether a site is named as Z-Library's are, as anyone can edit Wikipedia and logging in sends it the password
local function isZlibName(domain)
    local name = domain:match("^([%w%-]+)%.%a+$")
    if not name then
        return false
    end
    name = name:lower()
    return name:find("z%-?lib") ~= nil or name:find("1lib", 1, true) ~= nil or name:find("singlelogin", 1, true) ~= nil
end

-- Z-Library's web addresses from the infobox's website row, not those on Tor or I2P, and only sites, not pages on them
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

-- urls, with those that didn't answer in the last while (see restUrl) after the others, in a new list
local function restedLast(urls)
    local now = os.time()
    local ready, resting = {}, {}
    for __, url in ipairs(urls) do
        local failed = failed_at[url]
        -- (or since the clock was put back)
        if failed and failed <= now and now - failed < REST_TIME then
            table.insert(resting, url)
        else
            table.insert(ready, url)
        end
    end
    for __, url in ipairs(resting) do
        table.insert(ready, url)
    end
    return ready
end

-- the urls listed on a page, cached or looked up again on refresh; else nil, why, and whether the page answered at all
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

    LogUtil.warn("found no mirrors on", url, "(HTTP", tostring(status) .. ",", #html, "bytes):", LogUtil.excerpt(html))
    return nil, _("no mirrors listed"), true
end

-- why the mirrors couldn't be looked up: no connection if Wikipedia can't be found or reached, else e.g. a wrong clock
function UrlApi.explainLookupFailure(err)
    if err == HttpUtil.CANCELLED then
        return err
    end
    if
        err == nil
        or err == HttpUtil.UNRESOLVED
        or err == CurlUtil.getErrorMeaning(7)
        or err == CurlUtil.getErrorMeaning(28)
    then
        return UrlApi.NO_CONNECTION_ERROR
    end
    if CurlUtil.isTlsFailure(err) then
        return T(
            _(
                "Wikipedia, where the mirrors are looked up, couldn't be connected to securely (%1): check the "
                    .. "device's date and time"
            ),
            err
        )
    end
    return T(_("the mirrors couldn't be looked up on Wikipedia (%1)"), err)
end

-- a site's urls without looking them up: those found before, however long ago, else fallback, and whether they were
local function knownUrls(key, fallback)
    local known = UrlCache:peek(key)
    local looked_up = type(known) == "table" and #known > 0
    local urls = {}
    for __, url in ipairs(looked_up and known or fallback) do
        table.insert(urls, url)
    end
    return urls, looked_up
end

-- a site's urls (see getUrls), resting ones last; if Wikipedia can't be reached, those known, unless they just failed
function UrlApi:getSiteUrls(key, url, parse, fallback, refresh, name)
    local urls, err, answered = self:getUrls(key, url, parse, refresh, name)
    if urls then
        return restedLast(urls)
    end
    if err == HttpUtil.CANCELLED or (not answered and refresh) then
        return nil, err, answered
    end
    if not answered then
        local known, looked_up = knownUrls(key, fallback)
        if looked_up then
            LogUtil.warn("using the mirrors looked up before, as Wikipedia couldn't be reached:", err)
        else
            LogUtil.warn("using the mirrors known when KindleFetch was written, as Wikipedia couldn't be reached:", err)
        end
        -- kept for as long as any others would be, as they're looked up again as soon as they fail
        UrlCache:set(known, key)
        return restedLast(known)
    end

    -- Wikipedia listed no mirrors: these are kept like any others, rather than asking it again for every page searched
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

-- Library Genesis' mirrors without looking them up (see knownUrls), e.g. to test connecting to them (see Diagnostics)
function UrlApi:peekLibgenUrls()
    return (knownUrls(LIBGEN_KEY, FALLBACK_URLS))
end

-- try this mirror first from now on, as it has just answered, when the ones before it may have been too busy
function UrlApi:preferLibgenUrl(url)
    return UrlCache:moveValueToFront(url, LIBGEN_KEY)
end

function UrlApi:deleteLibgenUrl(url)
    LogUtil.info("dropping mirror", LogUtil.site(url), "as it failed")
    return UrlCache:deleteValueFromKey(url, LIBGEN_KEY)
end

-- try a mirror that didn't answer after the others for a while, not drop it, as it may only have been down a moment
local function restUrl(url, key)
    failed_at[url] = os.time()
    return UrlCache:moveValueToBack(url, key)
end

function UrlApi:restLibgenUrl(url)
    LogUtil.info("trying mirror", LogUtil.site(url), "after the others for a while, as it didn't answer")
    return restUrl(url, LIBGEN_KEY)
end

-- Z-Library's addresses, which it moves between as they're taken down, looked up again on refresh (see getUrls)
function UrlApi:getZlibUrls(refresh)
    return self:getSiteUrls(ZLIB_KEY, ZLIB_URL, parseZlibUrls, ZLIB_FALLBACK_URLS, refresh, "Z-Library")
end

-- as peekLibgenUrls, for Z-Library's addresses
function UrlApi:peekZlibUrls()
    return (knownUrls(ZLIB_KEY, ZLIB_FALLBACK_URLS))
end

-- try this address first from now on, as it has just answered
function UrlApi:preferZlibUrl(url)
    return UrlCache:moveValueToFront(url, ZLIB_KEY)
end

function UrlApi:deleteZlibUrl(url)
    LogUtil.info("dropping Z-Library's address", LogUtil.site(url), "as it failed")
    return UrlCache:deleteValueFromKey(url, ZLIB_KEY)
end

-- as restLibgenUrl
function UrlApi:restZlibUrl(url)
    LogUtil.info("trying Z-Library's address", LogUtil.site(url), "after the others for a while, as it didn't answer")
    return restUrl(url, ZLIB_KEY)
end

return UrlApi
