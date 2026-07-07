local StringUtil = require("util.stringutil")

local FileUtil = {}

-- return the size in bytes of the file at path, or 0 if it doesn't exist / can't be opened yet
function FileUtil.getSize(path)
    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local size = f:seek("end")
    f:close()
    return size or 0
end

-- read a small text file and returns its trimmed contents, or nil if the file doesn't exist yet
function FileUtil.readFile(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content and StringUtil.trim(content) or nil
end

-- remove a file at the given path
function FileUtil.removeFile(path)
    if path then
        os.remove(path)
    end
end

return FileUtil
