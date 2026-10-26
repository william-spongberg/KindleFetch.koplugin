local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")

-- the added libraries' sites and their logins, looked up by site so each is only sent to its own, and never logged
local LibrarySites = {}

-- each site's { login = { username = ..., password = ... } }, or { login = false } where it needs none
local sites = {}

-- add the site of the library at url, with login where it has a username, replacing any; false if not a web address
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

-- the login for the site url is on, where it's a library's that needs one, otherwise nil
function LibrarySites.loginFor(url)
    local site = StringUtil.siteOf(url)
    local entry = site and sites[site]
    return entry and entry.login or nil
end

return LibrarySites
