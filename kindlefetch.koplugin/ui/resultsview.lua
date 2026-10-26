local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local KindleFetchSettings = require("settings.settings")
local SettingsPage = require("settings.settingspage")
local Sites = require("api.sites")
local MultiSearch = require("api.multisearch")
local BookMenu = require("ui.bookmenu")
local BookFilter = require("ui.bookfilter")
local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")
local NotifyUtil = require("util.notifyutil")
local Guard = require("util.guard")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

-- the menu of a search's books (see SearchSession), with what can be done with them from its top left menu
local ResultsView = {}
ResultsView.__index = ResultsView

-- whether the results show covers: when turned on, and KOReader's menu can lay them out (see BookMenu.isSupported)
local function coversShown()
    return BookMenu.isSupported() and KindleFetchSettings:getShowBookCovers()
end

-- session's results, downloading, loading more and searching again through plugin, then on_close(view) once closed
function ResultsView.new(plugin, session, on_close)
    return setmetatable({ plugin = plugin, session = session, on_close = on_close }, ResultsView)
end

-- the books shown (see SearchSession.isShown) as entries for the menu, then Load more where there's more
function ResultsView:menuItems()
    local view, session = self, self.session
    local menu_items = {}

    for __, book in ipairs(session.books) do
        if session:isShown(book) then
            table.insert(menu_items, {
                book = book,
                text = session:bookItemText(book),
                -- (where it's KOReader's own menu that lists them, see show)
                mandatory_func = function()
                    return session:isDownloaded(book) and _("Downloaded") or nil
                end,
                callback = function()
                    view.plugin:downloadBook(book)
                end,
            })
        end
    end

    -- the sites still searching, whose books are added once found, or Load more, where there's more
    local search = self.plugin.search
    if search and not search:isDone() then
        table.insert(menu_items, {
            still_searching = true,
            text = T(_("Still searching %1…"), MultiSearch.sitesName(search:pendingSources())),
            callback = function()
                NotifyUtil.info(
                    T(
                        _("The books %1 finds are added here once it has."),
                        MultiSearch.sitesName(view.plugin.search:pendingSources())
                    )
                )
            end,
        })
    elseif session:hasMore() then
        table.insert(menu_items, {
            text = _("Load more"),
            callback = function()
                view.plugin:loadMoreBooks()
            end,
        })
    end

    return menu_items
end

-- the query and how many books were found, for the top of the results, and how many are shown, where only some are
function ResultsView:title()
    local session = self.session
    local count = #session.books
    if session:isFiltering() then
        return T(_("%1 · %2 of %3 books"), session.query, session:countShown(), count)
    end
    -- there may be more to load, or still to come
    local more = session:hasMore() or self.plugin.search and not self.plugin.search:isDone()
    local found = more and T(_("%1+ books"), count) or T(N_("1 book", "%1 books", count), count)
    return string.format("%s · %s", session.query, found)
end

-- show the books, returning the menu
function ResultsView:show()
    local view, session = self, self.session

    -- or as KOReader's own menu lists things, where its menu can't lay them out with their covers
    local MenuClass = BookMenu.isSupported() and BookMenu or Menu
    local menu
    menu = MenuClass:new {
        title = self:title(),
        -- rather than cutting a long search short
        title_shrink_font_to_fit = true,
        -- what can be done with the books found (see showMenu)
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            view:showMenu()
        end,
        -- the Search button KOReader offers on tapping the page number looks through the books found
        search_callback = function(text)
            view:filterBooks(text)
        end,
        item_table = self:menuItems(),
        covers_fullscreen = true,
        is_borderless = true,
        -- with square corners: rounded ones aren't painted, and show what was on screen before
        is_popout = false,
        width = self.plugin.dimen.w,
        height = self.plugin.dimen.h,
        items_max_lines = true,
        -- so books that have been downloaded already are marked as such
        is_downloaded = function(book)
            return session:isDownloaded(book)
        end,
        -- and which site each was found on, where several were searched
        source_name = session.several_sites and function(book)
            return Sites[book.source] and Sites[book.source].NAME
        end or nil,
        -- once closed (as with its X), call off the sites still searching, whose books would have nowhere to go
        close_callback = function()
            view.on_close(view)
        end,
        onPageChange = Guard.wrap("loading covers", function(page)
            if coversShown() then
                LogUtil.debug("loading covers for page", page)
                menu:loadCoversForPage(page)
            end
        end, Guard.quiet),
    }
    self.menu = menu

    UIManager:show(menu)
    UIManager:setDirty(menu, "full")

    -- load covers for first page
    if coversShown() then
        LogUtil.debug("loading covers for page 1")
        menu:loadCoversForPage(1)
    end
    return menu
end

-- list the books again as more are found, on the same page or the itemnumber'th book's, and load the covers on it
function ResultsView:refresh(itemnumber)
    local menu = self.menu
    menu:switchItemTable(self:title(), self:menuItems(), itemnumber or -1)
    if coversShown() then
        LogUtil.debug("loading covers for page", menu.page)
        menu:loadCoversForPage(menu.page)
    end
end

-- once all are done, end with Load more if there's more, unless the end is the same, as listing again reloads covers
function ResultsView:finish()
    local menu = self.menu
    local items, shown = self:menuItems(), menu.item_table
    local last, was = items[#items], shown[#shown]
    if #items ~= #shown or (last and last.text) ~= (was and was.text) then
        menu:switchItemTable(self:title(), items, -1)
    end
end

-- list the books shown again, from the first, once what's shown has changed (see SearchSession.isShown)
function ResultsView:showFromFirst()
    local menu = self.menu
    menu:switchItemTable(self:title(), self:menuItems(), 1)
    if coversShown() then
        menu:loadCoversForPage(1)
    end
end

-- show only the books with text in their title, authors or file type, whatever its capitals, unless none have it
function ResultsView:filterBooks(text)
    local session = self.session
    text = StringUtil.trim(text)
    local previous = session.filter
    session.filter = text ~= "" and text or nil

    local shown = session:countShown()
    if shown == 0 then
        local hiding = BookFilter.isHiding(session.hidden)
        session.filter = previous
        NotifyUtil.message(
            hiding and T(_("None of the books shown have “%1” in them."), text)
                or T(_("None of the books found have “%1” in them."), text)
        )
        return
    end
    LogUtil.info(string.format("showing %d of the %d books found, looking for %q", shown, #session.books, text))
    self:showFromFirst()
end

-- tick the books' values for filter (see BookFilter.FILTERS) to show only those, with counts, never hiding every book
function ResultsView:chooseShown(filter)
    local session = self.session
    local values = BookFilter.values(session.books, filter, function(book)
        return session:isDownloaded(book)
    end)
    local hidden = session.hidden[filter.id] or {}
    local choices, ticked = {}, {}
    for __, value in ipairs(values) do
        table.insert(choices, { text = T(_("%1 (%2)"), value.text, value.count), code = value.code })
        if not hidden[value.code] then
            table.insert(ticked, value.code)
        end
    end
    SettingsPage:tickSeveral(
        filter.name,
        choices,
        ticked,
        function(shown)
            local before = session.hidden[filter.id]
            session.hidden[filter.id] = BookFilter.hiding(values, shown)
            if session:countShown() == 0 then
                session.hidden[filter.id] = before
                NotifyUtil.info(_("That would hide every book found."))
                return false
            end
        end,
        _("That would hide every book found."),
        function(changed)
            -- (rather than going back to the first page, where nothing has)
            if changed then
                LogUtil.info(
                    string.format(
                        "showing %d of the %d books found, by %s",
                        session:countShown(),
                        #session.books,
                        filter.id
                    )
                )
                self:showFromFirst()
            end
        end
    )
end

-- ask for text to look through the books found for (see filterBooks)
function ResultsView:askForFilter()
    local view = self
    local dialog
    dialog = InputDialog:new {
        title = _("Look through the books found for"),
        input = self.session.filter or "",
        input_hint = _("Title, author or file type"),
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
                    text = _("Look through"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        view:filterBooks(text)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- the results' top left menu: looking through them, showing only some (see chooseShown) or all, and searching again
function ResultsView:showMenu()
    local view, session = self, self.session
    local dialog
    local buttons = {
        {
            {
                text = _("Look through the books found…"),
                callback = function()
                    UIManager:close(dialog)
                    view:askForFilter()
                end,
            },
        },
    }
    for __, filter in ipairs(BookFilter.FILTERS) do
        -- (whether each book has been downloaded is only looked up once it's asked for, see BookFilter.values)
        local values = filter.fixed or BookFilter.values(session.books, filter)
        if BookFilter.isOffered(filter, values) then
            table.insert(buttons, {
                {
                    text = T(_("%1: %2"), filter.name, BookFilter.describe(values, session.hidden[filter.id])),
                    callback = function()
                        UIManager:close(dialog)
                        view:chooseShown(filter)
                    end,
                },
            })
        end
    end
    if session:isFiltering() then
        table.insert(buttons, {
            {
                text = T(_("Show all %1 books"), #session.books),
                callback = function()
                    UIManager:close(dialog)
                    session:showAll()
                    view:showFromFirst()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Search again…"),
            callback = function()
                UIManager:close(dialog)
                view:searchAgain()
            end,
        },
    })
    dialog = ButtonDialog:new {
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- change the languages, file types or book types chosen, from the results, then search again (see changeChoices)
function ResultsView:searchAgain()
    local view = self
    local dialog
    -- narrowing the search down, or widening it, searching again (see KindleFetch.changeChoices)
    local changes = {
        { text = _("Languages…"), change = SettingsPage.changeLanguages },
        { text = _("File types…"), change = SettingsPage.changeFileTypes },
    }
    for __, source in ipairs(self.plugin:sitesToSearch()) do
        if Sites[source].HAS_BOOK_TYPES then
            table.insert(changes, { text = _("Book types…"), change = SettingsPage.changeBookTypes })
            break
        end
    end
    local row = {}
    for __, choice in ipairs(changes) do
        table.insert(row, {
            text = choice.text,
            callback = function()
                UIManager:close(dialog)
                view.plugin:changeChoices(choice.change)
            end,
        })
    end
    dialog = ButtonDialog:new {
        title = _("Change the settings, and search again:"),
        buttons = { row },
    }
    UIManager:show(dialog)
end

return ResultsView
