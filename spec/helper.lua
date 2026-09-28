-- Stand-ins for the KOReader modules the plugin requires, plus filesystem helpers for specs.
-- Specs call helper.reset() in before_each to get fresh stubs and freshly loaded plugin modules,
-- and helper.cleanup() in after_each to remove any temporary files.

local helper = {}

-- keep the unpatched functions somewhere that survives this file being loaded again
local originals = io.kindlefetch_spec_originals or {
    execute = os.execute,
    popen = io.popen
}
io.kindlefetch_spec_originals = originals
local real_execute = originals.execute
local real_popen = originals.popen

local function quote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end
helper.quote = quote

local function succeeded(cmd)
    local ok = real_execute(cmd)
    return ok == true or ok == 0
end

local pwd = real_popen("pwd")
helper.ROOT = pwd:read("*l")
pwd:close()

-- relative on purpose: koreader's data dir is "." on kindle and kobo
helper.TMP_ROOT = "spec/.tmp"

-- guard against specs reaching the network or modifying the host system
local function guardCommand(cmd)
    if cmd:match("^%(?curl%s") then
        error("unstubbed network command: " .. cmd, 3)
    end
    if cmd:find("mntroot", 1, true) or cmd:find("/usr/bin/curl", 1, true) then
        error("spec tried to modify the system: " .. cmd, 3)
    end
end

-- KOReader runs on LuaJIT, where os.execute returns the raw exit status (0 on success) rather than
-- Lua 5.2+'s true/nil, so emulate that when needed to make `os.execute(cmd) ~= 0` checks behave as on device
os.execute = function(cmd)
    if cmd == nil then
        return real_execute()
    end
    guardCommand(cmd)
    local ok, how, code = real_execute(cmd)
    if type(ok) == "number" then
        return ok
    end
    if ok then
        return 0
    end
    return how == "exit" and code * 256 or code
end

local function fakeHandle(output)
    local pos = 1
    return {
        read = function(_, format)
            if format == "*a" or format == "a" or format == "*all" then
                local rest = output:sub(pos)
                pos = #output + 1
                return rest
            end
            if pos > #output then
                return nil
            end
            local newline = output:find("\n", pos, true)
            local line = output:sub(pos, newline and newline - 1 or #output)
            pos = newline and newline + 1 or #output + 1
            return line
        end,
        close = function()
            return true
        end
    }
end

io.popen = function(cmd, mode)
    table.insert(helper.state.popen_calls, cmd)
    for i = #helper.state.commands, 1, -1 do
        local stub = helper.state.commands[i]
        if cmd:find(stub.pattern, 1, true) then
            return fakeHandle(stub.output)
        end
    end
    guardCommand(cmd)
    return real_popen(cmd, mode)
end

-- modules loaded before any spec runs are kept across resets
local baseline = {
    helper = true
}
for name in pairs(package.loaded) do
    baseline[name] = true
end

local function createStubs(state)
    local stubs = {}

    stubs.logger = {
        warn = function(...) table.insert(state.logs, {"warn", ...}) end,
        dbg = function(...) table.insert(state.logs, {"dbg", ...}) end,
        info = function(...) table.insert(state.logs, {"info", ...}) end,
        err = function(...) table.insert(state.logs, {"err", ...}) end
    }

    stubs.gettext = setmetatable({}, {
        __call = function(_, text)
            return text
        end
    })

    stubs.device = {
        sdl = false,
        android = false,
        home_dir = nil,
        screen = {
            getSize = function()
                return {w = 600, h = 800}
            end
        },
        isSDL = function(self)
            return self.sdl
        end,
        isAndroid = function(self)
            return self.android
        end
    }

    stubs.datastorage = {
        getDataDir = function()
            return assert(state.data_dir, "helper.state.data_dir must be set before requiring datastorage users")
        end,
        getSettingsDir = function(self)
            return self:getDataDir() .. "/settings"
        end
    }

    stubs.lfs = {
        attributes = function(path, request)
            local mode
            if state.fs[path] ~= nil then
                mode = state.fs[path] or nil
            elseif succeeded("test -d " .. quote(path)) then
                mode = "directory"
            elseif succeeded("test -f " .. quote(path)) then
                mode = "file"
            end
            if request == "mode" then
                return mode
            end
            return mode and {mode = mode} or nil
        end,
        mkdir = function(path)
            if succeeded("mkdir " .. quote(path) .. " 2>/dev/null") then
                return true
            end
            return nil, "could not create " .. path
        end,
        currentdir = function()
            return helper.ROOT
        end
    }

    stubs.luasettings = {
        open = function(_, path)
            state.settings_files[path] = state.settings_files[path] or {}
            local data = state.settings_files[path]
            return {
                readSetting = function(_, key)
                    return data[key]
                end,
                saveSetting = function(_, key, value)
                    data[key] = value
                end,
                flush = function() end
            }
        end
    }

    stubs.uimanager = {
        show = function(_, widget)
            table.insert(state.shown, widget)
        end,
        close = function(_, widget)
            table.insert(state.closed, widget)
        end,
        setDirty = function() end,
        forceRePaint = function() end,
        scheduleIn = function(_, _, fn)
            table.insert(state.scheduled, fn)
        end
    }

    stubs.inputdialog = {
        new = function(_, o)
            return o or {}
        end
    }

    stubs.notification = {
        SOURCE_ALWAYS_SHOW = 1,
        notify = function(_, text)
            table.insert(state.notifications, text)
        end
    }

    stubs.util = {
        htmlEntitiesToUtf8 = function(text)
            return text
        end,
        getSafeFilename = function(name)
            return name
        end
    }

    stubs.network = {
        connected = true,
        isConnected = function(self)
            return self.connected
        end,
        isWifiOn = function(self)
            return self.connected
        end,
        promptWifiOn = function() end,
        promptWifi = function() end
    }

    stubs.dispatcher = {
        registerAction = function() end
    }

    -- mirrors Widget:new, which calls init on new instances
    local WidgetContainer = {}
    function WidgetContainer:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        if o.init then
            o:init()
        end
        return o
    end
    stubs.widgetcontainer = WidgetContainer

    return stubs
end

local MODULE_STUBS = {
    ["logger"] = "logger",
    ["gettext"] = "gettext",
    ["device"] = "device",
    ["datastorage"] = "datastorage",
    ["libs/libkoreader-lfs"] = "lfs",
    ["luasettings"] = "luasettings",
    ["ui/uimanager"] = "uimanager",
    ["ui/widget/inputdialog"] = "inputdialog",
    ["ui/widget/notification"] = "notification",
    ["util"] = "util",
    ["ui/network/manager"] = "network",
    ["dispatcher"] = "dispatcher",
    ["ui/widget/container/widgetcontainer"] = "widgetcontainer",
    ["ui/downloadmgr"] = false,
    ["ui/widget/menu"] = false
}

-- unload plugin modules and install fresh stubs
function helper.reset()
    helper.cleanup()

    for name in pairs(package.loaded) do
        if not baseline[name] then
            package.loaded[name] = nil
        end
    end

    helper.state = {
        data_dir = nil,
        fs = {}, -- path -> "directory" | "file" | false, overrides the real filesystem
        settings_files = {},
        commands = {},
        popen_calls = {},
        shown = {},
        closed = {},
        scheduled = {},
        notifications = {},
        logs = {}
    }
    helper.stubs = createStubs(helper.state)

    for module_name, stub_name in pairs(MODULE_STUBS) do
        package.loaded[module_name] = stub_name and helper.stubs[stub_name] or {}
    end
end

-- replace a module with the given table
function helper.stub(module_name, module)
    package.loaded[module_name] = module
end

-- return output for any io.popen command containing pattern
function helper.stubCommand(pattern, output)
    table.insert(helper.state.commands, {
        pattern = pattern,
        output = output
    })
end

-- run callbacks passed to UIManager:scheduleIn
function helper.runScheduled()
    while #helper.state.scheduled > 0 do
        table.remove(helper.state.scheduled, 1)()
    end
end

function helper.lastNotification()
    return helper.state.notifications[#helper.state.notifications]
end

-- filesystem

local tmp_count = 0

function helper.run(cmd)
    if not succeeded(cmd) then
        error("command failed: " .. cmd, 2)
    end
end

function helper.cleanup()
    helper.run("rm -rf " .. quote(helper.TMP_ROOT))
end

-- create a fresh directory under spec/.tmp, returned as a path relative to the repo root
function helper.tmpdir(name)
    tmp_count = tmp_count + 1
    local path = string.format("%s/%d-%s", helper.TMP_ROOT, tmp_count, name)
    helper.run("mkdir -p " .. quote(path))
    return path
end

function helper.abs(path)
    return helper.ROOT .. "/" .. path
end

function helper.exists(path)
    return succeeded("test -e " .. quote(path))
end

function helper.isDir(path)
    return succeeded("test -d " .. quote(path))
end

function helper.writeFile(path, content)
    helper.run("mkdir -p " .. quote(path:match("^(.*)/[^/]*$")))
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

function helper.readFile(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

-- copy a plugin source file into plugin_path and load it from there, as KOReader would
function helper.loadPluginFileFrom(plugin_path, relative_path)
    local target = plugin_path .. "/" .. relative_path
    helper.writeFile(target, assert(helper.readFile("kindlefetch.koplugin/" .. relative_path)))
    return dofile(target)
end

helper.reset()

return helper
