local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local Trapper = require("ui/trapper")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local Request = require("util.request")
local HttpLogin = require("util.httplogin")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

local HttpUtil = {}

-- the error when a request was called off, by a tap on the trap widget (see setTrapWidget)
HttpUtil.CANCELLED = Errors.CANCELLED
-- curl's error when a site's name couldn't be looked up, as when the network blocks it, which KOReader's is turned into
HttpUtil.UNRESOLVED = CurlUtil.getErrorMeaning(6)

-- how long a site can take to answer, then to send the whole page, in seconds (generous, as Library Genesis is slow)
local ANSWER_TIMEOUT = 10
local PAGE_TIMEOUT = 60
-- how long a file can take to download, in seconds: much longer than a page, as files are big and e-readers' Wi-Fi slow
local FILE_TIMEOUT = 300
-- and with curl, how long it can go without any of it arriving before it's given up on
local FILE_STALL_TIME = 30

-- what went wrong when KOReader's own HTTP had no answer, as curl says it, logging its own words for crash.log
local function explainFailure(err)
    err = tostring(err or _("no response"))
    local exit_code = CurlUtil.exitCodeFor(err)
    local explained = exit_code and CurlUtil.getErrorMeaning(exit_code) or err
    if explained ~= err then
        LogUtil.info("KOReader's HTTP said:", err)
    end
    return explained
end

-- http.request, returning what it can raise (e.g. TLS errors), which KOReader would exit on, its timeouts not put back
local function send(options)
    local requested, ok, status, headers = pcall(http.request, options)
    if not requested then
        LogUtil.warn("KOReader's HTTP raised an error rather than returning it:", tostring(ok))
        return nil, ok
    end
    return ok, status, headers
end

-- whether requests made from inside Trapper:wrap can be called off (see setTrapWidget), which those made with curl can
function HttpUtil.canCancel()
    return CurlUtil.canFetch()
end

-- each coroutine's widget that calls off its requests when tapped, as one search's Cancel called off another's download
local trap_widgets = setmetatable({}, { __mode = "k" })
local MAIN = {}

-- set the widget calling off this coroutine's requests from here on, or nil once they're over (in Trapper:wrap)
function HttpUtil.setTrapWidget(widget)
    trap_widgets[coroutine.running() or MAIN] = widget
end

-- the widget that calls off the requests made in the coroutine this is called from (see setTrapWidget)
function HttpUtil.getTrapWidget()
    return trap_widgets[coroutine.running() or MAIN]
end

-- say what's being waited for on that widget, where it says such things, or with nil what it said before
function HttpUtil.sayStatus(text)
    local widget = HttpUtil.getTrapWidget()
    if widget and widget.setStatus then
        widget:setStatus(text)
    end
end

-- the fields of a form, as a list of each one's name and value, as they're sent
local function formBody(form)
    local fields = {}
    for __, field in ipairs(form) do
        table.insert(fields, util.urlEncode(field[1]) .. "=" .. util.urlEncode(tostring(field[2])))
    end
    return table.concat(fields, "&")
end

-- fetch a page with curl, giving it the form, cookies and login in a file, as any program can read its command line
local function requestBodyWithCurl(request)
    local request_url = request.url
    local config_file
    local options = {}
    if request.form or request.cookies then
        -- curl keeps cookies for bot checks that set one and redirect back, only if given none, so ours go in a header
        table.insert(options, { "cookie", "" })
        if request.cookies and request.cookies ~= "" then
            table.insert(options, { "header", "Cookie: " .. request.cookies })
        end
        if request.form then
            table.insert(options, { "data", formBody(request.form) })
        end
    end
    for __, option in ipairs(CurlUtil.loginOptions(request) or {}) do
        table.insert(options, option)
    end
    if #options > 0 then
        config_file = CurlUtil.createConfigFile(options)
        if not config_file then
            return nil, _("could not write the request for curl")
        end
    end

    local page_file = CurlUtil.createPageFile()
    local cmd = CurlUtil.fetchCommand(request_url, page_file, ANSWER_TIMEOUT, PAGE_TIMEOUT, config_file)

    local completed, output
    local trap_widget = HttpUtil.getTrapWidget()
    if Trapper:isWrapped() then
        completed, output = Trapper:dismissablePopen(cmd, trap_widget)
    else
        local pipe = io.popen(cmd, "r")
        if pipe then
            completed, output = true, pipe:read("*a")
            pipe:close()
        end
    end
    if not completed then
        -- called off by Cancel, or a tap anywhere without one; curl carries on, its leftovers removed at the next start
        if Trapper:isWrapped() and (not trap_widget or trap_widget.cancelled) then
            return nil, HttpUtil.CANCELLED
        end
        -- or the shell that runs curl couldn't be started, which isn't the same, and isn't to be passed over
        LogUtil.warn("could not start curl to fetch", LogUtil.site(request_url))
        FileUtil.removeFile(page_file)
        FileUtil.removeFile(config_file)
        return nil, Errors.START_FAILED
    end

    local body = FileUtil.readFile(page_file)
    FileUtil.removeFile(page_file)

    -- the HTTP status and curl's exit code, e.g. "200 0", or just " 127" when curl couldn't be run
    local status, exit_code = (output or ""):match("(%d*) (%d+)%s*$")
    status, exit_code = tonumber(status), tonumber(exit_code)
    if not exit_code then
        return nil, _("no response")
    end
    -- the site didn't answer, or stopped part of the way through the page
    if exit_code ~= 0 or not status or status == 0 then
        return nil, CurlUtil.getErrorMeaning(exit_code)
    end
    if not body or body == "" then
        return nil, T(_("empty response (HTTP %1)"), tostring(status)), status
    end

    return body, nil, status
end

-- the first cookie a response sets, e.g. "name=value" from "name=value; Path=/; Secure"
local function setCookie(headers)
    local set_cookie = type(headers) == "table" and headers["set-cookie"]
    return type(set_cookie) == "string" and set_cookie:match("^%s*([^;,%s]+=[^;,]*)") or nil
end

-- the page's body and HTTP status from what luasocket's request and sink gave, or nil and what went wrong
local function bodyFrom(ok, status, response_body)
    -- status is the HTTP status code, or what went wrong if there wasn't a response
    local body = table.concat(response_body)
    if not ok then
        return nil, explainFailure(status)
    end
    if body == "" then
        return nil, T(_("empty response (HTTP %1)"), tostring(status)), status
    end

    return body, nil, status
end

-- fetch a page on a library's site with KOReader's own HTTP, logging in where asked, with no proxy on the local network
local function requestLibraryBody(request_url)
    socketutil:set_timeout(ANSWER_TIMEOUT, PAGE_TIMEOUT)
    local response_body = {}
    local ok, status = HttpLogin.request(request_url, { ["User-Agent"] = "Mozilla/5.0" }, function()
        response_body = {}
        return socketutil.table_sink(response_body)
    end)
    socketutil:reset_timeout()
    if not ok then
        LogUtil.warn("KOReader's HTTP couldn't fetch from", LogUtil.site(request_url) .. ":", tostring(status))
    end
    return bodyFrom(ok, status, response_body)
end

-- fetch a page with KOReader's own HTTP, which holds KOReader up until it has, through its HTTP proxy where it's on
local function requestBodyWithKOReader(request)
    local request_url, opts = request.url, request
    if request.library and not (opts.form or opts.cookies) then
        return requestLibraryBody(request_url)
    end
    -- set through KOReader, as https requests ignore luasocket's own timeout and wait a minute instead
    socketutil:set_timeout(ANSWER_TIMEOUT, PAGE_TIMEOUT)

    local form_body = opts.form and formBody(opts.form)
    local cookies = opts.cookies
    local url = request_url
    local response_body, ok, status, headers
    -- and again when a bot check sets a cookie and redirects back, which luasocket can't follow as it keeps no cookies
    for __ = 1, 2 do
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
        ok, status, headers = send {
            url = url,
            method = form_body and "POST" or "GET",
            source = form_body and ltn12.source.string(form_body),
            proxy = request.proxy,
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

    return bodyFrom(ok, status, response_body)
end

-- pages in a row only KOReader's HTTP could fetch securely before it takes over, not one: it may not check certificates
local TLS_FALLBACKS = 3
local tls_fallbacks = 0

-- fetch a page with curl, or KOReader's own HTTP where curl can't, through KOReader's HTTP proxy where it's on
function HttpUtil.requestBody(request_url, opts)
    local request = Request.new(request_url, opts)
    if not CurlUtil.canFetch() then
        return requestBodyWithKOReader(request)
    end

    local body, err, status = requestBodyWithCurl(request)
    -- (not on a library's site, whose certificate KOReader's HTTP may not check, nor to stop curl for every site)
    if body or not CurlUtil.isTlsFailure(err) or request.library then
        if body then
            tls_fallbacks = 0
        end
        return body, err, status
    end
    -- curl couldn't connect securely, as when built without TLS or too old for the site's, so KOReader's own HTTP tries
    LogUtil.warn(
        "curl couldn't connect to",
        LogUtil.site(request_url),
        "securely:",
        err .. ", so trying KOReader's own HTTP"
    )
    local fetched, fetch_err, fetch_status = requestBodyWithKOReader(request)
    if not fetched then
        return nil, err, status
    end
    tls_fallbacks = tls_fallbacks + 1
    if tls_fallbacks >= TLS_FALLBACKS then
        CurlUtil.stopFetching(
            string.format("curl couldn't connect securely %d times in a row where it could", tls_fallbacks)
        )
    end
    return fetched, fetch_err, fetch_status
end

-- a page's body and HTTP status, or nil and why; opts.form (to post) and opts.cookies aren't logged: they can be logins
function HttpUtil.getBody(url, opts)
    if opts and opts.form then
        local names = {}
        for __, field in ipairs(opts.form) do
            table.insert(names, field[1])
        end
        LogUtil.debug("posting", table.concat(names, ", "), "to", url)
    else
        LogUtil.debug("fetching", url)
    end
    local body, err, status = HttpUtil.requestBody(url, opts)
    if body then
        LogUtil.debug("fetched", #body, "bytes, HTTP", status, "from", url)
        return body, nil, status
    end
    if err == HttpUtil.CANCELLED then
        LogUtil.info("stopped waiting for", LogUtil.site(url), "when asked to")
        return nil, err
    end
    LogUtil.warn("could not fetch", url, "error:", err)
    return nil, err, status
end

-- download a file with KOReader's own HTTP, leaving nothing behind if it doesn't download
local function downloadWithKOReader(request, path)
    local url = request.url
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, T(_("could not write the file: %1"), tostring(open_err))
    end

    socketutil:set_timeout(ANSWER_TIMEOUT, FILE_TIMEOUT)
    local ok, status
    if request.library then
        -- logging in where it asks to, into the file afresh each time, as the answer without the login isn't the file
        local sinks = 0
        ok, status = HttpLogin.request(url, { ["User-Agent"] = "Mozilla/5.0" }, function()
            sinks = sinks + 1
            if sinks > 1 then
                if io.type(file) == "file" then
                    file:close()
                end
                file = io.open(path, "wb")
            end
            return socketutil.file_sink(file)
        end)
    else
        ok, status = send {
            url = url,
            headers = {
                ["User-Agent"] = "Mozilla/5.0",
            },
            sink = socketutil.file_sink(file),
            redirect = true,
        }
    end
    socketutil:reset_timeout()
    -- which KOReader's sink has done once the whole file has arrived, but not when none of it did
    if io.type(file) == "file" then
        file:close()
    end

    if ok and status == 200 then
        return true
    end
    FileUtil.removeFile(path)
    -- status is the HTTP status code, or what went wrong if there wasn't a response
    if not ok then
        return nil, explainFailure(status)
    end
    return nil, string.format("%s (%s)", CurlUtil.getErrorMeaning(22), tostring(status))
end

-- download to path with curl, or KOReader's HTTP where it can't, with time limits, as a stall froze KOReader mid-update
function HttpUtil.downloadFile(url, path)
    LogUtil.debug("downloading", url, "to", path)
    if not CurlUtil.canFetch() then
        return downloadWithKOReader(Request.new(url), path)
    end
    local ok, err = CurlUtil.download(url, path, FILE_TIMEOUT, { stall_time = FILE_STALL_TIME })
    if not ok then
        return nil, err
    end
    return true
end

return HttpUtil
