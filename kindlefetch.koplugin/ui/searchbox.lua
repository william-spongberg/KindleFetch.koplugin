local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local UIManager = require("ui/uimanager")
local KindleFetchSettings = require("settings.settings")
local Sites = require("api.sites")
local MultiSearch = require("api.multisearch")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local T = require("ffi/util").template
local _ = require("gettext")

-- the search box: what's searched for, on which sites (see chooseSites) and narrowed down to what (see chooseScope)
local SearchBox = {}
SearchBox.__index = SearchBox

-- the name of what a search can be narrowed to (see SCOPES in Site), or of searching all a site does
local function scopeName(scope)
    return ({ title = _("Title"), author = _("Author"), isbn = _("ISBN") })[scope] or _("All")
end

-- whether source is among the sites in sources
local function isTicked(sources, source)
    for __, ticked in ipairs(sources) do
        if ticked == source then
            return true
        end
    end
    return false
end

-- what the Sites button says: the sites ticked, or that they all are, or all but one, which is shorter
local function sitesText(sources)
    local offered = MultiSearch.sources()
    if #sources == #offered then
        return _("Sites: All")
    end
    if #sources == #offered - 1 and #sources > 1 then
        for __, source in ipairs(offered) do
            if not isTicked(sources, source) then
                return T(_("Sites: All but %1"), Sites[source].NAME)
            end
        end
    end
    return T(_("Sites: %1"), MultiSearch.sitesName(sources))
end

-- the search box for sources, or those ticked last, with query and scope where given, searching through plugin
function SearchBox.new(plugin, query, scope, sources)
    local box = setmetatable({ plugin = plugin, scope = scope, sources = {} }, SearchBox)
    local chosen = sources or KindleFetchSettings:getSearchSources()
    local offered = MultiSearch.sources()
    for __, source in ipairs(offered) do
        if isTicked(chosen, source) then
            table.insert(box.sources, source)
        end
    end
    if #box.sources == 0 then
        box.sources = { offered[1] }
    end

    local buttons = {
        -- which sites to search (see chooseSites)
        {
            {
                text = box:sitesButtonText(),
                id = "sites",
                callback = function()
                    box:chooseSites()
                end,
            },
        },
        -- what the search is narrowed down to, on the sites that can be (see chooseScope)
        {
            {
                text = T(_("Search in: %1"), scopeName(box.scope)),
                id = "scope",
                callback = function()
                    box:chooseScope()
                end,
            },
        },
        {
            {
                text = "Cancel",
                callback = function()
                    UIManager:close(box.dialog)
                end,
            },
            {
                text = _("Recent"),
                id = "recent",
                enabled = #KindleFetchSettings:getRecentSearches() > 0,
                callback = function()
                    plugin:showRecentSearches()
                end,
            },
            {
                text = "Search",
                -- so the keyboard's enter key searches too
                is_enter_default = true,
                callback = function()
                    plugin:performSearch()
                end,
            },
        },
    }
    box.dialog = InputDialog:new {
        title = _("Search for books"),
        input = query,
        input_type = "text",
        buttons = buttons,
    }
    return box
end

function SearchBox:show()
    UIManager:show(self.dialog)
end

-- the sites ticked that can be searched now (see MultiSearch.canSearch), in the order they're offered
function SearchBox:sitesToSearch()
    local sources = {}
    for __, source in ipairs(self.sources) do
        if MultiSearch.canSearch(source) then
            table.insert(sources, source)
        end
    end
    return sources
end

-- what the Sites button says: the sites it searches, or those ticked where none can be yet (as Z-Library, logged out)
function SearchBox:sitesButtonText()
    local sources = self:sitesToSearch()
    return sitesText(#sources > 0 and sources or self.sources)
end

-- turn Recent on once there's a search to choose from, as there may have been none
function SearchBox:enableRecent()
    local recent = self.dialog.button_table and self.dialog.button_table:getButtonById("recent")
    if recent then
        recent:enable()
    end
end

-- tick the sites searched from now on (Z-Library only once logged into, logging in on ticking), keeping at least one
function SearchBox:chooseSites()
    local box = self
    local dialog
    local function shownTicked(source)
        return isTicked(box.sources, source) and MultiSearch.canSearch(source)
    end
    local function label(source)
        local text = (shownTicked(source) and "✓ " or "") .. Sites[source].NAME
        if not MultiSearch.canSearch(source) then
            return T(_("%1 (log in)"), text)
        end
        return text
    end
    local function tick(source, ticked)
        local sources = {}
        for __, site in ipairs(MultiSearch.sources()) do
            if site == source and ticked or site ~= source and isTicked(box.sources, site) then
                table.insert(sources, site)
            end
        end
        box.sources = sources
        LogUtil.info("searching", table.concat(sources, ", "), "from now on")
        local saved, err = KindleFetchSettings:setSearchSources(sources)
        if not saved then
            NotifyUtil.error(err)
        end
        local sites_button = box.dialog.button_table:getButtonById("sites")
        if sites_button then
            sites_button:setText(box:sitesButtonText(), sites_button.width)
            UIManager:setDirty(box.dialog, "ui")
        end
    end

    local rows = {}
    for __, source in ipairs(MultiSearch.sources()) do
        table.insert(rows, {
            {
                text = label(source),
                id = source,
                callback = function()
                    local ticked = shownTicked(source)
                    if ticked and #box:sitesToSearch() == 1 then
                        NotifyUtil.info(_("Choose at least one site to search"))
                        return
                    end
                    if
                        not ticked
                        and box.plugin:needsLogin(source, function()
                            tick(source, true)
                        end)
                    then
                        UIManager:close(dialog)
                        return
                    end
                    tick(source, not ticked)
                    local button = dialog.buttontable:getButtonById(source)
                    button:setText(label(source), button.width)
                    UIManager:setDirty(dialog, "ui")
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        title = _("Search on"),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end

-- choose what the search box narrows to (see SCOPES in Site): whatever any site can, as the rest search everything
function SearchBox:chooseScope()
    local box = self
    local dialog
    local row = {}
    local scopes, offered = { false }, {}
    for __, source in ipairs(MultiSearch.sources()) do
        for __, scope in ipairs(Sites[source].SCOPES or {}) do
            if not offered[scope] then
                offered[scope] = true
                table.insert(scopes, scope)
            end
        end
    end
    for __, scope in ipairs(scopes) do
        scope = scope or nil
        table.insert(row, {
            text = (scope == box.scope and "✓ " or "") .. scopeName(scope),
            callback = function()
                UIManager:close(dialog)
                box.scope = scope
                LogUtil.info("searching", scope and "by " .. scope or "all", "from now on")
                local scope_button = box.dialog.button_table:getButtonById("scope")
                scope_button:setText(T(_("Search in: %1"), scopeName(scope)), scope_button.width)
                UIManager:setDirty(box.dialog, "ui")
            end,
        })
    end
    dialog = ButtonDialog:new {
        title = _("Search in"),
        title_align = "center",
        buttons = { row },
    }
    UIManager:show(dialog)
end

return SearchBox
