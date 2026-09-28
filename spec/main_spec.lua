local helper = require("helper")

describe("KindleFetch", function()
    local KindleFetch, checks

    -- KOReader creates a new plugin instance for the file manager and for every book that is opened
    local function openUI()
        return KindleFetch:new{
            ui = {
                menu = {
                    registerToMainMenu = function() end
                }
            }
        }
    end

    before_each(function()
        helper.reset()
        checks = {
            curl = 0,
            plugin = 0
        }

        helper.stub("settings.settings", {
            load = function() end
        })
        helper.stub("settings.settingspage", {})
        helper.stub("api.annasapi", {})
        helper.stub("api.lgliapi", {})
        helper.stub("ui.bookmenu", {})
        helper.stub("cache.covercache", {})
        helper.stub("updater.curlupdater", {
            checkVersion = function()
                checks.curl = checks.curl + 1
            end
        })
        helper.stub("updater.pluginupdater", {
            checkForUpdates = function()
                checks.plugin = checks.plugin + 1
            end
        })

        -- KOReader loads main.lua once per session
        KindleFetch = dofile("kindlefetch.koplugin/main.lua")
    end)

    describe("init", function()
        it("checks for updates once the UI is ready", function()
            openUI()
            assert.are.same({curl = 0, plugin = 0}, checks)

            helper.runScheduled()
            assert.are.same({curl = 1, plugin = 1}, checks)
        end)

        it("only checks for updates once per session", function()
            openUI()
            helper.runScheduled()
            openUI()
            openUI()
            helper.runScheduled()

            assert.are.same({curl = 1, plugin = 1}, checks)
        end)

        it("waits for a network connection before checking for updates", function()
            helper.stubs.network.connected = false
            openUI()
            helper.runScheduled()
            assert.are.same({curl = 0, plugin = 0}, checks)

            helper.stubs.network.connected = true
            openUI()
            helper.runScheduled()
            assert.are.same({curl = 1, plugin = 1}, checks)
        end)
    end)
end)
