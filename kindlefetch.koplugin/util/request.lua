local StringUtil = require("util.stringutil")
local ProxyUtil = require("util.proxyutil")
local LibrarySites = require("util.librarysites")
local LogUtil = require("util.logutil")
local KindleFetchSettings = require("settings.settings")

-- how a site is asked for something, decided in one place from its address: proxy, encrypted DNS, login and timeouts
local Request = {}
Request.__index = Request

-- how long a site on the local network can take to connect, in seconds: not long, as one that's there connects at once
Request.LOCAL_CONNECT_TIMEOUT = 5

-- asking for url, posting opts.form and sending opts.cookies; on the local network without the proxy or encrypted DNS
function Request.new(url, opts)
    opts = opts or {}
    local is_local = StringUtil.isLocalUrl(url)
    return setmetatable({
        url = url,
        is_local = is_local,
        -- a library's site, logged in to where it needs one (see LibrarySites)
        library = LibrarySites.isLibrary(url),
        login = LibrarySites.loginFor(url),
        proxy = ProxyUtil.forUrl(url),
        -- where it's turned on, as the network's DNS may block sites (#55), but not for what only that DNS knows
        encrypted_dns = not is_local and KindleFetchSettings:getEncryptedDns() == true,
        form = opts.form,
        cookies = opts.cookies,
    }, Request)
end

-- asking for each of urls at once, with one set of options: a library's login only where they're all on its site
function Request.batch(urls)
    local all_local, site = #urls > 0, StringUtil.siteOf(urls[1])
    for __, url in ipairs(urls) do
        all_local = all_local and StringUtil.isLocalUrl(url)
        if StringUtil.siteOf(url) ~= site then
            site = nil
        end
    end
    -- as it would go to the other sites too
    local login = LibrarySites.loginFor(urls[1] or "")
    if login and not site then
        LogUtil.warn("downloading files from several sites, so without the login of the library one is on")
        login = nil
    end
    return setmetatable({
        urls = urls,
        is_local = all_local,
        login = login,
        proxy = not all_local and ProxyUtil.get() or nil,
        encrypted_dns = not all_local and KindleFetchSettings:getEncryptedDns() == true,
    }, Request)
end

-- how long it can take to connect, in seconds: seconds, or not long on the local network
function Request:connectTimeout(seconds)
    return self.is_local and math.min(Request.LOCAL_CONNECT_TIMEOUT, seconds) or seconds
end

return Request
