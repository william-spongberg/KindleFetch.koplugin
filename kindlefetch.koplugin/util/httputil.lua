local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
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

-- the fields of a form, as a list of each one's name and value, as they're sent
local function formBody(form)
    local fields = {}
    for _, field in ipairs(form) do
        table.insert(fields, util.urlEncode(field[1]) .. "=" .. util.urlEncode(tostring(field[2])))
    end
    return table.concat(fields, "&")
end

-- fetch a page with curl, which asks for it compressed, and doesn't hold KOReader up while it waits when called
-- from inside Trapper:wrap. the form and cookies (see getBody) are passed to curl in a file, rather than on its
-- command line, where any program on the device can read them
local function requestBodyWithCurl(request_url, use_proxy, opts)
    local config_file
    if opts.form or opts.cookies then
        -- with curl keeping the cookies it's sent, as a site's check that it isn't a bot can answer with a cookie,
        -- and a redirect back to where it was, to be asked again with it. curl only keeps them when not given any
        -- cookies of its own to send, so those are sent in a header (which curl only sends to the same site)
        local options = { { "cookie", "" } }
        if opts.cookies and opts.cookies ~= "" then
            table.insert(options, { "header", "Cookie: " .. opts.cookies })
        end
        if opts.form then
            table.insert(options, { "data", formBody(opts.form) })
        end
        config_file = CurlUtil.createConfigFile(options)
        if not config_file then
            return nil, "could not write the request for curl"
        end
    end

    local page_file = CurlUtil.createPageFile()
    local cmd = CurlUtil.fetchCommand(request_url, page_file, use_proxy, ANSWER_TIMEOUT, PAGE_TIMEOUT, config_file)

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

-- the first cookie a response sets, e.g. "name=value" from "name=value; Path=/; Secure"
local function setCookie(headers)
    local set_cookie = type(headers) == "table" and headers["set-cookie"]
    return type(set_cookie) == "string" and set_cookie:match("^%s*([^;,%s]+=[^;,]*)") or nil
end

function HttpUtil.requestBody(request_url, proxy_url, opts)
    opts = opts or {}
    if CurlUtil.canFetch() then
        return requestBodyWithCurl(request_url, proxy_url ~= nil, opts)
    end

    -- set through KOReader, as https requests ignore luasocket's own timeout and wait a minute instead
    socketutil:set_timeout(ANSWER_TIMEOUT, PAGE_TIMEOUT)

    local form_body = opts.form and formBody(opts.form)
    local cookies = opts.cookies
    local url = request_url
    local response_body, ok, status, headers
    -- and once more when the site answers with a cookie and a redirect back to where it was, as its check that it
    -- isn't a bot can, which luasocket can't follow by itself, as it doesn't keep cookies (nor follow a form)
    for _ = 1, 2 do
        response_body = {}
        local request_headers = {
            ["User-Agent"] = "Mozilla/5.0",
        }
        if form_body then
            request_headers["Content-Type"] = "application/x-www-form-urlencoded"
            request_headers["Content-Length"] = tostring(#form_body)
        end
        if cookies and cookies ~= "" then
            request_headers["Cookie"] = cookies
        end
        ok, status, headers = http.request {
            url = url,
            method = form_body and "POST" or "GET",
            source = form_body and ltn12.source.string(form_body),
            proxy = proxy_url,
            sink = socketutil.table_sink(response_body),
            headers = request_headers,
            redirect = not (opts.form or opts.cookies),
        }

        local cookie = ok and type(status) == "number" and status >= 300 and status < 400 and setCookie(headers)
        local location = type(headers) == "table" and headers.location
        if not (cookie and type(location) == "string" and location:find("^https?://")) then
            break
        end
        cookies = (cookies and cookies ~= "" and cookies .. "; " or "") .. cookie
        url = location
    end
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

-- a page's body and HTTP status, or nil and what went wrong. opts.form optionally gives the fields of a form to send
-- (which posts it), as a list of each one's name and value, and opts.cookies the cookies to send, e.g. "a=1; b=2".
-- neither is logged, as they can be a password and what logs into a site
function HttpUtil.getBody(url, opts)
    if opts and opts.form then
        local names = {}
        for _, field in ipairs(opts.form) do
            table.insert(names, field[1])
        end
        LogUtil.debug("posting", table.concat(names, ", "), "to", url)
    else
        LogUtil.debug("fetching", url)
    end
    local body, err, status = HttpUtil.requestBody(url, nil, opts)
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
        body, err, status = HttpUtil.requestBody(url, proxy_url, opts)
        if body then
            return body, nil, status
        end
        LogUtil.warn("could not fetch", url, "through the proxy either, error:", err)
    end

    return nil, err, status
end

return HttpUtil
