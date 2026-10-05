local util = require("util")

local StringUtil = {}

function StringUtil.assertValidString(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    return true
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

-- a title as it's written, for showing on screen, without what Library Genesis adds to it in brackets (such as
-- the series it's in)
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

-- whether text is a web address that can be passed on as it is. mirrors are looked up on a page anyone can edit,
-- so what a mirror sends can't be trusted: a line break or quote in an address written to curl's config file
-- would add options of the mirror's own, such as where on the device to save a file
function StringUtil.isSafeUrl(text)
    return type(text) == "string" and text:find('^https?://[^%c%s"\\]+$') ~= nil
end

function StringUtil.cleanFileName(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    text = StringUtil.removeParentheses(text)
    text = text:gsub('[<>:"/\\|?*]', "-") -- replace invalid chars with dash
    text = text:gsub("^[%s%.]+", "") -- remove leading spaces/dots
    text = text:gsub("[%s%.]+$", "") -- remove trailing spaces/dots
    text = StringUtil.collapseWhitespace(StringUtil.collapseDashes(StringUtil.collapseDots(text)))

    return text
end

function StringUtil.replaceCarriageReturns(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end

    return text:gsub("\r\n", "\n")
end

return StringUtil
