-- Stand-ins for the KOReader modules the plugin requires, plus filesystem helpers for specs.
-- Specs call helper.reset() in before_each to get fresh stubs and freshly loaded plugin modules,
-- and helper.cleanup() in after_each to remove any temporary files.

local helper = {}

-- keep the unpatched functions somewhere that survives this file being loaded again
local originals = io.kindlefetch_spec_originals
    or {
        execute = os.execute,
        popen = io.popen,
        getenv = os.getenv,
        time = os.time,
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

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = deepCopy(v)
    end
    return copy
end
helper.deepCopy = deepCopy

local pwd = real_popen("pwd")
helper.ROOT = pwd:read("*l")
pwd:close()

-- relative on purpose: koreader's data dir is "." on kindle and kobo
helper.TMP_ROOT = "spec/.tmp"

-- guard against specs reaching the network or modifying the host system
local function guardCommand(cmd)
    -- curl run anywhere in the command, e.g. by the shell that saves its exit code (see CurlUtil.saveExitCode)
    if cmd:find("%f[%w]curl%s") then
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
    table.insert(helper.state.executed, cmd)
    for i = #helper.state.execute_stubs, 1, -1 do
        local stub = helper.state.execute_stubs[i]
        if cmd:find(stub.pattern, 1, true) then
            return stub.handler(cmd) or 0
        end
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
    local handle = {}
    function handle:read(format)
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
    end
    function handle:lines()
        return function()
            return self:read("*l")
        end
    end
    function handle:close()
        return true
    end
    return handle
end

io.popen = function(cmd, mode)
    table.insert(helper.state.popen_calls, cmd)
    for i = #helper.state.commands, 1, -1 do
        local stub = helper.state.commands[i]
        if cmd:find(stub.pattern, 1, true) then
            local output = stub.output
            if type(output) == "function" then
                output = output(cmd)
            end
            return fakeHandle(output or "")
        end
    end
    guardCommand(cmd)
    return real_popen(cmd, mode)
end

os.getenv = function(name)
    if helper.state.env[name] ~= nil then
        return helper.state.env[name] or nil
    end
    return originals.getenv(name)
end

os.time = function(...)
    if helper.state.time and select("#", ...) == 0 then
        return helper.state.time
    end
    return originals.time(...)
end

-- modules loaded before any spec runs are kept across resets
local baseline = {
    helper = true,
}
for name in pairs(package.loaded) do
    baseline[name] = true
end

-- a minimal version of KOReader's widget class hierarchy
local function widgetClass()
    local Widget = {}
    Widget.__index = Widget

    function Widget:extend(subclass)
        subclass = subclass or {}
        setmetatable(subclass, self)
        self.__index = self
        return subclass
    end

    function Widget:new(o)
        o = self:extend(o)
        if o.init then
            o:init()
        end
        return o
    end

    function Widget:setText(text)
        self.text = text
    end

    -- roughly the size text would take up, for widgets laid out by their size
    function Widget:getSize()
        return {
            w = self.width or #(self.text or "") * 10,
            h = self.height or 20,
        }
    end

    function Widget:free()
        self.freed = true
    end

    function Widget:clear()
        for i = #self, 1, -1 do
            self[i] = nil
        end
    end

    function Widget:resetLayout() end

    return Widget
end
helper.widgetClass = widgetClass

local function createStubs(state)
    local stubs = {}

    stubs.logger = {
        warn = function(...)
            table.insert(state.logs, { "warn", ... })
        end,
        dbg = function(...)
            table.insert(state.logs, { "dbg", ... })
        end,
        info = function(...)
            table.insert(state.logs, { "info", ... })
        end,
        err = function(...)
            table.insert(state.logs, { "err", ... })
        end,
    }

    stubs.gettext = setmetatable({
        -- the singular or plural of a translated message, for the number
        ngettext = function(singular, plural, n)
            return n == 1 and singular or plural
        end,
    }, {
        __call = function(_, text)
            return text
        end,
    })

    stubs.device = {
        kindle = true,
        sdl = false,
        android = false,
        home_dir = nil,
        -- KOReader's input, which can be told to ignore taps for a moment, kept in state.input_inhibited
        input = {
            inhibitInputUntil = function(_, set_or_seconds)
                state.input_inhibited = set_or_seconds
            end,
            setClipboardText = function(text)
                state.clipboard = text
            end,
            group = {
                Back = { "Back" },
            },
        },
        screen = {
            scaleBySize = function(_, size)
                return size
            end,
            getWidth = function()
                return 600
            end,
            getHeight = function()
                return 800
            end,
            getSize = function()
                return { w = 600, h = 800 }
            end,
        },
        isKindle = function(self)
            return self.kindle
        end,
        -- whether it has keys, such as Back, rather than only a touch screen
        hasKeys = function(self)
            return self.keys
        end,
        isSDL = function(self)
            return self.sdl
        end,
        isAndroid = function(self)
            return self.android
        end,
    }

    stubs.datastorage = {
        getDataDir = function()
            return assert(state.data_dir, "helper.state.data_dir must be set before requiring datastorage users")
        end,
        getSettingsDir = function(self)
            return self:getDataDir() .. "/settings"
        end,
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
            return mode and { mode = mode } or nil
        end,
        -- the names in a directory, like lfs.dir
        dir = function(path)
            local names = { ".", ".." }
            local pipe = real_popen("ls -A " .. quote(path) .. " 2>/dev/null")
            for name in pipe:lines() do
                table.insert(names, name)
            end
            pipe:close()
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
        -- the mode of what's at the path, without following a link to what it links to
        symlinkattributes = function(path, request)
            local mode
            if succeeded("test -L " .. quote(path)) then
                mode = "link"
            else
                mode = stubs.lfs.attributes(path, "mode")
            end
            if request == "mode" then
                return mode
            end
            return mode and { mode = mode } or nil
        end,
        mkdir = function(path)
            if succeeded("mkdir " .. quote(path) .. " 2>/dev/null") then
                return true
            end
            return nil, "could not create " .. path
        end,
        currentdir = function()
            return helper.ROOT
        end,
    }

    -- settings files live in state.settings_files, and like LuaSettings only change on flush
    stubs.luasettings = {
        open = function(_, path)
            local file = {
                data = deepCopy(state.settings_files[path]) or {},
            }
            function file:readSetting(key)
                return self.data[key]
            end
            function file:saveSetting(key, value)
                self.data[key] = value
            end
            function file:delSetting(key)
                self.data[key] = nil
            end
            -- (unless the storage can't be written, which LuaSettings doesn't say)
            function file:flush()
                if not state.settings_unwritable then
                    state.settings_files[path] = deepCopy(self.data)
                end
            end
            return file
        end,
    }

    stubs.uimanager = {
        show = function(_, widget)
            table.insert(state.shown, widget)
        end,
        close = function(_, widget)
            table.insert(state.closed, widget)
        end,
        isWidgetShown = function(_, widget)
            for _, shown in ipairs(state.shown) do
                if shown == widget then
                    for _, closed in ipairs(state.closed) do
                        if closed == widget then
                            return false
                        end
                    end
                    return true
                end
            end
            return false
        end,
        -- every refresh asked for is kept, as its type and the region of the screen it covers (none for all of it)
        setDirty = function(_, _, refresh, region)
            if type(refresh) == "function" then
                state.refresh = { refresh() }
                table.insert(state.refreshes, state.refresh)
            else
                table.insert(state.refreshes, { refresh, region })
            end
        end,
        forceRePaint = function() end,
        widgetInvert = function() end,
        yieldToEPDC = function() end,
        scheduleIn = function(_, _, fn)
            table.insert(state.scheduled, fn)
        end,
        broadcastEvent = function(_, event)
            table.insert(state.broadcasts, event.name)
        end,
        nextTick = function(_, fn)
            table.insert(state.scheduled, fn)
        end,
        -- KOReader's offer to restart, or saying it needs restarting where it can't restart itself
        askForRestart = function(_, text)
            table.insert(state.restart_prompts, text)
        end,
        -- how many things are keeping the device from going into standby, which KOReader asserts never goes below 0
        preventStandby = function()
            state.standby_prevented = state.standby_prevented + 1
        end,
        allowStandby = function()
            assert(state.standby_prevented > 0, "allowing standby that isn't prevented")
            state.standby_prevented = state.standby_prevented - 1
        end,
    }

    -- what plugins share with each other, such as whether AutoSuspend is to wait
    stubs.pluginshare = {}

    -- the parts of KOReader's ffi/util the plugin uses
    stubs.ffiutil = {
        -- a translated message with what's said in it put in place of %1, %2..., as KOReader does
        template = function(text, ...)
            local params = { ... }
            return (
                text:gsub("%%([1-9][0-9]?)", function(i)
                    return tostring(params[tonumber(i)])
                end)
            )
        end,
        -- KOReader runs what it's given in a process of its own; here it's run straight away, as if it had finished
        -- by the time it's checked on, keeping each one's pid in state.subprocesses (or failing to start, as fork
        -- does, when state.fork_fails is set)
        runInSubProcess = function(fn)
            if state.fork_fails then
                return false, "fork failed: Resource temporarily unavailable"
            end
            -- (above any pid Linux gives, so none is taken to be running)
            local pid = 5000000 + #state.subprocesses
            table.insert(state.subprocesses, pid)
            fn(pid)
            return pid
        end,
        -- whether a process has finished, collecting it, which they all have here, unless listed in
        -- state.subprocesses_running
        isSubProcessDone = function(pid)
            if state.subprocesses_running[pid] then
                return false
            end
            state.subprocesses_collected[pid] = true
            return true
        end,
    }

    stubs.inputdialog = {
        new = function(_, o)
            o = o or {}
            -- what's been typed, or what it was opened with
            o.getInputText = function(self)
                return self.input_text or self.input or ""
            end
            o.setInputText = function(self, text)
                self.input_text = text
            end
            o.onCloseKeyboard = function(self)
                self.keyboard_closed = true
            end
            o.onShowKeyboard = function(self)
                self.keyboard_shown = true
            end
            return o
        end,
    }

    -- KOReader's dialog with several boxes to type in, where what's typed in each is kept as its field's text
    stubs.multiinputdialog = {
        new = function(_, o)
            o = o or {}
            o.getFields = function(self)
                local texts = {}
                for _, field in ipairs(self.fields) do
                    table.insert(texts, field.text)
                end
                return texts
            end
            o.onShowKeyboard = function(self)
                self.keyboard_shown = true
            end
            return o
        end,
    }

    stubs.notification = {
        SOURCE_ALWAYS_SHOW = 1,
        notify = function(_, text)
            table.insert(state.notifications, text)
        end,
        -- a notification shown and closed by the plugin itself
        new = function(_, notification)
            notification.is_notification = true
            return notification
        end,
    }

    -- the parts of KOReader's util the plugin uses (the real one needs KOReader's ffi modules)
    stubs.util = {
        htmlEntitiesToUtf8 = function(text)
            text = text:gsub("&#(%d+);", function(code)
                return string.char(tonumber(code))
            end)
            text = text:gsub("&quot;", '"'):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&")
            return text
        end,
        urlEncode = function(url)
            if url == nil then
                return
            end
            url = url:gsub("\n", "\r\n")
            url = url:gsub("([^%w%-%._~])", function(c)
                return string.format("%%%02X", string.byte(c))
            end)
            return url
        end,
        getSafeFilename = function(name)
            return (name:gsub("/", "_"))
        end,
        -- KOReader's lowers the capitals of every alphabet, rather than only English's
        stringLower = function(text)
            return text and text:lower()
        end,
    }

    stubs.network = {
        connected = true,
        wifi_on = true,
        isConnected = function(self)
            return self.connected
        end,
        isWifiOn = function(self)
            return self.wifi_on
        end,
        promptWifiOn = function(self)
            state.wifi_prompts = (state.wifi_prompts or 0) + 1
            self.prompted = "turn wifi on"
        end,
        promptWifi = function(self)
            state.wifi_prompts = (state.wifi_prompts or 0) + 1
            self.prompted = "connect to wifi"
        end,
        -- as KOReader's: what luasocket goes through, saved as turned on, or off
        setHTTPProxy = function(_, proxy)
            stubs.http.PROXY = proxy
            if proxy then
                state.reader_settings.http_proxy = proxy
                state.reader_settings.http_proxy_enabled = true
            else
                state.reader_settings.http_proxy_enabled = false
            end
        end,
        -- like KOReader, turns wifi on (as the user has configured) and runs callback once connected
        runWhenConnected = function(self, callback)
            if self.connected then
                return callback()
            end
            self.prompted = "turn wifi on"
            self.when_connected = callback
        end,
    }

    stubs.event = {
        new = function(_, name, ...)
            return {
                name = name,
                args = { ... },
            }
        end,
    }

    stubs.dispatcher = {
        registerAction = function(_, name, action)
            state.actions[name] = action
        end,
    }

    stubs.widgetcontainer = widgetClass()

    -- luasocket
    stubs.http = {
        request = function()
            error("unstubbed http request", 2)
        end,
    }
    stubs.ltn12 = {
        -- what's sent, which here is kept as it is, so specs can read it
        source = {
            string = function(text)
                return {
                    text = text,
                }
            end,
        },
        sink = {
            table = function(t)
                return function(chunk)
                    if chunk then
                        table.insert(t, chunk)
                    end
                    return 1
                end
            end,
        },
    }
    -- KOReader's Trapper, which runs a function without holding up the rest of KOReader. here the function is just
    -- run, and the commands it waits for are kept in state.trapped (and aren't finished if state.dismiss is set, as
    -- when the widget that was given is tapped)
    stubs.trapper = {
        wrapped = false,
        wrap = function(self, fn)
            local wrapped = self.wrapped
            self.wrapped = true
            fn()
            self.wrapped = wrapped
            return true
        end,
        isWrapped = function(self)
            return self.wrapped
        end,
        dismissablePopen = function(_, cmd, trap_widget)
            table.insert(state.trapped, {
                cmd = cmd,
                trap_widget = trap_widget,
            })
            if state.dismiss then
                return false
            end
            local pipe = io.popen(cmd, "r")
            local output = pipe:read("*a")
            pipe:close()
            return true, output
        end,
    }

    -- KOReader's json, read with dkjson instead, which busted installs
    stubs.json = {
        decode = function(text)
            return (require("dkjson").decode(text))
        end,
    }

    -- KOReader's timeouts for luasocket, kept in state.http_timeouts while they're set
    stubs.socketutil = {
        set_timeout = function(_, answer_timeout, total_timeout)
            state.http_timeouts = { answer_timeout, total_timeout }
        end,
        reset_timeout = function()
            state.http_timeouts = nil
        end,
        table_sink = function(t)
            return stubs.ltn12.sink.table(t)
        end,
        -- writes what arrives to the file, which, unlike KOReader's, isn't closed, as the stand-ins for luasocket
        -- here don't say when the last of it has arrived
        file_sink = function(handle)
            return function(chunk)
                if chunk then
                    handle:write(chunk)
                end
                return 1
            end
        end,
    }

    -- KOReader's hashes, worked out with sha256sum and md5sum instead
    local function hash(command, message)
        local path = os.tmpname()
        local f = assert(io.open(path, "wb"))
        f:write(message)
        f:close()
        local pipe = real_popen(command .. " " .. quote(path))
        local digest = pipe:read("*l"):match("^(%x+)")
        pipe:close()
        os.remove(path)
        return digest
    end
    stubs.sha2 = {
        sha256 = function(message)
            return hash("sha256sum", message)
        end,
        -- given the whole message, or, as KOReader's can be, a piece at a time, then nothing for the md5
        md5 = function(message)
            if message then
                return hash("md5sum", message)
            end
            local pieces = {}
            local function append(piece)
                if not piece then
                    return hash("md5sum", table.concat(pieces))
                end
                table.insert(pieces, piece)
                return append
            end
            return append
        end,
    }

    -- widgets
    stubs.Menu = widgetClass()
    function stubs.Menu:onGotoPage(page)
        self.page = page
        return true
    end
    function stubs.Menu:onCloseWidget()
        self.close_widget_handled = true
    end
    -- show other entries, on the page with the given one, or the page that's showing for a negative one
    function stubs.Menu:switchItemTable(title, item_table, item_number)
        self.title = title or self.title
        self.item_table = item_table or self.item_table
        self.switched_to_item = item_number
    end
    stubs.InputContainer = widgetClass()
    stubs.geometry = {
        new = function(_, o)
            o = o or {}
            function o:copy()
                return stubs.geometry:new { x = self.x, y = self.y, w = self.w, h = self.h }
            end
            function o:combine()
                return self
            end
            function o:notIntersectWith(other)
                return self.outside
            end
            return o
        end,
    }
    stubs.downloadmgr = {
        new = function(_, o)
            function o:chooseDir()
                table.insert(state.dir_choosers, self)
            end
            return o
        end,
    }

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
    ["ui/widget/multiinputdialog"] = "multiinputdialog",
    ["ui/widget/notification"] = "notification",
    ["util"] = "util",
    ["ui/network/manager"] = "network",
    ["dispatcher"] = "dispatcher",
    ["ui/event"] = "event",
    ["ui/widget/container/widgetcontainer"] = "widgetcontainer",
    ["socket.http"] = "http",
    ["ltn12"] = "ltn12",
    ["socketutil"] = "socketutil",
    ["ffi/sha2"] = "sha2",
    ["json"] = "json",
    ["ui/trapper"] = "trapper",
    ["ui/widget/menu"] = "Menu",
    ["ui/widget/container/inputcontainer"] = "InputContainer",
    ["ui/geometry"] = "geometry",
    ["ui/downloadmgr"] = "downloadmgr",
    ["pluginshare"] = "pluginshare",
    ["ffi/util"] = "ffiutil",
}

-- widgets the plugin only builds and lays out
local WIDGET_MODULES = {
    "ui/gesturerange",
    "ui/widget/container/centercontainer",
    "ui/widget/container/framecontainer",
    "ui/widget/container/leftcontainer",
    "ui/widget/verticalgroup",
    "ui/widget/horizontalgroup",
    "ui/widget/verticalspan",
    "ui/widget/horizontalspan",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/widget/imagewidget",
    "ui/widget/button",
    "ui/widget/progresswidget",
    "ui/widget/confirmbox",
    "ui/widget/infomessage",
    "ui/widget/buttondialog",
    "ui/widget/iconwidget",
    "ui/widget/buttontable",
    "ui/widget/focusmanager",
    "ui/widget/textviewer",
}

local CONSTANT_MODULES = {
    ["ui/font"] = {
        getFace = function(_, name, size)
            return { name = name, size = size }
        end,
    },
    ["ui/size"] = {
        padding = { small = 2, default = 5, large = 10 },
        border = { thin = 1, default = 1, window = 2 },
        radius = { button = 7, window = 7 },
    },
    ["ffi/blitbuffer"] = {
        COLOR_WHITE = "white",
        COLOR_BLACK = "black",
        COLOR_LIGHT_GRAY = "light gray",
        COLOR_GRAY = "gray",
        COLOR_DARK_GRAY = "dark gray",
        COLOR_GRAY_4 = "gray 4",
        COLOR_GRAY_6 = "gray 6",
    },
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
        time = nil, -- fixed os.time() when set
        env = {}, -- os.getenv overrides, false to unset
        fs = {}, -- path -> "directory" | "file" | false, overrides the real filesystem
        settings_files = {},
        reader_settings = {},
        -- curl isn't there unless a spec says it is, so pages are fetched with luasocket
        commands = { { pattern = "curl --version", output = "" } },
        trapped = {},
        -- a Kindle's settings, such as whether its screensaver is held off, which are kept in lipc
        execute_stubs = {
            {
                pattern = "lipc-set-prop",
                handler = function(cmd)
                    table.insert(helper.state.lipc, cmd)
                end,
            },
        },
        lipc = {},
        standby_prevented = 0,
        subprocesses = {},
        subprocesses_running = {},
        subprocesses_collected = {},
        executed = {},
        popen_calls = {},
        shown = {},
        closed = {},
        refreshes = {},
        scheduled = {},
        broadcasts = {},
        notifications = {},
        restart_prompts = {},
        dir_choosers = {},
        actions = {},
        logs = {},
    }
    helper.stubs = createStubs(helper.state)

    for module_name, stub_name in pairs(MODULE_STUBS) do
        package.loaded[module_name] = helper.stubs[stub_name]
    end
    for _, module_name in ipairs(WIDGET_MODULES) do
        package.loaded[module_name] = widgetClass()
    end
    -- buttons that can't be tapped until they're enabled again, as KOReader's are dimmed
    local Button = package.loaded["ui/widget/button"]
    function Button:enable()
        self.enabled = true
    end
    function Button:disable()
        self.enabled = false
    end
    -- the characters TextBoxWidget uses for bold text
    local TextBoxWidget = package.loaded["ui/widget/textboxwidget"]
    -- how many lines its text wraps over, at 10px a character as in getSize, and how tall each is
    function TextBoxWidget:getVisLineCount()
        return math.max(1, math.ceil(#(self.text or "") * 10 / (self.width or 1)))
    end
    function TextBoxWidget:getLineHeight()
        return 20
    end
    TextBoxWidget.PTF_HEADER = "\u{FFF1}"
    TextBoxWidget.PTF_BOLD_START = "\u{FFF2}"
    TextBoxWidget.PTF_BOLD_END = "\u{FFF3}"
    for module_name, module in pairs(CONSTANT_MODULES) do
        package.loaded[module_name] = module
    end

    G_reader_settings = {
        isFalse = function(_, key)
            return helper.state.reader_settings[key] == false
        end,
        readSetting = function(_, key)
            return helper.state.reader_settings[key]
        end,
    }
end

-- replace a module with the given table
function helper.stub(module_name, module)
    package.loaded[module_name] = module
end

-- responses to real requests, kept for the whole run so each live page is only downloaded once
local live_responses = {}

-- use a stand-in for luasocket's http module that makes real requests with curl (luasocket's https
-- support needs luasec, which needs OpenSSL headers to build), so specs can scrape live pages
function helper.useLiveHttp()
    local http = {
        requests = {},
    }
    function http.request(request)
        table.insert(http.requests, request.url)
        local form = request.source and request.source.text
        local cookie = request.headers and request.headers["Cookie"]
        -- what other specs asking the same can share, unlike what a form or cookies were sent for, or a redirect
        -- that wasn't followed
        local shared = not form and not cookie and request.redirect ~= false
        local response = shared and live_responses[request.url]
        if not response then
            -- like luasocket, the timeout the plugin sets limits each wait for data rather than the whole transfer
            local timeout = helper.state.http_timeouts and helper.state.http_timeouts[1] or 60
            local headers_file = os.tmpname()
            local cmd = string.format(
                "curl -s%s --connect-timeout %d --speed-time %d --speed-limit 1 --max-time 120 -A %s -D %s "
                    .. "-w '\\n%%{http_code} %%{exitcode}' %s",
                request.redirect == false and "" or "L",
                timeout,
                timeout,
                quote(request.headers and request.headers["User-Agent"] or "curl"),
                quote(headers_file),
                quote(request.url)
            )
            if request.proxy then
                cmd = cmd .. " -x " .. quote(request.proxy)
            end
            -- the form and cookies in a file, rather than on curl's command line, as they can log into an account
            local config_file
            if form or cookie then
                config_file = os.tmpname()
                local config = io.open(config_file, "w")
                if form then
                    config:write(string.format('data = "%s"\n', form))
                end
                if cookie then
                    config:write(string.format('header = "Cookie: %s"\n', cookie))
                end
                config:close()
                cmd = cmd .. " -K " .. quote(config_file)
            end
            local pipe = real_popen(cmd)
            local output = pipe:read("*a")
            pipe:close()
            if config_file then
                os.remove(config_file)
            end

            -- the headers of the last response, with their names in lower case, as luasocket gives them
            local headers = {}
            local headers_f = io.open(headers_file, "r")
            local raw_headers = headers_f and headers_f:read("*a") or ""
            if headers_f then
                headers_f:close()
            end
            os.remove(headers_file)
            for line in (raw_headers:match(".*(HTTP/[^\n]*\n.*)$") or ""):gmatch("[^\r\n]+") do
                local name, value = line:match("^([^:]+):%s*(.*)$")
                if name then
                    headers[name:lower()] = value
                end
            end

            local body, code, exit_code = output:match("^(.*)\n(%d+) (%d+)$")
            code = tonumber(code)
            if not code or code == 0 or exit_code ~= "0" then
                return nil, "could not fetch " .. request.url .. " (curl exit code " .. tostring(exit_code) .. ")"
            end
            response = { body, code, headers }
            if shared then
                live_responses[request.url] = response
            end
        end
        request.sink(response[1])
        return 1, response[2], response[3]
    end
    package.loaded["socket.http"] = http
    return http
end

-- return output (a string, or a function of the command) for any io.popen command containing pattern
function helper.stubCommand(pattern, output)
    table.insert(helper.state.commands, {
        pattern = pattern,
        output = output,
    })
end

-- run handler(cmd) instead of any os.execute command containing pattern, returning its exit status (default 0)
function helper.stubExecute(pattern, handler)
    table.insert(helper.state.execute_stubs, {
        pattern = pattern,
        handler = handler,
    })
end

-- run the callbacks currently scheduled with UIManager:scheduleIn, but not ones they schedule
function helper.tick()
    local due = helper.state.scheduled
    helper.state.scheduled = {}
    for _, fn in ipairs(due) do
        fn()
    end
    return #due
end

-- run scheduled callbacks until nothing is left
function helper.runScheduled()
    local ticks = 0
    while #helper.state.scheduled > 0 do
        helper.tick()
        ticks = ticks + 1
        assert(ticks < 100, "scheduled callbacks keep rescheduling themselves")
    end
end

-- the first message logged at level (e.g. "info") that matches pattern, without the plugin's prefix
function helper.logged(level, pattern)
    for _, log in ipairs(helper.state.logs) do
        if log[1] == level then
            local parts = {}
            for i = 3, #log do
                table.insert(parts, tostring(log[i]))
            end
            local message = table.concat(parts, " ")
            if message:find(pattern) then
                return message
            end
        end
    end
end

function helper.lastNotification()
    return helper.state.notifications[#helper.state.notifications]
end

function helper.lastShown()
    return helper.state.shown[#helper.state.shown]
end

-- what the last message about something going wrong said (see NotifyUtil.error)
function helper.lastError()
    for i = #helper.state.shown, 1, -1 do
        if helper.state.shown[i].icon == "notice-warning" then
            return helper.state.shown[i].text
        end
    end
end

function helper.wasClosed(widget)
    for _, closed in ipairs(helper.state.closed) do
        if closed == widget then
            return true
        end
    end
    return false
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

function helper.readDir(path)
    local entries = {}
    local ls = real_popen("ls -A " .. quote(path) .. " 2>/dev/null")
    for entry in ls:lines() do
        table.insert(entries, entry)
    end
    ls:close()
    table.sort(entries)
    return entries
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
