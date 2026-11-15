local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local LogUtil = require("fetchanna.util.logutil")

local FetchAnnaCache = {}

function FetchAnnaCache:new(opts)
    local obj = {
        filename = opts.filename,
        expiry = opts.expiry,
        max_entries = opts.max_entries,
        makeKey = opts.makeKey or function(key)
            return key
        end,
        -- Optional. Called with the key and value of an entry that expired or was pushed out.
        onEvict = opts.onEvict,
        -- Keeps expired entries for when there's nothing newer (see peek).
        keep_expired = opts.keep_expired,
        cache = nil,
    }

    setmetatable(obj, self)
    self.__index = self
    return obj
end

-- Opened once and kept, rather than read again on every save.
function FetchAnnaCache:getCacheFile()
    if not self.file then
        self.file = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. self.filename)
    end
    return self.file
end

function FetchAnnaCache:getExpiry()
    return type(self.expiry) == "function" and self.expiry() or self.expiry
end

function FetchAnnaCache:count()
    local count = 0

    for _ in pairs(self.cache) do
        count = count + 1
    end

    return count
end

function FetchAnnaCache:delete(key)
    LogUtil.debug("deleting cache entry:", key)

    self.cache[key] = nil
end

-- Deletes an expired or pushed-out entry and tells the cache's owner.
function FetchAnnaCache:evict(key)
    local entry = self.cache[key]
    self:delete(key)
    if type(entry) == "table" and self.onEvict then
        self.onEvict(key, entry.value)
    end
end

-- Returns an entry's age in seconds, or nil when it has no time or one still to come (an e-reader's clock can go
-- back when its battery runs flat). Those count as expired.
local function age(entry, now)
    local timestamp = type(entry) == "table" and tonumber(entry.timestamp)
    if not timestamp or timestamp > now then
        return nil
    end
    return now - timestamp
end

-- Returns the highest seq stored. Unlike the time, seq doesn't go back when the clock does, which had the newest
-- covers pushed out as the oldest.
function FetchAnnaCache:lastSeq()
    if not self.last_seq then
        self.last_seq = 0
        for _, entry in pairs(self.cache) do
            local seq = type(entry) == "table" and tonumber(entry.seq)
            if seq and seq > self.last_seq then
                self.last_seq = seq
            end
        end
    end
    return self.last_seq
end

-- Pushes out the entry stored first. Entries with no seq (from older versions) go first.
function FetchAnnaCache:removeOldest()
    local oldest_key, oldest_seq, oldest_timestamp
    for key, entry in pairs(self.cache) do
        local seq = type(entry) == "table" and tonumber(entry.seq) or 0
        local timestamp = type(entry) == "table" and tonumber(entry.timestamp) or -math.huge
        if oldest_key == nil or seq < oldest_seq or (seq == oldest_seq and timestamp < oldest_timestamp) then
            oldest_key, oldest_seq, oldest_timestamp = key, seq, timestamp
        end
    end

    if oldest_key ~= nil then
        self:evict(oldest_key)
    end
end

function FetchAnnaCache:load()
    if self.cache then
        return
    end

    local file = self:getCacheFile()
    self.cache = type(file.data) == "table" and file.data or {}
end

function FetchAnnaCache:save()
    self:load()

    -- Drops expired entries, which would otherwise stay until they're looked up again.
    local expiry = self:getExpiry()
    if expiry and not self.keep_expired then
        local now = os.time()
        local expired = {}
        for key, entry in pairs(self.cache) do
            local entry_age = age(entry, now)
            if not entry_age or entry_age > expiry then
                table.insert(expired, key)
            end
        end
        for _, key in ipairs(expired) do
            self:evict(key)
        end
    end

    if self.max_entries then
        while self:count() > self.max_entries do
            self:removeOldest()
        end
    end

    local file = self:getCacheFile()
    file.data = self.cache
    file:flush()
end

function FetchAnnaCache:get(...)
    self:load()

    local key = self.makeKey(...)
    LogUtil.debug("checking cache for key:", key)

    local entry = self.cache[key]
    if entry == nil then
        return nil
    end

    local entry_age = age(entry, os.time())
    local expiry = self:getExpiry()
    if type(entry) ~= "table" or (expiry and (not entry_age or entry_age > expiry)) then
        LogUtil.debug("cache expired for key:", key, "age:", entry_age, "seconds")

        if type(entry) ~= "table" or not self.keep_expired then
            self:evict(key)
            self:save()
        end
        return nil
    end

    LogUtil.debug("cache hit for key:", key, "returned", entry.value)
    return entry.value
end

-- Returns what's stored for the key, however old (see keep_expired), e.g. the sites looked up before, for when
-- they can't be looked up again.
function FetchAnnaCache:peek(...)
    self:load()
    local entry = self.cache[self.makeKey(...)]
    return type(entry) == "table" and entry.value or nil
end

-- Stores an entry without saving, so several can be saved together.
function FetchAnnaCache:put(value, ...)
    self:load()

    local key = self.makeKey(...)

    self.last_seq = self:lastSeq() + 1
    self.cache[key] = {
        timestamp = os.time(),
        seq = self.last_seq,
        value = value,
    }

    LogUtil.debug("stored cache entry:", key, "with", value)
end

function FetchAnnaCache:set(value, ...)
    self:put(value, ...)
    self:save()
end

function FetchAnnaCache:clear()
    LogUtil.debug("clearing cache")

    self.cache = {}
    self.last_seq = nil
    self:save()
end

function FetchAnnaCache:deleteValueFromKey(value, ...)
    self:load()
    local key = self.makeKey(...)
    local entry = self.cache[key]

    if type(entry) ~= "table" then
        LogUtil.debug("cache key not found:", key)
        return
    end

    local values = entry.value
    if type(values) ~= "table" then
        LogUtil.debug("cached value is not a table for key:", key)
        return
    end

    -- A new list, as callers may still be looping over the old one.
    local remaining = {}
    for _, v in ipairs(values) do
        if v ~= value then
            table.insert(remaining, v)
        else
            LogUtil.debug("removing url from cache:", value)
        end
    end
    entry.value = remaining

    if #remaining == 0 then
        self:delete(key)
    end

    self:save()
end

-- Puts value first in the key's list. The entry keeps its time, so it expires when it would have.
function FetchAnnaCache:moveValueToFront(value, ...)
    self:load()
    local entry = self.cache[self.makeKey(...)]
    if type(entry) ~= "table" or type(entry.value) ~= "table" or entry.value[1] == value then
        return
    end

    -- A new list, as callers may still be looping over the old one.
    local reordered = { value }
    for _, v in ipairs(entry.value) do
        if v ~= value then
            table.insert(reordered, v)
        end
    end
    if #reordered > #entry.value then
        return
    end
    entry.value = reordered

    self:save()
end

-- Puts value last in the key's list.
function FetchAnnaCache:moveValueToBack(value, ...)
    self:load()
    local entry = self.cache[self.makeKey(...)]
    if type(entry) ~= "table" or type(entry.value) ~= "table" or entry.value[#entry.value] == value then
        return
    end

    local reordered = {}
    for _, v in ipairs(entry.value) do
        if v ~= value then
            table.insert(reordered, v)
        end
    end
    if #reordered == #entry.value then
        return
    end
    table.insert(reordered, value)
    entry.value = reordered

    self:save()
end

return FetchAnnaCache
