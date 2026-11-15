local LogUtil = require("fetchanna.util.logutil")

-- Which sites FetchAnna will talk to. A site is an origin ("https://" and a name), and two are the same only when their
-- origins match exactly: never by a name that starts or ends alike, has "annas" in it, or looks right. What a page says
-- a site is (SLUM, a redirect, an answer) is checked here before the site is asked or trusted with anything (see
-- AnnasMirrors).
local OriginPolicy = {}

-- Why a URL was turned down, for the log and the screen.
OriginPolicy.INVALID = "isn't a web address"
OriginPolicy.NOT_HTTPS = "isn't a secure (https) address"
OriginPolicy.CREDENTIALS = "has a login in it"
OriginPolicy.PORT = "uses a port other than https's own"
OriginPolicy.ADDRESS = "is a numeric address rather than a name"
OriginPolicy.NAME = "isn't a valid site name"
OriginPolicy.PRIVATE = "leads to a private or local network address"

local MAX_NAME_LENGTH = 253
local MAX_LABEL_LENGTH = 63

-- Whether host is an internet site's name: two or more labels of letters, digits and inner hyphens, ending in a
-- top-level domain of letters or xn--... That turns down numeric addresses such as 192.168.1.1 too.
local function isValidName(host)
    if #host == 0 or #host > MAX_NAME_LENGTH then
        return false
    end
    local labels = 0
    for label in (host .. "."):gmatch("([^.]*)%.") do
        if
            #label > MAX_LABEL_LENGTH or not (label:find("^[a-z0-9]$") or label:find("^[a-z0-9][a-z0-9%-]*[a-z0-9]$"))
        then
            return false
        end
        labels = labels + 1
    end
    local top = host:match("([^.]+)$")
    return labels >= 2 and (top:find("^%a%a+$") ~= nil or top:find("^xn%-%-[a-z0-9%-]+$") ~= nil)
end

-- Returns an HTTPS URL's host, origin ("https://host") and path with any query, or nil and why not. A bare name, e.g.
-- "annas-archive.gl", is taken as HTTPS.
function OriginPolicy.parse(url)
    if type(url) ~= "string" then
        return nil, OriginPolicy.INVALID
    end
    -- Nothing that could end the URL early, or that curl could read differently.
    if url == "" or url:find("[%s%c\\]") then
        return nil, OriginPolicy.INVALID
    end
    local scheme, rest = url:match("^(%a[%w+.%-]*)://(.*)$")
    if not scheme then
        if url:find("^[%w.%-]+$") then
            scheme, rest = "https", url
        else
            return nil, OriginPolicy.INVALID
        end
    end
    if scheme:lower() ~= "https" then
        return nil, OriginPolicy.NOT_HTTPS
    end

    local authority, path = rest:match("^([^/?#]*)(.*)$")
    -- A login (user:password@) would be sent to the site, or make it look like another.
    if authority:find("@", 1, true) then
        return nil, OriginPolicy.CREDENTIALS
    end
    if authority:find("^%[") then
        return nil, OriginPolicy.ADDRESS
    end
    local host, port = authority:match("^([^:]*):(.*)$")
    if not host then
        host, port = authority, nil
    end
    if port and port ~= "443" then
        return nil, OriginPolicy.PORT
    end
    host = host:lower():gsub("%.$", "")
    if host:find("^[%d.]+$") then
        return nil, OriginPolicy.ADDRESS
    end
    if not isValidName(host) then
        return nil, OriginPolicy.NAME
    end
    -- The fragment is only for the browser.
    path = path:gsub("#.*$", "")
    if path == "" or path:sub(1, 1) == "?" then
        path = "/" .. path
    end
    return {
        host = host,
        origin = "https://" .. host,
        path = path,
    }
end

-- Returns the origin of a URL or bare name, e.g. "https://annas-archive.gl" for "HTTPS://Annas-Archive.gl:443/faq", or
-- nil and why it can't be used.
function OriginPolicy.canonicalOrigin(url)
    local parsed, err = OriginPolicy.parse(url)
    if not parsed then
        return nil, err
    end
    return parsed.origin
end

-- Whether two URLs are on exactly the same site.
function OriginPolicy.sameOrigin(a, b)
    local origin_a, origin_b = OriginPolicy.canonicalOrigin(a), OriginPolicy.canonicalOrigin(b)
    return origin_a ~= nil and origin_a == origin_b
end

-- Returns the host of an origin, e.g. "annas-archive.gl".
function OriginPolicy.hostOf(origin)
    local parsed = OriginPolicy.parse(origin)
    return parsed and parsed.host
end

-- Returns the four numbers of an IPv4 address, or nil if it isn't one.
local function ipv4Octets(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    local octets = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
    for __, octet in ipairs(octets) do
        if octet > 255 then
            return nil
        end
    end
    return octets
end

-- Returns why an IPv4 address isn't on the public internet, or nil when it is.
local function ipv4Private(octets)
    local a, b, c = octets[1], octets[2], octets[3]
    if a == 127 then
        return "loopback"
    elseif a == 10 then
        return "private"
    elseif a >= 224 and a <= 239 then
        return "multicast"
    elseif a == 0 or a >= 240 then
        return "reserved"
    elseif a == 100 and b >= 64 and b <= 127 then
        return "shared (carrier-grade NAT)"
    elseif a == 169 and b == 254 then
        return "link-local"
    elseif a == 172 and b >= 16 and b <= 31 then
        return "private"
    elseif a == 192 and b == 168 then
        return "private"
    elseif a == 192 and b == 0 and c == 0 then
        return "reserved"
    elseif a == 198 and (b == 18 or b == 19) then
        return "benchmarking"
    elseif
        (a == 192 and b == 0 and c == 2)
        or (a == 198 and b == 51 and c == 100)
        or (a == 203 and b == 0 and c == 113)
    then
        return "documentation"
    end
    return nil
end

-- Returns the eight groups of an IPv6 address, or nil if it isn't one. An IPv4 address at its end, as in
-- ::ffff:192.0.2.1, becomes the last two.
local function ipv6Groups(ip)
    ip = ip:lower():gsub("%%.*$", "")
    if not ip:find("^[%x:.]+$") then
        return nil
    end
    local tail = {}
    local v4 = ip:match(":(%d+%.%d+%.%d+%.%d+)$")
    if v4 then
        local octets = ipv4Octets(v4)
        if not octets then
            return nil
        end
        tail = { octets[1] * 256 + octets[2], octets[3] * 256 + octets[4] }
        -- Without ":a.b.c.d", which leaves one colon of a "::" before it.
        ip = ip:sub(1, #ip - #v4 - 1)
        if ip:sub(-1) == ":" then
            ip = ip .. ":"
        end
    end

    local function groupsOf(part)
        local groups = {}
        if part == "" then
            return groups
        end
        for group in (part .. ":"):gmatch("([^:]*):") do
            if not group:find("^%x%x?%x?%x?$") then
                return nil
            end
            table.insert(groups, tonumber(group, 16))
        end
        return groups
    end

    local wanted = 8 - #tail
    local head, rest = ip:match("^(.-)::(.*)$")
    local groups
    if head then
        local before, after = groupsOf(head), groupsOf(rest)
        if not before or not after or #before + #after >= wanted then
            return nil
        end
        groups = before
        for __ = 1, wanted - #before - #after do
            table.insert(groups, 0)
        end
        for __, group in ipairs(after) do
            table.insert(groups, group)
        end
    else
        groups = groupsOf(ip)
        if not groups or #groups ~= wanted then
            return nil
        end
    end
    for __, group in ipairs(tail) do
        table.insert(groups, group)
    end
    return groups
end

-- Returns the IPv4 address held in two IPv6 groups.
local function embeddedIpv4(high, low)
    return {
        math.floor(high / 256),
        high % 256,
        math.floor(low / 256),
        low % 256,
    }
end

-- Returns why an IPv6 address isn't on the public internet, or nil when it is.
local function ipv6Private(groups)
    local first = groups[1]
    local zeros = 0
    for i = 1, 6 do
        if groups[i] == 0 then
            zeros = zeros + 1
        end
    end
    if zeros == 6 then
        if groups[7] == 0 and groups[8] == 1 then
            return "loopback"
        end
        -- :: and the deprecated IPv4-compatible ::a.b.c.d
        return "reserved"
    end
    if zeros == 5 and groups[6] == 0xffff then
        -- An IPv4 address written as IPv6 (::ffff:a.b.c.d) is that IPv4 address.
        return ipv4Private(embeddedIpv4(groups[7], groups[8]))
    end
    if first == 0x64 and groups[2] == 0xff9b then
        -- NAT64 goes on to the IPv4 address at its end.
        return ipv4Private(embeddedIpv4(groups[7], groups[8]))
    end
    if first == 0x2002 then
        -- 6to4 goes on to the IPv4 address in its second and third groups.
        return ipv4Private(embeddedIpv4(groups[2], groups[3]))
    end
    if first >= 0xfc00 and first <= 0xfdff then
        return "private"
    elseif first >= 0xfe80 and first <= 0xfeff then
        return "link-local"
    elseif first >= 0xff00 then
        return "multicast"
    elseif first == 0x2001 and groups[2] == 0x0db8 then
        return "documentation"
    end
    return nil
end

-- Whether an IP address (as text) is on the public internet, and if not, what kind it is. Text that isn't an address
-- isn't public.
function OriginPolicy.isPublicAddress(ip)
    if type(ip) ~= "string" then
        return false, "not an address"
    end
    local octets = ipv4Octets(ip)
    if octets then
        local kind = ipv4Private(octets)
        return kind == nil, kind
    end
    local groups = ipv6Groups(ip)
    if groups then
        local kind = ipv6Private(groups)
        return kind == nil, kind
    end
    return false, "not an address"
end

-- Returns the addresses host's name leads to, or nil when it can't be looked up here. curl looks names up itself,
-- possibly with encrypted DNS, so that isn't taken as wrong. Replaced in the specs.
function OriginPolicy.resolve(host)
    local ok, socket = pcall(require, "socket")
    local dns = ok and type(socket) == "table" and socket.dns
    if not dns then
        return nil
    end
    if dns.getaddrinfo then
        local looked_up, results = pcall(dns.getaddrinfo, host)
        if looked_up and type(results) == "table" then
            local addresses = {}
            for __, result in ipairs(results) do
                if type(result) == "table" and type(result.addr) == "string" then
                    table.insert(addresses, result.addr)
                end
            end
            if #addresses > 0 then
                return addresses
            end
        end
    end
    if dns.toip then
        local looked_up, address = pcall(dns.toip, host)
        if looked_up and type(address) == "string" then
            return { address }
        end
    end
    return nil
end

-- Checks a name doesn't lead off the public internet, where a page could point FetchAnna at a router or the device
-- itself. Returns true, or nil and why not. A name that can't be looked up here passes (see resolve).
function OriginPolicy.checkHost(host)
    local addresses = OriginPolicy.resolve(host)
    for __, address in ipairs(addresses or {}) do
        local public, kind = OriginPolicy.isPublicAddress(address)
        if not public then
            LogUtil.warn(host, "leads to a", kind, "address:", address)
            return nil, OriginPolicy.PRIVATE
        end
    end
    return true
end

-- Returns where a redirect from from_url to location goes, and whether that's the same site, or nil and why it can't be
-- followed. Only HTTPS is followed.
function OriginPolicy.resolveRedirect(from_url, location)
    local from = OriginPolicy.parse(from_url)
    if not from or type(location) ~= "string" or location == "" or location:find("[%s%c\\]") then
        return nil, OriginPolicy.INVALID
    end
    local target
    if location:find("^//") then
        target = "https:" .. location
    elseif location:find("^/") then
        target = from.origin .. location
    elseif location:find("^%a[%w+.%-]*:") then
        target = location
    else
        -- A path relative to the page's own, which none of the sites send.
        return nil, OriginPolicy.INVALID
    end
    local parsed, err = OriginPolicy.parse(target)
    if not parsed then
        return nil, err
    end
    return parsed.origin .. parsed.path, parsed.origin == from.origin
end

return OriginPolicy
