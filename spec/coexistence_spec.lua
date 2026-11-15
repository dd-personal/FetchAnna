local helper = require("helper")

-- FetchAnna is a fork of KindleFetch, and both can be installed at once. KOReader loads every plugin's modules into one
-- package.loaded and searches every plugin's folder (see PluginLoader in KOReader's frontend), so a module named like
-- one of KindleFetch's would be KindleFetch's if that loaded first. So FetchAnna shares no names with it: modules,
-- files, folders, events or actions.
describe("FetchAnna installed alongside KindleFetch", function()
    local PLUGIN = "fetchanna.koplugin"
    -- KindleFetch's modules are in these folders, and at its root.
    local KINDLEFETCH_DIRS = { "api", "cache", "settings", "ui", "updater", "util" }
    local KINDLEFETCH_ROOT_MODULES = { "kindlefetch", "safemode" }
    -- Every file by its path in the plugin, and each .lua file's code without comments.
    local files, code
    local data_dir

    before_each(function()
        helper.reset()
        data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
    end)

    setup(function()
        files, code = {}, {}
        local pipe = io.popen("cd " .. PLUGIN .. " && find . -type f | sort")
        for path in pipe:lines() do
            path = path:gsub("^%./", "")
            files[path] = true
            if path:find("%.lua$") then
                local source = helper.readFile(PLUGIN .. "/" .. path)
                code[path] = source:gsub("%-%-%[(=*)%[.-%]%1%]", ""):gsub("%-%-[^\n]*", "")
            end
        end
        pipe:close()
    end)

    -- Returns each match of pattern in the plugin's code, as "path: match".
    local function found(pattern)
        local matches = {}
        for path, source in pairs(code) do
            for match in source:gmatch(pattern) do
                table.insert(matches, path .. ": " .. match)
            end
        end
        table.sort(matches)
        return matches
    end

    describe("its modules", function()
        it("are all in fetchanna/, but for the files KOReader looks for at the plugin's root", function()
            local at_root = {}
            for path in pairs(files) do
                if not path:find("^fetchanna/") then
                    table.insert(at_root, path)
                end
            end
            table.sort(at_root)
            assert.are.same({ "_meta.lua", "main.lua", "version.txt" }, at_root)
        end)

        -- A name worked out at run time couldn't be checked here.
        it("are only ever required by name", function()
            assert.are.same({}, found("require%s*%(%s*[^\"'%s][^)]*%)"))
            assert.are.same({}, found("require%s+[^\"'%s(]"))
        end)

        it("are required by their names in fetchanna/", function()
            local outside = {}
            for __, name in ipairs(found("require%s*%(%s*[\"']([^\"']+)[\"']")) do
                local module = name:match(": (.+)$")
                if files[module:gsub("%.", "/") .. ".lua"] and not module:find("^fetchanna%.") then
                    table.insert(outside, name)
                end
            end
            assert.are.same({}, outside)
        end)

        -- For example "util.httputil", which would be KindleFetch's wherever it's loaded.
        it("never name one of KindleFetch's", function()
            local theirs = {}
            for __, dir in ipairs(KINDLEFETCH_DIRS) do
                for __, match in ipairs(found("[\"'](" .. dir .. "%.[%w_]+)[\"']")) do
                    table.insert(theirs, match)
                end
            end
            for __, module in ipairs(KINDLEFETCH_ROOT_MODULES) do
                for __, match in ipairs(found("[\"'](" .. module .. ")[\"']")) do
                    table.insert(theirs, match)
                end
            end
            table.sort(theirs)
            assert.are.same({}, theirs)
        end)

        it("load FetchAnna's own, even once KindleFetch's of the same names are loaded", function()
            -- KindleFetch's load first, as when its folder sorts first.
            local kindlefetch = {}
            for path in pairs(files) do
                local module = path:match("^fetchanna/(.+)%.lua$")
                if module then
                    module = module == "plugin" and "kindlefetch" or module:gsub("/", ".")
                    kindlefetch[module] = setmetatable({}, {
                        __index = function(__, key)
                            error("used KindleFetch's " .. module .. "." .. tostring(key))
                        end,
                    })
                    package.loaded[module] = kindlefetch[module]
                end
            end

            local ok, err = pcall(function()
                local LogUtil = require("fetchanna.util.logutil")
                LogUtil.info("loaded alongside KindleFetch")
                local Settings = require("fetchanna.settings.settings")
                Settings:setShowBookCovers(false)
                require("fetchanna.api.sources")
            end)
            for module in pairs(kindlefetch) do
                package.loaded[module] = nil
            end
            assert(ok, err)
        end)
    end)

    describe("what it keeps on the device", function()
        it("is in a settings file of its own", function()
            local Settings = require("fetchanna.settings.settings")
            Settings:setShowBookCovers(false)
            assert.is_table(helper.state.settings_files[data_dir .. "/settings/fetchanna_settings.lua"])
            assert.is_nil(helper.state.settings_files[data_dir .. "/settings/kindlefetch_settings.lua"])
        end)

        -- Unrelated to KindleFetch's mirrors, kept in its URL cache (see AnnasMirrors).
        it("keeps Anna's Archive's sites in a file of its own", function()
            require("fetchanna.util.originpolicy").resolve = function()
                return nil
            end
            assert.is_true(require("fetchanna.api.annasmirrors"):reset())
            assert.is_table(helper.state.settings_files[data_dir .. "/settings/fetchanna_mirrors.lua"])
        end)

        it("is in caches of its own", function()
            local others = {}
            local caches = found('Cache:new%s*{%s*filename%s*=%s*"([^"]+)"')
            for __, match in ipairs(caches) do
                if not match:find(": fetchanna_[%w_]+%.lua$") then
                    table.insert(others, match)
                end
            end
            assert.are.same({}, others)
            -- Searches and covers.
            assert.are.equal(2, #caches)
            assert.are.equal(
                data_dir .. "/settings/fetchanna_covers/1.jpg",
                require("fetchanna.cache.covercache"):getPath("1")
            )
        end)

        -- Both are emptied when KOReader starts (see CurlUtil.removeLeftovers) and after updating (see PathUtil), so a
        -- shared folder would lose KindleFetch's work in progress.
        it("is in temporary folders of its own", function()
            assert.are.equal(data_dir .. "/cache/fetchanna", require("fetchanna.util.pathutil").getTmpPath())
            assert.matches(
                "^" .. data_dir:gsub("%p", "%%%0") .. "/settings/fetchanna_tmp/curl_download_",
                require("fetchanna.util.curlutil").createPageFile()
            )
        end)

        -- Except its description in KOReader's plugin list, which says what it's based on.
        it("is never named after KindleFetch", function()
            local named = {}
            for __, match in ipairs(found("[^\n]*[Kk][Ii][Nn][Dd][Ll][Ee][ _%-]?[Ff][Ee][Tt][Cc][Hh][^\n]*")) do
                if not match:find("^_meta%.lua: ") then
                    table.insert(named, match)
                end
            end
            assert.are.same({}, named)
        end)
    end)

    -- KOReader sends these to every plugin, so with KindleFetch's names both plugins would act.
    describe("its events and actions", function()
        it("are named after FetchAnna", function()
            local others = {}
            for __, match in ipairs(found('registerAction%(%s*"([^"]+)"')) do
                if not match:find(": fetchanna_") then
                    table.insert(others, match)
                end
            end
            for __, pattern in ipairs({ 'event%s*=%s*"([^"]+)"', 'Event:new%(%s*"([^"]+)"' }) do
                for __, match in ipairs(found(pattern)) do
                    if not match:find(": FetchAnna") then
                        table.insert(others, match)
                    end
                end
            end
            assert.are.same({}, others)
        end)
    end)
end)
