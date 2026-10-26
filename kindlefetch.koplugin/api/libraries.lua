local KindleFetchSettings = require("settings.settings")
local MultiSearch = require("api.multisearch")
local OpdsSearch = require("api.opdssearch")
local LibrarySites = require("util.librarysites")
local LogUtil = require("util.logutil")
local StringUtil = require("util.stringutil")

-- the libraries the user has added (see KindleFetchSettings:getLibraries), such as Calibre's content server's, each an
-- OPDS catalogue searched as a site of its own (see OpdsSearch), offered before the others (see MultiSearch.addSite),
-- logged into with its own login (see LibrarySites)
local Libraries = {}

-- the sites offered (see register), by their names in Sites, each with what it was made from (see signature)
local registered = {}

-- the name a library is searched as in Sites, which the books found in it are saved with
function Libraries.source(library)
    return "library_" .. library.id
end

-- what a library is searched with, to tell when it has changed
local function signature(library)
    return table.concat({
        library.name,
        library.url,
        library.kind,
        library.search_url,
        library.username,
        library.password,
    }, "\n")
end

-- offer each library in the settings to search, logging in to its site with its login (see LibrarySites), and stop
-- offering those that have been removed: whenever the file manager or a book is opened, and once they've changed. a
-- library that hasn't changed keeps its site, with the pages of results it has linked to (see OpdsSearch.new)
function Libraries.register()
    LibrarySites.clear()
    local current = {}
    for __, library in ipairs(KindleFetchSettings:getLibraries()) do
        local login = library.username ~= "" and { username = library.username, password = library.password } or nil
        LibrarySites.add(library.url, login)
        -- (in case its search is on another of its sites)
        LibrarySites.add(library.search_url, login)
        local source = Libraries.source(library)
        current[source] = signature(library)
        if registered[source] ~= current[source] then
            MultiSearch.addSite(source, OpdsSearch.new(source, library))
        end
    end
    for source in pairs(registered) do
        if not current[source] then
            MultiSearch.removeSite(source)
        end
    end
    registered = current
end

-- the library with this id, or nil
function Libraries.find(id)
    for __, library in ipairs(KindleFetchSettings:getLibraries()) do
        if library.id == id then
            return library
        end
    end
end

-- a new library's id, which isn't another's, as its site's name in Sites is made from it (see source)
local function newId(libraries)
    local taken = {}
    for __, library in ipairs(libraries) do
        taken[library.id] = true
    end
    local id
    repeat
        id = string.format("%x%04x", os.time(), math.random(0, 0xffff))
    until not taken[id]
    return id
end

-- add the library at found (as OpdsSearch.discover finds it), logged into with login ({ username = ..., password =
-- ... }), where given, and named name, where given, otherwise what it calls itself, ticking it in the search box, so
-- it's searched straight away. returns it, or nil and why not
function Libraries.add(found, login, name)
    local libraries = KindleFetchSettings:getLibraries()
    name = StringUtil.trim(name or "")
    local library = {
        id = newId(libraries),
        name = name ~= "" and name or found.name,
        url = found.url,
        kind = found.kind,
        search_url = found.search_url,
        username = login and login.username or "",
        password = login and login.password or "",
    }
    table.insert(libraries, library)
    local ok, err = KindleFetchSettings:setLibraries(libraries)
    if not ok then
        return nil, err
    end
    Libraries.register()
    local sources = KindleFetchSettings:getSearchSources()
    table.insert(sources, Libraries.source(library))
    KindleFetchSettings:setSearchSources(sources)
    LogUtil.info(string.format("added the %s library %q", library.kind, library.name))
    return library
end

-- put library in place of the one with its id, e.g. once it has been renamed. returns true, or nil and why not
function Libraries.update(library)
    local libraries = KindleFetchSettings:getLibraries()
    for i, saved in ipairs(libraries) do
        if saved.id == library.id then
            libraries[i] = library
        end
    end
    local ok, err = KindleFetchSettings:setLibraries(libraries)
    if not ok then
        return nil, err
    end
    Libraries.register()
    LogUtil.info(string.format("changed the library %q", library.name))
    return true
end

-- remove the library with this id, which is no longer searched. returns true, or nil and why not
function Libraries.remove(id)
    local libraries = {}
    for __, library in ipairs(KindleFetchSettings:getLibraries()) do
        if library.id ~= id then
            table.insert(libraries, library)
        end
    end
    local ok, err = KindleFetchSettings:setLibraries(libraries)
    if not ok then
        return nil, err
    end
    Libraries.register()
    -- and untick it in the search box, where it would otherwise stay ticked for good
    local source = Libraries.source({ id = id })
    local sources = {}
    for __, ticked in ipairs(KindleFetchSettings:getSearchSources()) do
        if ticked ~= source then
            table.insert(sources, ticked)
        end
    end
    KindleFetchSettings:setSearchSources(sources)
    LogUtil.info("removed a library")
    return true
end

return Libraries
