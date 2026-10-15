-- the proxies Kindle Fetch goes through: KOReader's HTTP proxy (see NetworkMgr:setHTTPProxy), where it's turned on,
-- for everything, as KOReader's own HTTP goes through it; and PROXY_URL, where it's set, as a backup, to try again
-- through once something has failed
local ProxyUtil = {}

local function proxy(url)
    return type(url) == "string" and url ~= "" and url or nil
end

-- KOReader's HTTP proxy, as it's in use (from its network settings, or its defaults), or nil when it's off
function ProxyUtil.koreader()
    return proxy(require("socket.http").PROXY)
end

-- PROXY_URL, where it's set, or nil
function ProxyUtil.backup()
    return proxy(os.getenv("PROXY_URL"))
end

-- the proxy to go through: the backup when trying again through it (use_backup), otherwise KOReader's, or nil when
-- there's none
function ProxyUtil.get(use_backup)
    if use_backup then
        return ProxyUtil.backup()
    end
    return ProxyUtil.koreader()
end

-- the proxy's address without who it's logged into as, for saying which it is
function ProxyUtil.describe(url)
    return (url:gsub("^(%a[%w+.-]*://)[^@/]*@", "%1"))
end

return ProxyUtil
