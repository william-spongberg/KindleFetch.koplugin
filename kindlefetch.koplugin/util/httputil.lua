local http = require("socket.http")
local ltn12 = require("ltn12")
local LogUtil = require("util.logutil")

local HttpUtil = {}

function HttpUtil.requestBody(request_url, proxy_url)
    http.TIMEOUT = 10

    local response_body = {}
    local ok, status = http.request {
        url = request_url,
        proxy = proxy_url,
        sink = ltn12.sink.table(response_body),
        headers = {
            ["User-Agent"] = "Mozilla/5.0",
        },
        redirect = true,
    }

    -- status is the HTTP status code, or what went wrong if there wasn't a response
    local body = table.concat(response_body)
    if not ok then
        return nil, tostring(status or "no response")
    end
    if body == "" then
        return nil, "empty response (HTTP " .. tostring(status) .. ")", status
    end

    return body, nil, status
end

-- a page's body and HTTP status, or nil and what went wrong
function HttpUtil.getBody(url)
    LogUtil.debug("fetching", url)
    local body, err, status = HttpUtil.requestBody(url)
    if body then
        LogUtil.debug("fetched", #body, "bytes, HTTP", status, "from", url)
        return body, nil, status
    end
    LogUtil.warn("could not fetch", url, "error:", err)

    -- use proxy as backup (without logging its address, which may include a password)
    local proxy_url = os.getenv("PROXY_URL")
    if proxy_url and proxy_url ~= "" then
        LogUtil.info("retrying through the proxy")
        body, err, status = HttpUtil.requestBody(url, proxy_url)
        if body then
            return body, nil, status
        end
        LogUtil.warn("could not fetch", url, "through the proxy either, error:", err)
    end

    return nil, err, status
end

return HttpUtil
