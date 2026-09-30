local helper = require("helper")

describe("DownloadProgress", function()
    local cancels, widget

    before_each(function()
        helper.reset()
        cancels = 0
        widget = require("ui.downloadprogress").new("Dune", function()
            cancels = cancels + 1
        end)
    end)

    it("shows the book title", function()
        assert.are.equal("Dune", widget.text_widget.text)
    end)

    it("shows and closes", function()
        widget:show()
        assert.are.equal(widget.container, helper.lastShown())

        widget:close()
        assert.is_true(helper.wasClosed(widget.container))
    end)

    it("updates the progress bar and status", function()
        widget:update(0.25, "25% · 1.0 / 4.0 MB")
        assert.are.equal(0.25, widget.bar_widget.percentage)
        assert.are.equal("25% · 1.0 / 4.0 MB", widget.status_widget.text)

        widget:update(0.5)
        assert.are.equal(0.5, widget.bar_widget.percentage)
        assert.are.equal("25% · 1.0 / 4.0 MB", widget.status_widget.text)
    end)

    it("can be hidden while the download continues, and shown again", function()
        widget:show()
        local hidden_container = widget.container
        widget:toggleVisibility()
        assert.is_false(widget.is_visible)
        assert.is_true(helper.wasClosed(hidden_container))

        -- not redrawn or closed again while hidden
        widget:update(0.5, "50%")
        assert.are.equal(0, widget.bar_widget.percentage)
        local closes = #helper.state.closed
        widget:close()
        assert.are.equal(closes, #helper.state.closed)
        widget:show()
        assert.are.equal(1, #helper.state.shown)

        widget:toggleVisibility()
        assert.is_true(widget.is_visible)
        assert.are.equal(widget.container, helper.lastShown())
    end)

    -- KOReader frees widgets once closed, so showing the same ones again would crash
    it("makes new widgets when shown again, with the progress made while hidden", function()
        widget:show()
        local old = {
            container = widget.container,
            text = widget.text_widget,
            status = widget.status_widget,
            bar = widget.bar_widget,
        }
        widget:toggleVisibility()
        widget:update(0.5, "50% · 1.0 / 2.0 MB")
        widget:toggleVisibility()

        assert.are_not.equal(old.container, widget.container)
        assert.are_not.equal(old.text, widget.text_widget)
        assert.are_not.equal(old.status, widget.status_widget)
        assert.are_not.equal(old.bar, widget.bar_widget)
        assert.are.equal("Dune", widget.text_widget.text)
        assert.are.equal("50% · 1.0 / 2.0 MB", widget.status_widget.text)
        assert.are.equal(0.5, widget.bar_widget.percentage)
        assert.are.equal("Hide", widget.hide_button.text)
    end)

    it("cancels once and stops updating", function()
        widget:show()
        widget.cancel_button.callback()
        widget.cancel_button.callback()

        assert.are.equal(1, cancels)
        assert.is_true(widget.cancelled)
        assert.is_true(helper.wasClosed(widget.container))

        widget:update(0.5, "50%")
        assert.are.equal(0, widget.bar_widget.percentage)
    end)

    it("can be cancelled without a cancel callback", function()
        widget = require("ui.downloadprogress").new("Dune")
        widget:cancel()
        assert.is_true(widget.cancelled)
    end)
end)
