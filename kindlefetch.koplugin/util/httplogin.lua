local http = require("socket.http")
local md5 = require("ffi/sha2").md5
local util = require("util")
local Request = require("util.request")
local StringUtil = require("util.stringutil")
local LogUtil = require("util.logutil")

-- asks libraries with luasocket, logging in Basic or Digest, as asked each time: Calibre's locks out stale answers
local HttpLogin = {}

-- how many times a library's site can send a request on elsewhere, as luasocket allows
local MAX_REDIRECTS = 5
local REDIRECTS = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

-- the value of a header's parameter at pos, quoted (with \ before what's meant as it is) or not, and where it ends
local function parameterValue(header, pos)
    if header:sub(pos, pos) ~= '"' then
        return header:match("^([^,%s]*)()", pos)
    end
    local value = {}
    local i = pos + 1
    while i <= #header do
        local char = header:sub(i, i)
        if char == '"' then
            break
        elseif char == "\\" then
            i = i + 1
            char = header:sub(i, i)
        end
        table.insert(value, char)
        i = i + 1
    end
    return table.concat(value), i + 1
end

-- the ways a WWW-Authenticate header says to log in to a site: each scheme and parameters, their names in small letters
function HttpLogin.challenges(header)
    local challenges, current = {}, nil
    local pos = 1
    while type(header) == "string" and pos <= #header do
        pos = header:match("^[%s,]*()", pos)
        local name, after = header:match("^([%w!#$%%&'*+%-.^_`|~]+)()", pos)
        if not name then
            break
        end
        local value_pos = header:match("^%s*=%s*()", after)
        if value_pos and current then
            local value
            value, pos = parameterValue(header, value_pos)
            current.params[name:lower()] = value
        else
            current = { scheme = name:lower(), params = {} }
            table.insert(challenges, current)
            pos = after
        end
    end
    return challenges
end

-- whether a Digest challenge can be answered: MD5, as Calibre's content server asks, with qop auth or none (RFC 2069)
local function canAnswer(challenge)
    local algorithm = (challenge.params.algorithm or "MD5"):upper()
    if algorithm ~= "MD5" and algorithm ~= "MD5-SESS" then
        return false
    end
    local qop = challenge.params.qop
    return qop == nil or (" " .. qop:gsub(",", " ") .. " "):find(" auth ", 1, true) ~= nil
end

-- the WWW-Authenticate challenge to answer: Digest where it can be, as it doesn't send the password, otherwise Basic
function HttpLogin.bestChallenge(header)
    local basic
    for __, challenge in ipairs(HttpLogin.challenges(header)) do
        if challenge.scheme == "digest" and challenge.params.nonce and canAnswer(challenge) then
            return challenge
        end
        if challenge.scheme == "basic" then
            basic = basic or challenge
        end
    end
    return basic
end

local function quoted(text)
    return '"' .. tostring(text):gsub('[\\"]', "\\%0") .. '"'
end

-- the Authorization header answering a Digest challenge for method on uri (path and query), as RFC 2617 says
function HttpLogin.digest(login, challenge, method, uri, cnonce)
    local params = challenge.params
    local qop = params.qop and "auth" or nil
    local nc = "00000001"
    local ha1 = md5(string.format("%s:%s:%s", login.username, params.realm or "", login.password))
    if (params.algorithm or ""):upper() == "MD5-SESS" then
        ha1 = md5(string.format("%s:%s:%s", ha1, params.nonce, cnonce))
    end
    local ha2 = md5(method .. ":" .. uri)
    local response = qop and md5(table.concat({ ha1, params.nonce, nc, cnonce, qop, ha2 }, ":"))
        or md5(table.concat({ ha1, params.nonce, ha2 }, ":"))

    local fields = {
        "username=" .. quoted(login.username),
        "realm=" .. quoted(params.realm or ""),
        "nonce=" .. quoted(params.nonce),
        "uri=" .. quoted(uri),
        "response=" .. quoted(response),
    }
    if params.algorithm then
        table.insert(fields, "algorithm=" .. params.algorithm)
    end
    if params.opaque then
        table.insert(fields, "opaque=" .. quoted(params.opaque))
    end
    if qop then
        table.insert(fields, "qop=" .. qop)
        table.insert(fields, "nc=" .. nc)
        table.insert(fields, "cnonce=" .. quoted(cnonce))
    end
    return "Digest " .. table.concat(fields, ", ")
end

-- a nonce of the request's own, for a Digest login (see digest)
local function newCnonce()
    return string.format("%08x%08x", math.random(0, 0x7fffffff), os.time() % 0x7fffffff)
end

-- http.request through proxy (none on the local network, see Request), returning what it raises, as KOReader exits
local function send(options, proxy)
    local saved = http.PROXY
    http.PROXY = proxy
    options.proxy = proxy
    local requested, ok, code, headers, status = pcall(http.request, options)
    http.PROXY = saved
    if not requested then
        return nil, ok
    end
    return ok, code, headers, status
end

-- ask a library's site for url, into a new sink each time, following redirects, logging in only on the login's own site
function HttpLogin.request(url, headers, new_sink)
    for __ = 0, MAX_REDIRECTS do
        local request = Request.new(url)
        local login = request.login
        local function ask(authorization, basic)
            local request_headers = {}
            for name, value in pairs(headers or {}) do
                request_headers[name] = value
            end
            request_headers["Authorization"] = authorization
            return send({
                url = url,
                headers = request_headers,
                sink = new_sink(),
                -- followed here, as luasocket would send the login on to wherever it goes
                redirect = false,
                -- for luasocket to log in the Basic way, which takes the password escaped, as it unescapes it
                user = basic and login.username or nil,
                password = basic and util.urlEncode(login.password) or nil,
            }, request.proxy)
        end

        local ok, code, response_headers, status = ask()
        if ok and code == 401 and login then
            local header = type(response_headers) == "table" and response_headers["www-authenticate"]
            local challenge = HttpLogin.bestChallenge(header)
            if challenge and challenge.scheme == "digest" then
                ok, code, response_headers, status =
                    ask(HttpLogin.digest(login, challenge, "GET", StringUtil.pathOf(url), newCnonce()))
            elseif challenge then
                ok, code, response_headers, status = ask(nil, true)
            else
                LogUtil.warn(LogUtil.site(url), "asks to be logged in to in a way KOReader's HTTP can't:", header)
            end
        end

        local location = type(response_headers) == "table" and response_headers.location
        if not (ok and REDIRECTS[code] and type(location) == "string") then
            return ok, code, response_headers, status
        end
        url = StringUtil.absoluteUrl(url, location)
        if not StringUtil.isSafeUrl(url) then
            return ok, code, response_headers, status
        end
    end
    return nil, "too many redirects"
end

return HttpLogin
