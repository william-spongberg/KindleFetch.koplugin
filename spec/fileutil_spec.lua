local helper = require("helper")

describe("FileUtil", function()
    local dir, FileUtil

    before_each(function()
        helper.reset()
        dir = helper.tmpdir("files")
        FileUtil = require("util.fileutil")
    end)

    after_each(helper.cleanup)

    describe("getSize", function()
        it("returns the size of a file in bytes", function()
            helper.writeFile(dir .. "/book.epub", "12345")
            assert.are.equal(5, FileUtil.getSize(dir .. "/book.epub"))
        end)

        it("returns 0 for missing files and invalid paths", function()
            assert.are.equal(0, FileUtil.getSize(dir .. "/missing.epub"))
            assert.are.equal(0, FileUtil.getSize(nil))
        end)
    end)

    describe("readFile", function()
        it("returns the trimmed contents", function()
            helper.writeFile(dir .. "/version.txt", "0.3\n")
            assert.are.equal("0.3", FileUtil.readFile(dir .. "/version.txt"))
        end)

        it("returns nil for missing files and invalid paths", function()
            assert.is_nil(FileUtil.readFile(dir .. "/missing.txt"))
            assert.is_nil(FileUtil.readFile(""))
        end)
    end)

    describe("writeFile", function()
        it("writes text to a file", function()
            assert.is_true(FileUtil.writeFile(dir .. "/version.txt", "0.4"))
            assert.are.equal("0.4", helper.readFile(dir .. "/version.txt"))
        end)

        it("refuses nil content and invalid paths", function()
            assert.are.same({ nil, "nothing to write" }, { FileUtil.writeFile(dir .. "/version.txt", nil) })
            assert.are.same({ nil, "no file to write to" }, { FileUtil.writeFile(nil, "0.4") })
            assert.is_false(helper.exists(dir .. "/version.txt"))
        end)

        it("says why the file can't be opened", function()
            local ok, err = FileUtil.writeFile(dir .. "/missing/version.txt", "0.4")
            assert.is_nil(ok)
            assert.matches("No such file or directory", err)
        end)

        -- which is only said once the file is closed, and was taken to have been written
        it("says when the file can't be written in full, as when the storage is full", function()
            local ok, err = FileUtil.writeFile("/dev/full", "0.4")
            assert.is_nil(ok)
            assert.matches("No space left on device", err)
        end)
    end)

    describe("removeFile", function()
        it("deletes the file", function()
            helper.writeFile(dir .. "/book.epub", "data")
            FileUtil.removeFile(dir .. "/book.epub")
            assert.is_false(helper.exists(dir .. "/book.epub"))
        end)

        it("ignores invalid paths", function()
            FileUtil.removeFile(nil)
            FileUtil.removeFile("")
        end)
    end)

    describe("removeDir", function()
        it("removes a folder and everything in it", function()
            helper.writeFile(dir .. "/plugin/main.lua", "-- v0.4")
            helper.writeFile(dir .. "/plugin/util/curlutil.lua", "-- v0.4")
            assert.is_true(FileUtil.removeDir(dir .. "/plugin"))
            assert.is_false(helper.exists(dir .. "/plugin"))
            -- and there's nothing to do once it's gone
            assert.is_true(FileUtil.removeDir(dir .. "/plugin"))
        end)

        it("doesn't follow links out of it", function()
            helper.writeFile(dir .. "/books/Dune.epub", "epub")
            helper.writeFile(dir .. "/plugin/main.lua", "-- v0.4")
            helper.run(
                string.format(
                    "ln -s %s %s",
                    helper.quote(helper.abs(dir .. "/books")),
                    helper.quote(dir .. "/plugin/books")
                )
            )
            assert.is_true(FileUtil.removeDir(dir .. "/plugin"))
            assert.are.equal("epub", helper.readFile(dir .. "/books/Dune.epub"))
        end)
    end)

    describe("listDir", function()
        it("lists what's in a folder", function()
            helper.writeFile(dir .. "/listed/a.txt", "a")
            helper.writeFile(dir .. "/listed/b.txt", "b")
            local names = FileUtil.listDir(dir .. "/listed")
            table.sort(names)
            assert.are.same({ "a.txt", "b.txt" }, names)
        end)

        -- which lfs.dir raises, and KOReader would exit on
        it("says when the folder can't be read", function()
            helper.stubs.lfs.dir = function(path)
                error("cannot open " .. path .. ": No such file or directory")
            end
            local names, err = FileUtil.listDir(dir .. "/missing")
            assert.is_nil(names)
            assert.matches("No such file or directory", err)
            assert.is_truthy(helper.logged("warn", "^could not read the folder"))
        end)
    end)

    describe("isValidFile / isValidDirectory", function()
        it("tells files and directories apart", function()
            helper.writeFile(dir .. "/book.epub", "data")
            assert.is_true(FileUtil.isValidFile(dir .. "/book.epub"))
            assert.is_false(FileUtil.isValidFile(dir))
            assert.is_true(FileUtil.isValidDirectory(dir))
            assert.is_false(FileUtil.isValidDirectory(dir .. "/book.epub"))
            assert.is_false(FileUtil.isValidFile(dir .. "/missing.epub"))
        end)

        it("rejects invalid paths", function()
            assert.falsy((FileUtil.isValidFile(nil)))
            assert.falsy((FileUtil.isValidDirectory("")))
        end)
    end)
end)
