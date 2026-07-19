local NotifyUtil = require("util.notifyutil")
local LogUtil = require("util.logutil")
local FileUtil = require("util.fileutil")
local Device = require("device")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")

local CurlUtil = {}

-- constants
local TMP_DIR = DataStorage:getSettingsDir() .. "/tmp/"
local CURL_ERRORS = {
    [1] = "unsupported protocol",
    [3] = "malformed URL",
    [5] = "could not resolve proxy",
    [6] = "could not resolve host",
    [7] = "failed to connect to server",
    [18] = "partial file transfer (download interrupted)",
    [19] = "HTTP range request error",
    [22] = "HTTP error response",
    [23] = "failed writing downloaded data",
    [26] = "failed reading local data",
    [27] = "out of memory",
    [28] = "request timed out",
    [35] = "TLS/SSL connection failed",
    [36] = "transfer was stopped",
    [37] = "failed to open local file",
    [47] = "too many redirects",
    [52] = "server returned an empty response",
    [55] = "failed sending network data",
    [56] = "failed receiving network data",
    [60] = "TLS certificate verification failed",
    [61] = "unsupported TLS/SSL feature",
    [67] = "authentication failed",
    [78] = "requested resource was not found"
}

local function ensureTmpDir()
    lfs.mkdir(TMP_DIR)
end

function CurlUtil.shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

function CurlUtil.isPidRunning(pid)
    if not pid then
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

function CurlUtil.killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

function CurlUtil.getErrorMeaning(exit_code)
    return CURL_ERRORS[exit_code] or "(curl exit code " .. tostring(exit_code) .. ")"
end

function CurlUtil.getRemoteFileSize(url)
    local cmd = string.format("curl -sL -I %s", CurlUtil.shellQuote(url))

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

function CurlUtil.createExitFile()
    ensureTmpDir()

    -- FIXME: os.time() is in seconds (for some reason), so overlaps are possible
    local exit_file = TMP_DIR .. "curl_download_" .. tostring(os.time()) .. ".exitcode"
    FileUtil.removeFile(exit_file)

    return exit_file
end

function CurlUtil.getExitCode(exit_file)
    local exit_code_str = FileUtil.readFile(exit_file)
    if not exit_code_str then
        return nil  -- file doesn't exist yet, process still running
    end
    FileUtil.removeFile(exit_file)
    return tonumber(exit_code_str)
end

function CurlUtil.getProxyFlag(use_proxy)
    local proxy_flag = ""
    if use_proxy then
        local proxy_url = os.getenv("PROXY_URL")
        if proxy_url and proxy_url ~= "" then
            proxy_flag = "-x " .. CurlUtil.shellQuote(proxy_url)
        end
    end

    return proxy_flag
end

function CurlUtil.spawnCurlPid(cmd)
    -- execute command
    local pipe = io.popen(cmd, "r")
    if not pipe then
        return nil, "unable to launch curl"
    end

    -- read pid from terminal output
    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        return nil, "unable to determine curl pid"
    end

    return pid
end

function CurlUtil.getDownloadCMD(download_url, filepath)
    return string.format("curl -sL -f -o %s %s", CurlUtil.shellQuote(filepath), CurlUtil.shellQuote(download_url))
end

function CurlUtil.pretendBrowser(curl_cmd)
    return curl_cmd .. " -A 'Mozilla/5.0'"
end

function CurlUtil.enableRetry(curl_cmd, count, delay)
    return string.format("%s --retry %d --retry-delay %d", curl_cmd, count, delay)
end

function CurlUtil.setTimeout(curl_cmd, seconds)
    return string.format("%s --connect-timeout %d", curl_cmd, seconds)
end

function CurlUtil.enableParallel(curl_cmd, max_parallel)
    return string.format("%s --parallel --parallel-max %d", curl_cmd, max_parallel)
end

function CurlUtil.applyProxy(curl_cmd)
    return string.format("%s %s", curl_cmd, CurlUtil.getProxyFlag())
end

function CurlUtil.saveExitCode(cmd, exit_file)
    local command = string.format("(%s; echo $? > %s)", cmd, CurlUtil.shellQuote(exit_file)) -- save exit code to exit_file
    command = string.format("%s >/dev/null 2>&1", command) -- do not print errors to terminal

    return command
end

function CurlUtil.echoPid(cmd)
    return string.format("%s & echo $!", cmd)
end

function CurlUtil.getCMD(download_url, filepath, exit_file, use_proxy)
    local cmd = CurlUtil.getDownloadCMD(download_url, filepath)
    cmd = CurlUtil.enableRetry(cmd, 2, 2)
    cmd = CurlUtil.setTimeout(cmd, 15)
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    return cmd
end

function CurlUtil.download(download_url, filepath, use_proxy, background)

    local cmd = CurlUtil.getDownloadCMD(download_url, filepath)
    cmd = CurlUtil.pretendBrowser(cmd)
    cmd = CurlUtil.enableRetry(cmd, 2, 2)
    cmd = CurlUtil.setTimeout(cmd, 15)
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end

    local exit_file = CurlUtil.createExitFile()
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    LogUtil.debug("curl download command", cmd)

    if background then
        local cmd = CurlUtil.echoPid(cmd)
        local pid, err = CurlUtil.spawnCurlPid(cmd, exit_file)
        if not pid or err then
            return nil, nil, err
        end

        return pid, exit_file
    end

    os.execute(cmd)

    local exit_code = CurlUtil.getExitCode(exit_file)
    if exit_code == 0 then
        local file_size = FileUtil.getSize(filepath)
        if file_size and file_size > 0 then
            LogUtil.debug("download completed successfully", {
                filepath = filepath,
                file_size = file_size
            })
            return true
        else
            LogUtil.warn("download produced empty file")
            FileUtil.removeFile(filepath)
            return false, "download produced empty file"
        end
    else
        LogUtil.warn("download failed", {
            filepath = filepath,
            exit_code = exit_code
        })
        FileUtil.removeFile(filepath)
        return false, CurlUtil.getErrorMeaning(exit_code)
    end
end

function CurlUtil.downloadMultiple(download_urls, filepaths, use_proxy, background, num_parallel_jobs, enable_retry, timeout)
    ensureTmpDir()

    local config_file = TMP_DIR .. "curl_download_config_" .. tostring(os.time()) .. ".txt"
    local f = io.open(config_file, "w")
    
    for i, download_url in ipairs(download_urls) do
        f:write(string.format('url = "%s"\n', download_url:gsub('"', '\\"')))
        f:write(string.format('output = "%s"\n', filepaths[i]:gsub('"', '\\"')))
    end
    f:close()

    local cmd = string.format('curl -sL -f --config "%s"', config_file)
    cmd = CurlUtil.pretendBrowser(cmd)
    if enable_retry then
        cmd = CurlUtil.enableRetry(cmd, 2, 2)
    end
    cmd = CurlUtil.setTimeout(cmd, timeout)
    cmd = CurlUtil.enableParallel(cmd, num_parallel_jobs)
    if use_proxy then
        cmd = CurlUtil.applyProxy(cmd)
    end

    local exit_file = CurlUtil.createExitFile()
    cmd = CurlUtil.saveExitCode(cmd, exit_file)

    LogUtil.debug("curl parallel download command", cmd)

    if background then
        cmd = CurlUtil.echoPid(cmd)
        
        local pid, err = CurlUtil.spawnCurlPid(cmd)
        if not pid then
            FileUtil.removeFile(config_file)
            FileUtil.removeFile(exit_file)
            return nil, nil, nil, err
        end

        LogUtil.debug("spawned parallel download", {
            pid = pid, exit_file = exit_file, config_file = config_file,
            file_count = #download_urls
        })
        return pid, exit_file, config_file
    end

    os.execute(cmd)

    local exit_code = CurlUtil.getExitCode(exit_file)
    if exit_code ~= 0 then
        local reason = CurlUtil.getErrorMeaning(exit_code)
        LogUtil.warn("parallel download command failed", {
            exit_code = exit_code,
            reason = reason
        })
        NotifyUtil.info("Download failed:" .. reason)
    end

    local successful_count = 0
    for _, filepath in ipairs(filepaths) do
        if exit_code == 0 and FileUtil.isValidFile(filepath) then
            local file_size = FileUtil.getSize(filepath)
            if file_size and file_size > 0 then
                successful_count = successful_count + 1
                LogUtil.debug("file downloaded successfully", {
                    filepath = filepath,
                    file_size = file_size
                })
            else
                LogUtil.warn("download produced empty file")
                FileUtil.removeFile(filepath)
            end
        else
            LogUtil.warn("file download failed")
            FileUtil.removeFile(filepath)
        end
    end

    FileUtil.removeFile(config_file)
    
    LogUtil.debug("parallel download completed", {
        total_requested = #download_urls,
        successful = successful_count
    })

    return successful_count
end


return CurlUtil
