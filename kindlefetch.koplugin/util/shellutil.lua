local LogUtil = require("util.logutil")

local ShellUtil = {}

-- str in single quotes, as the shell takes it as it is
function ShellUtil.quote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- run a step done with shell commands: true, or nil and the command's own words or exit code, logged with the step
function ShellUtil.run(step, cmd)
    local pipe = io.popen(string.format('(%s) 2>&1; echo "exit $?"', cmd))
    local output = pipe and pipe:read("*a") or ""
    if pipe then
        pipe:close()
    end
    local said, exit_code = output:match("^(.-)%s*exit (%d+)%s*$")
    if exit_code == "0" then
        return true
    end
    said = said and said ~= "" and said or "exit code " .. tostring(exit_code)
    LogUtil.warn("could not", step .. ":", said)
    return nil, said
end

return ShellUtil
