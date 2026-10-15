local LogUtil = require("util.logutil")

local ShellUtil = {}

-- run a step of something that's done with shell commands, such as installing an update, returning true, or nil and
-- what went wrong: the command's own words (e.g. "cp: write error: No space left on device"), or its exit code when it
-- said nothing, which is logged along with the step, as it's what makes sense of a crash.log
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
