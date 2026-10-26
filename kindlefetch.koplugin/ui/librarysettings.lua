local MultiInputDialog = require("ui/widget/multiinputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local KindleFetchSettings = require("settings.settings")
local Libraries = require("api.libraries")
local OpdsSearch = require("api.opdssearch")
local LibrarySites = require("util.librarysites")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local StringUtil = require("util.stringutil")
local BackgroundTask = require("ui.backgroundtask")
local Errors = require("util.errors")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")

-- the libraries added in the settings (see Libraries): adding one at its address, and editing and removing them
local LibrarySettings = {}

-- text as it's written in a web address, e.g. "%40" as "@"
local function unescape(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

-- the address asked at: http:// if it has none, no end slashes, no login (kept out of logs and curl's command line)
function LibrarySettings.normalise(address)
    address = StringUtil.trim(address)
    if address == "" then
        return nil
    end
    if not address:find("^%a[%w+.-]*://") then
        address = "http://" .. address
    end
    local username, password
    local scheme, userinfo, rest = address:match("^(%a[%w+.-]*://)([^/?#]*)@(.*)$")
    if scheme then
        username, password = userinfo:match("^([^:]*):?(.*)$")
        username, password = unescape(username), unescape(password)
        address = scheme .. rest
    end
    address = address:gsub("/+$", "")
    if not (StringUtil.isSafeUrl(address) and StringUtil.siteOf(address)) then
        return nil
    end
    return address, username, password
end

-- what kind of library it is, for showing (see OpdsSearch.CALIBRE)
local function kindName(kind)
    return ({
        [OpdsSearch.CALIBRE] = _("Calibre"),
        [OpdsSearch.CALIBRE_WEB] = _("Calibre-Web"),
    })[kind] or _("OPDS")
end

-- one of Calibre's libraries, searched at its own feed and library_id, as the server's search has the first one's
local function calibreLibrary(found, library)
    local id = library.url:match("[?&]library_id=([^&#]*)")
    local search_url = found.search_url
    if id then
        if search_url:find("[?&]library_id=") then
            search_url = search_url:gsub("([?&]library_id=)[^&#]*", "%1" .. id:gsub("%%", "%%%%"))
        else
            search_url = search_url .. (search_url:find("?", 1, true) and "&" or "?") .. "library_id=" .. id
        end
    end
    return { url = library.url, name = library.name, kind = found.kind, search_url = search_url }
end

-- look for a catalogue at address with login (see LibrarySites), saying so with a Cancel, then on_found or on_failed
local function find(address, login, on_found, on_failed)
    NetworkMgr:runWhenConnected(function()
        -- logging in to its site while it's looked for, then putting the sites back as the settings have them
        BackgroundTask.withMessage(
            "finding a library's catalogue",
            T(_("Looking for a library at %1..."), LogUtil.site(address)),
            function()
                LibrarySites.add(address, login)
                return Guard.pcall("finding a library's catalogue", OpdsSearch.discover, address)
            end,
            function(ok, found, err)
                if not ok then
                    found, err = nil, Errors.UNEXPECTED
                end
                if err == HttpUtil.CANCELLED then
                    LogUtil.info("looking for a library was called off")
                    return
                end
                if not found then
                    on_failed(err)
                    return
                end
                on_found(found)
            end,
            Libraries.register
        )
    end)
end

-- add each of the libraries found (each as OpdsSearch.discover finds one), saying so, then on_added()
local function addAll(libraries, login, on_added)
    local names = {}
    for __, found in ipairs(libraries) do
        local library, err = Libraries.add(found, login)
        if not library then
            NotifyUtil.error(err)
            return
        end
        table.insert(names, library.name)
    end
    NotifyUtil.info(
        T(_("Added %1, which is searched with the sites ticked in the search box"), table.concat(names, ", "))
    )
    if on_added then
        on_added()
    end
end

-- add the library found, or where it's Calibre's content server with several libraries, those of them chosen
local function addFound(found, login, on_added)
    if found.kind ~= OpdsSearch.CALIBRE or #found.libraries <= 1 then
        addAll({ found }, login, on_added)
        return
    end
    local dialog
    local libraries = {}
    for __, library in ipairs(found.libraries) do
        table.insert(libraries, calibreLibrary(found, library))
    end
    local buttons = {}
    for __, library in ipairs(libraries) do
        table.insert(buttons, {
            {
                text = library.name,
                callback = function()
                    UIManager:close(dialog)
                    addAll({ library }, login, on_added)
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = T(_("All %1"), #libraries),
            callback = function()
                UIManager:close(dialog)
                addAll(libraries, login, on_added)
            end,
        },
    })
    dialog = ButtonDialog:new {
        title = _("This Calibre has several libraries. Which would you like to add?"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- the username and password typed in, as a login (see LibrarySites), or nil where there's no username
local function loginOf(username, password)
    username = StringUtil.trim(username or "")
    if username == "" then
        return nil
    end
    return { username = username, password = password or "" }
end

-- ask for a library's address and any login, then add its catalogue (see addFound); fields are what was typed before
function LibrarySettings.add(on_added, fields)
    fields = fields or {}
    local dialog
    dialog = MultiInputDialog:new {
        title = _("Add a library"),
        fields = {
            { text = fields[1] or "", hint = _("Address, e.g. 192.168.1.10:8080") },
            { text = fields[2] or "", hint = _("Username, where it asks for one") },
            { text = fields[3] or "", hint = _("Password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local typed = dialog:getFields()
                        local address, username, password = LibrarySettings.normalise(typed[1])
                        if not address then
                            NotifyUtil.info(_("Enter the library's address, e.g. 192.168.1.10:8080"))
                            return
                        end
                        UIManager:close(dialog)
                        local login = loginOf(username or typed[2], password or typed[3])
                        find(address, login, function(found)
                            addFound(found, login, on_added)
                        end, function(err)
                            NotifyUtil.error(T(_("The library couldn't be added: %1"), err))
                            -- to put right what was typed
                            LibrarySettings.add(
                                on_added,
                                { address, login and login.username, login and login.password }
                            )
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- change the library's name, address or login, finding its catalogue again if the address or login changed
function LibrarySettings.edit(library, on_changed)
    local dialog
    dialog = MultiInputDialog:new {
        title = T(_("Edit %1"), library.name),
        fields = {
            { text = library.name, hint = _("Name") },
            { text = library.url, hint = _("Address") },
            { text = library.username, hint = _("Username, where it asks for one") },
            { text = library.password, hint = _("Password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local typed = dialog:getFields()
                        local address, username, password = LibrarySettings.normalise(typed[2])
                        if not address then
                            NotifyUtil.info(_("Enter the library's address, e.g. 192.168.1.10:8080"))
                            return
                        end
                        UIManager:close(dialog)
                        local name = StringUtil.trim(typed[1])
                        local login = loginOf(username or typed[3], password or typed[4])
                        local changed = {}
                        for key, value in pairs(library) do
                            changed[key] = value
                        end
                        changed.name = name ~= "" and name or library.name
                        local function save()
                            local ok, err = Libraries.update(changed)
                            if not ok then
                                NotifyUtil.error(err)
                                return
                            end
                            if on_changed then
                                on_changed()
                            end
                        end
                        if
                            address == library.url
                            and (login and login.username or "") == library.username
                            and (login and login.password or "") == library.password
                        then
                            save()
                            return
                        end
                        find(address, login, function(found)
                            changed.url, changed.kind, changed.search_url = found.url, found.kind, found.search_url
                            changed.username = login and login.username or ""
                            changed.password = login and login.password or ""
                            save()
                        end, function(err)
                            NotifyUtil.error(T(_("The library couldn't be changed: %1"), err))
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ask before removing the library, then call on_changed once it has been
function LibrarySettings.remove(library, on_changed)
    UIManager:show(ConfirmBox:new {
        text = T(_("Remove %1 from Kindle Fetch? Its books won't be searched any more."), library.name),
        ok_text = _("Remove"),
        ok_callback = function()
            local ok, err = Libraries.remove(library.id)
            if not ok then
                NotifyUtil.error(err)
                return
            end
            if on_changed then
                on_changed()
            end
        end,
    })
end

-- the libraries' names, for the settings, e.g. "Books, Comics", or None
function LibrarySettings.describe()
    local names = {}
    for __, library in ipairs(KindleFetchSettings:getLibraries()) do
        table.insert(names, library.name)
    end
    return #names > 0 and table.concat(names, ", ") or _("None")
end

-- the libraries added, to edit or remove, and adding another, in a menu from new_menu (see SettingsPage:newMenu)
function LibrarySettings.show(new_menu, on_changed)
    local menu
    local function items()
        local list = {
            {
                text = _("Add a library…"),
                callback = function()
                    LibrarySettings.add(function()
                        menu:switchItemTable(nil, items(), -1)
                        if on_changed then
                            on_changed()
                        end
                    end)
                end,
            },
        }
        for __, library in ipairs(KindleFetchSettings:getLibraries()) do
            table.insert(list, {
                text = StringUtil.joinDetails(library.name, kindName(library.kind)),
                callback = function()
                    local function changed()
                        menu:switchItemTable(nil, items(), -1)
                        if on_changed then
                            on_changed()
                        end
                    end
                    local dialog
                    dialog = ButtonDialog:new {
                        title = StringUtil.joinDetails(library.name, LogUtil.site(library.url)),
                        title_align = "center",
                        buttons = {
                            {
                                {
                                    text = _("Edit…"),
                                    callback = function()
                                        UIManager:close(dialog)
                                        LibrarySettings.edit(library, changed)
                                    end,
                                },
                                {
                                    text = _("Remove"),
                                    callback = function()
                                        UIManager:close(dialog)
                                        LibrarySettings.remove(library, changed)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(dialog)
                end,
            })
        end
        return list
    end
    menu = new_menu(_("Your Libraries"), items())
    UIManager:show(menu)
end

return LibrarySettings
