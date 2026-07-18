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
            ["User-Agent"] = "Mozilla/5.0"
        },
        redirect = true
    }

    local body = table.concat(response_body)
    if not ok or body == "" then
        return nil, status or "empty response"
    end

    return body
end

function HttpUtil.getBody(url)
    LogUtil.debug("fetching page for url", url)
    local body, err = HttpUtil.requestBody(url)
    if body then
        LogUtil.debug("page fetched", #body, "bytes return")
        return body
    end

    -- use proxy as backup
    local proxy_url = os.getenv("PROXY_URL")
    if proxy_url and proxy_url ~= "" then
        LogUtil.warn("direct fetch failed, retrying through proxy")
        body, err = HttpUtil.requestBody(url, proxy_url)
        if body then
            return body
        end
    end

    LogUtil.warn("failed to fetch page for")
    return nil, err
end

return HttpUtil
