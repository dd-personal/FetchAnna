local helper = require("helper")

-- What's left of FetchAnna when an update doesn't work with this KOReader. Without it, FetchAnna would be gone from
-- KOReader's menu, update check included, until it was copied over USB.
describe("SafeMode", function()
    local plugin_path, registered

    -- Loads a version of FetchAnna that can't be loaded, as main.lua loads it.
    local function loadBroken()
        package.preload["fetchanna.plugin"] = function()
            error("fetchanna.lua:12: attempt to call field 'isKobo' (a nil value)")
        end
        package.loaded["fetchanna.safemode"] = helper.loadPluginFileFrom(plugin_path, "fetchanna/safemode.lua")
        local Plugin = dofile("fetchanna.koplugin/main.lua")
        Plugin:new {
            ui = {
                menu = {
                    registerToMainMenu = function(_, widget)
                        table.insert(registered, widget)
                    end,
                },
            },
        }
        local menu_items = {}
        registered[1]:addToMainMenu(menu_items)
        return menu_items.fetchanna
    end

    before_each(function()
        helper.reset()
        plugin_path = helper.tmpdir("plugins") .. "/fetchanna.koplugin"
        helper.writeFile(plugin_path .. "/main.lua", "-- v0.4")
        helper.writeFile(plugin_path .. "/version.txt", "0.4\n")
        registered = {}
    end)

    after_each(function()
        package.preload["fetchanna.plugin"] = nil
        helper.cleanup()
    end)

    it("shows FetchAnna's menu, saying it couldn't start, and why", function()
        local menu = loadBroken()
        assert.are.equal("FetchAnna", menu.text)
        assert.are.equal("FetchAnna couldn't start", menu.sub_item_table[1].text)
        assert.is_truthy(helper.logged("err", "^could not load FetchAnna:.*isKobo"))

        menu.sub_item_table[1].callback()
        assert.matches("^FetchAnna couldn't start: .*attempt to call field 'isKobo'", helper.lastError())
        assert.matches("See crash.log for where.$", helper.lastError())
    end)

    it("goes back to the version installed before the last update", function()
        helper.writeFile(plugin_path .. ".previous/main.lua", "-- v0.3")
        helper.writeFile(plugin_path .. ".previous/version.txt", "0.3\n")
        local go_back = loadBroken().sub_item_table[2]
        assert.are.equal("Go back to v0.3", go_back.text)
        assert.is_true(go_back.enabled)

        go_back.callback()
        helper.lastShown().ok_callback()
        assert.are.equal("-- v0.3", helper.readFile(plugin_path .. "/main.lua"))
        assert.are.same(
            { "FetchAnna has gone back to v0.3, which KOReader will use once it restarts." },
            helper.state.restart_prompts
        )
    end)

    it("can't go back when no version is kept from before", function()
        local go_back = loadBroken().sub_item_table[2]
        assert.are.equal("Go back to the version before", go_back.text)
        assert.is_false(go_back.enabled)
    end)
end)
