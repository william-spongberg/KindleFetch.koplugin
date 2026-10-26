local ffiutil = require("ffi/util")
local FileUtil = require("util.fileutil")
local LogUtil = require("util.logutil")
local Guard = require("util.guard")
local ShellUtil = require("util.shellutil")
local Errors = require("util.errors")
local _ = require("gettext")

-- what runs in the background, curl in a shell or a process of KOReader's own, saving its exit code to a file
local BackgroundProcess = {}
BackgroundProcess.__index = BackgroundProcess

-- where running processes are listed (changed by the tests)
BackgroundProcess.PROC_DIR = "/proc"
-- how often a process that has finished is looked for again, to collect it (see collectPid)
local COLLECT_INTERVAL = 1

-- the process with pid, which saves its exit code to exit_file once it has finished
function BackgroundProcess.new(pid, exit_file)
    return setmetatable({ pid = pid, exit_file = exit_file }, BackgroundProcess)
end

function BackgroundProcess.isPidRunning(pid)
    if not pid then
        return false
    end

    -- downloads are checked on twice a second, so look in /proc rather than starting a shell each time to ask kill
    local stat_file = io.open(string.format("%s/%d/stat", BackgroundProcess.PROC_DIR, pid), "r")
    if stat_file then
        local stat = stat_file:read("*l") or ""
        stat_file:close()
        -- a process that has finished, but hasn't been cleaned up yet, isn't running
        return stat:match(".*%)%s+(%a)") ~= "Z"
    end
    local self_stat = io.open(BackgroundProcess.PROC_DIR .. "/self/stat", "r")
    if self_stat then
        self_stat:close()
        return false
    end

    local ok = os.execute(string.format("kill -0 %d 2>/dev/null", pid))
    return ok == 0
end

-- stop a process started in the background (see saveExitCode), whose shell passes the signal on to curl
function BackgroundProcess.killPid(pid)
    if not pid then
        return
    end
    os.execute(string.format("kill %d 2>/dev/null", pid))
end

-- the exit code once it has finished, or nil while it runs, or while the shell is still writing it to the empty file
function BackgroundProcess.getExitCode(exit_file)
    local exit_code_str = FileUtil.readFile(exit_file)
    local exit_code = exit_code_str and tonumber(exit_code_str)
    if not exit_code then
        return nil
    end
    FileUtil.removeFile(exit_file)
    return exit_code
end

-- run cmd in a shell that saves its exit code to exit_file, passing a kill on to cmd, which would otherwise carry on
function BackgroundProcess.saveExitCode(cmd, exit_file, config_files)
    -- (those curl was given its options in, once it has finished with them: one, or a list of them)
    local removed = {}
    for __, config_file in ipairs(type(config_files) == "table" and config_files or { config_files }) do
        table.insert(removed, ShellUtil.quote(config_file))
    end
    local command = string.format(
        "(trap 'kill $c 2>/dev/null' TERM; %s & c=$!; wait $c; s=$?; "
            .. "if kill -0 $c 2>/dev/null; then wait $c; s=$?; fi; %secho $s > %s)",
        cmd,
        #removed > 0 and string.format("rm -f %s; ", table.concat(removed, " ")) or "",
        ShellUtil.quote(exit_file)
    )
    command = string.format("%s >/dev/null 2>&1", command) -- do not print errors to terminal

    return command
end

function BackgroundProcess.echoPid(cmd)
    return string.format("%s & echo $!", cmd)
end

-- start cmd in the background (see echoPid), returning its pid, or nil and Errors.START_FAILED
function BackgroundProcess.spawn(cmd)
    -- execute command
    local pipe = io.popen(cmd, "r")
    if not pipe then
        LogUtil.warn("could not start a shell to run curl")
        return nil, Errors.START_FAILED
    end

    -- read pid from terminal output
    local pid_str = pipe:read("*l")
    pipe:close()

    local pid = tonumber(pid_str)
    if not pid then
        LogUtil.warn("curl was started, but its pid wasn't given:", tostring(pid_str))
        return nil, Errors.START_FAILED
    end

    return pid
end

-- run fn in a process of KOReader's own, saving what it returns to exit_file (1 on an error): its pid, or nil and why
function BackgroundProcess.run(what, fn, exit_file)
    local pid, err = ffiutil.runInSubProcess(function()
        local ok, exit_code = pcall(fn)
        if not ok then
            LogUtil.err(what, "went wrong:", tostring(exit_code))
            exit_code = 1
        end
        FileUtil.writeFile(exit_file, tostring(exit_code) .. "\n")
    end)
    if not pid then
        LogUtil.warn("could not start a process for", what .. ":", tostring(err))
        return nil, _("could not start downloading")
    end
    return pid
end

-- collect a process of KOReader's own once done, or it's a zombie until KOReader closes (curl's are done at once)
function BackgroundProcess.collectPid(pid)
    if not pid or ffiutil.isSubProcessDone(pid) then
        return
    end
    Guard.scheduleIn(COLLECT_INTERVAL, "collecting a download's process", function()
        BackgroundProcess.collectPid(pid)
    end, Guard.quiet)
end

-- whether it's still running
function BackgroundProcess:isRunning()
    return not self.exited and BackgroundProcess.isPidRunning(self.pid)
end

-- its exit code once it has finished, or nil and whether it's still running (nil, false when it stopped without one)
function BackgroundProcess:poll()
    local exit_code = BackgroundProcess.getExitCode(self.exit_file)
    if not exit_code then
        if BackgroundProcess.isPidRunning(self.pid) then
            return nil, true
        end
        -- it may have finished between looking for its exit code and whether it was running
        exit_code = BackgroundProcess.getExitCode(self.exit_file)
    end
    self.exited = true
    return exit_code, false
end

-- stop it, unless it has finished already, as its pid may have gone to another process since
function BackgroundProcess:kill()
    if not self.exited then
        BackgroundProcess.killPid(self.pid)
    end
end

-- collect it, where it's KOReader's own (see collectPid), once it has finished
function BackgroundProcess:collect()
    BackgroundProcess.collectPid(self.pid)
end

-- stop it and collect it, as it's no longer needed
function BackgroundProcess:stop()
    self:kill()
    self:collect()
    self.exited = true
end

return BackgroundProcess
