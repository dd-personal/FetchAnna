local logger = require("logger")

-- KOReader writes info and above to crash.log on every device, but debug messages only when debug logging is on. So
-- whatever is needed to work out what went wrong is logged at info or above.
-- Nothing secret is ever logged. Everything is redacted first (see redact), so crash.log and the diagnostics, which
-- people share to get help, never hold the key, a session or a working download link.
local LogUtil = {}

-- The last lines logged at info or above, oldest first, for the diagnostics. crash.log can be hard to get at on a
-- device, and has every other plugin's lines in it.
local RECENT_LINES = 200
local recent = {}

-- What replaces anything redacted.
LogUtil.REDACTED = "[redacted]"
-- Query parameters and form fields whose values are secret wherever they're logged. The member API takes the key as
-- "key", and Library Genesis' download links have one too.
local SENSITIVE_NAMES = {
    key = true,
    secret = true,
    secret_key = true,
    apikey = true,
    api_key = true,
    token = true,
    password = true,
    passwd = true,
    auth = true,
    session = true,
    signature = true,
}
-- Cookies whose values log into an account.
local SENSITIVE_COOKIES = { "aa_account_id2" }
-- The shortest secret that's redacted wherever it's found (see addSecret). Redacting anything shorter could garble
-- everything else logged.
local MIN_SECRET_LENGTH = 8

-- Secrets known this session (see addSecret), redacted wherever they turn up.
local secrets = {}

-- Returns text as it would be sent in a URL or a form.
local function urlEncoded(text)
    return (text:gsub("[^%w%-_%.~]", function(char)
        return string.format("%%%02X", char:byte())
    end))
end

local function replacePlain(text, find, replacement)
    local parts, position = {}, 1
    while true do
        local start, finish = text:find(find, position, true)
        if not start then
            break
        end
        table.insert(parts, text:sub(position, start - 1))
        table.insert(parts, replacement)
        position = finish + 1
    end
    if position == 1 then
        return text
    end
    table.insert(parts, text:sub(position))
    return table.concat(parts)
end

-- Never logs value from now on, as it is or URL-encoded: the key, a session, a working download link. Kept until
-- KOReader restarts, so it stays redacted after it's forgotten elsewhere.
function LogUtil.addSecret(value)
    if type(value) == "string" and #value >= MIN_SECRET_LENGTH then
        secrets[value] = true
    end
end

-- Returns text with secrets replaced by REDACTED: the whole query of a URL with a secret in it (as the member API takes
-- the key), the value of each secret field or cookie, and each known secret.
function LogUtil.redact(text)
    text = tostring(text)
    text = text:gsub("(%a[%w+.%-]*://[^%s\"'<>?#]*)%?([^%s\"'<>#]*)", function(address, query)
        for name in ("&" .. query):gmatch("&([^=&]*)=") do
            if SENSITIVE_NAMES[name:lower()] then
                return address .. "?" .. LogUtil.REDACTED
            end
        end
    end)
    text = text:gsub("%f[%w_]([%w_]+)=([^&%s;,\"'<>]*)", function(name, value)
        if SENSITIVE_NAMES[name:lower()] and value ~= "" then
            return name .. "=" .. LogUtil.REDACTED
        end
    end)
    for __, cookie in ipairs(SENSITIVE_COOKIES) do
        text = text:gsub("(%f[%w_]" .. cookie .. "=)[^;,%s\"']+", "%1" .. LogUtil.REDACTED)
    end
    for secret in pairs(secrets) do
        text = replacePlain(text, secret, LogUtil.REDACTED)
        local encoded = urlEncoded(secret)
        if encoded ~= secret then
            text = replacePlain(text, encoded, LogUtil.REDACTED)
            text = replacePlain(text, encoded:lower(), LogUtil.REDACTED)
        end
    end
    return text
end

-- Returns a logged value, redacted: text as above, and each value in a table, a few tables deep, as KOReader's logger
-- prints tables.
local function redactValue(value, depth)
    if type(value) == "string" then
        return LogUtil.redact(value)
    end
    if type(value) == "table" and depth < 4 then
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = redactValue(item, depth + 1)
        end
        return copy
    end
    return value
end

-- Returns the values to log, redacted, as a list and a count, as some can be nil.
local function redactAll(...)
    local count = select("#", ...)
    local values = {}
    for i = 1, count do
        values[i] = redactValue((select(i, ...)), 0)
    end
    return values, count
end

local function remember(level, values, count)
    local parts = { os.date("%H:%M:%S", os.time()), level }
    for i = 1, count do
        table.insert(parts, tostring(values[i]))
    end
    table.insert(recent, table.concat(parts, " "))
    if #recent > RECENT_LINES then
        table.remove(recent, 1)
    end
end

function LogUtil.err(...)
    local values, count = redactAll(...)
    remember("ERROR", values, count)
    logger.err("FetchAnna:", unpack(values, 1, count))
end

function LogUtil.warn(...)
    local values, count = redactAll(...)
    remember("WARN", values, count)
    logger.warn("FetchAnna:", unpack(values, 1, count))
end

function LogUtil.info(...)
    local values, count = redactAll(...)
    remember("INFO", values, count)
    logger.info("FetchAnna:", unpack(values, 1, count))
end

-- Returns the last lines logged at info or above this session, oldest first, each with its time.
function LogUtil.recent()
    local lines = {}
    for i, line in ipairs(recent) do
        lines[i] = line
    end
    return lines
end

function LogUtil.debug(...)
    local values, count = redactAll(...)
    logger.dbg("FetchAnna:", unpack(values, 1, count))
end

-- Returns the site a URL is on, to log which site was used without the rest: download links carry a temporary key.
function LogUtil.site(url)
    if type(url) ~= "string" then
        return tostring(url)
    end
    return url:match("^%a+://([^/?#]+)") or url
end

-- Returns the start of a page as text without tags, to log what a site said when it can't be used.
function LogUtil.excerpt(html)
    return (html:gsub("<[^>]+>", " "):gsub("%s+", " "):sub(1, 200))
end

return LogUtil
