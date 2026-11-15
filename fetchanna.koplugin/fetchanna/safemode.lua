local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Rollback = require("fetchanna.updater.rollback")
local T = require("ffi/util").template
local _ = require("gettext")

-- What's left of FetchAnna when it can't be loaded or started (see main.lua): a menu that says so and why, and offers
-- to go back to the version before the last update, while one is kept (see Rollback). Uses only KOReader itself, as
-- FetchAnna's own modules may be what's broken.
local SafeMode = {}

-- The plugin's folder, from where this file was loaded. PathUtil may be what's broken.
local PLUGIN_PATH = debug.getinfo(1, "S").source:match("^@(.+)/fetchanna/safemode%.lua$")

-- Swaps back to the previous version, once confirmed, then offers to restart KOReader to load it.
local function goBack(previous_version)
    UIManager:show(ConfirmBox:new {
        text = T(_("Go back to FetchAnna v%1?"), previous_version),
        ok_text = _("Go back"),
        ok_callback = function()
            local ok, err = Rollback.goBack(PLUGIN_PATH)
            if not ok then
                UIManager:show(InfoMessage:new {
                    text = T(_("Going back failed: %1"), err),
                    icon = "notice-warning",
                })
                return
            end
            UIManager:askForRestart(
                T(_("FetchAnna has gone back to v%1, which KOReader will use once it restarts."), previous_version)
            )
        end,
    })
end

-- Adds FetchAnna's menu with only what's left. err is why it couldn't start.
function SafeMode.addToMainMenu(menu_items, err)
    local previous_version = PLUGIN_PATH and Rollback.previousVersion(PLUGIN_PATH)
    -- The error without its traceback, which is in crash.log.
    local reason = tostring(err):match("^[^\n]*")
    menu_items.fetchanna = {
        text = _("FetchAnna"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("FetchAnna couldn't start"),
                callback = function()
                    UIManager:show(InfoMessage:new {
                        text = T(_("FetchAnna couldn't start: %1\n\nSee crash.log for where."), reason),
                        icon = "notice-warning",
                    })
                end,
            },
            {
                text = previous_version and T(_("Go back to v%1"), previous_version)
                    or _("Go back to the version before"),
                -- One is only kept once FetchAnna has updated itself.
                enabled = previous_version ~= nil,
                callback = function()
                    goBack(previous_version)
                end,
            },
        },
    }
end

-- Returns a stand-in plugin with only that menu, for when FetchAnna couldn't be loaded.
function SafeMode.new(err)
    local Plugin = WidgetContainer:extend {
        name = "fetchanna",
        is_doc_only = false,
    }
    function Plugin:init()
        self.ui.menu:registerToMainMenu(self)
    end
    function Plugin:addToMainMenu(menu_items)
        SafeMode.addToMainMenu(menu_items, err)
    end
    return Plugin
end

-- Shows that menu in place of FetchAnna's own, when it couldn't start. Registers it again in case init failed before it
-- had. If it had, the same menu is only added twice.
function SafeMode.takeOver(plugin, err)
    plugin.addToMainMenu = function(__, menu_items)
        SafeMode.addToMainMenu(menu_items, err)
    end
    if plugin.ui and plugin.ui.menu then
        plugin.ui.menu:registerToMainMenu(plugin)
    end
end

return SafeMode
