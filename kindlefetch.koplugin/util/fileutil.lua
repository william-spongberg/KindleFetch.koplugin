local StringUtil = require("util.stringutil")
local lfs = require("libs/libkoreader-lfs")
local LogUtil = require("util.logutil")

local FileUtil = {}

-- return the size in bytes of the file at path, or 0 if it doesn't exist / can't be opened yet
function FileUtil.getSize(path)
    if not StringUtil.assertValidString(path) then
        return 0
    end

    local f = io.open(path, "rb")
    if not f then
        return 0
    end
    local size = f:seek("end")
    f:close()
    return size or 0
end

function FileUtil.createFile(path, data)    
    local file = io.open(path, "wb")
    if not file then
        LogUtil.warn("could not write to file")
        return nil
    end
    
    file:write(data)
    file:close()
end

-- read a small text file and returns its trimmed contents, or nil if the file doesn't exist yet
function FileUtil.readFile(path)
    if not StringUtil.assertValidString(path) then
        return nil
    end

    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content and StringUtil.trim(content) or nil
end


-- writes data to a small text file, or false if the data is null
function FileUtil.writeFile(path, content)
    if not StringUtil.assertValidString(path) then
        return false
    end
    
    if content == nil then
        return false
    end

    local f = io.open(path, "w")
    if not f then
        return false
    end
    
    local success = f:write(content)
    f:close()
    
    return success and true or false
end

-- remove a file at the given path
function FileUtil.removeFile(path)
    if not StringUtil.assertValidString(path) then
        return
    end

    if path then
        os.remove(path)
    end
end

-- check whether file exists
function FileUtil.isValidFile(path)
    if not StringUtil.assertValidString(path) then
        return
    end

    return lfs.attributes(path, "mode") == "file"
end

-- check whether folder exists
function FileUtil.isValidDirectory(path)
    if not StringUtil.assertValidString(path) then
        return
    end

    return lfs.attributes(path, "mode") == "directory"
end

return FileUtil
