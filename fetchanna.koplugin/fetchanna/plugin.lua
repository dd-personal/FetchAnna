local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local SettingsPage = require("fetchanna.settings.settingspage")
local AccountPage = require("fetchanna.ui.accountpage")
local Diagnostics = require("fetchanna.ui.diagnostics")
local util = require("util")
local NetworkMgr = require("ui/network/manager")
local StringUtil = require("fetchanna.util.stringutil")
local Sources = require("fetchanna.api.sources")
local MultiSearch = require("fetchanna.api.multisearch")
local Downloader = require("fetchanna.api.downloader")
local HttpUtil = require("fetchanna.util.httputil")
local LogUtil = require("fetchanna.util.logutil")
local NotifyUtil = require("fetchanna.util.notifyutil")
local BookMenu = require("fetchanna.ui.bookmenu")
local BookFilter = require("fetchanna.ui.bookfilter")
local Menu = require("ui/widget/menu")
local WaitingMessage = require("fetchanna.ui.waitingmessage")
local AnnasAccount = require("fetchanna.api.annasaccount")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local SearchCache = require("fetchanna.cache.searchcache")
local CurlUpdater = require("fetchanna.updater.curlupdater")
local CurlUtil = require("fetchanna.util.curlutil")
local PluginUpdater = require("fetchanna.updater.pluginupdater")
local FileUtil = require("fetchanna.util.fileutil")
local Errors = require("fetchanna.util.errors")
local Guard = require("fetchanna.util.guard")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

-- A plugin instance is created each time the file manager or a book opens, so these run once a session.
local update_check_scheduled = false
local version_checked = false
-- Seconds between automatic update checks: a day.
local UPDATE_CHECK_INTERVAL = 24 * 60 * 60
-- The most highlighted text that's searched for (see searchFor), as a whole paragraph can't be.
local MAX_QUERY_LENGTH = 100
-- The instance for whichever of the file manager or a book opened last, which the buttons in KOReader's own dialogs
-- search with (see addFileDialogButtons).
local latest
local file_dialog_buttons_added = false

local function updateCheckDue()
    local last_check = FetchAnnaSettings:getLastUpdateCheck()
    -- Or the clock has been put back since, as an e-reader's can be.
    return not last_check or math.abs(os.time() - last_check) >= UPDATE_CHECK_INTERVAL
end

-- What's needed to make sense of someone else's crash.log.
local function logEnvironment()
    LogUtil.info(Diagnostics.summary())
    LogUtil.info(
        "downloading to",
        FetchAnnaSettings:getDownloadDir(),
        "with covers",
        FetchAnnaSettings:getShowBookCovers() and "on" or "off",
        "and update checks",
        FetchAnnaSettings:getCheckForUpdates() and "on" or "off"
    )
    if not BookMenu.isSupported() then
        LogUtil.warn("showing results as a list without covers, as this KOReader's menu can't lay them out")
    end
end

-- Clears caches left by other versions, as their contents may not work with this one.
local function clearCachesAfterUpdate()
    local version = Diagnostics.version()
    if not version or version == FetchAnnaSettings:getLastVersion() then
        return
    end

    LogUtil.info(
        "FetchAnna was",
        FetchAnnaSettings:getLastVersion() or "not installed",
        "before, so clearing its caches"
    )
    SearchCache:clear()
    FetchAnnaSettings:setLastVersion(version)
end

local FetchAnna = WidgetContainer:new {
    name = "fetchanna",
    is_doc_only = false,
}

function FetchAnna:onDispatcherRegisterActions()
    Dispatcher:registerAction("fetchanna_action", {
        category = "none",
        event = "FetchAnna",
        title = _("FetchAnna"),
        general = true,
    })
end

-- Cancels downloads when KOReader exits or restarts, so curl isn't left running and partial books are removed. Doesn't
-- return true, so the event reaches the rest of KOReader.
-- Powering off, restarting the device, sharing its storage over USB (which curl would keep writing to) and quitting
-- from the file manager only send Close. Closing a book doesn't send it.
function FetchAnna:onExit()
    if #Downloader:getActiveDownloads() > 0 then
        LogUtil.info("cancelling downloads, as KOReader is closing")
    end
    Downloader:cancelAllDownloads()
end
FetchAnna.onRestart = FetchAnna.onExit
FetchAnna.onClose = FetchAnna.onExit

-- Downloads wait while the device sleeps or Wi-Fi is off, and carry on after. These don't return true either.
function FetchAnna:onSuspend()
    Downloader:onSuspend()
end
function FetchAnna:onResume()
    Downloader:onResume()
end
function FetchAnna:onNetworkDisconnected()
    Downloader:onNetworkDisconnected()
end
function FetchAnna:onNetworkConnected()
    Downloader:onNetworkConnected()
end

-- The dispatcher action, e.g. from a gesture: opens the search box.
function FetchAnna:onFetchAnna()
    self:setupUI()
    return true
end

-- Returns a book's first author from its properties (KOReader lists authors one per line), or nil.
local function firstAuthor(props)
    local authors = type(props) == "table" and props.authors
    local author = type(authors) == "string" and StringUtil.trim(authors:match("^[^\n]*")) or ""
    return author ~= "" and author or nil
end

-- Adds More by this author to the dialog KOReader shows on holding a book, where KOReader lets plugins add to it. Once
-- a session, as the dialogs are KOReader's own.
local function addFileDialogButtons()
    local FileManager = require("apps/filemanager/filemanager")
    if file_dialog_buttons_added or not FileManager.addFileDialogButtons then
        return
    end
    file_dialog_buttons_added = true
    local widgets = { FileManager }
    for __, name in ipairs({ "filemanagerhistory", "filemanagercollection", "filemanagerfilesearcher" }) do
        local found, widget = pcall(require, "apps/filemanager/" .. name)
        if found then
            table.insert(widgets, widget)
        end
    end
    for __, widget in ipairs(widgets) do
        FileManager.addFileDialogButtons(widget, "fetchanna", function(__, is_file, book_props)
            -- On an error, no button, rather than breaking KOReader's dialog (see Guard).
            local author = is_file and Guard.call("finding a book's author", firstAuthor, Guard.quiet, book_props)
            if not author then
                return nil
            end
            return {
                {
                    text = _("More by this author"),
                    callback = Guard.wrap("searching for more by an author", function()
                        local menu = widget.getMenuInstance and widget.getMenuInstance()
                        if menu and menu.file_dialog then
                            UIManager:close(menu.file_dialog)
                        end
                        latest:searchFor(author, "author")
                    end),
                },
            }
        end)
    end
end

function FetchAnna:init()
    FetchAnnaSettings:load()
    latest = self

    if not version_checked then
        version_checked = true
        logEnvironment()
        clearCachesAfterUpdate()
        -- Tidy up after the last session, which may have closed with downloads running.
        CurlUtil.removeLeftovers()
    end

    if self.dimen == nil then
        self.dimen = Screen:getSize()
    end

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    -- Add to KOReader's own dialogs, to search from books (see searchFor).
    addFileDialogButtons()
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self:addToHighlightDialog()
    end

    -- Check for updates once the UI is ready.
    if
        not update_check_scheduled
        and FetchAnnaSettings:getCheckForUpdates()
        and NetworkMgr:isConnected()
        and updateCheckDue()
    then
        update_check_scheduled = true
        -- Silent on failure, as the user didn't ask for it.
        Guard.scheduleIn(0.1, "checking for updates", function()
            -- The next check waits a day from now even if the release can't be looked up. Otherwise a Kindle whose curl
            -- is too old to look it up is offered a curl update at every start (KindleFetch #57).
            FetchAnnaSettings:setLastUpdateCheck(os.time())
            -- Checks curl is new enough.
            CurlUpdater.checkVersion()
            PluginUpdater.checkForUpdates(false)
        end, Guard.quiet)
    end
end

function FetchAnna:checkForUpdates()
    NetworkMgr:runWhenConnected(function()
        NotifyUtil.info(_("Checking for updates..."))
        CurlUpdater.checkVersion(true)
        PluginUpdater.checkForUpdates(true)
    end)
end

function FetchAnna:addToMainMenu(menu_items)
    menu_items.fetchanna = {
        text = _("FetchAnna"),
        sorting_hint = "search",
        sub_item_table = {
            {
                text = _("Search"),
                callback = function()
                    self:setupUI()
                end,
            },
            {
                -- Shows a hidden download again, without finding its book.
                text_func = function()
                    local count = #Downloader:getActiveDownloads()
                    return count > 0 and T(_("Downloads (%1)"), count) or _("Downloads")
                end,
                enabled_func = function()
                    return #Downloader:getActiveDownloads() > 0
                end,
                callback = function()
                    self:showDownloads()
                end,
            },
            {
                -- The key, and logging in with it (see AccountPage).
                text = _("Account"),
                callback = function()
                    AccountPage:show(function(title, items)
                        return SettingsPage:newMenu(title, items)
                    end)
                end,
            },
            {
                text = _("Settings"),
                callback = function()
                    SettingsPage:showSettings()
                end,
            },
            {
                text = _("Check for updates"),
                callback = function()
                    self:checkForUpdates()
                end,
            },
            {
                -- What to copy or save for whoever's helping, and a connection test.
                text = _("Diagnostics"),
                callback = function()
                    Diagnostics.show()
                end,
            },
        },
    }

    -- In a book, More by its author goes after Search (see searchFor).
    if self.ui.document then
        table.insert(menu_items.fetchanna.sub_item_table, 2, {
            text_func = function()
                local author = firstAuthor(self.ui.doc_props)
                return author and T(_("More by %1"), author) or _("More by this author")
            end,
            enabled_func = function()
                return firstAuthor(self.ui.doc_props) ~= nil
            end,
            callback = function()
                self:searchFor(firstAuthor(self.ui.doc_props), "author")
            end,
        })
    end
end

-- Shows the download's progress, or a list to choose from when there are several.
function FetchAnna:showDownloads()
    local downloads = Downloader:getActiveDownloads()
    if #downloads == 0 then
        NotifyUtil.info(_("No downloads in progress"))
        return
    end
    if #downloads == 1 then
        Downloader:showDownload(downloads[1].id)
        return
    end

    local dialog
    local buttons = {}
    for __, download in ipairs(downloads) do
        -- Its progress, or what it's doing when that isn't known.
        local percentage = download.widget.percentage or 0
        local progress = percentage > 0 and string.format("%d%%", math.floor(percentage * 100))
            or download.widget.status_text
        table.insert(buttons, {
            {
                text = download.title .. " · " .. progress,
                callback = function()
                    UIManager:close(dialog)
                    Downloader:showDownload(download.id)
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        title = _("Downloads"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Lists recent searches, to run one again.
function FetchAnna:showRecentSearches()
    local dialog
    local buttons = {}
    for __, query in ipairs(FetchAnnaSettings:getRecentSearches()) do
        table.insert(buttons, {
            {
                text = query,
                callback = function()
                    UIManager:close(dialog)
                    self.search_box:setInputText(query)
                    self:performSearch()
                end,
            },
        })
    end
    dialog = ButtonDialog:new {
        title = _("Recent searches"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Shows the account (see AccountPage) in a full-screen menu.
local function showAccount()
    AccountPage:show(function(title, items)
        return SettingsPage:newMenu(title, items)
    end)
end

-- Whether the site needs the key and there isn't one. If so, asks for it.
local function needsKey(source)
    if not (Sources[source] and Sources[source].NEEDS_KEY) or AnnasAccount:hasKey() then
        return false
    end
    LogUtil.info("asking for", Sources[source].NAME .. "'s key before using it")
    NotifyUtil.info(_("Enter your Anna's Archive secret key first"))
    showAccount()
    return true
end

-- Whether the site can be searched now: one that needs the key, only once there is one.
local function canSearch(source)
    return not Sources[source].NEEDS_KEY or AnnasAccount:hasKey()
end

-- Returns the sites' names as said together, e.g. "Anna's Archive".
local function sitesName(sources)
    local names = {}
    for __, source in ipairs(sources) do
        table.insert(names, Sources[source].NAME)
    end
    if #names <= 1 then
        return names[1] or ""
    end
    local last = table.remove(names)
    return T(_("%1 and %2"), table.concat(names, ", "), last)
end

-- Returns the sites in pages, in the order they're offered.
local function sourcesOf(pages)
    local sources = {}
    for __, source in ipairs(MultiSearch.SOURCES) do
        if pages[source] then
            table.insert(sources, source)
        end
    end
    return sources
end

-- Returns page 1 for each site.
local function firstPages(sources)
    local pages = {}
    for __, source in ipairs(sources) do
        pages[source] = 1
    end
    return pages
end

-- Returns what went wrong for the failed sites (failures, each { source, err }). With one site searched, one ("Search
-- failed: %1") gets the error alone. Otherwise several ("Search failed:\n%1") gets a line per site.
local function describeFailures(one, several, failures, sites_searched)
    if sites_searched == 1 then
        return T(one, failures[1].err)
    end
    local lines = {}
    for __, failure in ipairs(failures) do
        table.insert(lines, T(_("%1: %2"), Sources[failure.source].NAME, failure.err))
    end
    return T(several, table.concat(lines, "\n"))
end

-- Returns the sites that can be searched now, in the order they're offered.
function FetchAnna:sitesToSearch()
    local sources = {}
    for __, source in ipairs(self.sources) do
        if canSearch(source) then
            table.insert(sources, source)
        end
    end
    return sources
end

-- Opens the search box with query in it, narrowed to scope (e.g. "author", see SCOPES in Sources), each where given.
function FetchAnna:setupUI(query, scope)
    local this = self
    self.sources = { unpack(MultiSearch.SOURCES) }
    self.scope = scope

    local buttons = {
        {
            {
                text = "Cancel",
                callback = function()
                    UIManager:close(this.search_box)
                end,
            },
            {
                text = _("Recent"),
                id = "recent",
                enabled = #FetchAnnaSettings:getRecentSearches() > 0,
                callback = function()
                    this:showRecentSearches()
                end,
            },
            {
                text = "Search",
                -- So the keyboard's Enter searches too.
                is_enter_default = true,
                callback = function()
                    this:performSearch()
                end,
            },
        },
    }
    self.search_box = InputDialog:new {
        title = _("Search for books"),
        input = query,
        -- Or a book found on Anna's Archive in a browser (see downloadByMd5).
        input_hint = _("Title, author, or an Anna's Archive link or MD5"),
        input_type = "text",
        buttons = buttons,
    }
    UIManager:show(self.search_box)
end

-- Adds Search FetchAnna to the dialog KOReader shows for highlighted text. Second to last, as KOReader's own plugins
-- add theirs, so its own Search stays last.
function FetchAnna:addToHighlightDialog()
    self.ui.highlight:addToHighlightDialog("12_fetchanna_search", function(this)
        return {
            text = _("Search FetchAnna"),
            callback = Guard.wrap("searching for what's highlighted", function()
                local text = this.selected_text and this.selected_text.text
                this:onClose()
                self:searchFor(text)
            end),
        }
    end)
end

-- Opens the search box with query in it, e.g. a book's author or highlighted text, on one line and cut short when long
-- (see MAX_QUERY_LENGTH). scope is as in setupUI.
function FetchAnna:searchFor(query, scope)
    query = StringUtil.trim(query or ""):gsub("%s+", " ")
    if #query > MAX_QUERY_LENGTH then
        -- Cut at a space, or else between characters, never partway through a multi-byte one.
        local start = query:sub(1, MAX_QUERY_LENGTH)
        if query:sub(MAX_QUERY_LENGTH + 1, MAX_QUERY_LENGTH + 1):find("^[\128-\191]") then
            start = start:gsub("[\192-\255][\128-\191]*$", "")
        end
        query = start:match("^(.*%S)%s") or start
    end
    if query == "" then
        return
    end
    LogUtil.info(string.format("searching for %q, from a book", query))
    self:setupUI(query, scope)
end

function FetchAnna:performSearch()
    local query = StringUtil.trim(self.search_box:getInputText())

    self.search_box:onCloseKeyboard()

    if query == "" then
        NotifyUtil.info(_("Enter a search term first"))
        return
    end

    -- A link or md5 of a book found on Anna's Archive in a browser, not a search.
    local md5 = Sources.annas.md5From(query)
    if md5 then
        self:downloadByMd5(md5)
        return
    end

    -- Nothing can be found with every language or file type turned off. Each message is its own sentence, to be
    -- translated whole.
    local sources = self:sitesToSearch()
    local turned_off = #FetchAnnaSettings:getPreferredLanguages() == 0 and "language"
        or #FetchAnnaSettings:getPreferredFileTypes() == 0 and "file type"
    if turned_off then
        LogUtil.warn("every", turned_off, "is turned off, so there's nothing to search for")
        NotifyUtil.info(({
            ["language"] = _("Turn on at least one language in FetchAnna's settings first"),
            ["file type"] = _("Turn on at least one file type in FetchAnna's settings first"),
        })[turned_off])
        return
    end

    -- The sites can't be searched until the key is entered.
    if #sources == 0 then
        for __, source in ipairs(self.sources) do
            if needsKey(source) then
                return
            end
        end
    end

    local pages = firstPages(sources)
    if not self:canSearchNow(query, pages, function()
        self:performSearch()
    end) then
        return
    end

    LogUtil.debug("starting search for", query)
    self:searchFrom(query, pages)
end

-- Searches the sites in pages (see MultiSearch.start). Books show as soon as a site finds some, and the others' are
-- added as found. If none are found, says why.
function FetchAnna:searchFrom(query, pages)
    self.current_search_query = query
    self.books = nil
    self.next_pages = {}
    local sources = sourcesOf(pages)
    -- With several sites, each book is shown with its site.
    self.several_sites = #sources > 1
    -- Failures still to report, results read by sites that found none, sites with none of the chosen file types, and
    -- whether it was called off.
    local failures, results_read, no_file_types = {}, 0, {}
    local read_any, called_off = false, false
    -- Says what's being searched for, as the search box is behind it. The query has its own line, so the message covers
    -- the search box's buttons however short it is.
    local waiting_text = T(_("Searching %1 for\n“%2”..."), sitesName(sources), query)
    self:startSearch(query, pages, waiting_text, {
        on_result = function(source, books, err, next_page, read)
            local name = Sources[source].NAME
            if err == HttpUtil.CANCELLED then
                called_off = true
                LogUtil.info(string.format("search of %s for %q was called off", name, query))
                return
            end
            -- The site has none of the chosen file types, so the settings are offered.
            if err == Errors.NO_FILE_TYPES then
                LogUtil.warn(name, "has none of the file types chosen")
                table.insert(no_file_types, source)
                return
            end
            if err or not books then
                err = err or "search failed"
                LogUtil.warn(string.format("search of %s for %q failed: %s", name, query, err))
                table.insert(failures, { source = source, err = err })
                -- Shown over the other sites' books, where they're showing.
                if self.books then
                    self:sayFailed(failures)
                end
                return
            end
            read_any = true
            results_read = results_read + (read or 0)
            self.next_pages[source] = next_page
            if #books == 0 then
                LogUtil.info(
                    string.format(
                        "%s found no books for %q with the preferred languages, file types and book types",
                        name,
                        query
                    )
                )
                return
            end
            self:addBooks(books)
            self:sayFailed(failures)
        end,
        on_done = function()
            if self.books then
                self:finishBooks()
                return
            end
            if called_off then
                return
            end
            if #failures > 0 then
                self:explainFailure(query, pages, failures)
                return
            end
            if not read_any and #no_file_types > 0 then
                self:explainNoBooks(query, no_file_types, nil, {})
                return
            end
            self:explainNoBooks(query, sources, results_read, self.next_pages)
        end,
    })
end

-- Reports over the books which sites failed and why, then empties failures.
function FetchAnna:sayFailed(failures)
    for __, failure in ipairs(failures) do
        NotifyUtil.error(T(_("Searching %1 failed: %2"), Sources[failure.source].NAME, failure.err))
    end
    for i = #failures, 1, -1 do
        failures[i] = nil
    end
end

-- Adds a site's books to those found so far, and shows them if they're the first.
function FetchAnna:addBooks(books)
    local first = self.books == nil
    self.books = self.books or {}
    for __, book in ipairs(books) do
        table.insert(self.books, book)
    end
    if first then
        self:closeWaitingMessage()
        self:rememberSearch(self.current_search_query)
        self:showBooks(self.books)
    else
        self:refreshBooks()
    end
end

-- Remembers a search that found books, for Recent, and enables Recent in the search box, which may have opened with
-- none. Typos and failed searches aren't remembered.
function FetchAnna:rememberSearch(query)
    FetchAnnaSettings:addRecentSearch(query)
    local recent = self.search_box
        and self.search_box.button_table
        and self.search_box.button_table:getButtonById("recent")
    if recent then
        recent:enable()
    end
end

-- Shows Anna's Archive's own search for query, to open in a browser that can do its browser check, e.g. on a phone: its
-- URL and, where KOReader can show one, a QR code. Nothing of the account's is in it.
function FetchAnna:showBrowserSearch(query)
    local origin = AnnasMirrors:candidates(AnnasMirrors.SEARCH, { credentials = false })[1]
        or AnnasMirrors.SEARCH_FALLBACK
    local url = origin
        .. Sources.annas.searchPath(
            query or "",
            1,
            FetchAnnaSettings:getPreferredLanguages(),
            FetchAnnaSettings:getPreferredFileTypes()
        )
    LogUtil.info("showing Anna's Archive's search for", query, "to search in a browser")
    local has_qr, QRMessage = pcall(require, "ui/widget/qrmessage")
    local dialog
    local row = {
        {
            text = _("Close"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    }
    if has_qr and type(QRMessage) == "table" then
        table.insert(row, 1, {
            text = _("Show QR Code"),
            callback = function()
                UIManager:close(dialog)
                UIManager:show(QRMessage:new {
                    text = url,
                })
            end,
        })
    end
    dialog = ButtonDialog:new {
        title = T(
            _(
                "Search Anna's Archive in a browser, on a phone say, which can do its browser check. This search "
                    .. "there is:\n\n%1"
            ),
            url
        ),
        buttons = { row },
    }
    UIManager:show(dialog)
end

-- Returns the file types a book asked for by md5 can be downloaded as (see downloadByMd5), preferred ones first.
local function md5FileTypes()
    local file_types, seen = {}, {}
    for __, list in ipairs({
        FetchAnnaSettings:getPreferredFileTypes(),
        FetchAnnaSettings:getEbookFileTypes(),
        FetchAnnaSettings:getDocumentFileTypes(),
        FetchAnnaSettings:getComicFileTypes(),
    }) do
        for __, file_type in ipairs(list) do
            if not seen[file_type] then
                seen[file_type] = true
                table.insert(file_types, file_type)
            end
        end
    end
    return file_types
end

-- Downloads a book by its md5 (see AnnasSearch.md5From), found in a browser (see showBrowserSearch), from the member
-- API. The user picks the file type, as it can't be looked up without searching. The download is checked to be that
-- type and to have that md5 (see Downloader).
function FetchAnna:downloadByMd5(md5)
    LogUtil.info("asking which file type the file with md5", md5, "on Anna's Archive is")
    local dialog
    local buttons, row = {}, {}
    for __, file_type in ipairs(md5FileTypes()) do
        table.insert(row, {
            text = file_type:upper(),
            callback = function()
                UIManager:close(dialog)
                LogUtil.info("downloading the file with md5", md5, "from Anna's Archive as", file_type)
                self:downloadBook({
                    source = "annas",
                    id = md5,
                    md5 = md5,
                    title = md5,
                    file_type = file_type,
                })
            end,
        })
        if #row == 3 then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then
        table.insert(buttons, row)
    end
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })
    dialog = ButtonDialog:new {
        title = T(
            _(
                "Download the file with MD5 %1 from Anna's Archive as which file type?\n\nChoose the one Anna's "
                    .. "Archive lists for it. Once it has downloaded, it's checked to be in that type, and to be the "
                    .. "file with that MD5."
            ),
            md5
        ),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Returns buttons for what fixes err, if anything: entering the key, searching in a browser, updating a Kindle's curl,
-- or turning on encrypted DNS. retry, where given, is called once it's fixed.
function FetchAnna:fixes(err, retry)
    if err == Errors.ANNAS_NO_KEY or err == Errors.ANNAS_KEY_REJECTED or err == Errors.ANNAS_NOT_MEMBER then
        return {
            {
                text = _("Account"),
                callback = showAccount,
            },
        }
    elseif err == Errors.ANNAS_BLOCKED then
        local query = self.current_search_query
        return {
            {
                text = _("Search in a Browser"),
                callback = function()
                    self:showBrowserSearch(query)
                end,
            },
        }
    elseif err == Errors.OUTDATED_CURL then
        return {
            {
                text = _("Update curl"),
                callback = function()
                    CurlUpdater.checkVersion(true)
                end,
            },
        }
    elseif
        err == Errors.ANNAS_UNFOUND
        and not FetchAnnaSettings:getEncryptedDns()
        and CurlUtil.canUseEncryptedDns()
    then
        -- The network's own DNS may be what's blocking them (KindleFetch #55).
        return {
            {
                text = _("Use encrypted DNS"),
                callback = function()
                    local ok, save_err = FetchAnnaSettings:setEncryptedDns(true)
                    if not ok then
                        NotifyUtil.error(save_err)
                        return
                    end
                    LogUtil.info("turned encrypted DNS on, as the network couldn't find the sites")
                    if retry then
                        retry()
                    end
                end,
            },
        }
    end
    return {}
end

-- Says something failed (text, because of err), with buttons for what fixes it (see fixes) and any other_rows, in a
-- message that stays until closed. With no buttons, it's shown as an error.
function FetchAnna:showFailure(text, err, retry, other_rows)
    local rows = {}
    local fixes = self:fixes(err, retry)
    if #fixes > 0 then
        table.insert(rows, fixes)
    end
    for __, row in ipairs(other_rows or {}) do
        if #row > 0 then
            table.insert(rows, row)
        end
    end
    if #rows == 0 then
        NotifyUtil.error(text)
        return
    end
    UIManager:show(ConfirmBox:new {
        text = text,
        icon = "notice-warning",
        no_ok_button = true,
        cancel_text = _("Close"),
        other_buttons = rows,
    })
end

-- Says the search failed and why, per site, offering the first fix any failure has.
function FetchAnna:explainFailure(query, pages, failures)
    local err = failures[1].err
    for __, failure in ipairs(failures) do
        if #self:fixes(failure.err, function() end) > 0 then
            err = failure.err
            break
        end
    end
    local text = describeFailures(_("Search failed: %1"), _("Search failed:\n%1"), failures, #sourcesOf(pages))
    self:showFailure(text, err, function()
        self:searchOnline(query, pages)
    end)
end

-- Says the sites found no books, and why when known: results_read results, all in other languages or file types than
-- those chosen, or (results_read nil) none of the chosen file types. Offers to keep searching the sites in next_pages
-- when there are more results.
function FetchAnna:explainNoBooks(query, sources, results_read, next_pages)
    local name = sitesName(sources)
    if results_read == 0 then
        UIManager:show(ConfirmBox:new {
            text = T(_("%1 found no books for “%2”."), name, query),
            icon = "notice-info",
            no_ok_button = true,
            cancel_text = _("Close"),
        })
        return
    end

    -- None at all for a site that has none of the chosen file types.
    local text = results_read
            and T(
                _("%1 listed %2 results, but none in the languages and file types chosen in FetchAnna's settings."),
                name,
                results_read
            )
        or T(
            N_(
                "%1 doesn't have books in any of the file types chosen in FetchAnna's settings.",
                "%1 don't have books in any of the file types chosen in FetchAnna's settings.",
                #sources
            ),
            name
        )
    local other_buttons = {}
    -- There are more results to look through.
    if next(next_pages) then
        local pages = {}
        for source, page in pairs(next_pages) do
            pages[source] = page
        end
        table.insert(other_buttons, 1, {
            {
                text = _("Keep searching"),
                callback = function()
                    self:searchOnline(query, pages)
                end,
            },
        })
    end
    UIManager:show(ConfirmBox:new {
        text = text,
        ok_text = _("Settings"),
        ok_callback = function()
            SettingsPage:showSettings()
        end,
        cancel_text = _("Close"),
        other_buttons = other_buttons,
    })
end

-- Whether the sites' pages can be searched now: when connected, or all saved from an earlier search. Otherwise turns
-- Wi-Fi on (as KOReader is set up to) and calls retry once connected.
function FetchAnna:canSearchNow(query, pages, retry)
    if NetworkMgr:isConnected() or MultiSearch.isCached(query, pages, self.scope) then
        return true
    end
    NetworkMgr:runWhenConnected(retry)
    return false
end

-- Searches from the sites' pages (see searchFrom), turning Wi-Fi on first if needed.
function FetchAnna:searchOnline(query, pages)
    local function search()
        self:searchFrom(query, pages)
    end
    if self:canSearchNow(query, pages, search) then
        search()
    end
end

-- Searches the sites in pages without blocking KOReader, where possible (see HttpUtil). Shows waiting_text, with a
-- Cancel that calls every site off, until the first books are found or all have finished. No message when every page is
-- saved from an earlier search.
-- handlers are called as MultiSearch's are, for this search only. An earlier search still going (e.g. loading more) is
-- called off first, as only one search's books are shown at a time.
function FetchAnna:startSearch(query, pages, waiting_text, handlers)
    if self.search then
        self.search:cancel()
    end
    self:closeWaitingMessage()

    local message
    if not MultiSearch.isCached(query, pages, self.scope) then
        message = WaitingMessage.new(waiting_text)
        UIManager:show(message)
        -- So a second tap on what started the search doesn't land on the message.
        Device.input:inhibitInputUntil(true)
        UIManager:forceRePaint()
        self.waiting_message = message
    end

    local search
    search = MultiSearch.start(query, pages, self.scope, {
        -- E.g. which site is being tried, shown under the query.
        on_status = function(status)
            if message and not message.closed and not message.cancelled then
                message:setStatus(status)
            end
        end,
        on_result = function(...)
            if self.search == search then
                -- An error while showing the results is reported as a failed search.
                Guard.call(string.format("showing what was found for %q", query), handlers.on_result, function(err)
                    self:closeWaitingMessage()
                    NotifyUtil.error(T(_("Search failed: %1"), err))
                end, ...)
            end
        end,
        on_done = function()
            if message and not message.closed and not message.cancelled then
                message.closed = true
                UIManager:close(message)
            end
            if self.search == search then
                handlers.on_done()
            end
        end,
    })
    self.search = search
    -- Its Cancel calls off every site's search, as each waits with its own stand-in (see MultiSearch).
    if message then
        message.dismiss_callback = function()
            search:cancel()
        end
    end
end

-- Closes the "searching" message, once books are found or the search has finished.
function FetchAnna:closeWaitingMessage()
    local message = self.waiting_message
    self.waiting_message = nil
    if message and not message.closed and not message.cancelled then
        message.closed = true
        UIManager:close(message)
    end
end

-- Whether the results show covers: they're turned on, and KOReader's menu can lay them out.
local function coversShown()
    return BookMenu.isSupported() and FetchAnnaSettings:getShowBookCovers()
end

-- Returns a book's title, authors and file type, which filterBooks looks through. It's also the entry's text for
-- KOReader's Go to letter, which exits KOReader on an entry without text.
local function bookText(book)
    return StringUtil.joinDetails(
        book.display_title or book.title,
        book.authors,
        book.file_type and book.file_type:upper()
    )
end

-- Returns the book's entry text (see bookText), plus its site when several were searched.
function FetchAnna:bookItemText(book)
    local text = bookText(book)
    if self.several_sites and Sources[book.source] then
        text = StringUtil.joinDetails(text, Sources[book.source].NAME)
    end
    return text
end

-- Whether the results show the book: it has the filter text (see filterBooks) and isn't hidden by an unticked site,
-- language and so on (see chooseShown).
function FetchAnna:isShown(book)
    local filter = self.filter and util.stringLower(self.filter)
    if filter and not util.stringLower(self:bookItemText(book)):find(filter, 1, true) then
        return false
    end
    return BookFilter.isShown(book, self.hidden or {}, function(b)
        return self:isDownloaded(b)
    end)
end

-- Whether only some of the books found are shown.
function FetchAnna:isFiltering()
    return self.filter ~= nil or BookFilter.isHiding(self.hidden or {})
end

-- Returns how many of the books found are shown, counting from index from, where given.
function FetchAnna:countShown(from)
    local count = 0
    local books = self.books or {}
    for i = from or 1, #books do
        if self:isShown(books[i]) then
            count = count + 1
        end
    end
    return count
end

-- Returns menu entries for the books shown, then Load more when there's more.
function FetchAnna:bookMenuItems(books)
    local this = self
    local menu_items = {}

    for __, book in ipairs(books) do
        if self:isShown(book) then
            table.insert(menu_items, {
                book = book,
                text = self:bookItemText(book),
                -- Used where KOReader's own menu lists them (see showBooks).
                mandatory_func = function()
                    return this:isDownloaded(book) and _("Downloaded") or nil
                end,
                callback = function()
                    this:downloadBook(book)
                end,
            })
        end
    end

    -- Last come the sites still being searched, whose books are added as found, or else Load more.
    if self.search and not self.search:isDone() then
        table.insert(menu_items, {
            still_searching = true,
            text = T(_("Still searching %1…"), sitesName(self.search:pendingSources())),
            callback = function()
                NotifyUtil.info(
                    T(_("The books %1 finds are added here once it has."), sitesName(this.search:pendingSources()))
                )
            end,
        })
    elseif self:hasMore() then
        table.insert(menu_items, {
            text = _("Load more"),
            callback = function()
                self:loadMoreBooks()
            end,
        })
    end

    return menu_items
end

-- Returns the results' title: the query and how many books were found, or how many of them are shown when filtering.
function FetchAnna:booksTitle()
    local count = #self.books
    if self:isFiltering() then
        return T(_("%1 · %2 of %3 books"), self.current_search_query, self:countShown(), count)
    end
    -- There may be more to load, or still to come.
    local more = self:hasMore() or self.search and not self.search:isDone()
    local found = more and T(_("%1+ books"), count) or T(N_("1 book", "%1 books", count), count)
    return string.format("%s · %s", self.current_search_query, found)
end

-- Returns the next page of each site that has more, leaving out sites whose books are hidden (see chooseShown).
function FetchAnna:pagesToLoad()
    local pages = {}
    local hidden_sites = self.hidden and self.hidden.site or {}
    for source, page in pairs(self.next_pages or {}) do
        if not hidden_sites[source] then
            pages[source] = page
        end
    end
    return pages
end

-- Whether any site whose books are shown has more results.
function FetchAnna:hasMore()
    return next(self:pagesToLoad()) ~= nil
end

-- Lists the books again after more were found. Stays on the current page, or turns to book number itemnumber's, and
-- loads that page's covers.
function FetchAnna:refreshBooks(itemnumber)
    local menu = self.books_menu
    if not menu then
        return
    end
    menu:switchItemTable(self:booksTitle(), self:bookMenuItems(self.books), itemnumber or -1)
    if coversShown() then
        LogUtil.debug("loading covers for page", menu.page)
        menu:loadCoversForPage(menu.page)
    end
end

-- Once every site has finished, ends the list with Load more (or nothing) in place of the sites still being searched.
-- The list is left alone when its end hasn't changed, as relisting would reload the covers showing.
function FetchAnna:finishBooks()
    local menu = self.books_menu
    if not menu then
        return
    end
    local items, shown = self:bookMenuItems(self.books), menu.item_table
    local last, was = items[#items], shown[#shown]
    if #items ~= #shown or (last and last.text) ~= (was and was.text) then
        menu:switchItemTable(self:booksTitle(), items, -1)
    end
end

-- Lists the books shown from the first, after what's shown has changed, and loads their covers.
function FetchAnna:showFromFirst()
    local menu = self.books_menu
    if not menu then
        return
    end
    menu:switchItemTable(self:booksTitle(), self:bookMenuItems(self.books), 1)
    if coversShown() then
        menu:loadCoversForPage(1)
    end
end

-- Shows only the books with text in their title, authors or file type (any case), among those shown, without searching
-- again. Empty text shows them all. Nothing changes when no book has it.
function FetchAnna:filterBooks(text)
    text = StringUtil.trim(text)
    local previous = self.filter
    self.filter = text ~= "" and text or nil

    local shown = self:countShown()
    if shown == 0 then
        local hiding = BookFilter.isHiding(self.hidden or {})
        self.filter = previous
        NotifyUtil.message(
            hiding and T(_("None of the books shown have “%1” in them."), text)
                or T(_("None of the books found have “%1” in them."), text)
        )
        return
    end
    LogUtil.info(string.format("showing %d of the %d books found, looking for %q", shown, #self.books, text))
    self:showFromFirst()
end

-- Lets the user tick which values of filter (see BookFilter.FILTERS), e.g. which sites, to show books for, without
-- searching again. Each value is listed with its count. A choice that would hide every book isn't taken.
function FetchAnna:chooseShown(filter)
    local values = BookFilter.values(self.books, filter, function(book)
        return self:isDownloaded(book)
    end)
    local hidden = self.hidden[filter.id] or {}
    local choices, ticked = {}, {}
    for __, value in ipairs(values) do
        table.insert(choices, { text = T(_("%1 (%2)"), value.text, value.count), code = value.code })
        if not hidden[value.code] then
            table.insert(ticked, value.code)
        end
    end
    SettingsPage:tickSeveral(
        filter.name,
        choices,
        ticked,
        function(shown)
            local before = self.hidden[filter.id]
            self.hidden[filter.id] = BookFilter.hiding(values, shown)
            if self:countShown() == 0 then
                self.hidden[filter.id] = before
                NotifyUtil.info(_("That would hide every book found."))
                return false
            end
        end,
        _("That would hide every book found."),
        function(changed)
            -- Don't go back to the first page when nothing changed.
            if changed then
                LogUtil.info(
                    string.format("showing %d of the %d books found, by %s", self:countShown(), #self.books, filter.id)
                )
                self:showFromFirst()
            end
        end
    )
end

-- Asks for text to look through the books for (see filterBooks).
function FetchAnna:askForFilter()
    local this = self
    local dialog
    dialog = InputDialog:new {
        title = _("Look through the books found for"),
        input = self.filter or "",
        input_hint = _("Title, author or file type"),
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
                    text = _("Look through"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        this:filterBooks(text)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The menu at the top left of the results: look through the books, show only some sites, languages and so on (each
-- offered when the books differ in it), show all again, and search again.
function FetchAnna:showResultsMenu()
    local this = self
    local dialog
    local buttons = {
        {
            {
                text = _("Look through the books found…"),
                callback = function()
                    UIManager:close(dialog)
                    this:askForFilter()
                end,
            },
        },
    }
    self.hidden = self.hidden or {}
    for __, filter in ipairs(BookFilter.FILTERS) do
        -- Whether each book is downloaded is only looked up when asked for (see BookFilter.values).
        local values = filter.fixed or BookFilter.values(self.books, filter)
        if BookFilter.isOffered(filter, values) then
            table.insert(buttons, {
                {
                    text = T(_("%1: %2"), filter.name, BookFilter.describe(values, self.hidden[filter.id])),
                    callback = function()
                        UIManager:close(dialog)
                        this:chooseShown(filter)
                    end,
                },
            })
        end
    end
    if self:isFiltering() then
        table.insert(buttons, {
            {
                text = T(_("Show all %1 books"), #self.books),
                callback = function()
                    UIManager:close(dialog)
                    this.filter = nil
                    this.hidden = {}
                    this:showFromFirst()
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Search again…"),
            callback = function()
                UIManager:close(dialog)
                this:searchAgain()
            end,
        },
    })
    dialog = ButtonDialog:new {
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- From the results, changes the languages or file types in the settings and searches again (see changeChoices).
function FetchAnna:searchAgain()
    local this = self
    local dialog
    local changes = {
        { text = _("Languages…"), change = SettingsPage.changeLanguages },
        { text = _("File types…"), change = SettingsPage.changeFileTypes },
    }
    local row = {}
    for __, choice in ipairs(changes) do
        table.insert(row, {
            text = choice.text,
            callback = function()
                UIManager:close(dialog)
                this:changeChoices(choice.change)
            end,
        })
    end
    dialog = ButtonDialog:new {
        title = _("Change the settings, and search again:"),
        buttons = { row },
    }
    UIManager:show(dialog)
end

-- Runs change (e.g. SettingsPage.changeLanguages) from the results. If the choices changed, searches again in place of
-- the results.
function FetchAnna:changeChoices(change)
    local query = self.current_search_query
    change(SettingsPage, function(changed)
        if not changed then
            return
        end
        LogUtil.info(string.format("searching for %q again with the new choices", query))
        if self.books_menu then
            UIManager:close(self.books_menu)
        end
        self:searchOnline(query, firstPages(self:sitesToSearch()))
    end)
end

local function buildDownloadPath(book)
    local download_dir = FetchAnnaSettings:getDownloadDir()
    local filename = util.getSafeFilename(book.title .. "." .. book.file_type, download_dir)
    return download_dir .. "/" .. filename
end

-- Whether the book is already in the download folder under the name it would be saved as. Cached until a download
-- finishes, as working out the name reads the mounted file systems.
function FetchAnna:isDownloaded(book)
    self.downloaded = self.downloaded or {}
    if self.downloaded[book.id] == nil then
        self.downloaded[book.id] = FileUtil.isValidFile(buildDownloadPath(book)) or false
    end
    return self.downloaded[book.id]
end

function FetchAnna:showBooks(books)
    local this = self
    self.downloaded = nil
    -- What's shown of them (see isShown) starts afresh for each search.
    self.filter = nil
    self.hidden = {}

    -- KOReader's own menu, where it can't lay books out with covers.
    local MenuClass = BookMenu.isSupported() and BookMenu or Menu
    local menu
    menu = MenuClass:new {
        title = self:booksTitle(),
        -- Rather than cutting a long query short.
        title_shrink_font_to_fit = true,
        -- What can be done with the books found (see showResultsMenu).
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            this:showResultsMenu()
        end,
        -- KOReader's Search button, on tapping the page number, looks through the books found.
        search_callback = function(text)
            this:filterBooks(text)
        end,
        item_table = self:bookMenuItems(books),
        covers_fullscreen = true,
        is_borderless = true,
        -- Square corners: rounded ones aren't painted, and show what was on screen before.
        is_popout = false,
        width = this.dimen.w,
        height = this.dimen.h,
        items_max_lines = true,
        -- Marks books already downloaded.
        is_downloaded = function(book)
            return this:isDownloaded(book)
        end,
        -- Names each book's site, where several were searched.
        source_name = self.several_sites and function(book)
            return Sources[book.source] and Sources[book.source].NAME
        end or nil,
        -- Closing it calls off the sites still being searched. Their books would have nowhere to go, and a failure
        -- message would come out of nowhere.
        close_callback = function()
            if this.books_menu == menu then
                this.books_menu = nil
            end
            if this.search then
                this.search:cancel()
            end
        end,
        onPageChange = Guard.wrap("loading covers", function(page)
            if coversShown() then
                LogUtil.debug("loading covers for page", page)
                menu:loadCoversForPage(page)
            end
        end, Guard.quiet),
    }

    self.books_menu = menu

    UIManager:show(menu)
    UIManager:setDirty(menu, "full")

    if coversShown() then
        LogUtil.debug("loading covers for page 1")
        menu:loadCoversForPage(1)
    end
end

-- Loads the next page of each site that has more (see pagesToLoad). Books are added as found, and the list turns to the
-- first new one that's shown.
function FetchAnna:loadMoreBooks()
    if not self:hasMore() then
        NotifyUtil.message(_("No more books found"))
        return
    end

    local query = self.current_search_query
    local pages = self:pagesToLoad()
    if not self:canSearchNow(query, pages, function()
        self:loadMoreBooks()
    end) then
        return
    end

    -- The sites that failed (which keep their page, to load again), results read by the others, books found, and how
    -- many of those are shown.
    local failures, results_read, found, shown = {}, 0, 0, 0
    local first_new_book = #self.books + 1
    self:startSearch(query, pages, _("Loading more books..."), {
        on_result = function(source, books, err, next_page, read)
            if err == HttpUtil.CANCELLED then
                return
            end
            -- No books and no error is a search that didn't say why, not the end of the results.
            if err or not books then
                err = err or "search failed"
                LogUtil.warn(
                    string.format("loading more books from %s for %q failed: %s", Sources[source].NAME, query, err)
                )
                table.insert(failures, { source = source, err = err })
                return
            end
            self.next_pages[source] = next_page
            results_read = results_read + (read or 0)
            if #books == 0 then
                return
            end
            for __, book in ipairs(books) do
                table.insert(self.books, book)
            end
            self:closeWaitingMessage()
            -- Turn to the page where the first new books shown start, not back to the first, and stay there as more
            -- arrive.
            local was_shown = shown
            shown = self:countShown(first_new_book)
            self:refreshBooks(was_shown == 0 and shown > 0 and self:countShown() - shown + 1 or nil)
            found = found + #books
        end,
        on_done = function()
            self:finishBooks()
            if #failures > 0 then
                if found == 0 then
                    self:showFailure(
                        describeFailures(
                            _("Loading more books failed: %1"),
                            _("Loading more books failed:\n%1"),
                            failures,
                            #sourcesOf(pages)
                        ),
                        failures[1].err,
                        function()
                            self:loadMoreBooks()
                        end
                    )
                else
                    self:sayFailed(failures)
                end
                return
            end
            if shown > 0 then
                return
            end
            if found > 0 then
                NotifyUtil.message(
                    T(
                        N_(
                            "1 more book was found, but it isn't among those shown.",
                            "%1 more books were found, but none of them are among those shown.",
                            found
                        ),
                        found
                    )
                )
                return
            end
            if self:hasMore() then
                -- There are more results to look through.
                NotifyUtil.message(
                    T(
                        _(
                            "None of the next %1 results are in the languages and file types chosen. Load more to "
                                .. "keep looking."
                        ),
                        results_read
                    )
                )
            else
                NotifyUtil.message(_("No more books found"))
            end
        end,
    })
end

-- Closes the results and the search box behind them, which would otherwise show again over wherever the user went.
function FetchAnna:closeSearch()
    -- Also calls off the sites still being searched, whose books would have nowhere to go.
    if self.search then
        self.search:cancel()
    end
    self:closeWaitingMessage()
    if self.books_menu then
        UIManager:close(self.books_menu)
    end
    if self.search_box then
        UIManager:close(self.search_box)
    end
end

function FetchAnna:openBook(filepath)
    -- It would otherwise show again once the book is closed.
    self:closeSearch()

    -- Open it from whichever of a book or the file manager is open now, not from self.ui, which may have closed since
    -- (e.g. while the download was hidden).
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(filepath)
        return
    end
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:openFile(filepath)
    else
        ReaderUI:showReader(filepath)
    end
end

-- Returns the buttons KOReader's file browser has for a book, where this KOReader has them: show folder, add to
-- collection, book information. Each calls close first. They act on whichever of a book or the file manager is open, as
-- KOReader's own do.
function FetchAnna:bookButtons(filepath, close)
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local ui = require("apps/reader/readerui").instance or require("apps/filemanager/filemanager").instance
    local row = {}
    if not ui then
        return row
    end
    if filemanagerutil.genShowFolderButton then
        table.insert(
            row,
            filemanagerutil.genShowFolderButton(filepath, function()
                close()
                -- It would otherwise hide the folder.
                self:closeSearch()
            end)
        )
    end
    if ui.collections and ui.collections.genAddToCollectionButton then
        table.insert(row, ui.collections:genAddToCollectionButton(filepath, close))
    end
    local genBookInformationButton = filemanagerutil.genBookInformationButton
    if genBookInformationButton and ui.bookinfo then
        -- Before KOReader v2024.04, it took close where it now takes the book's details.
        if debug.getinfo(genBookInformationButton, "u").nparams < 4 then
            table.insert(row, genBookInformationButton(filepath, close))
        else
            table.insert(row, genBookInformationButton(filepath, nil, close))
        end
    end
    return row
end

function FetchAnna:downloadBook(book)
    -- Ask for the key first when there's none, rather than look the link up only for the site to say so.
    if needsKey(book.source) then
        return
    end

    local filepath = buildDownloadPath(book)
    Downloader:downloadBook(book, filepath, function(ok, err, saved_filepath)
        if ok then
            LogUtil.debug("downloaded book to", saved_filepath)
            -- So it's marked as downloaded in the results behind.
            self.downloaded = nil
            if self.books_menu and not self.books_menu.closed then
                self.books_menu:updateItems()
            end
            -- And listed in the file browser, which otherwise doesn't show it until it's left and reopened.
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:onRefresh()
            end
            -- Ask on the next tick, once the download progress has closed.
            Guard.nextTick("offering to read the downloaded book", function()
                -- Centred, with the title in bold on its own line, so it stands out from the question.
                local dialog
                local function close()
                    UIManager:close(dialog)
                end
                local buttons = {
                    {
                        -- The book has downloaded, so nothing is called off.
                        { text = _("Not now"), id = "close", callback = close },
                        {
                            text = _("Read now"),
                            id = "read",
                            callback = function()
                                close()
                                self:openBook(saved_filepath)
                            end,
                        },
                    },
                }
                -- Beneath them, the file browser's buttons for it (none where KOReader is too old to have them).
                local book_buttons = self:bookButtons(saved_filepath, close)
                if #book_buttons > 0 then
                    table.insert(buttons, book_buttons)
                end
                dialog = ButtonDialog:new {
                    title = string.format(
                        "%s%s\n%s%s%s\n\n%s",
                        TextBoxWidget.PTF_HEADER,
                        _("Downloaded"),
                        TextBoxWidget.PTF_BOLD_START,
                        book.display_title or book.title,
                        TextBoxWidget.PTF_BOLD_END,
                        _("Would you like to read it now?")
                    ),
                    title_align = "center",
                    buttons = buttons,
                }
                UIManager:show(dialog)
            end)
        elseif err == Errors.CANCELLED then
            LogUtil.debug("download cancelled", book.title)
            NotifyUtil.info(_("Download cancelled"))
        else
            LogUtil.warn("download failed for", book.title, err)
            -- Offers what fixes it, then downloads again (see fixes).
            self:showFailure(err and T(_("Download failed: %1"), err) or _("Download failed"), err, function()
                self:downloadBook(book)
            end)
        end
    end, function(existing_filepath)
        -- The book is already there, and the user chose to read it rather than download it again.
        self:openBook(existing_filepath)
    end)
end

return FetchAnna
