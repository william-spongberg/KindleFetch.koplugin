local H = require("helpers")

-- the menu at the top left of the results, which shows only some of the books found, without searching again
describe("Showing only some of the books found", function()
    after_each(H.closeAll)

    -- tap the icon at the results' top left, returning the button in the menu it opens whose text starts with start
    local function resultsMenuButton(menu, start)
        H.tap(assert(
            H.find(function(widget)
                return widget.icon == "appbar.menu" and widget.onTapIconButton
            end, menu),
            "no menu at the top left of the results"
        ))
        return H.waitFor("the results' menu", 10, function()
            return H.find(function(widget)
                return widget.onTapSelectButton
                    and type(widget.text) == "string"
                    and widget.text:sub(1, #start) == start
            end)
        end)
    end

    -- the entry in the list of what the books found have to tick whose text starts with start
    local function entry(list, start)
        return H.find(function(widget)
            return type(widget.text) == "string" and widget.text:sub(1, #start) == start and widget.onTapSelect
        end, list)
    end

    -- tick or untick the site in the list, waiting for it to show
    local function tap(list, site, ticked)
        H.tap(assert(entry(list, (ticked and "☐ " or "☑ ") .. site), site .. " isn't listed"))
        H.waitFor(site .. " to be " .. (ticked and "ticked" or "unticked"), 10, function()
            return entry(list, (ticked and "☑ " or "☐ ") .. site)
        end)
    end

    it("hides the books of a site unticked, without searching again, but not every book", function()
        -- which both have Pride and Prejudice, while Library Genesis can't be reached
        local plugin = H.startSearch(H.BOOK_QUERY, { "Internet Archive", "Project Gutenberg" })
        local menu = H.waitFor("both sites' books", 120, function()
            assert(not H.errorShown(), H.errorShown())
            return plugin.books_menu and H.isShown(plugin.books_menu) and plugin.search:isDone() and plugin.books_menu
        end)
        local counts = { archive = 0, gutenberg = 0 }
        for _, book in ipairs(H.books(menu)) do
            counts[book.source] = counts[book.source] + 1
        end
        assert(counts.archive > 0 and counts.gutenberg > 0, "both sites should have found books")
        local found = counts.archive + counts.gutenberg

        H.tap(resultsMenuButton(menu, "Sites: All"))
        local list = H.waitFor("the sites to tick", 10, function()
            return H.find(function(widget)
                return widget.title == "Sites" and widget.item_table
            end)
        end)
        assert(entry(list, string.format("☑ Internet Archive (%d)", counts.archive)), "Internet Archive's count")
        tap(list, "Project Gutenberg", false)
        H.shot("filter-sites")

        -- every site unticked isn't taken
        tap(list, "Internet Archive", false)
        local since = #H.notifications
        list:onClose()
        H.waitForNotification("That would hide every book found.", 10, since)
        assert(H.isShown(list), "the sites were closed with none ticked")

        tap(list, "Internet Archive", true)
        list:onClose()
        H.waitFor("only Internet Archive's books", 10, function()
            return not H.isShown(list) and #H.books(menu) == counts.archive
        end)
        for _, book in ipairs(H.books(menu)) do
            H.eq("archive", book.source, "source")
        end
        -- (which KOReader's menu changes on its title bar, rather than its own title)
        H.eq(string.format("%s · %d of %d books", H.BOOK_QUERY, counts.archive, found), menu.title_bar.title, "title")
        H.eq(1, menu.page, "page")

        -- which the menu says, offering to show them all again
        local show_all = resultsMenuButton(menu, "Show all")
        H.eq(string.format("Show all %d books", found), show_all.text, "Show all")
        assert(H.findButton("Sites: Internet Archive"), "the menu doesn't say which sites are shown")
        H.shot("filter-results-menu")
        H.tap(show_all)
        H.waitFor("every book again", 10, function()
            return #H.books(menu) == found
        end)

        -- and offers to change the settings and search again
        H.tap(resultsMenuButton(menu, "Search again…"))
        H.waitFor("what can be changed to search again", 10, function()
            return H.findButton("Languages…") and H.findButton("File types…")
        end)
        H.shot("filter-search-again")
    end)
end)
