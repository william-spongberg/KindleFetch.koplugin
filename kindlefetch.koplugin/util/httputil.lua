local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local util = require("util")
local Trapper = require("ui/trapper")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

local HttpUtil = {}

-- the error when a request was called off, by a tap on the trap widget (see setTrapWidget)
HttpUtil.CANCELLED = Errors.CANCELLED
-- the error when a site's name couldn't be looked up, as when the network blocks the site: curl's, which what
-- KOReader's own HTTP says for it is turned into (see explainFailure)
HttpUtil.UNRESOLVED = CurlUtil.getErrorMeaning(6)

-- constants
-- how long a site can take to answer, and then to send the whole page, in seconds. pages of search results are
-- large and Library Genesis sends them slowly, so the second is generous
local ANSWER_TIMEOUT = 10
local PAGE_TIMEOUT = 60
-- how long a file can take to download, in seconds: much longer than a page, as a file can be several megabytes, and
-- an e-reader's Wi-Fi slow
local FILE_TIMEOUT = 300
-- and with curl, how long it can go without any of it arriving before it's given up on
local FILE_STALL_TIME = 30

-- what went wrong when KOReader's own HTTP had no answer, as curl says it (logging what it said itself, for
-- crash.log)
local function explainFailure(err)
    err = tostring(err or _("no response"))
    local exit_code = CurlUtil.exitCodeFor(err)
    local explained = exit_code and CurlUtil.getErrorMeaning(exit_code) or err
    if explained ~= err then
        LogUtil.info("KOReader's HTTP said:", err)
    end
    return explained
end

-- luasocket's http.request, which returns what went wrong, but can raise it instead, e.g. from the TLS library, which
-- KOReader would exit on, without its timeouts being put back
local function request(options)
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

-- the widget on screen that calls off the requests being waited for when tapped, such as a message saying what's
-- being waited for, for each of the coroutines Trapper runs searches, downloads and logins in, as several can be
-- waiting at once: one search's Cancel called off another's download (keyed by the coroutine, or MAIN outside one)
local trap_widgets = setmetatable({}, { __mode = "k" })
local MAIN = {}

-- set the widget that calls off the requests made from here on in the coroutine this is called from, or nil once
-- they're over. set by whoever made them from inside Trapper:wrap
function HttpUtil.setTrapWidget(widget)
    trap_widgets[coroutine.running() or MAIN] = widget
end

-- the widget that calls off the requests made in the coroutine this is called from (see setTrapWidget)
function HttpUtil.getTrapWidget()
    return trap_widgets[coroutine.running() or MAIN]
end

-- say what's being waited for now on that widget, where it says such things (see DownloadProgress:setStatus), e.g.
-- that a site's mirrors are being looked up, which takes a while, or with nil, what it said before. what's waiting
-- says so, rather than the module that knows, so only what's on screen shows anything
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
            return nil, _("could not write the request for curl")
        end
    end

    local page_file = CurlUtil.createPageFile()
    local cmd = CurlUtil.fetchCommand(request_url, page_file, use_proxy, ANSWER_TIMEOUT, PAGE_TIMEOUT, config_file)

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
        -- called off by a tap on the widget's Cancel, which marks it cancelled (see WaitingMessage and
        -- DownloadProgress), or without one, a tap anywhere. curl carries on until it has finished or timed out, and
        -- what it leaves behind is removed when KOReader next starts
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

-- fetch a page with KOReader's own HTTP, which holds KOReader up until it has
local function requestBodyWithKOReader(request_url, proxy_url, opts)
    -- set through KOReader, as https requests ignore luasocket's own timeout and wait a minute instead
    socketutil:set_timeout(ANSWER_TIMEOUT, PAGE_TIMEOUT)

    local form_body = opts.form and formBody(opts.form)
    local cookies = opts.cookies
    local url = request_url
    local response_body, ok, status, headers
    -- and once more when the site answers with a cookie and a redirect back to where it was, as its check that it
    -- isn't a bot can, which luasocket can't follow by itself, as it doesn't keep cookies (nor follow a form)
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
        ok, status, headers = request {
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
        return nil, explainFailure(status)
    end
    if body == "" then
        return nil, T(_("empty response (HTTP %1)"), tostring(status)), status
    end

    return body, nil, status
end

-- how many pages in a row curl couldn't connect to securely, where KOReader's own HTTP could, after which pages are
-- fetched with KOReader's own HTTP for the rest of the session (see CurlUtil.stopFetching): not after only one, as a
-- mirror's certificate can have expired, which KOReader's HTTP may not check
local TLS_FALLBACKS = 3
local tls_fallbacks = 0

function HttpUtil.requestBody(request_url, proxy_url, opts)
    opts = opts or {}
    if not CurlUtil.canFetch() then
        return requestBodyWithKOReader(request_url, proxy_url, opts)
    end

    local body, err, status = requestBodyWithCurl(request_url, proxy_url ~= nil, opts)
    if body or not CurlUtil.isTlsFailure(err) then
        if body then
            tls_fallbacks = 0
        end
        return body, err, status
    end
    -- curl couldn't make a secure connection, which a curl built without TLS, or too old for the site's, can't, so
    -- KOReader's own HTTP fetches it instead, where it can, which was never tried
    LogUtil.warn(
        "curl couldn't connect to",
        LogUtil.site(request_url),
        "securely:",
        err .. ", so trying KOReader's own HTTP"
    )
    local fetched, fetch_err, fetch_status = requestBodyWithKOReader(request_url, proxy_url, opts)
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

-- a page's body and HTTP status, or nil and what went wrong. opts.form optionally gives the fields of a form to send
-- (which posts it), as a list of each one's name and value, and opts.cookies the cookies to send, e.g. "a=1; b=2".
-- neither is logged, as they can be a password and what logs into a site
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

-- download a file with KOReader's own HTTP, leaving nothing behind if it doesn't download
local function downloadWithKOReader(url, path)
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, T(_("could not write the file: %1"), tostring(open_err))
    end

    socketutil:set_timeout(ANSWER_TIMEOUT, FILE_TIMEOUT)
    local ok, status = request {
        url = url,
        headers = {
            ["User-Agent"] = "Mozilla/5.0",
        },
        sink = socketutil.file_sink(file),
        redirect = true,
    }
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

-- download a file to path, with curl where it can fetch (see CurlUtil.canFetch), otherwise with KOReader's own HTTP,
-- as a Kindle's own curl is too old to connect to many sites, such as GitHub. either way, KOReader is held up until
-- it has downloaded, so only for so long (a stalled download froze KOReader, until the device was restarted, in the
-- middle of updating). returns true, or nil and what went wrong
function HttpUtil.downloadFile(url, path)
    LogUtil.debug("downloading", url, "to", path)
    if not CurlUtil.canFetch() then
        return downloadWithKOReader(url, path)
    end
    local ok, err = CurlUtil.download(url, path, false, FILE_TIMEOUT, { stall_time = FILE_STALL_TIME })
    if not ok then
        return nil, err
    end
    return true
end

return HttpUtil
