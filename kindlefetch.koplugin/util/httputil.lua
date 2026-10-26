local CurlUtil = require("util.curlutil")
local CurlVersion = require("util.curlversion")
local CurlTransport = require("util.curltransport")
local KoreaderTransport = require("util.koreadertransport")
local LogUtil = require("util.logutil")
local Request = require("util.request")
local Errors = require("util.errors")

-- fetches pages and downloads files the way that works here (see transport), saying what's waited for
local HttpUtil = {}

-- the error when a request was called off, by a tap on the trap widget (see setTrapWidget)
HttpUtil.CANCELLED = Errors.CANCELLED
-- curl's error when a site's name couldn't be looked up, as when the network blocks it, which KOReader's is turned into
HttpUtil.UNRESOLVED = CurlUtil.getErrorMeaning(6)

-- whether requests made from inside Trapper:wrap can be called off (see setTrapWidget), which those made with curl can
function HttpUtil.canCancel()
    return CurlVersion.canFetch()
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

-- the transport requests go by: curl, or KOReader's own HTTP where curl can't (see CurlVersion.canFetch)
function HttpUtil.transport()
    return CurlVersion.canFetch() and CurlTransport or KoreaderTransport
end

-- pages in a row only KOReader's HTTP could fetch securely before it takes over, not one: it may not check certificates
local TLS_FALLBACKS = 3
local tls_fallbacks = 0

-- fetch a page with curl, or KOReader's own HTTP where curl can't, through KOReader's HTTP proxy where it's on
function HttpUtil.requestBody(request_url, opts)
    local request = Request.new(request_url, opts)
    if not CurlVersion.canFetch() then
        return KoreaderTransport.fetchPage(request)
    end

    local body, err, status = CurlTransport.fetchPage(request, HttpUtil.getTrapWidget())
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
    local fetched, fetch_err, fetch_status = KoreaderTransport.fetchPage(request)
    if not fetched then
        return nil, err, status
    end
    tls_fallbacks = tls_fallbacks + 1
    if tls_fallbacks >= TLS_FALLBACKS then
        CurlVersion.stopFetching(
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

-- download to path with curl, or KOReader's HTTP where it can't, with time limits, as a stall froze KOReader mid-update
function HttpUtil.downloadFile(url, path)
    LogUtil.debug("downloading", url, "to", path)
    local ok, err = HttpUtil.transport().download(Request.new(url), path, {
        max_time = Request.FILE_TIMEOUT,
        stall_time = Request.FILE_STALL_TIME,
    })
    if not ok then
        return nil, err
    end
    return true
end

return HttpUtil
