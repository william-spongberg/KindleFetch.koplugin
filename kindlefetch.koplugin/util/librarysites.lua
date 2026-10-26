local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")

-- the sites of the libraries the user has added, by their sites (see StringUtil.siteOf), with the username and
-- password to log in to each with, where it needs them. what fetches pages and downloads books and covers looks a
-- site's login up here (see loginFor), so that it's only ever sent to its own site, rather than e.g. to the other
-- sites whose covers are on the same page of results, or wherever a library's site sends a request on to. the
-- passwords are never logged (see LogUtil.hide)
local LibrarySites = {}

-- each site's { login = { username = ..., password = ... } }, or { login = false } where it needs none
local sites = {}

-- add the site of the library at url (any address on it), logging in to it with login ({ username = ..., password =
-- ... }), where given with a username, in place of what was added for its site before. returns false when url isn't
-- a web address
function LibrarySites.add(url, login)
    local site = StringUtil.siteOf(url)
    if not site then
        return false
    end
    if type(login) == "table" and StringUtil.assertValidString(login.username) then
        LogUtil.hide(login.password)
        sites[site] = { login = { username = login.username, password = login.password or "" } }
    else
        sites[site] = { login = false }
    end
    return true
end

-- forget the sites added, e.g. before adding those of the libraries again once they've changed
function LibrarySites.clear()
    sites = {}
end

-- whether url is on the site of one of the libraries added
function LibrarySites.isLibrary(url)
    local site = StringUtil.siteOf(url)
    return site ~= nil and sites[site] ~= nil
end

-- what to log in to the site url is on with, where it's a library's that needs it ({ username = ..., password = ...
-- }), otherwise nil
function LibrarySites.loginFor(url)
    local site = StringUtil.siteOf(url)
    local entry = site and sites[site]
    return entry and entry.login or nil
end

return LibrarySites
