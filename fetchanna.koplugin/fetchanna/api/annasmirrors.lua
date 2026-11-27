local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local JSON = require("json")
local HttpUtil = require("fetchanna.util.httputil")
local CurlUtil = require("fetchanna.util.curlutil")
local LogUtil = require("fetchanna.util.logutil")
local OriginPolicy = require("fetchanna.util.originpolicy")
local TimeUtil = require("fetchanna.util.timeutil")
local SlumParser = require("fetchanna.api.slumparser")
local AnnasParser = require("fetchanna.api.annasparser")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local KeyStore = require("fetchanna.api.keystore")
local T = require("ffi/util").template
local _ = require("gettext")

-- Anna's Archive's sites: which exist, what each is for, how each is doing, and which are trusted with the key (see
-- docs/annas-protocol.md).
-- They're looked up on SLUM (see SlumParser), but a listing never makes a site trusted. Only being a reviewed built-in
-- site (SEEDS) does, or being approved on the device after it was checked to answer as Anna's Archive does (see probe).
-- A trusted site that SLUM stops listing, or that stops answering as Anna's Archive, isn't sent the key until that's
-- put right or it's approved again.
-- Operations try a few sites in turn (see run), and say why when none worked.
local AnnasMirrors = {}

-- Where the sites are looked up.
AnnasMirrors.SLUM_URL = "https://open-slum.org/annas.html"
-- Where to send someone to search in a browser when there's no other site. Needs nothing of the account's.
AnnasMirrors.SEARCH_FALLBACK = "https://annas-archive.gl"
-- The built-in sites, and when they were last checked by hand to be Anna's Archive's.
AnnasMirrors.SEEDS_REVIEWED = "2026-11-11"
local SEEDS = {
    { origin = "https://annas-archive.gl", role = SlumParser.CATALOGUE },
    { origin = "https://annas-archive.pk", role = SlumParser.CATALOGUE },
    { origin = "https://annas-archive.gd", role = SlumParser.CATALOGUE },
    { origin = "https://software.annas-archive.gl", role = SlumParser.SOFTWARE },
}

-- What can be asked of a site. Each is tracked separately, as a site may search but not log in.
AnnasMirrors.PROBE = "probe"
AnnasMirrors.SEARCH = "search"
AnnasMirrors.ACCOUNT = "account"
AnnasMirrors.API = "api"
AnnasMirrors.TRANSFER = "transfer"
local ROLE_FOR = {
    probe = SlumParser.CATALOGUE,
    search = SlumParser.CATALOGUE,
    account = SlumParser.CATALOGUE,
    api = SlumParser.CATALOGUE,
    transfer = SlumParser.DOWNLOAD,
}
-- Those asked as the account, so only of trusted sites.
local CREDENTIALED = {
    search = true,
    account = true,
    api = true,
}

-- Why asking a site failed. The first are the site's doing: the next site is tried, and this one rests for a while (see
-- COOLDOWN_BASE). The rest would be the same on any site, so no other is tried.
AnnasMirrors.FAILURE = {
    UNRESOLVED = "unresolved",
    CONNECT = "connect",
    TIMEOUT = "timeout",
    TLS = "tls",
    SERVER = "server_error",
    CHALLENGE = "challenge",
    RATE_LIMITED = "rate_limited",
    UNEXPECTED = "unexpected",
    REDIRECTED = "redirected",
    BLOCKED = "blocked",
    INVALID_KEY = "invalid_key",
    NOT_MEMBER = "not_member",
    QUOTA = "quota",
    NOT_FOUND = "not_found",
    UNAVAILABLE = "unavailable",
    CANCELLED = "cancelled",
    -- Before any site is asked.
    NO_MIRRORS = "no_mirrors",
    NO_TRUSTED = "no_trusted",
}
local FAILURE = AnnasMirrors.FAILURE
local MIRROR_FAILURES = {
    [FAILURE.UNRESOLVED] = true,
    [FAILURE.CONNECT] = true,
    [FAILURE.TIMEOUT] = true,
    [FAILURE.TLS] = true,
    [FAILURE.SERVER] = true,
    [FAILURE.CHALLENGE] = true,
    [FAILURE.RATE_LIMITED] = true,
    [FAILURE.UNEXPECTED] = true,
    [FAILURE.REDIRECTED] = true,
    [FAILURE.BLOCKED] = true,
}
-- Those where the site answered, which say more than that it couldn't be reached.
local ANSWERED_FAILURES = {
    [FAILURE.SERVER] = true,
    [FAILURE.CHALLENGE] = true,
    [FAILURE.RATE_LIMITED] = true,
    [FAILURE.UNEXPECTED] = true,
    [FAILURE.REDIRECTED] = true,
}

-- Whether a site can be sent the key, and why.
AnnasMirrors.TRUST = {
    SEED = "seed",
    APPROVED = "approved",
    UNTRUSTED = "untrusted",
    REVOKED = "revoked",
    SUSPENDED = "suspended",
}
local TRUST = AnnasMirrors.TRUST

local STORE_FILE = "fetchanna_mirrors.lua"
-- How long SLUM's list is used before it's looked up again, when next needed (never in the background), and how long to
-- wait after SLUM couldn't be read.
local DISCOVERY_MAX_AGE = 24 * 60 * 60
local DISCOVERY_RETRY_AFTER = 60 * 60
-- How many sites an operation tries, and for how many seconds, before giving up.
local MAX_CANDIDATES = 3
local DEADLINE = 30
-- How long a failed site rests: a minute, doubling with each failure in a row, up to an hour, or as long as it asked
-- (up to 6 hours).
local COOLDOWN_BASE = 60
local COOLDOWN_MAX = 60 * 60
local RETRY_AFTER_MAX = 6 * 60 * 60
-- How long a site SLUM no longer lists is remembered, unless it's built in or approved.
local FORGET_DELISTED_AFTER = 30 * 24 * 60 * 60

local ROLES = {
    [SlumParser.CATALOGUE] = true,
    [SlumParser.SOFTWARE] = true,
    [SlumParser.DOWNLOAD] = true,
}
local SOURCES = {
    seed = true,
    slum = true,
}
local STATUSES = {
    up = true,
    protected = true,
    degraded = true,
    down = true,
    unknown = true,
}

-- The sites, as saved in STORE_FILE: { records = { [origin] = record }, discovery, last_working = { [capability] =
-- origin } }. Loaded when first needed.
local store, store_file

local function number(value)
    return type(value) == "number" and value or nil
end

local function newRecord(origin, role, source, now)
    return {
        origin = origin,
        host = OriginPolicy.hostOf(origin),
        role = role,
        source = source,
        first_seen = now,
        health = {},
    }
end

-- Returns a saved record, checked, or nil when it can't be used. The file can be edited by hand or cut short.
local function validRecord(origin, saved)
    if type(saved) ~= "table" or OriginPolicy.canonicalOrigin(origin) ~= origin or not ROLES[saved.role] then
        return nil
    end
    local record =
        newRecord(origin, saved.role, SOURCES[saved.source] and saved.source or "slum", number(saved.first_seen))
    for __, field in ipairs({ "last_listed", "delisted_at", "verified_at", "impostor_at" }) do
        record[field] = number(saved[field])
    end
    record.slum_id = type(saved.slum_id) == "string" and saved.slum_id or nil
    if type(saved.slum) == "table" then
        record.slum = {
            status = STATUSES[saved.slum.status] and saved.slum.status or "unknown",
            checked_at = number(saved.slum.checked_at),
            expected_status = number(saved.slum.expected_status),
            actual_status = number(saved.slum.actual_status),
            latency_ms = number(saved.slum.latency_ms),
        }
    end
    if type(saved.health) == "table" then
        for capability, health in pairs(saved.health) do
            if ROLE_FOR[capability] and type(health) == "table" then
                record.health[capability] = {
                    ok_at = number(health.ok_at),
                    fail_at = number(health.fail_at),
                    failure = type(health.failure) == "string" and health.failure or nil,
                    failures = number(health.failures) or 0,
                    cooldown_until = number(health.cooldown_until),
                }
            end
        end
    end
    return record
end

local function openStore()
    if not store_file then
        store_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. STORE_FILE)
    end
    return store_file
end

-- Returns the known sites. The built-in ones are always among them, with their built-in roles.
local function load()
    if store then
        return store
    end
    local file = openStore()
    local saved = file:readSetting("records")
    local records = {}
    for origin, record in pairs(type(saved) == "table" and saved or {}) do
        records[origin] = validRecord(origin, record)
    end
    local now = os.time()
    for __, seed in ipairs(SEEDS) do
        local record = records[seed.origin]
        if not record then
            records[seed.origin] = newRecord(seed.origin, seed.role, "seed", now)
        else
            record.source, record.role = "seed", seed.role
        end
    end

    local discovery = file:readSetting("discovery")
    discovery = type(discovery) == "table" and discovery or {}
    local last_working = {}
    local saved_working = file:readSetting("last_working")
    for capability, origin in pairs(type(saved_working) == "table" and saved_working or {}) do
        if ROLE_FOR[capability] and records[origin] then
            last_working[capability] = origin
        end
    end
    store = {
        records = records,
        discovery = {
            fetched_at = number(discovery.fetched_at),
            generated_at = number(discovery.generated_at),
            last_error = type(discovery.last_error) == "string" and discovery.last_error or nil,
            last_error_at = number(discovery.last_error_at),
        },
        last_working = last_working,
    }
    return store
end

local function save()
    local file = openStore()
    file:saveSetting("records", store.records)
    file:saveSetting("discovery", store.discovery)
    file:saveSetting("last_working", store.last_working)
    file:flush()
end

-- Trust.

-- Returns whether a site can be sent the key (see TRUST), and since when it's been suspended or revoked.
function AnnasMirrors:trustOf(origin)
    local record = load().records[origin]
    if not record or record.role ~= SlumParser.CATALOGUE then
        return TRUST.UNTRUSTED
    end
    local decision = FetchAnnaSettings:getMirrorTrust()[origin]
    if decision and decision.revoked_at then
        return TRUST.REVOKED, decision.revoked_at
    end
    local trust
    if decision and decision.approved_at then
        trust = TRUST.APPROVED
    elseif record.source == "seed" then
        trust = TRUST.SEED
    else
        return TRUST.UNTRUSTED
    end
    -- Suspended: since it was approved, SLUM stopped listing it or it stopped answering as Anna's Archive does.
    local suspended_at = math.max(record.delisted_at or 0, record.impostor_at or 0)
    if suspended_at > 0 and not (decision and decision.approved_at and decision.approved_at > suspended_at) then
        return TRUST.SUSPENDED, suspended_at
    end
    return trust
end

function AnnasMirrors:isTrusted(origin)
    local trust = self:trustOf(origin)
    return trust == TRUST.SEED or trust == TRUST.APPROVED
end

-- Trusts a site with the key from now on, once it has been checked to answer as Anna's Archive does (see probe).
-- Returns true, or nil and why not.
function AnnasMirrors:approve(origin)
    local record = load().records[origin]
    if not record or record.role ~= SlumParser.CATALOGUE then
        return nil, _("Only Anna's Archive's own sites can be sent your key.")
    end
    if not record.verified_at or record.impostor_at then
        return nil, _("This site hasn't been checked to be Anna's Archive yet.")
    end
    local trust = FetchAnnaSettings:getMirrorTrust()
    trust[origin] = { approved_at = os.time() }
    LogUtil.info("approved", record.host, "to be sent the account's key")
    return FetchAnnaSettings:setMirrorTrust(trust)
end

-- Stops sending a site the key until it's approved again, and forgets its session.
function AnnasMirrors:revoke(origin)
    KeyStore.dropSession(origin)
    local trust = FetchAnnaSettings:getMirrorTrust()
    trust[origin] = { revoked_at = os.time() }
    local working = load().last_working
    for capability, working_origin in pairs(working) do
        if working_origin == origin and CREDENTIALED[capability] then
            working[capability] = nil
        end
    end
    save()
    LogUtil.info("revoked", OriginPolicy.hostOf(origin) or origin, "being sent the account's key")
    return FetchAnnaSettings:setMirrorTrust(trust)
end

-- Goes back to the built-in sites. Forgets the sites looked up, their health, approvals and revocations, and every
-- session.
function AnnasMirrors:reset()
    KeyStore.dropSession()
    store = nil
    local file = openStore()
    file:delSetting("records")
    file:delSetting("discovery")
    file:delSetting("last_working")
    load()
    save()
    LogUtil.info("reset Anna's Archive's sites to those FetchAnna was released with")
    return FetchAnnaSettings:setMirrorTrust({})
end

-- Returns copies of the records for a role (all without one), with trust and trust_since added. Built-in sites first,
-- then by host.
function AnnasMirrors:list(role)
    local list = {}
    for origin, record in pairs(load().records) do
        if not role or record.role == role then
            local copy = {}
            for key, value in pairs(record) do
                copy[key] = value
            end
            copy.trust, copy.trust_since = self:trustOf(origin)
            table.insert(list, copy)
        end
    end
    table.sort(list, function(a, b)
        if (a.source == "seed") ~= (b.source == "seed") then
            return a.source == "seed"
        end
        return a.host < b.host
    end)
    return list
end

-- Discovery.

-- Returns SLUM's page, following redirects only within SLUM, or nil and why not.
local function fetchSlum()
    local url = AnnasMirrors.SLUM_URL
    for __ = 1, 3 do
        local body, err, status, headers = HttpUtil.getBody(url, { follow_redirects = false })
        if not body then
            return nil, err
        end
        if status and status >= 300 and status < 400 then
            local target, same = OriginPolicy.resolveRedirect(url, headers and headers.location)
            if not (target and same) then
                LogUtil.warn(
                    "SLUM redirected to another site, which isn't followed:",
                    tostring(headers and headers.location)
                )
                return nil, _("SLUM sent FetchAnna to another site")
            end
            url = target
        elseif status ~= 200 then
            return nil, T(_("SLUM answered with an error (HTTP %1)"), tostring(status))
        else
            return body
        end
    end
    return nil, _("SLUM redirected too many times")
end

-- Takes in what SLUM lists. Returns how many catalogue sites it lists.
local function merge(parsed, now)
    local records = store.records
    local listed = {}
    for __, found in ipairs(parsed.records) do
        listed[found.origin] = true
        local record = records[found.origin]
        if not record then
            record = newRecord(found.origin, found.role, "slum", now)
            records[found.origin] = record
            LogUtil.info("SLUM lists a site not known before:", found.host, "(" .. found.role .. ")")
        elseif record.role ~= found.role then
            if record.source == "seed" then
                -- A built-in site's role isn't changed by a page anyone could change.
                LogUtil.warn(
                    "SLUM lists",
                    found.host,
                    "as a",
                    found.role,
                    "site, but it was released as a",
                    record.role,
                    "site"
                )
            else
                record.role = found.role
            end
        end
        if record.delisted_at then
            LogUtil.info("SLUM lists", found.host, "again")
        end
        record.slum_id = found.slum_id
        record.last_listed = now
        record.delisted_at = nil
        record.slum = {
            status = found.status,
            checked_at = parsed.generated_at or now,
            expected_status = found.expected_status,
            actual_status = found.actual_status,
            latency_ms = found.latency_ms,
        }
    end

    local trust = FetchAnnaSettings:getMirrorTrust()
    for origin, record in pairs(records) do
        if not listed[origin] then
            -- A site SLUM never listed (only a built-in one) isn't counted as gone.
            if record.last_listed and not record.delisted_at then
                record.delisted_at = now
                LogUtil.warn("SLUM no longer lists", record.host)
            end
            local remembered = record.source == "seed" or trust[origin]
            if not remembered and record.delisted_at and now - record.delisted_at > FORGET_DELISTED_AFTER then
                records[origin] = nil
            end
        end
    end

    local catalogue = 0
    for __, found in ipairs(parsed.records) do
        if found.role == SlumParser.CATALOGUE then
            catalogue = catalogue + 1
        end
    end
    return catalogue
end

-- Looks the sites up on SLUM again. Returns true, or nil and why not. SLUM's list is only taken in when it has a
-- catalogue site. Otherwise the known sites are kept, as an empty list would leave nothing to use.
function AnnasMirrors:refresh()
    load()
    local now = os.time()
    HttpUtil.sayStatus(_("Looking up Anna's Archive's sites on SLUM..."))
    local html, err = fetchSlum()
    HttpUtil.sayStatus(nil)
    if err == HttpUtil.CANCELLED then
        return nil, err
    end
    local parsed
    if html then
        parsed, err = SlumParser.parse(html)
    end
    if parsed then
        local listed = {}
        for __, found in ipairs(parsed.records) do
            if found.role == SlumParser.CATALOGUE then
                listed[#listed + 1] = found
            end
        end
        if #listed == 0 then
            parsed, err = nil, _("SLUM lists none of Anna's Archive's own sites")
        end
    end
    if not parsed then
        LogUtil.warn("could not look up Anna's Archive's sites on SLUM, so keeping those known:", err)
        store.discovery.last_error = err
        store.discovery.last_error_at = now
        save()
        return nil, err
    end

    local catalogue = merge(parsed, now)
    store.discovery = {
        fetched_at = now,
        generated_at = parsed.generated_at,
    }
    save()
    LogUtil.info(
        "SLUM lists",
        #parsed.records,
        "of Anna's Archive's sites,",
        catalogue,
        "of them to search and log into"
    )
    return true
end

-- Looks the sites up again if the list is too old or missing, but not soon after SLUM couldn't be read. Returns whether
-- the list is up to date, and why not.
function AnnasMirrors:ensureDiscovery()
    local discovery = load().discovery
    local now = os.time()
    if discovery.fetched_at and now >= discovery.fetched_at and now - discovery.fetched_at < DISCOVERY_MAX_AGE then
        return true
    end
    if
        discovery.last_error_at
        and now >= discovery.last_error_at
        and now - discovery.last_error_at < DISCOVERY_RETRY_AFTER
    then
        return false, discovery.last_error
    end
    local ok, err = self:refresh()
    return ok == true, err
end

-- Returns when the sites were last looked up, when SLUM made that page (each nil if never), and the last error with its
-- time.
function AnnasMirrors:discovery()
    local discovery = load().discovery
    return {
        fetched_at = discovery.fetched_at,
        generated_at = discovery.generated_at,
        last_error = discovery.last_error,
        last_error_at = discovery.last_error_at,
    }
end

-- Health.

-- Returns a FAILURE and details (e.g. retry_after) for what HttpUtil.getBody returned when a request didn't get what it
-- asked for.
function AnnasMirrors.classify(body, err, status, headers)
    if err == HttpUtil.CANCELLED then
        return FAILURE.CANCELLED
    end
    -- Cloudflare says when it answered with a browser check, whatever the page looks like.
    local cloudflare_check = headers and headers["cf-mitigated"] == "challenge"
    if cloudflare_check or (body and AnnasMirrors.isChallenge(body)) then
        return FAILURE.CHALLENGE
    end
    if status == 429 or status == 503 then
        local retry_after = TimeUtil.parseRetryAfter(headers and headers["retry-after"], os.time())
        if status == 429 or retry_after then
            return FAILURE.RATE_LIMITED, { retry_after = retry_after }
        end
    end
    if status and status >= 500 then
        return FAILURE.SERVER
    end
    if status and status >= 300 and status < 400 then
        -- How Anna's Archive sends non-members to a browser check (see docs/annas-protocol.md).
        local location = headers and headers.location
        if type(location) == "string" and location:find("[?&]check=1") then
            return FAILURE.CHALLENGE
        end
        return FAILURE.REDIRECTED
    end
    if not body and not status then
        if err == HttpUtil.UNRESOLVED then
            return FAILURE.UNRESOLVED
        elseif err and CurlUtil.isTlsFailure(err) then
            return FAILURE.TLS
        elseif err == CurlUtil.getErrorMeaning(28) then
            return FAILURE.TIMEOUT
        end
        return FAILURE.CONNECT
    end
    return FAILURE.UNEXPECTED
end

-- Whether a page is a browser check, which FetchAnna never tries to get past (see AnnasParser.isChallenge).
AnnasMirrors.isChallenge = AnnasParser.isChallenge

local function healthOf(record, capability)
    local health = record.health[capability]
    if not health then
        health = { failures = 0 }
        record.health[capability] = health
    end
    return health
end

-- Notes that capability worked on the site.
function AnnasMirrors:recordSuccess(origin, capability)
    local record = load().records[origin]
    if not record then
        return
    end
    local health = healthOf(record, capability)
    health.ok_at = os.time()
    health.failures = 0
    health.failure = nil
    health.cooldown_until = nil
    store.last_working[capability] = origin
end

-- Notes that capability failed on the site, and why. When it was the site's doing, the site rests for a while.
-- info.retry_after is how long it asked to be left, in seconds.
function AnnasMirrors:recordFailure(origin, capability, failure, info)
    local record = load().records[origin]
    if not record or not MIRROR_FAILURES[failure] then
        return
    end
    local now = os.time()
    local health = healthOf(record, capability)
    health.fail_at = now
    health.failure = failure
    health.failures = (health.failures or 0) + 1
    local cooldown = math.min(COOLDOWN_BASE * 2 ^ (health.failures - 1), COOLDOWN_MAX)
    local retry_after = info and number(info.retry_after)
    if retry_after then
        cooldown = math.max(cooldown, math.min(retry_after, RETRY_AFTER_MAX))
    end
    health.cooldown_until = now + cooldown
    if store.last_working[capability] == origin then
        store.last_working[capability] = nil
    end
end

-- Ranks a site for capability, lower first: last worked, has worked since it last failed, checked to be Anna's Archive,
-- built in, then by SLUM's status.
local function rank(record, capability)
    local health = record.health[capability] or {}
    if store.last_working[capability] == record.origin then
        return 1
    elseif health.ok_at and (not health.fail_at or health.ok_at >= health.fail_at) then
        return 2
    elseif record.verified_at and not record.impostor_at then
        return 3
    elseif record.source == "seed" then
        return 4
    end
    local status = record.slum and record.slum.status
    if status == "up" or status == "protected" then
        return 5
    elseif status == "degraded" then
        return 6
    end
    return 7
end

-- Returns the sites to try for capability, best first (see rank), resting ones last, at most opts.limit (default 3).
-- Only sites for its role that SLUM still lists, and only trusted ones when asked as the account (opts.credentials, the
-- default for searching, logging in and the member API).
function AnnasMirrors:candidates(capability, opts)
    opts = opts or {}
    local role = assert(ROLE_FOR[capability], "unknown capability")
    local credentials = opts.credentials
    if credentials == nil then
        credentials = CREDENTIALED[capability] or false
    end
    local now = os.time()
    local eligible = {}
    for origin, record in pairs(load().records) do
        if record.role == role and not record.delisted_at and (not credentials or self:isTrusted(origin)) then
            local health = record.health[capability] or {}
            table.insert(eligible, {
                record = record,
                resting = health.cooldown_until ~= nil and health.cooldown_until > now,
                rank = rank(record, capability),
                ok_at = health.ok_at or 0,
            })
        end
    end
    table.sort(eligible, function(a, b)
        if a.resting ~= b.resting then
            return not a.resting
        end
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        if a.ok_at ~= b.ok_at then
            return a.ok_at > b.ok_at
        end
        return a.record.origin < b.record.origin
    end)
    local origins = {}
    for i = 1, math.min(#eligible, opts.limit or MAX_CANDIDATES) do
        origins[i] = eligible[i].record.origin
    end
    return origins
end

-- Asks the sites for capability in turn (see candidates) with attempt(origin, info), until one succeeds. attempt
-- returns the result, or nil, a FAILURE and details ({ retry_after = seconds, detail = text }). info has the site's
-- index, the count, and the deadline (by os.time).
-- No site is asked after opts.deadline seconds (default 30), nor one whose name leads to a private network (see
-- OriginPolicy.checkHost).
-- opts.stop_on names failures that are the account's doing for this operation, though otherwise the site's (as a
-- browser check is when searching as a member). They stop the run as the others do.
-- Returns the result and the site that gave it, or nil and an outcome: { failure, tried = { { origin, failure, detail }
-- }, stopped = true when it wasn't the sites' doing }.
function AnnasMirrors:run(capability, attempt, opts)
    opts = opts or {}
    local credentials = opts.credentials
    if credentials == nil then
        credentials = CREDENTIALED[capability] or false
    end
    local candidates = self:candidates(capability, opts)
    local outcome = { capability = capability, tried = {} }
    if #candidates == 0 then
        outcome.failure = credentials
                and #self:candidates(capability, { credentials = false }) > 0
                and FAILURE.NO_TRUSTED
            or FAILURE.NO_MIRRORS
        LogUtil.warn("no site to", capability, "on:", outcome.failure)
        return nil, outcome
    end

    local deadline = os.time() + (opts.deadline or DEADLINE)
    for index, origin in ipairs(candidates) do
        if index > 1 and os.time() >= deadline then
            LogUtil.warn("gave up trying sites to", capability, "on after", opts.deadline or DEADLINE, "seconds")
            outcome.timed_out = true
            break
        end
        local host = OriginPolicy.hostOf(origin)
        HttpUtil.sayStatus(T(_("Trying %1 (site %2 of %3)..."), host, index, #candidates))
        local result, failure, info
        local allowed = OriginPolicy.checkHost(host)
        if allowed then
            result, failure, info = attempt(origin, { index = index, count = #candidates, deadline = deadline })
        else
            failure = FAILURE.BLOCKED
        end
        if result ~= nil then
            HttpUtil.sayStatus(nil)
            self:recordSuccess(origin, capability)
            save()
            return result, origin
        end
        failure = failure or FAILURE.UNEXPECTED
        table.insert(outcome.tried, { origin = origin, failure = failure, detail = info and info.detail })
        if failure == FAILURE.CANCELLED then
            HttpUtil.sayStatus(nil)
            outcome.failure = failure
            outcome.stopped = true
            save()
            return nil, outcome
        end
        LogUtil.warn("could not", capability, "on", host .. ":", failure, info and info.detail or "")
        -- The account's doing for this operation (opts.stop_on): not counted against the site, and no other site is
        -- tried.
        local account_wide = opts.stop_on and opts.stop_on[failure]
        if not account_wide then
            self:recordFailure(origin, capability, failure, info)
        end
        if not MIRROR_FAILURES[failure] or account_wide then
            HttpUtil.sayStatus(nil)
            outcome.failure = failure
            outcome.stopped = true
            save()
            return nil, outcome
        end
        if failure == FAILURE.RATE_LIMITED then
            outcome.retry_after = info and number(info.retry_after)
        end
    end
    HttpUtil.sayStatus(nil)
    save()

    -- Why, when every site failed: what they all said, else what the last one that answered said, else what the last
    -- said.
    local failure = outcome.tried[#outcome.tried].failure
    local answered
    for __, tried in ipairs(outcome.tried) do
        if tried.failure ~= failure then
            outcome.mixed = true
        end
        if ANSWERED_FAILURES[tried.failure] then
            answered = tried.failure
        end
    end
    outcome.failure = outcome.mixed and answered or failure
    return nil, outcome
end

-- Checking a site.

-- Whether a site answers as Anna's Archive does, without sending it anything of the account's. Its member API, asked
-- for nothing, says what it is and that it got no file to find (see docs/annas-protocol.md).
-- Returns true, or nil, a FAILURE and details. A site that answers otherwise is suspended (see trustOf) until it
-- answers as Anna's Archive again.
function AnnasMirrors:probe(origin)
    local record = load().records[origin]
    if not record or record.role ~= SlumParser.CATALOGUE then
        return nil, FAILURE.UNEXPECTED
    end
    if not OriginPolicy.checkHost(record.host) then
        self:recordFailure(origin, AnnasMirrors.PROBE, FAILURE.BLOCKED)
        save()
        return nil, FAILURE.BLOCKED
    end
    local body, err, status, headers = HttpUtil.getBody(origin .. "/dyn/api/fast_download.json", {
        follow_redirects = false,
    })
    local ok, data = false, nil
    if body and status == 400 then
        ok, data = pcall(JSON.decode, body)
    end
    local now = os.time()
    if ok and type(data) == "table" and type(data["///download_url"]) == "table" and data.error == "Invalid md5" then
        record.verified_at = now
        if record.impostor_at then
            LogUtil.info(record.host, "answers as Anna's Archive again")
        end
        record.impostor_at = nil
        self:recordSuccess(origin, AnnasMirrors.PROBE)
        save()
        return true
    end

    local failure, info = AnnasMirrors.classify(body, err, status, headers)
    if failure == FAILURE.CANCELLED then
        return nil, failure
    end
    if failure == FAILURE.UNEXPECTED then
        -- It answered, but not as Anna's Archive does, as a site that's been taken over might.
        LogUtil.warn(
            record.host,
            "answered the member API as Anna's Archive doesn't: HTTP",
            tostring(status),
            body and LogUtil.excerpt(body) or ""
        )
        record.impostor_at = record.impostor_at or now
    end
    self:recordFailure(origin, AnnasMirrors.PROBE, failure, info)
    save()
    return nil, failure, info
end

-- What to say when no site worked (see run).
local MESSAGES = {
    [FAILURE.UNRESOLVED] = _(
        "Anna's Archive's sites couldn't be found. The network may be blocking them: try turning on Encrypted DNS in "
            .. "the settings."
    ),
    [FAILURE.CONNECT] = _("Anna's Archive didn't answer. Check the Wi-Fi connection, or try again later."),
    [FAILURE.TIMEOUT] = _("Anna's Archive took too long to answer. Try again later."),
    [FAILURE.TLS] = _("Anna's Archive couldn't be connected to securely. Check the device's date and time."),
    [FAILURE.SERVER] = _("Anna's Archive answered with an error. Try again later."),
    [FAILURE.CHALLENGE] = _(
        "Anna's Archive asked for a browser check, which FetchAnna doesn't do. It only lets members whose membership "
            .. "skips it search without one."
    ),
    [FAILURE.RATE_LIMITED] = _("Anna's Archive asked FetchAnna to wait before asking again."),
    [FAILURE.UNEXPECTED] = _("Anna's Archive answered with something FetchAnna couldn't read. It may have changed."),
    [FAILURE.REDIRECTED] = _("Anna's Archive's site tried to send FetchAnna to another site, which isn't followed."),
    [FAILURE.BLOCKED] = _("Anna's Archive's site leads to an address on a private network, so it wasn't asked."),
    [FAILURE.NO_MIRRORS] = _("No site of Anna's Archive's can be tried. Refresh the list of sites under Mirrors."),
    [FAILURE.NO_TRUSTED] = _(
        "None of Anna's Archive's sites is approved to be sent your key. Approve one under Mirrors."
    ),
    -- Not the sites' doing (see run): the same on any of them.
    [FAILURE.INVALID_KEY] = _(
        "Anna's Archive doesn't accept your key. Check it against the one on your account page on Anna's Archive."
    ),
    [FAILURE.NOT_MEMBER] = _("Your account has no membership with fast downloads."),
    [FAILURE.QUOTA] = _("Your account has used all of today's fast downloads."),
    [FAILURE.NOT_FOUND] = _("Anna's Archive has no such file."),
    [FAILURE.UNAVAILABLE] = _("Anna's Archive can't give that file right now."),
    [FAILURE.CANCELLED] = _("Called off."),
}

-- Returns what to say about why an operation failed (see run).
function AnnasMirrors.describe(outcome)
    local message = MESSAGES[outcome.failure] or T(_("Anna's Archive couldn't be reached (%1)."), outcome.failure)
    if outcome.failure == FAILURE.RATE_LIMITED and outcome.retry_after then
        message = message .. " " .. T(_("Try again in %1 minutes."), math.max(1, math.ceil(outcome.retry_after / 60)))
    end
    return message
end

return AnnasMirrors
