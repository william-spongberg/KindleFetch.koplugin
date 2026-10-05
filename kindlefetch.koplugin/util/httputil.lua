local http = require("socket.http")
local socketutil = require("socketutil")
local LogUtil = require("util.logutil")

local HttpUtil = {}

-- constants
-- how long a site can take to answer, and then to send the whole page, in seconds. pages of search results are
-- large and Library Genesis sends them slowly, so the second is generous
local ANSWER_TIMEOUT = 10
local PAGE_TIMEOUT = 60

function HttpUtil.requestBody(request_url, proxy_url)
    -- set through KOReader, as https requests ignore luasocket's own timeout and wait a minute instead
    socketutil:set_timeout(ANSWER_TIMEOUT, PAGE_TIMEOUT)

    local response_body = {}
    local ok, status = http.request {
        url = request_url,
        proxy = proxy_url,
        sink = socketutil.table_sink(response_body),
        headers = {
            ["User-Agent"] = "Mozilla/5.0",
        },
        redirect = true,
    }
    socketutil:reset_timeout()

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
