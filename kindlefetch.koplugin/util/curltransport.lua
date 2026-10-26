local Trapper = require("ui/trapper")
local CurlUtil = require("util.curlutil")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local Request = require("util.request")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- fetches pages and downloads files with curl, without holding KOReader up (see CurlUtil for the commands it runs)
local CurlTransport = {}

-- the request's page with curl, given its form, cookies and login in a file, as any program can read command lines
function CurlTransport.fetchPage(request, trap_widget)
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
            table.insert(options, { "data", request:formBody() })
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
    local cmd = CurlUtil.fetchCommand(request_url, page_file, Request.ANSWER_TIMEOUT, Request.PAGE_TIMEOUT, config_file)

    local completed, output
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
            return nil, Errors.CANCELLED
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

-- download the request's file to path, holding KOReader up until it has: true, or nil and what went wrong
function CurlTransport.download(request, path, opts)
    return CurlUtil.download(request.url, path, opts.max_time, opts)
end

-- download the request's file to path in the background, returning its pid and exit file, or nil and why
function CurlTransport.startDownload(request, path, opts)
    return CurlUtil.startDownload(request.url, path, opts.max_time, opts)
end

-- download each of urls to its path in the background, as CurlUtil.downloadMultiple does, opts.parallel_jobs at once
function CurlTransport.startDownloadMany(urls, paths, opts)
    return CurlUtil.downloadMultiple(urls, paths, true, opts.parallel_jobs, false, opts.connect_timeout, {
        stall_time = opts.stall_time,
    })
end

return CurlTransport
