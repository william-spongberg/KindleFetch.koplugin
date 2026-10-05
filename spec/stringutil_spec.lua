local helper = require("helper")

describe("StringUtil", function()
    local StringUtil

    before_each(function()
        helper.reset()
        StringUtil = require("util.stringutil")
    end)

    it("only accepts non-empty strings as valid", function()
        assert.is_true(StringUtil.assertValidString("a"))
        assert.is_false(StringUtil.assertValidString(""))
        assert.is_false(StringUtil.assertValidString(nil))
        assert.is_false(StringUtil.assertValidString(42))
    end)

    -- every helper returns an empty string for invalid input rather than erroring
    for _, name in ipairs({
        "trim",
        "collapseWhitespace",
        "collapseDots",
        "collapseDashes",
        "convertHtmlToText",
        "removeParentheses",
        "cleanTitle",
        "cleanFileName",
        "replaceCarriageReturns",
    }) do
        it(name .. " returns an empty string for invalid input", function()
            assert.are.equal("", StringUtil[name](nil))
            assert.are.equal("", StringUtil[name](""))
        end)
    end

    it("trims whitespace from both ends", function()
        assert.are.equal("dune", StringUtil.trim("  \tdune \n"))
    end)

    it("collapses repeated whitespace, dots and dashes", function()
        assert.are.equal("a b c", StringUtil.collapseWhitespace("a  \t b\n\nc"))
        assert.are.equal("a.b.c", StringUtil.collapseDots("a...b..c"))
        assert.are.equal("a-b-c", StringUtil.collapseDashes("a---b--c"))
    end)

    it("converts html entities to text", function()
        assert.are.equal("Pride & Prejudice", StringUtil.convertHtmlToText("Pride &amp; Prejudice"))
    end)

    it("removes parenthesised and bracketed text", function()
        assert.are.equal("Dune", StringUtil.removeParentheses("Dune (Dune Chronicles 1) [Ace, 1990]"))
    end)

    describe("cleanTitle", function()
        it("leaves a title as it's written, unlike a file name", function()
            assert.are.equal("Dune: Messiah / What if?", StringUtil.cleanTitle("Dune: Messiah / What if?"))
            assert.are.equal("Dune- Messiah - What if-", StringUtil.cleanFileName("Dune: Messiah / What if?"))
        end)

        it("leaves out what's in brackets, and the space around it", function()
            assert.are.equal("Dune", StringUtil.cleanTitle("  Dune (Dune Chronicles, Book 1) [1965] "))
            assert.are.equal("Dune - House Atreides", StringUtil.cleanTitle("Dune - House Atreides(Boom 2020)"))
        end)

        it("keeps a title that is all in brackets", function()
            assert.are.equal("[Untitled]", StringUtil.cleanTitle(" [Untitled] "))
        end)

        it("leaves titles in other alphabets whole", function()
            local title =
                "Мастер и Маргарита: роман в двух частях, с иллюстрациями"
            assert.are.equal(title, StringUtil.cleanTitle(title))
        end)
    end)

    it("makes titles safe to use as file names", function()
        assert.are.equal("Dune- Messiah", StringUtil.cleanFileName("Dune: Messiah (Book 2)"))
        assert.are.equal("AC-DC - The Story", StringUtil.cleanFileName("AC/DC -- The Story"))
        assert.are.equal("Title", StringUtil.cleanFileName("...Title... "))
        assert.are.equal("Mr. Mercedes", StringUtil.cleanFileName("Mr. Mercedes"))
    end)

    it("turns the line breaks in github's release notes into new lines", function()
        assert.are.equal("line 1\nline 2\n", StringUtil.replaceCarriageReturns("line 1\r\nline 2\r\n"))
    end)
end)
