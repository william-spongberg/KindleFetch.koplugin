local logger = require("logger")

local CurlUtil = {}

-- shell-escape a string for safe inclusion in a shell command
function CurlUtil.shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- get the remote file size in bytes from a URL's Content-Length header
function CurlUtil.getRemoteFileSize(url)
    local cmd = string.format("curl -s -L -I %s", CurlUtil.shellQuote(url))

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil
    end

    local headers = pipe:read("*a")
    pipe:close()

    if not headers then
        return nil
    end

    -- get content length from first 200 response
    local file_size = nil
    for block in headers:gmatch("HTTP[/%d%.]+.-\r?\n\r?\n") do
        local size = block:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")
        if size then
            file_size = tonumber(size)
        end
    end

    return file_size
end

-- spawn a curl download process in the background
-- returns: pid, exit_file_path, or nil, nil, error_message
function CurlUtil.spawnDownload(download_url, filepath, use_proxy)
    local FileUtil = require("util.fileutil")
    local exit_file = filepath .. ".exitcode"
    FileUtil.removeFile(exit_file)
    FileUtil.removeFile(filepath)

    local proxy_flag = ""
    if use_proxy then
        local proxy_url = os.getenv("PROXY_URL")
        if proxy_url and proxy_url ~= "" then
            proxy_flag = "-x " .. CurlUtil.shellQuote(proxy_url) .. " "
        end
    end

    local cmd = string.format(
        "(curl -sL -f %s-A 'Mozilla/5.0' --retry 2 --retry-delay 2 --connect-timeout 15 -o %s %s; echo $? > %s) >/dev/null 2>&1 & echo $!",
        proxy_flag, CurlUtil.shellQuote(filepath), CurlUtil.shellQuote(download_url), CurlUtil.shellQuote(exit_file))

    logger.info("KindleFetch: curl command", cmd)

    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, nil, "unable to launch curl"
    end

    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        return nil, nil, "unable to determine curl pid"
    end

    return pid, exit_file
end

-- check if a process with the given PID is still running
function CurlUtil.isPidRunning(pid)
    if not pid then
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

-- kill a process with the given PID
function CurlUtil.killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

return CurlUtil
