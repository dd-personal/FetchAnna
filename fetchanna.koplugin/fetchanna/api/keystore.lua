local DataStorage = require("datastorage")
local FetchAnnaSettings = require("fetchanna.settings.settings")
local LogUtil = require("fetchanna.util.logutil")
local OriginPolicy = require("fetchanna.util.originpolicy")

-- Holds the key, its sessions (see AnnasAccount) and the account info, apart from everything else: not in the settings,
-- caches or diagnostics, nor in the plugin's folder, which updates back up.
-- Kept only until KOReader restarts, unless the user chose to remember them (see FetchAnnaSettings:getRememberKey).
-- Then they're in a file of their own (see path), readable by its owner only where the storage allows.
-- The file isn't encrypted: whatever decrypted it would have to sit beside it.
-- The key and sessions are never logged (see LogUtil.addSecret).
local KeyStore = {}

local FILE_NAME = "fetchanna_key.txt"
local HEADER = "# FetchAnna: your Anna's Archive secret key and login sessions, kept because you asked for them to "
    .. "be remembered. This file isn't encrypted: anyone who can read this device's storage can read it."
-- 0600: read and write for the owner only.
local OWNER_ONLY = 384
-- Account info (see AnnasAccount). For the last download link, only its host names, never the link (see SECRET_LINKS in
-- Sources).
local INFO_FIELDS = {
    verified_at = "number",
    invalid_at = "number",
    logged_in_at = "number",
    tier = "number",
    tier_checked_at = "number",
    downloads_left = "number",
    downloads_per_day = "number",
    downloads_checked_at = "number",
    failure = "string",
    failure_at = "number",
    last_link_at = "number",
    last_link_site = "string",
    last_link_server = "string",
}

-- The key, sessions (by origin: { value, expires_at, created_at }) and account info, read from the file when first
-- needed.
local state

-- Returns the file the key is remembered in.
function KeyStore.path()
    return DataStorage:getSettingsDir() .. "/" .. FILE_NAME
end

-- Whether key could be a key. Anna's Archive's are letters and digits, and it turns down any shorter than 20. Nothing
-- else is let in, as the key is sent in a form and in the member API's URL.
function KeyStore.isValidKey(key)
    return type(key) == "string" and #key >= 20 and #key <= 100 and key:find("^%w+$") ~= nil
end

-- Whether value looks like one of Anna's Archive's session cookies. Nothing else gets into a request.
function KeyStore.isValidSession(value)
    return type(value) == "string" and #value >= 8 and #value <= 4096 and value:find("^[%w%-_%.]+$") ~= nil
end

-- Makes the file readable by its owner only, where the storage has owners (the FAT storage Kindles and Kobos share over
-- USB doesn't). Done in-process, not by a command with the path in it.
local function restrictToOwner(path)
    local ok, restricted = pcall(function()
        local ffi = require("ffi")
        pcall(ffi.cdef, "int chmod(const char *pathname, unsigned int mode);")
        return ffi.C.chmod(path, OWNER_ONLY) == 0
    end)
    return ok and restricted
end

local function remove()
    os.remove(KeyStore.path() .. ".new")
    return os.remove(KeyStore.path())
end

-- Writes the file when the key is remembered, and removes it otherwise. Returns true, or nil and why not.
-- Writes to a new file, made owner-only while empty, then renames it over the old one.
local function save()
    if not FetchAnnaSettings:getRememberKey() or not state.key then
        remove()
        return true
    end
    local lines = { HEADER, "key " .. state.key }
    for origin, session in pairs(state.sessions) do
        table.insert(
            lines,
            string.format(
                "session %s %s %d %d",
                origin,
                session.value,
                session.expires_at or 0,
                session.created_at or 0
            )
        )
    end
    for name, value in pairs(state.info) do
        table.insert(lines, string.format("info %s %s", name, tostring(value)))
    end

    local new_path = KeyStore.path() .. ".new"
    os.remove(new_path)
    local file, err = io.open(new_path, "w")
    if not file then
        LogUtil.warn("could not remember the key:", err)
        return nil, err
    end
    file:close()
    restrictToOwner(new_path)
    file, err = io.open(new_path, "w")
    if not file then
        os.remove(new_path)
        return nil, err
    end
    local written = file:write(table.concat(lines, "\n"), "\n")
    file:close()
    local renamed, rename_err
    if written then
        renamed, rename_err = os.rename(new_path, KeyStore.path())
    end
    if not renamed then
        os.remove(new_path)
        LogUtil.warn("could not remember the key:", rename_err or "could not write it")
        return nil, rename_err or "could not write it"
    end
    return true
end

-- Reads the file, skipping lines that aren't as save writes them (e.g. edited by hand).
local function read()
    local file = io.open(KeyStore.path(), "r")
    if not file then
        return
    end
    for line in file:lines() do
        local key = line:match("^key (%S+)$")
        local origin, value, expires_at, created_at = line:match("^session (%S+) (%S+) (%d+) (%d+)$")
        local name, info = line:match("^info ([%w_]+) (%S+)$")
        if key and KeyStore.isValidKey(key) then
            state.key = key
            LogUtil.addSecret(key)
        elseif origin and OriginPolicy.canonicalOrigin(origin) == origin and KeyStore.isValidSession(value) then
            state.sessions[origin] = {
                value = value,
                expires_at = tonumber(expires_at) > 0 and tonumber(expires_at) or nil,
                created_at = tonumber(created_at),
            }
            LogUtil.addSecret(value)
        elseif name and INFO_FIELDS[name] == "number" then
            state.info[name] = tonumber(info)
        elseif name and INFO_FIELDS[name] == "string" then
            state.info[name] = info
        end
    end
    file:close()
    -- Sessions are only for the key they were made with.
    if not state.key then
        state.sessions, state.info = {}, {}
    end
end

local function load()
    if state then
        return state
    end
    state = { sessions = {}, info = {} }
    if FetchAnnaSettings:getRememberKey() then
        read()
    else
        -- A file left from when the key was remembered.
        remove()
    end
    return state
end

-- Returns the key, or nil.
function KeyStore.getKey()
    return load().key
end

-- Uses key from now on, forgetting another key's sessions and info. Returns true, or nil and why it couldn't be
-- remembered (it's still kept until KOReader restarts).
function KeyStore.setKey(key)
    assert(KeyStore.isValidKey(key), "not a secret key")
    load()
    if state.key ~= key then
        state.sessions, state.info = {}, {}
    end
    state.key = key
    LogUtil.addSecret(key)
    return save()
end

-- Forgets the key, sessions and info, and removes the file. Flash storage may keep the data until it's written over.
function KeyStore.forget()
    load()
    state.key, state.sessions, state.info = nil, {}, {}
    remove()
    LogUtil.info("forgot Anna's Archive's key and its sessions")
    return true
end

function KeyStore.isRemembered()
    return FetchAnnaSettings:getRememberKey() == true
end

-- Remembers the key on the device, or only until KOReader restarts (removing the file). Returns true, or nil and why
-- not.
function KeyStore.setRemembered(remember)
    load()
    local ok, err = FetchAnnaSettings:setRememberKey(remember)
    if not ok then
        return nil, err
    end
    return save()
end

-- Returns the session for origin, or nil. An expired one is forgotten.
function KeyStore.getSession(origin)
    local session = load().sessions[origin]
    if not session then
        return nil
    end
    if session.expires_at and session.expires_at <= os.time() then
        state.sessions[origin] = nil
        save()
        return nil
    end
    return session.value
end

-- Keeps origin's session until expires_at (by os.time). It's only ever sent to origin.
function KeyStore.setSession(origin, value, expires_at)
    assert(OriginPolicy.canonicalOrigin(origin) == origin, "not an origin")
    assert(KeyStore.isValidSession(value), "not a session")
    load()
    LogUtil.addSecret(value)
    state.sessions[origin] = {
        value = value,
        expires_at = expires_at,
        created_at = os.time(),
    }
    return save()
end

-- Forgets origin's session, or every session when origin is nil.
function KeyStore.dropSession(origin)
    load()
    if origin then
        state.sessions[origin] = nil
    else
        state.sessions = {}
    end
    return save()
end

-- Lists the sites with sessions, and when each expires and was made, without the sessions themselves.
function KeyStore.sessions()
    local list = {}
    for origin, session in pairs(load().sessions) do
        table.insert(list, { origin = origin, expires_at = session.expires_at, created_at = session.created_at })
    end
    table.sort(list, function(a, b)
        return a.origin < b.origin
    end)
    return list
end

-- Returns a copy of the account info (see INFO_FIELDS).
function KeyStore.getInfo()
    local copy = {}
    for name, value in pairs(load().info) do
        copy[name] = value
    end
    return copy
end

-- Sets account info. Only INFO_FIELDS of the right type are kept. false forgets one.
function KeyStore.setInfo(fields)
    load()
    for name, value in pairs(fields) do
        if value == false then
            state.info[name] = nil
        elseif INFO_FIELDS[name] and type(value) == INFO_FIELDS[name] then
            state.info[name] = value
        end
    end
    return save()
end

return KeyStore
