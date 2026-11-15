local FetchAnnaSettings = require("fetchanna.settings.settings")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local DownloadMgr = require("ui/downloadmgr")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local NotifyUtil = require("fetchanna.util.notifyutil")
local SearchCache = require("fetchanna.cache.searchcache")
local CoverCache = require("fetchanna.cache.covercache")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local LogUtil = require("fetchanna.util.logutil")
local ProxyUtil = require("fetchanna.util.proxyutil")
local CurlUtil = require("fetchanna.util.curlutil")
local StringUtil = require("fetchanna.util.stringutil")
local PathUtil = require("fetchanna.util.pathutil")
local Diagnostics = require("fetchanna.ui.diagnostics")
local Rollback = require("fetchanna.updater.rollback")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local MirrorsPage = require("fetchanna.ui.mirrorspage")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

local SettingsPage = {}

-- Says when a setting couldn't be saved (see FetchAnnaSettings:setSetting).
local function saved(ok, err)
    if not ok then
        NotifyUtil.error(err)
    end
end

local function formatDays(days)
    return T(N_("1 day", "%1 days", days), days)
end

-- About as much of a folder's path as fits beside its label.
local MAX_FOLDER_LENGTH = 32

-- Returns the end of a long path, which says the most about it, e.g. "…/documents/books".
function SettingsPage.shortenFolder(path)
    if #path <= MAX_FOLDER_LENGTH then
        return path
    end
    local shortened = path
    while #shortened > MAX_FOLDER_LENGTH - 1 do
        local rest = shortened:match("^/?[^/]+(/.+)$")
        if not rest then
            break
        end
        shortened = rest
    end
    return "…" .. shortened
end

-- Returns the names of the chosen choices ({ text, code } each), or All when every one is.
local function describeChosen(choices, chosen)
    local is_chosen = {}
    for __, code in ipairs(chosen) do
        is_chosen[code] = true
    end
    local names = {}
    for __, choice in ipairs(choices) do
        if choice.code and is_chosen[choice.code] then
            table.insert(names, choice.text)
        end
    end
    local available = 0
    for __, choice in ipairs(choices) do
        if choice.code then
            available = available + 1
        end
    end
    if #names == available then
        return _("All")
    end
    return table.concat(names, ", ")
end

-- Returns the file types that can be chosen, under a heading for each kind.
local function fileTypeChoices()
    local categories = {
        {
            name = _("Ebooks"),
            types = FetchAnnaSettings:getEbookFileTypes(),
        },
        {
            name = _("Comics"),
            types = FetchAnnaSettings:getComicFileTypes(),
        },
        {
            name = _("Documents"),
            types = FetchAnnaSettings:getDocumentFileTypes(),
        },
        {
            name = _("Images"),
            types = FetchAnnaSettings:getImageFileTypes(),
        },
        {
            name = _("Web"),
            types = FetchAnnaSettings:getWebFileTypes(),
        },
    }

    local choices = {}
    for __, category in ipairs(categories) do
        table.insert(choices, {
            heading = category.name,
        })
        for __, ext in ipairs(category.types) do
            table.insert(choices, {
                text = ext,
                code = ext,
            })
        end
    end
    return choices
end

-- Returns how many of Anna's Archive's sites are sent the key, e.g. "3 sent your key".
local function describeSites()
    local trusted = 0
    for __, record in ipairs(AnnasMirrors:list("catalogue")) do
        if record.trust == AnnasMirrors.TRUST.SEED or record.trust == AnnasMirrors.TRUST.APPROVED then
            trusted = trusted + 1
        end
    end
    return T(N_("1 sent your key", "%1 sent your key", trusted), trusted)
end

-- Returns a full-screen menu. onClose, when given, replaces KOReader's own way to close it, so it has to close
-- the menu itself. What follows closing goes in the menu's close_callback instead.
function SettingsPage:newMenu(title, item_table, onClose)
    local size = Screen:getSize()
    return Menu:new {
        title = title,
        item_table = item_table,
        covers_fullscreen = true,
        is_borderless = true,
        -- Square corners: rounded ones aren't painted, and show what was on screen before.
        is_popout = false,
        width = size.w,
        height = size.h,
        onClose = onClose,
    }
end

function SettingsPage:settingsItems()
    local this = self
    local show_book_covers = FetchAnnaSettings:getShowBookCovers()
    local download_dir = FetchAnnaSettings:getDownloadDir()
    local languages = FetchAnnaSettings:getPreferredLanguages()
    local file_types = FetchAnnaSettings:getPreferredFileTypes()
    local check_for_updates = FetchAnnaSettings:getCheckForUpdates()
    local search_cache_days = FetchAnnaSettings:getSearchCacheExpiryDays()
    local proxy = ProxyUtil.get()
    local encrypted_dns = FetchAnnaSettings:getEncryptedDns()

    local items = {
        {
            text = T(_("Show Book Covers: %1"), show_book_covers and "☑" or "☐"),
            callback = function()
                this:changeBookCoverVisibility()
            end,
        },
        {
            text = T(_("Download Folder: %1"), SettingsPage.shortenFolder(download_dir)),
            callback = function()
                this:changeDownloadFolder()
            end,
        },
        {
            text = T(
                _("Preferred Languages: %1"),
                describeChosen(FetchAnnaSettings:getAvailableLanguages(), languages)
            ),
            callback = function()
                this:changeLanguages()
            end,
        },
        {
            text = T(_("Preferred File Types: %1"), describeChosen(fileTypeChoices(), file_types)),
            callback = function()
                this:changeFileTypes()
            end,
        },
        {
            text = T(_("Check for Updates Automatically: %1"), check_for_updates and "☑" or "☐"),
            callback = function()
                this:changeCheckForUpdates()
            end,
        },
        {
            text = T(_("Keep Searches For: %1"), formatDays(search_cache_days)),
            callback = function()
                this:changeCacheExpiry(_("Keep Searches For"), search_cache_days, function(days)
                    saved(FetchAnnaSettings:setSearchCacheExpiryDays(days))
                end)
            end,
        },
        {
            -- KOReader's proxy, which FetchAnna uses for everything (see ProxyUtil).
            text = T(_("HTTP Proxy: %1"), proxy and ProxyUtil.describe(proxy) or _("Off")),
            callback = function()
                this:changeProxy()
            end,
        },
        {
            -- Can be turned off even where curl can't do it (see CurlUtil.applyEncryptedDns).
            text = T(_("Encrypted DNS: %1"), encrypted_dns and "☑" or "☐"),
            enabled = encrypted_dns or CurlUtil.canUseEncryptedDns(),
            callback = function()
                this:changeEncryptedDns()
            end,
        },
        {
            -- Clear Cache leaves the sites alone, as approving one is a decision (see MirrorsPage).
            text = T(_("Anna's Archive Sites: %1"), describeSites()),
            callback = function()
                this:showMirrors()
            end,
        },
        {
            text = _("Clear Cache"),
            callback = function()
                this:clearCache()
            end,
        },
    }

    -- The version installed before the last update, while it's kept, in case this one doesn't work on the device.
    local previous_version = Rollback.previousVersion(PathUtil.getPluginPath())
    if previous_version then
        table.insert(items, {
            text = T(_("Go back to v%1"), previous_version),
            callback = function()
                this:goBack(previous_version)
            end,
        })
    end
    return items
end

-- Goes back to the version before the last update (see Rollback), once KOReader restarts.
function SettingsPage:goBack(previous_version)
    local current_version = Diagnostics.version() or "?"
    UIManager:show(ConfirmBox:new {
        text = T(
            _("Go back to FetchAnna v%1? v%2, the version installed now, is kept to go forward to again."),
            previous_version,
            current_version
        ),
        ok_text = _("Go back"),
        ok_callback = function()
            local ok, err = Rollback.goBack(PathUtil.getPluginPath())
            if not ok then
                NotifyUtil.error(T(_("Going back failed: %1"), err))
                return
            end
            -- So it isn't offered again every day, only when asked to check for updates.
            FetchAnnaSettings:setSkippedVersion(current_version)
            UIManager:askForRestart(
                T(_("FetchAnna has gone back to v%1, which KOReader will use once it restarts."), previous_version)
            )
        end,
    })
end

-- Shows Anna's Archive's sites (see MirrorsPage), and the settings as they are once the sites close. That's done
-- in close_callback: an onClose (see newMenu) would replace what closes the menu, which left a Kindle on the
-- sites with no way back.
function SettingsPage:showMirrors()
    local this = self
    MirrorsPage:show(function(title, items)
        local menu = this:newMenu(title, items)
        menu.close_callback = function()
            this:refresh()
        end
        return menu
    end)
end

function SettingsPage:showSettings()
    self.menu = self:newMenu(_("FetchAnna Settings"), self:settingsItems())
    UIManager:show(self.menu)
end

-- Refreshes the open menu in place, as closing and reopening it for every change flashes the whole screen twice.
-- Does nothing once the menu has closed.
function SettingsPage:refresh()
    if self.menu and UIManager:isWidgetShown(self.menu) then
        self.menu:switchItemTable(nil, self:settingsItems(), -1)
    end
end

function SettingsPage:changeBookCoverVisibility()
    saved(FetchAnnaSettings:setShowBookCovers(not FetchAnnaSettings:getShowBookCovers()))
    self:refresh()
end

function SettingsPage:changeCacheExpiry(title, current_days, save)
    local this = self
    local menu
    local items = {}

    for __, days in ipairs(FetchAnnaSettings:getAvailableCacheExpiryDays()) do
        table.insert(items, {
            text = string.format("%s %s", days == current_days and "◉" or "○", formatDays(days)),
            callback = function()
                save(days)
                UIManager:close(menu)
                this:refresh()
            end,
        })
    end

    menu = self:newMenu(title, items)
    UIManager:show(menu)
end

-- Sets KOReader's HTTP proxy, as its network settings do, or turns it off (see ProxyUtil).
function SettingsPage:changeProxy()
    local this = self
    local dialog
    dialog = InputDialog:new {
        title = _("HTTP Proxy"),
        description = _("FetchAnna and KOReader go through it, as set in KOReader's network settings too."),
        input = G_reader_settings:readSetting("http_proxy") or "http://",
        input_hint = "http://proxy.example:8080",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Turn off"),
                    enabled = ProxyUtil.get() ~= nil,
                    callback = function()
                        UIManager:close(dialog)
                        NetworkMgr:setHTTPProxy(nil)
                        LogUtil.info("turned KOReader's HTTP proxy off")
                        this:refresh()
                    end,
                },
                {
                    text = _("Turn on"),
                    is_enter_default = true,
                    callback = function()
                        local proxy = StringUtil.trim(dialog:getInputText())
                        if not proxy:find("^%a[%w+.-]*://[^%s/]+") then
                            NotifyUtil.info(_("Enter the proxy's address, e.g. http://proxy.example:8080"))
                            return
                        end
                        UIManager:close(dialog)
                        NetworkMgr:setHTTPProxy(proxy)
                        -- Without the login, which can have a password in it.
                        LogUtil.info("turned KOReader's HTTP proxy on:", ProxyUtil.describe(proxy))
                        this:refresh()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function SettingsPage:changeEncryptedDns()
    saved(FetchAnnaSettings:setEncryptedDns(not FetchAnnaSettings:getEncryptedDns()))
    self:refresh()
end

function SettingsPage:changeCheckForUpdates()
    saved(FetchAnnaSettings:setCheckForUpdates(not FetchAnnaSettings:getCheckForUpdates()))
    self:refresh()
end

function SettingsPage:changeDownloadFolder()
    local this = self

    DownloadMgr:new {
        title = _("Choose download directory"),
        onConfirm = function(dir)
            local ok, err = FetchAnnaSettings:setDownloadDir(dir)
            if ok then
                this:refresh()
            else
                NotifyUtil.error(T(_("Books can't be downloaded to %1: %2"), dir, err))
            end
        end,
    }:chooseDir()
end

-- Shows a menu of choices to tick, each { text, code } or a heading. Closing it passes the ticked codes to save.
-- With none ticked it says none_text and stays open, as it does where save returns false (e.g. when the ticks
-- would hide every book found). on_closed, where given, is called after closing with whether the ticks changed.
function SettingsPage:tickSeveral(title, choices, ticked, save, none_text, on_closed)
    local this = self
    local selected = {}
    for __, code in ipairs(ticked) do
        selected[code] = true
    end

    local menu
    local function items()
        local item_table = {}
        for __, choice in ipairs(choices) do
            if choice.heading then
                table.insert(item_table, {
                    text = "── " .. choice.heading .. " ──",
                    enabled = false,
                })
            else
                table.insert(item_table, {
                    text = string.format("%s %s", selected[choice.code] and "☑" or "☐", choice.text),
                    callback = function()
                        selected[choice.code] = not selected[choice.code]
                        -- Ticks it in place, staying on the same page.
                        menu:switchItemTable(nil, items(), -1)
                    end,
                })
            end
        end
        return item_table
    end

    -- Whether KOReader's Home key is closing it. Home is sent again until what's on top changes, which it never did
    -- while this stayed open with nothing ticked.
    local going_home = false
    menu = self:newMenu(title, items(), function()
        local result = {}
        for __, choice in ipairs(choices) do
            if choice.code and selected[choice.code] then
                table.insert(result, choice.code)
            end
        end

        local refused = false
        if #result == 0 then
            NotifyUtil.info(none_text)
            if not going_home then
                return
            end
        else
            refused = save(result) == false
            if refused and not going_home then
                return
            end
        end
        UIManager:close(menu)
        this:refresh()
        if on_closed then
            local changed = #result ~= #ticked
            for __, code in ipairs(ticked) do
                changed = changed or not selected[code]
            end
            on_closed(changed and #result > 0 and not refused)
        end
    end)
    if Menu.onHome then
        function menu:onHome()
            going_home = true
            return Menu.onHome(self)
        end
    end
    UIManager:show(menu)
end

-- Changes the preferred languages, from the settings or the results. on_closed is as in tickSeveral.
function SettingsPage:changeLanguages(on_closed)
    self:tickSeveral(
        _("Preferred Languages"),
        FetchAnnaSettings:getAvailableLanguages(),
        FetchAnnaSettings:getPreferredLanguages(),
        function(languages)
            saved(FetchAnnaSettings:setPreferredLanguages(languages))
        end,
        _("Select at least one language"),
        on_closed
    )
end

-- As changeLanguages, for file types.
function SettingsPage:changeFileTypes(on_closed)
    local choices = fileTypeChoices()

    self:tickSeveral(_("Preferred File Types"), choices, FetchAnnaSettings:getPreferredFileTypes(), function(file_types)
        saved(FetchAnnaSettings:setPreferredFileTypes(file_types))
    end, _("Select at least one file type"), on_closed)
end

-- Forgets the saved searches and covers, e.g. when they no longer match what Anna's Archive has. The sites are
-- kept, as they're what the key is trusted to (see AnnasMirrors).
function SettingsPage:clearCache()
    UIManager:show(ConfirmBox:new {
        text = _("Clear the searches and book covers that FetchAnna has saved?"),
        ok_text = _("Clear"),
        ok_callback = function()
            SearchCache:clear()
            CoverCache:clear()
            FetchAnnaSettings:clearRecentSearches()
            NotifyUtil.info(_("Cache cleared"))
        end,
    })
end

return SettingsPage
