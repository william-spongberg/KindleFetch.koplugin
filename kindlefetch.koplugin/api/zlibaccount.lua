local JSON = require("json")
local HttpUtil = require("util.httputil")
local LogUtil = require("util.logutil")
local KindleFetchSettings = require("settings.settings")
local UrlApi = require("api.urlapi")
local Errors = require("util.errors")
local T = require("ffi/util").template
local _ = require("gettext")

-- the Z-Library account Kindle Fetch is logged into, as Z-Library only lets those logged in search for and
-- download books, and asking it about the account, through the API its own app uses
local ZlibAccount = {
    -- when Z-Library no longer accepts the account's key (see Errors)
    LOGGED_OUT_ERROR = Errors.LOGGED_OUT,
}

function ZlibAccount:isLoggedIn()
    return KindleFetchSettings:getZlibAccount() ~= nil
end

-- the email of the account logged into, if there is one
function ZlibAccount:getEmail()
    local account = KindleFetchSettings:getZlibAccount()
    return account and account.email
end

-- what Z-Library's API answered, as the account logged into, or nil and what went wrong. forgets the account once
-- Z-Library no longer accepts it
local function readAnswer(self, data, path, account)
    if data.success ~= 1 and data.success ~= true then
        local message = type(data.error) == "string" and data.error ~= "" and data.error or nil
        LogUtil.warn("Z-Library answered", path, "with an error:", message or "none given")
        -- "Please login", once the key no longer logs into the account, or when it was logged out of
        if message and message:lower():find("login", 1, true) then
            if account then
                KindleFetchSettings:setZlibAccount(nil)
            end
            return nil, self.LOGGED_OUT_ERROR
        end
        return nil, message and T(_("Z-Library says: %1"), message) or _("unexpected response from Z-Library")
    end
    return data
end

-- ask Z-Library's API at path (posting the form, when there is one, see HttpUtil.getBody) as the account logged into,
-- returning what it answered, or nil and what went wrong (HttpUtil.CANCELLED when called off). it's asked at each of
-- its addresses (see UrlApi) until one answers, and they're looked up again, in case they've moved, when none do
function ZlibAccount:request(path, form, refresh)
    local urls, urls_err = UrlApi:getZlibUrls(refresh)
    if not urls then
        return nil, UrlApi.explainLookupFailure(urls_err)
    end

    local account = KindleFetchSettings:getZlibAccount()
    local cookies = account and string.format("remix_userid=%s; remix_userkey=%s", account.user_id, account.user_key)
    local last_err
    -- addresses that didn't answer at all, which may be down, or the device may be offline, and how many of them
    -- couldn't even have their names looked up
    local unanswered = {}
    local unresolved = 0
    local answered = false
    for __, url in ipairs(urls) do
        local body, err, status = HttpUtil.getBody(url .. path, {
            form = form,
            cookies = cookies or "",
        })
        -- called off, which says nothing about the addresses
        if err == HttpUtil.CANCELLED then
            return nil, err
        end
        answered = answered or body ~= nil or status ~= nil

        -- it answers with what went wrong as JSON too, even with an error status
        local ok, data = false, nil
        if body then
            ok, data = pcall(JSON.decode, body)
        end
        if ok and type(data) == "table" then
            for __, unanswered_url in ipairs(unanswered) do
                UrlApi:restZlibUrl(unanswered_url)
            end
            UrlApi:preferZlibUrl(url)
            return readAnswer(self, data, path, account)
        end

        if body or status then
            -- it answered, but not as Z-Library's API does: e.g. an error page, or a site that's no longer Z-Library
            if body then
                LogUtil.warn(
                    "unexpected answer from",
                    LogUtil.site(url),
                    "to",
                    path .. ": HTTP",
                    status,
                    #body,
                    "bytes:",
                    body:gsub("<[^>]+>", " "):gsub("%s+", " "):sub(1, 200)
                )
            end
            last_err = status
                    and status >= 400
                    and T(_("Z-Library answered with an error (HTTP %1), try again later"), status)
                or _("unexpected response from Z-Library")
            UrlApi:deleteZlibUrl(url)
        else
            table.insert(unanswered, url)
            last_err = T(_("Z-Library didn't answer (%1)"), err)
            if err == HttpUtil.UNRESOLVED then
                unresolved = unresolved + 1
            end
        end
    end

    -- the internet is working if another address answered, or the addresses were just looked up, so the ones that
    -- didn't may be down. otherwise the device may be offline, so leave them as they are
    if answered or refresh then
        for __, url in ipairs(unanswered) do
            UrlApi:restZlibUrl(url)
        end
    end

    if not refresh then
        LogUtil.info("none of Z-Library's addresses answered, looking them up again")
        return self:request(path, form, true)
    end
    -- none of their names could be looked up just after they were looked up on Wikipedia, so the device is online:
    -- most likely the network is blocking them, as for Library Genesis (#55)
    if #urls > 0 and unresolved == #urls then
        LogUtil.warn("none of Z-Library's addresses' names could be looked up, though Wikipedia's could")
        return nil, Errors.ZLIB_UNFOUND
    end
    return nil, last_err or _("Z-Library didn't answer")
end

-- log into the account with the email and password, keeping the user id and key Z-Library answers with rather than
-- the password. returns whether it logged in, and why not
function ZlibAccount:login(email, password)
    local data, err = self:request("/eapi/user/login", {
        { "email", email },
        { "password", password },
    })
    if not data then
        return false, err
    end

    local user = type(data.user) == "table" and data.user or {}
    local user_id, user_key = tonumber(user.id), user.remix_userkey
    -- the key is sent to curl in a cookie, so it's only ever letters and digits
    if not (user_id and type(user_key) == "string" and user_key:find("^%w+$")) then
        LogUtil.warn("Z-Library's answer to logging in didn't say how to log in")
        return false, _("unexpected response from Z-Library")
    end
    KindleFetchSettings:setZlibAccount({
        email = email,
        user_id = user_id,
        user_key = user_key,
    })
    LogUtil.info("logged in to Z-Library")
    return true
end

function ZlibAccount:logout()
    KindleFetchSettings:setZlibAccount(nil)
    LogUtil.info("logged out of Z-Library")
end

return ZlibAccount
