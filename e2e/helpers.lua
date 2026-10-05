-- Helpers for driving KOReader's UI in the end-to-end tests: waiting for things to happen, finding widgets
-- on screen, tapping them, and taking screenshots.

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local time = require("ui/time")

local H = {}

H.work_dir = os.getenv("E2E_WORK")
H.books_dir = H.work_dir .. "/books"
H.profile_name = os.getenv("E2E_PROFILE")
H.profile = require("profiles")[H.profile_name]

-- run whatever KOReader has scheduled that is due, and redraw the screen
function H.pump()
    UIManager:setInputTimeout(0)
    UIManager:handleInput()
end

function H.sleep(seconds)
    ffiUtil.usleep(math.floor(seconds * 1000000))
end

-- keep KOReader running until check() returns something, which is then returned
function H.waitFor(what, timeout, check)
    local deadline = os.time() + timeout
    while true do
        H.pump()
        local result = check()
        if result then
            return result
        end
        if os.time() > deadline then
            error(string.format("timed out after %ds waiting for %s", timeout, what), 2)
        end
        H.sleep(0.2)
    end
end

-- like waitFor, but returns nil rather than failing when the time is up
function H.poll(timeout, check)
    local ok, result = pcall(H.waitFor, "", timeout, check)
    return ok and result or nil
end

function H.eq(expected, actual, what)
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

-- widgets on screen, from the top one down
function H.windows()
    local windows = {}
    for i = #UIManager._window_stack, 1, -1 do
        table.insert(windows, UIManager._window_stack[i].widget)
    end
    return windows
end

function H.isShown(widget)
    for _, window in ipairs(H.windows()) do
        if window == widget then
            return true
        end
    end
    return false
end

-- skip references back to the rest of KOReader, so searches stay within the widget
local SKIP_FIELDS = {
    ui = true,
    document = true,
    view = true,
    show_parent = true,
}

-- the first widget on screen (or inside root) that predicate accepts, searching the top window first
function H.find(predicate, root)
    local visited = {}
    local function search(widget, depth)
        if type(widget) ~= "table" or visited[widget] or depth > 60 then
            return nil
        end
        visited[widget] = true
        local ok, found = pcall(predicate, widget)
        if ok and found then
            return widget
        end
        for key, child in pairs(widget) do
            if type(child) == "table" and not SKIP_FIELDS[key] then
                local result = search(child, depth + 1)
                if result then
                    return result
                end
            end
        end
    end

    if root then
        return search(root, 0)
    end
    for _, window in ipairs(H.windows()) do
        local result = search(window, 0)
        if result then
            return result
        end
    end
end

function H.findButton(text, root)
    return H.find(function(widget)
        return widget.onTapSelectButton and widget.text == text
    end, root)
end

-- tap the middle of a widget, as a finger would
function H.tap(widget)
    assert(widget, "nothing to tap")
    local dimen = widget.dimen
    assert(dimen and dimen.x, "can't tap a widget that hasn't been drawn")
    UIManager:sendEvent(Event:new("Gesture", {
        ges = "tap",
        pos = Geom:new {
            x = dimen.x + math.floor(dimen.w / 2),
            y = dimen.y + math.floor(dimen.h / 2),
            w = 0,
            h = 0,
        },
        time = time.now(),
    }))
    H.pump()
end

function H.tapButton(text, root)
    H.pump()
    H.tap(assert(H.findButton(text, root), "no button labelled " .. text))
end

-- follow a path through KOReader's main menu, e.g. {"Kindle Fetch", "Settings"}
function H.openMainMenu(path)
    local ui = H.fileManager()
    ui.menu:onShowMenu()
    H.pump()

    local touch_menu = H.find(function(widget)
        return widget.tab_item_table and widget.switchMenuTab
    end)
    assert(touch_menu, "main menu didn't open")

    local function itemText(item)
        return item.text or (item.text_func and item.text_func())
    end

    -- the tab with the first entry
    for tab_num, tab in ipairs(touch_menu.tab_item_table) do
        for _, item in ipairs(tab) do
            if itemText(item) == path[1] then
                touch_menu:switchMenuTab(tab_num)
                break
            end
        end
    end
    H.pump()

    for _, text in ipairs(path) do
        local function findItem()
            return H.find(function(widget)
                return widget.item and widget.onTapSelect and itemText(widget.item) == text
            end, touch_menu)
        end

        -- turn the menu's pages until the entry is showing, as a user would
        local menu_item = H.poll(3, findItem)
        for _ = 1, 10 do
            if menu_item then
                break
            end
            touch_menu:onNextPage()
            menu_item = H.poll(3, findItem)
        end
        assert(menu_item, "no menu entry " .. text)
        H.tap(menu_item)
    end
end

-- what to search for: a popular book, mostly in other languages on the first pages of Library Genesis' results
H.SEARCH_QUERY = "harry potter and the chamber of secrets"
-- a public domain book to search for and download, so the tests don't download books under copyright
H.BOOK_QUERY = "pride and prejudice austen"

-- whether a book is Jane Austen's own Pride and Prejudice, rather than one of the newer books based on it
function H.isPublicDomain(book)
    local title = book.title:lower():gsub("&", "and"):gsub("%s+", " ")
    local authors = (book.authors or ""):lower()
    return title == "pride and prejudice" and (authors == "austen, jane" or authors == "jane austen")
end

-- search Library Genesis from KindleFetch's search dialog, returning the results menu
-- open the search dialog, type query and tap Search, returning KindleFetch and the dialog
function H.startSearch(query)
    H.openMainMenu({ "Kindle Fetch", "Search Library Genesis" })
    local plugin = H.plugin()
    local dialog = H.waitFor("the search dialog", 10, function()
        return plugin.search_box and H.isShown(plugin.search_box) and plugin.search_box
    end)
    dialog:setInputText(query)

    H.tapButton("Search", dialog)
    return plugin, dialog
end

-- search for query, returning the menu of books once they're found
function H.search(query)
    local plugin = H.startSearch(query)
    return H.waitFor("search results", 120, function()
        local failure = H.errorShown() or H.messageSaying("No books found") or H.messageSaying("but none in the")
        if failure then
            error("search failed: " .. failure, 0)
        end
        return plugin.books_menu and H.isShown(plugin.books_menu) and plugin.books_menu
    end)
end

-- search, tapping "Load more" until a book matching predicate is found, returning the results menu
function H.searchUntil(query, predicate, max_pages)
    local menu = H.search(query)
    for _ = 2, max_pages or 3 do
        for _, book in ipairs(H.books(menu)) do
            if predicate(book) then
                return menu
            end
        end
        local count = #H.books(menu)
        H.tapMenuEntry(menu, function(item)
            return item.text == "Load more"
        end)
        H.waitFor("more books", 120, function()
            local failure = H.errorShown()
            if failure then
                error(failure, 0)
            end
            return #H.books(menu) > count
        end)
    end
    return menu
end

function H.books(menu)
    local books = {}
    for _, item in ipairs(menu.item_table) do
        if item.book then
            table.insert(books, item.book)
        end
    end
    return books
end

-- turn to the page with the book (or other entry) and tap it
function H.tapMenuEntry(menu, predicate)
    local index
    for i, item in ipairs(menu.item_table) do
        if predicate(item) then
            index = i
            break
        end
    end
    assert(index, "no such entry in the menu")

    for page, indexes in ipairs(menu.page_items) do
        for _, i in ipairs(indexes) do
            if i == index then
                menu:onGotoPage(page)
            end
        end
    end
    H.pump()

    H.tap(assert(
        H.find(function(widget)
            return widget.entry == menu.item_table[index] and widget.onTapSelect
        end, menu),
        "the entry isn't showing"
    ))
end

function H.tapBook(menu, book)
    H.tapMenuEntry(menu, function(item)
        return item.book == book
    end)
end

-- close everything but the file manager
function H.closeAll()
    local FileManager = require("apps/filemanager/filemanager")
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        -- close the book and go back to the file manager, as the home button does
        ReaderUI.instance:onHome()
        H.fileManager()
    end
    for _, window in ipairs(H.windows()) do
        if window ~= FileManager.instance then
            UIManager:close(window)
        end
    end
    H.pump()
end

-- empty KindleFetch's caches, so each test finds everything afresh rather than relying on what earlier tests found
function H.clearCaches()
    require("cache.searchcache"):clear()
    require("cache.urlcache"):clear()
    require("cache.covercache"):clear()
end

-- put mirrors that don't work before the real ones: one that doesn't exist, and one that answers without any books.
-- returns them
function H.breakMirrors()
    local mirrors = assert(require("api.urlapi"):getLibgenUrls(), "couldn't look up the mirrors on Wikipedia")
    local broken = { "https://libgen.invalid", "https://example.com" }
    require("cache.urlcache"):set({ broken[1], broken[2], unpack(mirrors) }, "libgen")
    return broken
end

function H.fileManager()
    return H.waitFor("the file manager", 10, function()
        return require("apps/filemanager/filemanager").instance
    end)
end

-- KindleFetch's instance for the file manager or book being shown
function H.plugin()
    local ReaderUI = require("apps/reader/readerui")
    local FileManager = require("apps/filemanager/filemanager")
    local ui = ReaderUI.instance or FileManager.instance
    return ui and ui.kindlefetch
end

-- every notification shown, oldest first
H.notifications = {}
local Notification = require("ui/widget/notification")
local notify = Notification.notify
function Notification:notify(text, ...)
    table.insert(H.notifications, tostring(text))
    return notify(self, text, ...)
end

-- what a message on screen says, if there's one that includes text
function H.messageSaying(text)
    for _, window in ipairs(H.windows()) do
        if type(window.text) == "string" and window.text:find(text, 1, true) then
            return window.text
        end
    end
end

-- what a message on screen about something going wrong says, if there is one
function H.errorShown()
    for _, window in ipairs(H.windows()) do
        if window.icon == "notice-warning" and type(window.text) == "string" then
            return window.text
        end
    end
end

-- wait for a notification containing text, shown after the first `since` notifications
function H.waitForNotification(text, timeout, since)
    return H.waitFor("a notification saying " .. text, timeout, function()
        for i = (since or 0) + 1, #H.notifications do
            if H.notifications[i]:find(text, 1, true) then
                return H.notifications[i]
            end
        end
    end)
end

function H.shot(name)
    H.pump()
    Device.screen:shot(string.format("%s/screenshots/%s.png", H.work_dir, name))
end

-- run fn as if on the profile's kind of device, for the checks KindleFetch makes itself
function H.asDevice(fn)
    local originals = {
        isKindle = Device.isKindle,
        isKobo = Device.isKobo,
        isAndroid = Device.isAndroid,
        isSDL = Device.isSDL,
    }
    local profile = H.profile
    Device.isKindle = function()
        return profile.kindle == true
    end
    Device.isKobo = function()
        return profile.kobo == true
    end
    Device.isAndroid = function()
        return profile.android == true
    end
    Device.isSDL = function()
        return false
    end

    local ok, err = pcall(fn)
    for name, original in pairs(originals) do
        Device[name] = original
    end
    if not ok then
        error(err, 0)
    end
end

-- file size in bytes from Library Genesis' "523 kB" / "1 MB" style sizes
function H.sizeInBytes(size)
    local number, unit = tostring(size):match("([%d%.]+)%s*(%a*)")
    local units = {
        b = 1,
        kb = 1024,
        mb = 1024 * 1024,
        gb = 1024 * 1024 * 1024,
    }
    return (tonumber(number) or math.huge) * (units[(unit or ""):lower()] or 1)
end

return H
