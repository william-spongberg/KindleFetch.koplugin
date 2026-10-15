local helper = require("helper")

-- rules the plugin's code keeps to everywhere, checked here so that they aren't forgotten in new code
describe("The plugin's code", function()
    local sources

    setup(function()
        sources = {}
        local pipe = io.popen("find kindlefetch.koplugin -name '*.lua' | sort")
        for path in pipe:lines() do
            sources[path] = helper.readFile(path)
        end
        pipe:close()
    end)

    -- each line of each file, without its comments, that has the pattern in it
    local function linesWith(pattern, except)
        local found = {}
        for path, source in pairs(sources) do
            if not (except and except[path]) then
                local number = 0
                for line in (source .. "\n"):gmatch("([^\n]*)\n") do
                    number = number + 1
                    local code = line:gsub("%-%-.*$", "")
                    if code:find(pattern) then
                        table.insert(found, string.format("%s:%d: %s", path, number, line))
                    end
                end
            end
        end
        table.sort(found)
        return found
    end

    -- which KOReader doesn't catch errors in (see Guard)
    it("schedules what runs later through Guard", function()
        assert.are.same({}, linesWith("UIManager:scheduleIn%(", { ["kindlefetch.koplugin/util/guard.lua"] = true }))
        assert.are.same({}, linesWith("UIManager:nextTick%(", { ["kindlefetch.koplugin/util/guard.lua"] = true }))
    end)

    it("wraps what Trapper runs in Guard", function()
        local unguarded = {}
        for _, line in ipairs(linesWith("Trapper:wrap%(")) do
            if not line:find("Trapper:wrap%(Guard%.wrap%(") then
                table.insert(unguarded, line)
            end
        end
        assert.are.same({}, unguarded)
    end)
end)
