
local StringUtil = {}

function StringUtil.assertValidString(text)
    if type(text) ~= "string" or text == "" then
        return ""
    end
end

function StringUtil.trim(text)
    StringUtil.assertValidString(text)
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

function StringUtil.collapseWhitespace(text)
    StringUtil.assertValidString(text)
    return text:gsub("%s+", " ")
end

return StringUtil
