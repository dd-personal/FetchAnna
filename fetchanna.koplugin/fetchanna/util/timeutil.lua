-- Times as sites write them, in UTC. os.time can't convert them itself, as it takes a time to be local.
local TimeUtil = {}

local MONTHS = {
    Jan = 1,
    Feb = 2,
    Mar = 3,
    Apr = 4,
    May = 5,
    Jun = 6,
    Jul = 7,
    Aug = 8,
    Sep = 9,
    Oct = 10,
    Nov = 11,
    Dec = 12,
}

-- Returns the seconds since 1970 of a UTC time, by days from the civil calendar, as in Howard Hinnant's
-- chrono-compatible algorithms.
function TimeUtil.utcTime(year, month, day, hour, min, sec)
    local y = month <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local year_of_era = y - era * 400
    local day_of_year = math.floor((153 * ((month + 9) % 12) + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365 + math.floor(year_of_era / 4) - math.floor(year_of_era / 100) + day_of_year
    local days = era * 146097 + day_of_era - 719468
    return ((days * 24 + hour) * 60 + min) * 60 + sec
end

-- Returns the seconds since 1970 of an HTTP date, e.g. "Wed, 11 Nov 2026 23:15:54 GMT", or nil.
function TimeUtil.parseHttpDate(text)
    if type(text) ~= "string" then
        return nil
    end
    local day, month, year, hour, min, sec =
        text:match("^%s*%a+, (%d%d?) (%a%a%a) (%d%d%d%d) (%d%d):(%d%d):(%d%d) GMT%s*$")
    if not day or not MONTHS[month] then
        return nil
    end
    return TimeUtil.utcTime(tonumber(year), MONTHS[month], tonumber(day), tonumber(hour), tonumber(min), tonumber(sec))
end

-- Returns the seconds a Retry-After header asks to wait, given as seconds or as a date (now is the current time), or
-- nil when it doesn't say.
function TimeUtil.parseRetryAfter(value, now)
    if type(value) ~= "string" then
        return nil
    end
    local seconds = value:match("^%s*(%d+)%s*$")
    if seconds then
        return tonumber(seconds)
    end
    local at = TimeUtil.parseHttpDate(value)
    return at and math.max(0, at - now) or nil
end

return TimeUtil
