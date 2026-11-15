local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local AnnasMirrors = require("fetchanna.api.annasmirrors")
local HttpUtil = require("fetchanna.util.httputil")
local LogUtil = require("fetchanna.util.logutil")
local NotifyUtil = require("fetchanna.util.notifyutil")
local NetworkTask = require("fetchanna.ui.networktask")
local T = require("ffi/util").template
local _ = require("gettext")
local N_ = _.ngettext

-- The Anna's Archive sites page (see AnnasMirrors): when SLUM was last read, each site's trust and how it's doing,
-- and the actions: look them up again, check a site, approve one to be sent the key, revoke one, or go back to the
-- sites FetchAnna comes with.
local MirrorsPage = {}

-- How each trust level is shown.
local TRUST_LABELS = {
    seed = _("Built in"),
    approved = _("Approved"),
    untrusted = _("Not approved"),
    revoked = _("Revoked"),
    suspended = _("Suspended"),
}
local TRUST_EXPLANATIONS = {
    seed = _("Sent your key: FetchAnna was released with it, checked by hand on %1."),
    approved = _("Sent your key: you approved it."),
    untrusted = _("Not sent your key, as it hasn't been approved."),
    revoked = _("Not sent your key, as you revoked it."),
    suspended = _(
        "Not sent your key for now: SLUM stopped listing it, or it stopped answering as Anna's Archive does. Check "
            .. "it, then approve it again."
    ),
}
-- What each capability is called when saying it worked.
local CAPABILITY_NAMES = {
    probe = _("check"),
    search = _("search"),
    account = _("login"),
    api = _("download link"),
    transfer = _("download"),
}

-- Returns how long ago time was, e.g. "3 hours ago".
function MirrorsPage.ago(time, now)
    local seconds = math.max(0, now - time)
    if seconds < 60 then
        return _("just now")
    elseif seconds < 60 * 60 then
        local minutes = math.floor(seconds / 60)
        return T(N_("1 minute ago", "%1 minutes ago", minutes), minutes)
    elseif seconds < 24 * 60 * 60 then
        local hours = math.floor(seconds / (60 * 60))
        return T(N_("1 hour ago", "%1 hours ago", hours), hours)
    end
    local days = math.floor(seconds / (24 * 60 * 60))
    return T(N_("1 day ago", "%1 days ago", days), days)
end

-- Shows the sites in a menu made by new_menu(title, items, on_close) (see SettingsPage:newMenu).
function MirrorsPage:show(new_menu)
    self.new_menu = new_menu
    self.menu = new_menu(_("Anna's Archive Sites"), self:items())
    UIManager:show(self.menu)
end

function MirrorsPage:refreshMenu()
    if self.menu and UIManager:isWidgetShown(self.menu) then
        self.menu:switchItemTable(nil, self:items(), -1)
    end
end

function MirrorsPage:items()
    local this = self
    local now = os.time()
    local discovery = AnnasMirrors:discovery()
    local items = {}

    table.insert(items, {
        text = discovery.fetched_at
                and T(_("Refresh from SLUM (looked up %1)"), MirrorsPage.ago(discovery.fetched_at, now))
            or _("Refresh from SLUM (never looked up)"),
        callback = function()
            this:refreshFromSlum()
        end,
    })
    -- Only when it has failed since it last worked.
    if discovery.last_error_at and (not discovery.fetched_at or discovery.last_error_at >= discovery.fetched_at) then
        table.insert(items, {
            text = T(_("SLUM couldn't be read %1"), MirrorsPage.ago(discovery.last_error_at, now)),
            callback = function()
                NotifyUtil.message(T(_("SLUM couldn't be read: %1"), discovery.last_error or _("unknown error")))
            end,
        })
    end

    for __, record in ipairs(AnnasMirrors:list("catalogue")) do
        table.insert(items, {
            text = record.host,
            mandatory = TRUST_LABELS[record.trust],
            callback = function()
                this:showSite(record.origin)
            end,
        })
    end

    local download_hosts = {}
    for __, record in ipairs(AnnasMirrors:list("download")) do
        if not record.delisted_at then
            table.insert(download_hosts, record.host)
        end
    end
    if #download_hosts > 0 then
        table.insert(items, {
            text = T(_("Download servers: %1"), table.concat(download_hosts, ", ")),
            callback = function()
                NotifyUtil.message(
                    _(
                        "Anna's Archive's download servers are only ever sent the download links its member API gives, "
                            .. "never your key."
                    )
                )
            end,
        })
    end

    table.insert(items, {
        text = _("Reset to Built-in Sites"),
        callback = function()
            this:confirmReset()
        end,
    })
    return items
end

-- Returns the current record for origin (see AnnasMirrors:list), or nil.
local function recordFor(origin)
    for __, record in ipairs(AnnasMirrors:list()) do
        if record.origin == origin then
            return record
        end
    end
end

-- Returns what's known about a site, as text.
function MirrorsPage.describeSite(record, now)
    local lines = { record.host }
    local explanation = TRUST_EXPLANATIONS[record.trust] or ""
    table.insert(lines, record.trust == "seed" and T(explanation, AnnasMirrors.SEEDS_REVIEWED) or explanation)
    if record.delisted_at then
        table.insert(lines, T(_("SLUM stopped listing it %1"), MirrorsPage.ago(record.delisted_at, now)))
    elseif record.slum then
        table.insert(
            lines,
            T(_("SLUM: %1, as of %2"), record.slum.status, MirrorsPage.ago(record.slum.checked_at or now, now))
        )
    else
        table.insert(lines, _("SLUM: not looked up yet"))
    end
    if record.impostor_at then
        table.insert(lines, T(_("Answered as Anna's Archive doesn't %1"), MirrorsPage.ago(record.impostor_at, now)))
    elseif record.verified_at then
        table.insert(lines, T(_("Checked to be Anna's Archive %1"), MirrorsPage.ago(record.verified_at, now)))
    else
        table.insert(lines, _("Not checked to be Anna's Archive yet"))
    end
    local latest, latest_capability
    for capability, health in pairs(record.health or {}) do
        if health.ok_at and (not latest or health.ok_at > latest) then
            latest, latest_capability = health.ok_at, capability
        end
    end
    if latest then
        table.insert(
            lines,
            T(
                _("Last worked %1 (%2)"),
                MirrorsPage.ago(latest, now),
                CAPABILITY_NAMES[latest_capability] or latest_capability
            )
        )
    end
    return table.concat(lines, "\n")
end

-- Shows a site, and what can be done about it.
function MirrorsPage:showSite(origin)
    local this = self
    local record = recordFor(origin)
    if not record then
        return
    end
    local trusted = record.trust == "seed" or record.trust == "approved"
    local dialog
    local function close()
        UIManager:close(dialog)
    end
    dialog = ButtonDialog:new {
        title = MirrorsPage.describeSite(record, os.time()),
        buttons = {
            {
                {
                    text = _("Check"),
                    callback = function()
                        close()
                        this:check(origin)
                    end,
                },
                {
                    text = trusted and _("Revoke") or _("Approve"),
                    callback = function()
                        close()
                        if trusted then
                            this:confirmRevoke(record)
                        else
                            this:checkThenApprove(record)
                        end
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = close,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function MirrorsPage:refreshFromSlum()
    NetworkTask.run("looking up Anna's Archive's sites", _("Looking up Anna's Archive's sites on SLUM..."), function()
        return AnnasMirrors:refresh()
    end, function(ok, err)
        if err == HttpUtil.CANCELLED or err == AnnasMirrors.FAILURE.CANCELLED then
            LogUtil.info("looking up Anna's Archive's sites was called off")
            return
        end
        if ok then
            local count = #AnnasMirrors:list("catalogue")
            NotifyUtil.info(T(N_("Anna's Archive has 1 site", "Anna's Archive has %1 sites", count), count))
        else
            NotifyUtil.error(T(_("SLUM couldn't be read: %1. The sites known before are kept."), err))
        end
        self:refreshMenu()
    end)
end

-- Checks that a site answers as Anna's Archive does, then calls done(ok).
function MirrorsPage:check(origin, done)
    local host = recordFor(origin).host
    NetworkTask.run("checking " .. host, T(_("Checking %1..."), host), function()
        return AnnasMirrors:probe(origin)
    end, function(ok, failure, info)
        if failure == AnnasMirrors.FAILURE.CANCELLED then
            return
        end
        if ok then
            if not done then
                NotifyUtil.info(T(_("%1 answers as Anna's Archive does"), host))
            end
        else
            NotifyUtil.error(
                T(
                    _("%1 couldn't be checked: %2"),
                    host,
                    AnnasMirrors.describe({ failure = failure, retry_after = info and info.retry_after })
                )
            )
        end
        self:refreshMenu()
        if done then
            done(ok)
        end
    end)
end

-- Checks a site, then asks before approving it to be sent the key.
function MirrorsPage:checkThenApprove(record)
    self:check(record.origin, function(ok)
        if not ok then
            return
        end
        UIManager:show(ConfirmBox:new {
            text = T(
                _(
                    "%1 answers as Anna's Archive does. Approve it to be sent your key? Only approve a site you "
                        .. "know to be Anna's Archive's own, as a look-alike could keep your key."
                ),
                record.host
            ),
            ok_text = _("Approve"),
            ok_callback = function()
                local approved, err = AnnasMirrors:approve(record.origin)
                if approved then
                    NotifyUtil.info(T(_("%1 approved"), record.host))
                else
                    NotifyUtil.error(err)
                end
                self:refreshMenu()
            end,
        })
    end)
end

function MirrorsPage:confirmRevoke(record)
    UIManager:show(ConfirmBox:new {
        text = T(_("Stop sending your key to %1? It can be approved again later."), record.host),
        ok_text = _("Revoke"),
        ok_callback = function()
            local ok, err = AnnasMirrors:revoke(record.origin)
            if ok then
                NotifyUtil.info(T(_("%1 revoked"), record.host))
            else
                NotifyUtil.error(err)
            end
            self:refreshMenu()
        end,
    })
end

function MirrorsPage:confirmReset()
    UIManager:show(ConfirmBox:new {
        text = _(
            "Go back to the sites FetchAnna was released with? The sites looked up on SLUM, how each has been "
                .. "doing, and which you approved or revoked are forgotten."
        ),
        ok_text = _("Reset"),
        ok_callback = function()
            local ok, err = AnnasMirrors:reset()
            if ok then
                NotifyUtil.info(_("Sites reset"))
            else
                NotifyUtil.error(err)
            end
            self:refreshMenu()
        end,
    })
end

return MirrorsPage
