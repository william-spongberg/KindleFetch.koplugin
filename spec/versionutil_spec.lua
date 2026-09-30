local helper = require("helper")

describe("VersionUtil", function()
    local VersionUtil

    before_each(function()
        helper.reset()
        VersionUtil = require("util.versionutil")
    end)

    describe("parseVersion", function()
        it("parses full, partial and single number versions", function()
            assert.are.same({ major = 7, minor = 68, patch = 0, str = "7.68.0" }, VersionUtil.parseVersion("7.68.0"))
            assert.are.same({ major = 0, minor = 2, patch = 0, str = "0.2" }, VersionUtil.parseVersion("0.2"))
            assert.are.same({ major = 1, minor = 0, patch = 0, str = "1" }, VersionUtil.parseVersion("1"))
        end)

        it("ignores anything after the version number", function()
            local version = VersionUtil.parseVersion("8.17.0-DEV")
            assert.are.same({ 8, 17, 0 }, { version.major, version.minor, version.patch })
        end)

        it("rejects strings that do not start with a number", function()
            assert.is_nil(VersionUtil.parseVersion("v0.3"))
            assert.is_nil(VersionUtil.parseVersion("nightly"))
            assert.is_nil(VersionUtil.parseVersion(""))
        end)

        it("rejects values that are not strings", function()
            assert.is_nil(VersionUtil.parseVersion(nil))
            assert.is_nil(VersionUtil.parseVersion(3))
            assert.is_nil(VersionUtil.parseVersion({}))
        end)
    end)

    describe("compareVersions", function()
        local function compare(v1, v2)
            return VersionUtil.compareVersions(VersionUtil.parseVersion(v1), VersionUtil.parseVersion(v2))
        end

        it("orders by major, then minor, then patch", function()
            assert.are.equal(-1, compare("0.3", "0.4"))
            assert.are.equal(1, compare("1.0", "0.9.9"))
            assert.are.equal(-1, compare("8.16.9", "8.17.0"))
            assert.are.equal(1, compare("8.17.1", "8.17.0"))
        end)

        it("compares numerically rather than alphabetically", function()
            assert.are.equal(1, compare("0.10", "0.9"))
            assert.are.equal(-1, compare("7.68.0", "8.17.0"))
        end)

        it("treats missing parts as zero", function()
            assert.are.equal(0, compare("0.3", "0.3.0"))
            assert.are.equal(0, compare("1", "1.0.0"))
        end)

        it("returns nil when either version is missing", function()
            assert.is_nil(VersionUtil.compareVersions(nil, VersionUtil.parseVersion("1.0")))
            assert.is_nil(VersionUtil.compareVersions(VersionUtil.parseVersion("1.0"), nil))
        end)
    end)
end)
