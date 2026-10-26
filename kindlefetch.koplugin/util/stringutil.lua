local util = require("util")

local StringUtil = {}

function StringUtil.assertValidString(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    return true
end

-- those of the given parts that are text (rather than nil or empty), joined with " · ", as a book's details are shown
function StringUtil.joinDetails(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if StringUtil.assertValidString(part) then
            table.insert(parts, part)
        end
    end
    return table.concat(parts, " · ")
end

function StringUtil.trim(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    -- remove spaces at start and end
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

function StringUtil.collapseWhitespace(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("%s+", " ")
end

function StringUtil.collapseDots(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("%.+", ".")
end

function StringUtil.collapseDashes(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return text:gsub("-+", "-")
end

function StringUtil.convertHtmlToText(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    return util.htmlEntitiesToUtf8(text)
end

function StringUtil.removeParentheses(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    -- remove anything in brackets, (...) or [...]
    text = text:gsub("%s*%([^)]*%)", "") -- remove (...)
    text = text:gsub("%s*%[[^%]]*%]", "") -- remove [...]
    return text
end

-- a title as it's written, for showing on screen, without what Library Genesis adds in brackets (such as its series)
function StringUtil.cleanTitle(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    local title = StringUtil.trim(StringUtil.collapseWhitespace(StringUtil.removeParentheses(text)))
    -- unless that's all there is of it
    if title == "" then
        title = StringUtil.trim(StringUtil.collapseWhitespace(text))
    end
    return title
end

-- whether text is a safe web address: mirrors are on a page anyone edits, and a quote or line break adds curl options
function StringUtil.isSafeUrl(text)
    return type(text) == "string" and text:find('^https?://[^%c%s"\\]+$') ~= nil
end

-- a web address's scheme, host (in small letters), port (even if not given) and path and query, without a login, or nil
local function urlParts(url)
    if type(url) ~= "string" then
        return nil
    end
    local scheme, authority, rest = url:match("^(%a[%w+.-]*)://([^/?#]*)([^#]*)")
    scheme = scheme and scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil
    end
    authority = authority:gsub("^.*@", "")
    local host, port = authority:match("^(%[[^%]]*%])(.*)$")
    if not host then
        host, port = authority:match("^([^:]*)(.*)$")
    end
    port = port:match("^:(%d*)$") or (port == "" and "")
    if host == "" or not port then
        return nil
    end
    if port == "" then
        port = scheme == "https" and "443" or "80"
    end
    return scheme, (host:lower():gsub("%.$", "")), port, rest
end

-- the site a web address is on as its scheme, host and port (even if not given), shared by those on one site, or nil
function StringUtil.siteOf(url)
    local scheme, host, port = urlParts(url)
    return scheme and string.format("%s://%s:%s", scheme, host, port) or nil
end

-- what's asked for at a web address on its site, its path and query, e.g. "/opds/search/dune?offset=30"
function StringUtil.pathOf(url)
    local scheme, _, _, rest = urlParts(url)
    if not scheme then
        return nil
    end
    return rest:find("^/") and rest or "/" .. rest
end

-- the names a network's own DNS gives its devices, which the internet's can't look up
local LOCAL_DOMAINS = { "local", "lan", "home", "home.arpa", "internal", "intranet", "localdomain", "localhost" }

-- whether a web address is local (private ranges, Tailscale's, local names), which encrypted DNS or proxies can't reach
function StringUtil.isLocalUrl(url)
    local scheme, host = urlParts(url)
    if not scheme then
        return false
    end
    local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
    if a then
        a, b = tonumber(a), tonumber(b)
        return a == 10
            or a == 127
            or (a == 172 and b >= 16 and b <= 31)
            or (a == 192 and b == 168)
            or (a == 169 and b == 254)
            or (a == 100 and b >= 64 and b <= 127)
    end
    local ipv6 = host:match("^%[(.*)%]$")
    if ipv6 then
        return ipv6 == "::1" or ipv6:find("^f[cd]") ~= nil or ipv6:find("^fe[89ab]") ~= nil
    end
    if not host:find(".", 1, true) then
        return true
    end
    for __, domain in ipairs(LOCAL_DOMAINS) do
        if host == domain or host:sub(-#domain - 1) == "." .. domain then
            return true
        end
    end
    return false
end

-- the path without its . and .. parts, as a browser asks for it
local function withoutDots(path)
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." then
            table.insert(parts, part)
        end
    end
    local ends_folder = path:find("/$") or path:find("/%.%.?$")
    local result = "/" .. table.concat(parts, "/")
    return (ends_folder and #parts > 0) and result .. "/" or result
end

-- the full web address of a link href on the page at base, which can leave out what it shares, or nil if base isn't one
function StringUtil.absoluteUrl(base, href)
    if type(href) ~= "string" then
        return nil
    end
    href = StringUtil.trim(href)
    if href:find("^%a[%w+.-]*:") then
        return href
    end
    local scheme, authority, path, query = (base or ""):match("^(%a[%w+.-]*)://([^/?#]*)([^?#]*)(%??[^#]*)")
    if not scheme then
        return nil
    end
    if href:find("^//") then
        return scheme .. ":" .. href
    end
    local site = scheme .. "://" .. authority
    path = path ~= "" and path or "/"
    if href == "" or href:find("^#") then
        return site .. path .. query .. href
    end
    if href:find("^%?") then
        return site .. path .. href
    end
    local href_path, href_rest = href:match("^([^?#]*)(.*)$")
    if not href_path:find("^/") then
        href_path = path:gsub("[^/]*$", "") .. href_path
    end
    return site .. withoutDots(href_path) .. href_rest
end

local function safeFileName(text)
    text = text:gsub('[<>:"/\\|?*]', "-") -- replace invalid chars with dash
    text = text:gsub("^[%s%.]+", "") -- remove leading spaces/dots
    text = text:gsub("[%s%.]+$", "") -- remove trailing spaces/dots
    return StringUtil.collapseWhitespace(StringUtil.collapseDashes(StringUtil.collapseDots(text)))
end

-- a title as a file is named, without Library Genesis' brackets unless that's all, as "[Poems]" made a hidden ".epub"
function StringUtil.cleanFileName(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    local name = safeFileName(StringUtil.removeParentheses(text))
    if name == "" then
        name = safeFileName(text)
    end
    return name
end

function StringUtil.replaceCarriageReturns(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    return text:gsub("\r\n", "\n")
end

return StringUtil
