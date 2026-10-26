local StringUtil = require("util.stringutil")

-- a library added (see Libraries) as it's saved in the settings: its OPDS catalogue, how it's searched, and its login
local SavedLibrary = {}
SavedLibrary.__index = SavedLibrary

-- the library as it was saved, or nil where it isn't one, e.g. edited by hand, which what reads it would fail on
function SavedLibrary.fromTable(saved)
    if
        type(saved) ~= "table"
        or not StringUtil.assertValidString(saved.id)
        or not StringUtil.assertValidString(saved.name)
        or not StringUtil.isSafeUrl(saved.url)
        or not StringUtil.assertValidString(saved.kind)
        or not StringUtil.assertValidString(saved.search_url)
    then
        return nil
    end
    return setmetatable({
        id = saved.id,
        name = saved.name,
        url = saved.url,
        kind = saved.kind,
        search_url = saved.search_url,
        -- with no login, where it needs none
        username = type(saved.username) == "string" and saved.username or "",
        password = type(saved.password) == "string" and saved.password or "",
    }, SavedLibrary)
end

-- as a plain table, as it's saved and handed to what searches it (see OpdsSearch)
function SavedLibrary:toTable()
    return {
        id = self.id,
        name = self.name,
        url = self.url,
        kind = self.kind,
        search_url = self.search_url,
        username = self.username,
        password = self.password,
    }
end

return SavedLibrary
