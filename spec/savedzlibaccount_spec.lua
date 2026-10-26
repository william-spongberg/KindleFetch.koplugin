local helper = require("helper")

describe("SavedZlibAccount", function()
    local SavedZlibAccount

    before_each(function()
        helper.reset()
        SavedZlibAccount = require("settings.savedzlibaccount")
    end)

    after_each(helper.cleanup)

    -- as ZlibAccount:login saves it
    it("is the account as it was saved: its email, user id and key", function()
        local saved = { email = "reader@example.com", user_id = 42, user_key = "secretkey" }
        assert.are.same(saved, SavedZlibAccount.fromTable(saved):toTable())
    end)

    -- such as a password, which is never kept
    it("is given as a plain table of its own, without anything else it was given", function()
        local plain = SavedZlibAccount.fromTable({
            email = "reader@example.com",
            user_id = 42,
            user_key = "secretkey",
            password = "secretpassword",
        }):toTable()
        assert.are.same({ email = "reader@example.com", user_id = 42, user_key = "secretkey" }, plain)
        assert.is_nil(getmetatable(plain))
    end)

    -- which is all it logs in with
    it("is one without an email", function()
        local saved = { user_id = 42, user_key = "secretkey" }
        assert.are.same(saved, SavedZlibAccount.fromTable(saved):toTable())
    end)

    it("isn't one without a user id and key", function()
        assert.is_nil(SavedZlibAccount.fromTable({ email = "reader@example.com" }))
        assert.is_nil(SavedZlibAccount.fromTable({ email = "reader@example.com", user_id = 42 }))
        assert.is_nil(SavedZlibAccount.fromTable({ email = "reader@example.com", user_key = "secretkey" }))
        assert.is_nil(SavedZlibAccount.fromTable({ user_id = false, user_key = "secretkey" }))
        assert.is_nil(SavedZlibAccount.fromTable("reader@example.com"))
        assert.is_nil(SavedZlibAccount.fromTable(nil))
    end)
end)
