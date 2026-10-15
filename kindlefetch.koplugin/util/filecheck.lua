local md5 = require("ffi/sha2").md5
local LogUtil = require("util.logutil")

-- what a file that has downloaded is, going by how it starts, to tell a book or cover from what a site can send in its
-- place, such as a web page saying it's busy; and whether it's the very file the site listed, by its md5
local FileCheck = {}

-- how much of a file's start is read to tell what it is: enough for a PDF's header, which can come after other bytes
local HEAD_SIZE = 1024
-- how much of a file is read at a time while working out its md5 (see Md5:step)
local MD5_CHUNK_SIZE = 1024 * 1024

-- how files in each file type start, any of these. those that can start any way aren't here, and are only checked
-- for not being a web page (see FileCheck.problem)
local ZIP = "PK\3\4"
local STARTS = {
    epub = { ZIP },
    cbz = { ZIP },
    docx = { ZIP },
    odt = { ZIP },
    htmlz = { ZIP },
    -- (or zipped)
    fb2 = { "<?xml", "<FictionBook", ZIP },
    djvu = { "AT&TFORM" },
    -- (and many are zipped, or 7-Zip archives, whatever they're named)
    cbr = { "Rar!", ZIP, "7z\188\175\39\28" },
    rtf = { "{\\rtf" },
    chm = { "ITSF" },
    jpg = { "\255\216\255" },
    tif = { "II*\0", "MM\0*" },
}
-- Palm databases of Mobipocket and PalmDOC books, which say so after their names
local PALM_TYPES = { mobi = true, azw = true, azw3 = true, prc = true }
-- what a web page is, rather than e.g. an FB2 book, which is XML too
local WEB_PAGE_STARTS = { "<!doctype html", "<html", "<head", "<body", "<script", "<meta", "<title" }

-- the first bytes of the file at path, or nil if it can't be read
function FileCheck.head(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local head = f:read(HEAD_SIZE)
    f:close()
    return head or ""
end

-- head, from what it says, i.e. without the mark some text starts with to say it's UTF-8, or the spaces before it
local function text(head)
    return (head:gsub("^\239\187\191", ""):gsub("^%s+", ""))
end

local function startsWith(s, start)
    return s:sub(1, #start) == start
end

-- whether a file starting with head is a web page, or a site's answer to a program (JSON), as sites send in place of
-- what was asked for, e.g. to say they're busy, or that a link has expired
function FileCheck.isWebPage(head)
    local start = text(head)
    local lower = start:lower()
    for __, page_start in ipairs(WEB_PAGE_STARTS) do
        if startsWith(lower, page_start) then
            return true
        end
    end
    -- one written as XML
    if startsWith(lower, "<?xml") and (lower:find("<!doctype html", 1, true) or lower:find("<html", 1, true)) then
        return true
    end
    -- an object, or a list, rather than e.g. a text book that starts with [Illustration]
    return start:find('^{%s*["}]') ~= nil or start:find('^%[%s*[{"%]]') ~= nil
end

-- whether a file starting with head is in the file type, going by how files in it start, or nil when they can start
-- any way
function FileCheck.isFileType(head, file_type)
    if file_type == "pdf" then
        -- which some have other bytes before
        return head:find("%PDF-", 1, true) ~= nil
    end
    if PALM_TYPES[file_type] then
        local palm_type = head:sub(61, 68)
        return palm_type == "BOOKMOBI" or palm_type == "TEXtREAd"
    end
    local starts = STARTS[file_type]
    if not starts then
        return nil
    end
    local start = text(head)
    for __, file_start in ipairs(starts) do
        if startsWith(head, file_start) or startsWith(start, file_start) then
            return true
        end
    end
    return false
end

-- whether a file starting with head is an image, as covers are: a JPEG, PNG, GIF or WebP
function FileCheck.isImage(head)
    return startsWith(head, "\255\216\255")
        or startsWith(head, "\137PNG\r\n\26\n")
        or startsWith(head, "GIF8")
        or startsWith(head, "RIFF") and head:sub(9, 12) == "WEBP"
end

-- the title of a web page starting with head, for saying what a site sent in place of a book, or nil if it has none
function FileCheck.pageTitle(head)
    local title = head:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>([^<]*)")
    title = title and title:gsub("%s+", " "):match("^ ?(.-) ?$")
    return title ~= "" and title or nil
end

-- what's wrong with the book of the file type that has downloaded to path, going by how it starts: that it's a web
-- page, or isn't in its file type. returns nil when nothing is, otherwise "web page" or "file type", then what it
-- starts with, for logging
function FileCheck.problem(path, file_type)
    local head = FileCheck.head(path)
    if not head then
        -- (as it's there, which isn't for this to say)
        return nil
    end
    local function shown()
        return FileCheck.pageTitle(head) or head:sub(1, 80):gsub("[^%w%p ]", "?")
    end
    -- (other than where one is what was asked for)
    if file_type ~= "htm" and file_type ~= "html" and FileCheck.isWebPage(head) then
        return "web page", shown()
    end
    if FileCheck.isFileType(head, file_type) == false then
        return "file type", shown()
    end
end

-- works out a file's md5 a piece at a time (see step), as a large book takes a while
local Md5 = {}
Md5.__index = Md5

-- read the next piece of the file, returning its md5 (in lower case) once it has all been read, otherwise nil, or
-- false and why if it can't be read
function Md5:step()
    local chunk, err = self.file:read(MD5_CHUNK_SIZE)
    if chunk then
        self.append(chunk)
        return nil
    end
    self:close()
    if err then
        return false, err
    end
    return self.append():lower()
end

-- stop reading the file, e.g. when called off
function Md5:close()
    if io.type(self.file) == "file" then
        self.file:close()
    end
end

-- work out the md5 of the file at path, a piece at a time (see Md5:step), or nil and why not if it can't be read
function FileCheck.md5(path)
    local file, err = io.open(path, "rb")
    if not file then
        LogUtil.warn("could not read", path, "to check it:", err)
        return nil, err
    end
    return setmetatable({ file = file, append = md5() }, Md5)
end

return FileCheck
