-- the Z-Library account logged into (see ZlibAccount) as it's saved: its email, user id and key, not its password
local SavedZlibAccount = {}
SavedZlibAccount.__index = SavedZlibAccount

-- the account as it was saved, or nil where it can't log in, without a user id and key
function SavedZlibAccount.fromTable(saved)
    if type(saved) ~= "table" or not saved.user_id or not saved.user_key then
        return nil
    end
    return setmetatable({ email = saved.email, user_id = saved.user_id, user_key = saved.user_key }, SavedZlibAccount)
end

-- as a plain table, as it's saved, leaving out anything else it was given
function SavedZlibAccount:toTable()
    return { email = self.email, user_id = self.user_id, user_key = self.user_key }
end

return SavedZlibAccount
