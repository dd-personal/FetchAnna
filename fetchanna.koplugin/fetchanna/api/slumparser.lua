local OriginPolicy = require("fetchanna.util.originpolicy")
local LogUtil = require("fetchanna.util.logutil")
local TimeUtil = require("fetchanna.util.timeutil")

-- Reads SLUM's page about Anna's Archive (https://open-slum.org/annas.html), which lists its sites as cards: what each
-- should answer, what it did, and its status (see docs/annas-protocol.md).
-- Only a card's own link is read as a site, and only when it's an https site (see OriginPolicy) that matches the one
-- the card names.
local SlumParser = {}

-- What a site is for. Only catalogue sites are searched and logged into. A download server only gets the links the
-- member API gives (see AnnasMirrors).
SlumParser.CATALOGUE = "catalogue"
SlumParser.SOFTWARE = "software"
SlumParser.DOWNLOAD = "download"

-- Why the page couldn't be read.
SlumParser.NOT_SLUM = "SLUM answered with a page that isn't its list of sites"
SlumParser.CHANGED = "SLUM's page has changed, so its sites couldn't be read"

-- Roles, by the text SLUM expects the site to answer with.
local ROLES_BY_CONTENT = {
    { "in one place %- Anna", SlumParser.CATALOGUE },
    { "AnnaArchivist", SlumParser.SOFTWARE },
    { "Link expired or invalid", SlumParser.DOWNLOAD },
}
-- Failing that, by the card's id. An id never makes a site a catalogue: only its expected text does.
local ROLES_BY_ID = {
    { "^annas%.software$", SlumParser.SOFTWARE },
    { "^annas%.dl%d+$", SlumParser.DOWNLOAD },
}
-- SLUM's statuses (see its page's key). Anything else is unknown.
local STATUSES = {
    up = true,
    protected = true,
    degraded = true,
    down = true,
    unknown = true,
}

local utcTime = TimeUtil.utcTime

-- Returns when SLUM made the page, from its footer ("Generated at 2026-11-11T23:12:58.398698+00:00"), or nil.
local function generatedAt(html)
    local y, mo, d, h, mi, s = html:match("Generated at (%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)[%d.]*%+00:00")
    if not y then
        return nil
    end
    return utcTime(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
end

local function decodeEntities(text)
    return (
        text:gsub("&quot;", '"')
            :gsub("&#34;", '"')
            :gsub("&#39;", "'")
            :gsub("&lt;", "<")
            :gsub("&gt;", ">")
            :gsub("&amp;", "&")
    )
end

-- Returns a card block's text, without tags, surrounding space or quotes.
local function fieldText(html)
    local text = decodeEntities(html:gsub("<[^>]+>", ""))
    return (text:gsub("^%s+", ""):gsub("%s+$", ""):gsub('^"(.*)"$', "%1"))
end

-- Returns the status, content and latency in the card's block under heading (Expected or Actual).
local function readBlock(card, heading)
    local block = card:match(">%s*" .. heading .. "%s*</div>(.-)</div>%s*</div>")
    if not block then
        return {}
    end
    local status = block:match("Status:%s*<span[^>]*>%s*(%d+)%s*</span>")
    local content = block:match("Content:%s*(<span[^>]*>.-</span>)")
    local latency = block:match("Latency:%s*<span[^>]*>%s*(%d+)%s*ms")
    return {
        status = tonumber(status),
        content = content and fieldText(content),
        latency = tonumber(latency),
    }
end

local function roleOf(id, expected_content)
    local by_content, by_id
    for __, role in ipairs(ROLES_BY_CONTENT) do
        if expected_content and expected_content:find(role[1]) then
            by_content = role[2]
            break
        end
    end
    for __, role in ipairs(ROLES_BY_ID) do
        if id:find(role[1]) then
            by_id = role[2]
            break
        end
    end
    -- A card whose id and content disagree is left out.
    if by_content and by_id and by_content ~= by_id then
        return nil, "its id and what it's expected to answer say different things"
    end
    local role = by_content or by_id
    if not role then
        return nil, "it isn't said what it's for"
    end
    return role
end

-- Returns the site a card is about, or nil and why it was left out.
local function readCard(id, card)
    local link = card:match('<a%s+href="([^"]*)"%s+class="card%-title"')
        or card:match('class="card%-title"%s+href="([^"]*)"')
    if not link then
        return nil, "it has no link"
    end
    link = decodeEntities(link)
    local parsed, policy_err = OriginPolicy.parse(link)
    if not parsed then
        return nil, "its link " .. policy_err
    end
    -- The domain the card names, and its title. A link to somewhere else wouldn't match them.
    for __, named in ipairs({
        card:match('data%-domain%-url="([^"]*)"'),
        card:match('class="card%-title"[^>]*>%s*([^<]-)%s*</a>'),
    }) do
        if named ~= "" and OriginPolicy.canonicalOrigin(decodeEntities(named)) ~= parsed.origin then
            return nil, "its link doesn't go to the site it names"
        end
    end

    local expected = readBlock(card, "Expected")
    local actual = readBlock(card, "Actual")
    local role, role_err = roleOf(id, expected.content)
    if not role then
        return nil, role_err
    end
    local status = card:match('<span class="status%-badge%s+([%w%-]+)"')
    status = status and status:lower()
    return {
        origin = parsed.origin,
        host = parsed.host,
        slum_id = id,
        role = role,
        status = STATUSES[status] and status or "unknown",
        expected_status = expected.status,
        actual_status = actual.status,
        latency_ms = actual.latency,
    }
end

-- Returns { records, skipped, generated_at (seconds or nil) }. A record has origin, host, slum_id, role, status (up,
-- protected, degraded, down or unknown), expected_status, actual_status and latency_ms. A skipped card has its slum_id
-- and reason.
-- Returns nil and why when the page isn't SLUM's (e.g. a bot check in front of it), or has changed so no site could be
-- read. That never means there are no sites.
function SlumParser.parse(html)
    if
        type(html) ~= "string"
        or not (html:find("Shadow Library Uptime Monitor", 1, true) or html:find("FlatMonitor", 1, true))
    then
        return nil, SlumParser.NOT_SLUM
    end

    local cards = {}
    local position = 1
    while true do
        local start, finish, id = html:find('<div class="card" id="([^"]*)">', position)
        if not start then
            break
        end
        if #cards > 0 then
            cards[#cards].html = html:sub(cards[#cards].start, start - 1)
        end
        table.insert(cards, { id = decodeEntities(id), start = finish + 1 })
        position = finish + 1
    end
    if #cards > 0 then
        cards[#cards].html = html:sub(cards[#cards].start)
    end

    local result = {
        records = {},
        skipped = {},
        generated_at = generatedAt(html),
    }
    local seen = {}
    for __, card in ipairs(cards) do
        local record, why = readCard(card.id, card.html)
        if record and seen[record.origin] then
            record, why = nil, "it lists a site listed before it"
        end
        if record then
            seen[record.origin] = true
            table.insert(result.records, record)
        else
            LogUtil.warn("left out SLUM's card", card.id, "as", why)
            table.insert(result.skipped, { slum_id = card.id, reason = why })
        end
    end

    if #result.records == 0 then
        LogUtil.warn("read no sites from SLUM's page, of its", #cards, "cards")
        return nil, SlumParser.CHANGED
    end
    return result
end

return SlumParser
