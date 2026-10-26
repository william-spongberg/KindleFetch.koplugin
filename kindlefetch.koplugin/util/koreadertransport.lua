local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local Request = require("util.request")
local HttpLogin = require("util.httplogin")
local HttpDownload = require("util.httpdownload")
local T = require("ffi/util").template
local _ = require("gettext")

-- fetches pages and downloads files with KOReader's own HTTP, where curl can't (see HttpUtil.transport)
local KoreaderTransport = {}

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
local function fetchLibraryPage(request_url)
    socketutil:set_timeout(Request.ANSWER_TIMEOUT, Request.PAGE_TIMEOUT)
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

-- the request's page with KOReader's own HTTP, holding KOReader up until it has, through its proxy where it's on
function KoreaderTransport.fetchPage(request)
    local request_url, opts = request.url, request
    if request.library and not (opts.form or opts.cookies) then
        return fetchLibraryPage(request_url)
    end
    -- set through KOReader, as https requests ignore luasocket's own timeout and wait a minute instead
    socketutil:set_timeout(Request.ANSWER_TIMEOUT, Request.PAGE_TIMEOUT)

    local form_body = request:formBody()
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

-- download the request's file to path, holding KOReader up until it has, leaving nothing behind if it doesn't download
function KoreaderTransport.download(request, path, opts)
    local url = request.url
    local file, open_err = io.open(path, "wb")
    if not file then
        return nil, T(_("could not write the file: %1"), tostring(open_err))
    end

    socketutil:set_timeout(Request.ANSWER_TIMEOUT, opts.max_time)
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

-- download the request's file to path in its own process, as CurlTransport.startDownload does, from the beginning
function KoreaderTransport.startDownload(request, path, opts)
    LogUtil.info("downloading with KOReader's own HTTP, as curl can't")
    return HttpDownload.start(request.url, path, opts)
end

-- download each of urls to its path, one after another in a process of its own, as CurlTransport.startDownloadMany does
function KoreaderTransport.startDownloadMany(urls, paths, opts)
    return HttpDownload.startMultiple(urls, paths, opts)
end

return KoreaderTransport
