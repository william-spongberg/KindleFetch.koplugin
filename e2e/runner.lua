-- Boots a real KOReader without a window, with KindleFetch installed, and runs the end-to-end tests in
-- e2e/*_e2e.lua against it. Started by e2e/run.sh from KOReader's own folder, which sets:
--   E2E_REPO     the repository's root
--   E2E_PROFILE  the device to emulate (see profiles.lua)
--   E2E_WORK     this run's folder, for downloaded books and screenshots
--   E2E_FILTER   only run tests whose name contains this, if set
--   KO_HOME      KOReader's data folder, with KindleFetch linked into its plugins folder
-- Lines starting with E2E| are results, everything else is KOReader's log.

local ffi = require("ffi")
ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);]]

local repo = assert(os.getenv("E2E_REPO"), "run the end-to-end tests with e2e/run.sh")
package.path = repo .. "/e2e/?.lua;" .. package.path
local profile_name = os.getenv("E2E_PROFILE")
local profile = assert(require("profiles")[profile_name], "unknown device profile " .. tostring(profile_name))

local function report(...)
    io.stdout:write("E2E|", string.format(...), "\n")
    io.stdout:flush()
end

-- emulate the device's screen, drawing offscreen rather than in a window
ffi.C.setenv("SDL_VIDEO_DRIVER", "offscreen", 1)
ffi.C.setenv("EMULATE_READER_W", tostring(profile.width), 1)
ffi.C.setenv("EMULATE_READER_H", tostring(profile.height), 1)
ffi.C.setenv("EMULATE_READER_DPI", tostring(profile.dpi), 1)

-- boot KOReader, as reader.lua does
require("setupkoenv")
G_defaults = require("luadefaults"):open()
local DataStorage = require("datastorage")
G_reader_settings = require("luasettings"):open(DataStorage:getDataDir() .. "/settings.reader.lua")
-- run button callbacks straight away, rather than after flashing the button
G_reader_settings:makeFalse("flash_ui")

local Device = require("device")
Device.screen:init()
require("document/canvascontext"):init(Device)
Device.input.dummy = true

local H = require("helpers")

-- KOReader loads every copy of a plugin it finds, so leave out any copy of KindleFetch installed in KOReader
-- itself (e.g. rsynced into the Flatpak to try it out), and test only the one linked into KO_HOME
local PluginLoader = require("pluginloader")
local discover = PluginLoader._discover
function PluginLoader:_discover()
    local plugins = {}
    for _, plugin in ipairs(discover(self)) do
        if plugin.name ~= "kindlefetch" or plugin.path:find(os.getenv("KO_HOME"), 1, true) == 1 then
            table.insert(plugins, plugin)
        end
    end
    return plugins
end

-- opening the file manager loads the plugins, adding KindleFetch's modules to package.path
require("apps/filemanager/filemanager"):showFiles(H.books_dir)
H.fileManager()
H.pump()

-- download books into this run's folder
require("settings.settings"):setDownloadDir(H.books_dir)

-- a small describe/it test runner

local root = {
    children = {},
    before_each = {},
    after_each = {}
}
local current = root

function describe(name, fn)
    local block = {
        name = name,
        parent = current,
        children = {},
        before_each = {},
        after_each = {}
    }
    table.insert(current.children, block)
    local previous = current
    current = block
    fn()
    current = previous
end

function it(name, fn)
    table.insert(current.children, {
        name = name,
        parent = current,
        test = fn
    })
end

function before_each(fn)
    table.insert(current.before_each, fn)
end

function after_each(fn)
    table.insert(current.after_each, fn)
end

local ls = io.popen("ls " .. repo .. "/e2e/*_e2e.lua")
for file in ls:lines() do
    dofile(file)
end
ls:close()

local function fullName(node)
    local names = {}
    while node and node.name do
        table.insert(names, 1, node.name)
        node = node.parent
    end
    return table.concat(names, " ")
end

local filter = os.getenv("E2E_FILTER")
local passed, failed, count = 0, 0, 0

local function runTest(node)
    local name = fullName(node)
    if filter and filter ~= "" and not name:find(filter, 1, true) then
        return
    end
    count = count + 1

    local chain = {}
    local block = node.parent
    while block do
        table.insert(chain, 1, block)
        block = block.parent
    end

    local started = os.time()
    local ok, err = xpcall(function()
        for _, b in ipairs(chain) do
            for _, fn in ipairs(b.before_each) do
                fn()
            end
        end
        node.test()
    end, debug.traceback)

    if not ok then
        pcall(H.shot, "failed-" .. count)
    end
    for i = #chain, 1, -1 do
        for _, fn in ipairs(chain[i].after_each) do
            local after_ok, after_err = xpcall(fn, debug.traceback)
            if ok and not after_ok then
                ok, err = false, after_err
            end
        end
    end

    if ok then
        passed = passed + 1
        report("  ok    %s (%ds)", name, os.time() - started)
    else
        failed = failed + 1
        report("  FAIL  %s (%ds)", name, os.time() - started)
        for line in tostring(err):gmatch("[^\n]+") do
            report("          %s", line)
        end
        report("          screenshot: %s/screenshots/failed-%d.png", H.work_dir, count)
    end
end

local function walk(block)
    for _, child in ipairs(block.children) do
        if child.test then
            runTest(child)
        else
            walk(child)
        end
    end
end

report("%s (%dx%d, %d dpi)", profile.description, profile.width, profile.height, profile.dpi)
walk(root)
report("%d passed, %d failed", passed, failed)

os.exit(failed == 0 and 0 or 1)
