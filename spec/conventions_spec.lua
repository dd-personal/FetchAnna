local helper = require("helper")

-- Rules the plugin's code keeps everywhere, checked so new code doesn't forget them.
describe("The plugin's code", function()
    local sources

    setup(function()
        sources = {}
        local pipe = io.popen("find fetchanna.koplugin -name '*.lua' | sort")
        for path in pipe:lines() do
            sources[path] = helper.readFile(path)
        end
        pipe:close()
    end)

    -- Returns every line with the pattern, ignoring comments.
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

    -- KOReader doesn't catch errors in scheduled functions (see Guard).
    it("schedules what runs later through Guard", function()
        assert.are.same(
            {},
            linesWith("UIManager:scheduleIn%(", { ["fetchanna.koplugin/fetchanna/util/guard.lua"] = true })
        )
        assert.are.same(
            {},
            linesWith("UIManager:nextTick%(", { ["fetchanna.koplugin/fetchanna/util/guard.lua"] = true })
        )
    end)

    -- Other code passes on what went wrong, so the UI says it once (see NotifyUtil).
    it("only says things from what's on screen", function()
        local said = {}
        for _, line in ipairs(linesWith("NotifyUtil%.")) do
            -- Relative to fetchanna/, where all but main.lua and _meta.lua are.
            local path = line:match("^fetchanna%.koplugin/([^:]+)"):gsub("^fetchanna/", "")
            if path:find("^api/") or path:find("^cache/") or path == "settings/settings.lua" then
                table.insert(said, line)
            elseif path:find("^util/") and path ~= "util/notifyutil.lua" and path ~= "util/guard.lua" then
                table.insert(said, line)
            end
        end
        assert.are.same({}, said)
    end)

    -- A variable named _ hides gettext's _, so text in its scope isn't translated, or fails.
    it("doesn't name what's left unused _ where _ translates", function()
        local hidden = {}
        for path, source in pairs(sources) do
            if source:find('local _ = require("gettext")', 1, true) then
                local number = 0
                for line in (source .. "\n"):gmatch("([^\n]*)\n") do
                    number = number + 1
                    local code = line:gsub("%-%-.*$", "")
                    if code:find("for _[ ,=]") or code:find("function[%w%.:%s]*%([^)]*%f[%w_]_[,)]") then
                        table.insert(hidden, string.format("%s:%d: %s", path, number, line))
                    end
                end
            end
        end
        table.sort(hidden)
        assert.are.same({}, hidden)
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
