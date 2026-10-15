-- the proxy Kindle Fetch goes through: KOReader's HTTP proxy (see NetworkMgr:setHTTPProxy), where it's turned on, in
-- KOReader's network settings or Kindle Fetch's, for everything, as KOReader's own HTTP goes through it
local ProxyUtil = {}

-- KOReader's HTTP proxy, as it's in use (from its network settings, or its defaults), or nil when it's off
function ProxyUtil.get()
    local url = require("socket.http").PROXY
    return type(url) == "string" and url ~= "" and url or nil
end

-- the proxy's address without who it's logged into as, for saying which it is
function ProxyUtil.describe(url)
    return (url:gsub("^(%a[%w+.-]*://)[^@/]*@", "%1"))
end

return ProxyUtil
