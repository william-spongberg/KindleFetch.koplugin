local StringUtil = require("util.stringutil")
local lfs = require("libs/libkoreader-lfs")
local LogUtil = require("util.logutil")
local T = require("ffi/util").template
local _ = require("gettext")

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

-- write content to a small text file: true, or nil and why not (when storage is full, it may only be said on closing)
function FileUtil.writeFile(path, content)
    if not StringUtil.assertValidString(path) then
        return nil, _("no file to write to")
    end

    if content == nil then
        return nil, _("nothing to write")
    end

    local f, open_err = io.open(path, "w")
    if not f then
        return nil, open_err
    end

    local written, write_err = f:write(content)
    local closed, close_err = f:close()
    if not (written and closed) then
        return nil, write_err or close_err
    end
    return true
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

-- remove a folder and all in it, without following links out of it: true (also if there's none), or nil and why not
function FileUtil.removeDir(path)
    if not StringUtil.assertValidString(path) then
        return nil, _("no folder to remove")
    end
    if lfs.attributes(path, "mode") ~= "directory" then
        return true
    end
    local names, err = FileUtil.listDir(path)
    if not names then
        return nil, err
    end
    for __, name in ipairs(names) do
        local child = path .. "/" .. name
        local ok, child_err
        if lfs.symlinkattributes(child, "mode") == "directory" then
            ok, child_err = FileUtil.removeDir(child)
        else
            ok, child_err = os.remove(child)
        end
        if not ok then
            return nil, child_err
        end
    end
    return os.remove(path)
end

-- whether files can be saved in a folder: true, or nil and why not (gone, e.g. with its SD card out, or unwritable)
function FileUtil.checkWritableDir(path)
    if not FileUtil.isValidDirectory(path) then
        return nil, _("it doesn't exist")
    end
    local check_path = path .. "/.kindlefetch_write_check"
    local ok, err = FileUtil.writeFile(check_path, "")
    FileUtil.removeFile(check_path)
    if not ok then
        return nil, T(_("it can't be written to (%1)"), tostring(err))
    end
    return true
end

-- the names in a folder (without . and ..), or nil and why not, as lfs.dir raises errors, which KOReader would exit on
function FileUtil.listDir(path)
    local names = {}
    local ok, err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                table.insert(names, name)
            end
        end
    end)
    if not ok then
        LogUtil.warn("could not read the folder", path .. ":", tostring(err))
        return nil, tostring(err)
    end
    return names
end

return FileUtil
