-- the proxy Kindle Fetch goes through: KOReader's HTTP proxy where it's on, for everything, as KOReader's HTTP uses it
local ProxyUtil = {}

-- KOReader's HTTP proxy, as it's in use (from its network settings, or its defaults), or nil when it's off
function ProxyUtil.get()
    local url = require("socket.http").PROXY
    return type(url) == "string" and url ~= "" and url or nil
end

-- the proxy for url: none on the local network, which a proxy on the internet can't reach, otherwise KOReader's
function ProxyUtil.forUrl(url)
    if url and require("util.stringutil").isLocalUrl(url) then
        return nil
    end
    return ProxyUtil.get()
end

-- the proxy's address without who it's logged into as, for saying which it is
function ProxyUtil.describe(url)
    return (url:gsub("^(%a[%w+.-]*://)[^@/]*@", "%1"))
end

return ProxyUtil
