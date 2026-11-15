local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local AnnasAccount = require("fetchanna.api.annasaccount")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local KeyStore = require("fetchanna.api.keystore")
local OriginPolicy = require("fetchanna.util.originpolicy")
local NotifyUtil = require("fetchanna.util.notifyutil")
local NetworkTask = require("fetchanna.ui.networktask")
local MirrorsPage = require("fetchanna.ui.mirrorspage")
local T = require("ffi/util").template
local _ = require("gettext")

-- The Anna's Archive account page (see AnnasAccount): the account's status, and entering, remembering and
-- forgetting its key.
local AccountPage = {}

local STATUS = AnnasAccount.STATUS
local STATUS_LABELS = {
    [STATUS.NO_KEY] = _("No key"),
    [STATUS.UNVERIFIED] = _("Key saved, not checked yet"),
    [STATUS.UNREACHABLE] = _("Key saved, couldn't be checked"),
    [STATUS.VALID] = _("Key accepted, not logged in"),
    [STATUS.LOGGED_IN] = _("Logged in"),
    [STATUS.INVALID] = _("Key not accepted"),
}

-- Returns a line saying what the membership allows, as far as it's known.
function AccountPage.describeMembership(status)
    if not status.tier then
        return _("Membership: not known yet")
    elseif status.tier == 0 then
        return _("Membership: none, so no fast downloads")
    elseif not status.allows or status.allows.downloads == 0 then
        return _("Membership: without fast downloads")
    end
    return T(
        _("Membership: about %1 fast downloads a day, and %2 searches an hour without a browser check"),
        status.allows.downloads,
        status.allows.searches
    )
end

-- Returns everything known of the account, as text.
function AccountPage.describe(status, now)
    local lines = { STATUS_LABELS[status.status] }
    for __, session in ipairs(status.sessions) do
        table.insert(
            lines,
            T(
                _("Logged in on %1 until %2"),
                OriginPolicy.hostOf(session.origin),
                os.date("%Y-%m-%d", session.expires_at or now)
            )
        )
    end
    if status.status ~= STATUS.NO_KEY then
        table.insert(lines, AccountPage.describeMembership(status))
    end
    if status.downloads_left and status.downloads_per_day then
        table.insert(
            lines,
            T(
                _("Fast downloads left: %1 of %2, %3"),
                status.downloads_left,
                status.downloads_per_day,
                MirrorsPage.ago(status.downloads_checked_at or now, now)
            )
        )
    end
    if status.verified_at then
        table.insert(lines, T(_("Key last accepted %1"), MirrorsPage.ago(status.verified_at, now)))
    end
    if status.failure_at and status.failure then
        table.insert(
            lines,
            T(
                _("Last time, %1: %2"),
                MirrorsPage.ago(status.failure_at, now),
                AnnasMirrors.describe({ failure = status.failure })
            )
        )
    end
    if status.status ~= STATUS.NO_KEY then
        table.insert(
            lines,
            KeyStore.isRemembered()
                    and T(_("Your key is remembered on this device, unencrypted, in %1."), KeyStore.path())
                or _("Your key is kept until KOReader restarts.")
        )
    end
    return table.concat(lines, "\n")
end

-- Shows the account in a menu made by new_menu(title, items) (see SettingsPage:newMenu).
function AccountPage:show(new_menu)
    self.menu = new_menu(_("Anna's Archive Account"), self:items())
    UIManager:show(self.menu)
end

function AccountPage:refreshMenu()
    if self.menu and UIManager:isWidgetShown(self.menu) then
        self.menu:switchItemTable(nil, self:items(), -1)
    end
end

function AccountPage:items()
    local this = self
    local status = AnnasAccount:status()
    local has_key = status.status ~= STATUS.NO_KEY
    return {
        {
            text = T(_("Status: %1"), STATUS_LABELS[status.status]),
            callback = function()
                NotifyUtil.message(AccountPage.describe(AnnasAccount:status(), os.time()))
            end,
        },
        {
            text = has_key and _("Replace Key") or _("Enter Key"),
            callback = function()
                this:enterKey()
            end,
        },
        {
            text = _("Connect"),
            enabled = has_key,
            callback = function()
                this:connect()
            end,
        },
        {
            text = T(_("Remember on This Device: %1"), KeyStore.isRemembered() and "☑" or "☐"),
            callback = function()
                this:changeRemember()
            end,
        },
        {
            text = _("Forget Key and Log Out"),
            enabled = has_key,
            callback = function()
                this:confirmForget()
            end,
        },
    }
end

-- Asks for the key in KOReader's password field, which hides it, then saves it and connects if asked.
function AccountPage:enterKey()
    local this = self
    local dialog
    local function save(connect)
        local ok, err = AnnasAccount:setKey(dialog:getInputText())
        if not ok then
            NotifyUtil.error(err)
            return
        end
        UIManager:close(dialog)
        this:refreshMenu()
        if connect then
            this:connect()
        else
            NotifyUtil.info(_("Key saved"))
        end
    end
    dialog = InputDialog:new {
        title = _("Anna's Archive Secret Key"),
        input = "",
        input_hint = _("Secret key"),
        description = _(
            "It's on your account page on Anna's Archive. FetchAnna only ever sends it to Anna's Archive's sites that "
                .. "are approved to be sent it, and never logs it."
        ),
        text_type = "password",
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
                    text = _("Save"),
                    callback = function()
                        save(false)
                    end,
                },
                {
                    text = _("Save and Connect"),
                    is_enter_default = true,
                    callback = function()
                        save(true)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Logs in with the key (see AnnasAccount:connect) and says how it went.
function AccountPage:connect()
    NetworkTask.run("connecting to Anna's Archive", _("Connecting to Anna's Archive..."), function()
        return AnnasAccount:connect()
    end, function(ok, outcome)
        self:refreshMenu()
        if type(outcome) == "string" then
            NotifyUtil.error(outcome)
            return
        end
        if outcome and outcome.failure == AnnasMirrors.FAILURE.CANCELLED then
            return
        end
        local status = AnnasAccount:status()
        if ok and status.status == STATUS.LOGGED_IN then
            NotifyUtil.message(
                T(_("Logged in to Anna's Archive on %1."), OriginPolicy.hostOf(status.sessions[1].origin))
                    .. "\n"
                    .. AccountPage.describeMembership(status)
            )
        elseif ok then
            NotifyUtil.message(
                T(
                    _("Anna's Archive accepts your key, but FetchAnna couldn't log in: %1"),
                    AnnasMirrors.describe(outcome or { failure = status.failure })
                )
            )
        else
            NotifyUtil.error(AnnasMirrors.describe(outcome))
        end
    end)
end

-- Remembers the key on the device, once the user accepts that it's kept unencrypted, or stops remembering it.
function AccountPage:changeRemember()
    local this = self
    if KeyStore.isRemembered() then
        local ok, err = KeyStore.setRemembered(false)
        if ok then
            NotifyUtil.info(_("Your key is no longer remembered on this device"))
        else
            NotifyUtil.error(err)
        end
        self:refreshMenu()
        return
    end
    UIManager:show(ConfirmBox:new {
        text = T(
            _(
                "Remember your key on this device? It's kept in %1, unencrypted, so anyone who can read the "
                    .. "device's storage can read it, which on most e-readers is anyone who connects it to a computer. "
                    .. "Otherwise it's kept until KOReader restarts."
            ),
            KeyStore.path()
        ),
        ok_text = _("Remember"),
        ok_callback = function()
            local ok, err = KeyStore.setRemembered(true)
            if ok then
                NotifyUtil.info(_("Your key is remembered on this device"))
            else
                NotifyUtil.error(err)
            end
            this:refreshMenu()
        end,
    })
end

function AccountPage:confirmForget()
    local this = self
    UIManager:show(ConfirmBox:new {
        text = _(
            "Forget your key and log out? It's removed from this device, along with its login sessions. On flash "
                .. "storage, removing a file doesn't guarantee that what was in it is erased."
        ),
        ok_text = _("Forget"),
        ok_callback = function()
            AnnasAccount:forget()
            NotifyUtil.info(_("Key forgotten"))
            this:refreshMenu()
        end,
    })
end

return AccountPage
