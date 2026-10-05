local http = require("socket.http")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")

local HttpUtil = {}

-- the error when a request was called off, by a tap on trap_widget
HttpUtil.CANCELLED = "request cancelled"
-- a widget on screen that calls off the request being waited for when tapped, such as a message saying what's
-- being waited for. set by whoever started the requests from inside Trapper:wrap, and cleared by them after
HttpUtil.trap_widget = nil

-- constants
-- how long a site can take to answer, and then to send the whole page, in seconds. pages of search results are
-- large and Library Genesis sends them slowly, so the second is generous
local ANSWER_TIMEOUT = 10
local PAGE_TIMEOUT = 60

-- whether requests made from inside Trapper:wrap can be called off (see trap_widget), which those made with curl can
function HttpUtil.canCancel()
    return CurlUtil.canFetch()
end

-- fetch a page with curl, which asks for it compressed, and doesn't hold KOReader up while it waits when called
-- from inside Trapper:wrap
local function requestBodyWithCurl(request_url, use_proxy)
    local page_file = CurlUtil.createPageFile()
    local cmd = CurlUtil.fetchCommand(request_url, page_file, use_proxy, ANSWER_TIMEOUT, PAGE_TIMEOUT)

    local completed, output
    if Trapper:isWrapped() then
        completed, output = Trapper:dismissablePopen(cmd, HttpUtil.trap_widget)
    else
        local pipe = io.popen(cmd, "r")
        if pipe then
            completed, output = true, pipe:read("*a")
            pipe:close()
        end
    end
    if not completed then
        -- curl carries on until it has finished or timed out. what it leaves behind is removed when KOReader
        -- next starts
        return nil, HttpUtil.CANCELLED
    end

    local body = FileUtil.readFile(page_file)
    FileUtil.removeFile(page_file)

    -- the HTTP status and curl's exit code, e.g. "200 0", or just " 127" when curl couldn't be run
    local status, exit_code = (output or ""):match("(%d*) (%d+)%s*$")
    status, exit_code = tonumber(status), tonumber(exit_code)
    if not exit_code then
        return nil, "no response"
    end
    -- the site didn't answer, or stopped part of the way through the page
    if exit_code ~= 0 or not status or status == 0 then
        return nil, CurlUtil.getErrorMeaning(exit_code)
    end
    if not body or body == "" then
        return nil, "empty response (HTTP " .. tostring(status) .. ")", status
    end

    return body, nil, status
end

function HttpUtil.requestBody(request_url, proxy_url)
    if CurlUtil.canFetch() then
        return requestBodyWithCurl(request_url, proxy_url ~= nil)
    end

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
    if err == HttpUtil.CANCELLED then
        LogUtil.info("stopped waiting for", LogUtil.site(url), "when asked to")
        return nil, err
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
