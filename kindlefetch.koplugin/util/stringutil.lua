
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

function StringUtil.cleanEmojis(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    -- remove non-ASCII chars
    return StringUtil.trim(string.gsub(text, "[^\x00-\x7F]", ""))
end

function StringUtil.removeExtension(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    -- remove everything before last dot
    return text:match("^(.+)%.[^%.]*$") or text
end

function StringUtil.removeParentheses(text)
    if not StringUtil.assertValidString(text) then
        return ""
    end
    -- remove anything in brackets, (...) or [...]
    text = text:gsub("%s*%([^)]*%)", "")  -- remove (...)
    text = text:gsub("%s*%[[^%]]*%]", "")  -- remove [...]
    return text
end

return StringUtil
