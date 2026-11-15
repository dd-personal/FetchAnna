-- The proxy FetchAnna goes through for everything: KOReader's HTTP proxy (see NetworkMgr:setHTTPProxy), where it's
-- turned on in KOReader's network settings or FetchAnna's.
local ProxyUtil = {}

-- Returns KOReader's HTTP proxy as it's in use, or nil when it's off.
function ProxyUtil.get()
    local url = require("socket.http").PROXY
    return type(url) == "string" and url ~= "" and url or nil
end

-- Returns the proxy's URL without its login, to show which it is.
function ProxyUtil.describe(url)
    return (url:gsub("^(%a[%w+.-]*://)[^@/]*@", "%1"))
end

return ProxyUtil
