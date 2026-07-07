local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")

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
    local body, err = HttpUtil.requestBody(url)
    if body then
        return body
    end

    -- use proxy as backup
    local proxy_url = os.getenv("PROXY_URL")
    if proxy_url and proxy_url ~= "" then
        logger.warn("KindleFetch: direct fetch failed, retrying through proxy", proxy_url, err or "unknown error")
        body, err = HttpUtil.requestBody(url, proxy_url)
        if body then
            return body
        end
    end

    return nil, err
end

return HttpUtil
