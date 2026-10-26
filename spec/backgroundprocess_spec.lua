local helper = require("helper")

describe("BackgroundProcess", function()
    local BackgroundProcess, CurlUtil

    before_each(function()
        helper.reset()
        local data_dir = helper.tmpdir("data")
        helper.state.data_dir = data_dir
        helper.run("mkdir -p " .. helper.quote(data_dir .. "/settings"))
        BackgroundProcess = require("util.backgroundprocess")
        CurlUtil = require("util.curlutil")
    end)

    after_each(helper.cleanup)

    it("detects whether a process is running and can kill it", function()
        local pipe = io.popen("sleep 30 > /dev/null 2>&1 & echo $!")
        local pid = tonumber(pipe:read("*l"))
        pipe:close()

        assert.is_true(BackgroundProcess.isPidRunning(pid))
        BackgroundProcess.killPid(pid)
        os.execute("sleep 0.2")
        assert.is_false(BackgroundProcess.isPidRunning(pid))
    end)

    -- Cancel left curl running by itself, using the Wi-Fi and filling the book's .part file
    it("stops what a background download runs, not only the shell that waits for it", function()
        local exit_file = CurlUtil.createExitFile()
        -- sleep standing in for curl
        local pipe = io.popen(BackgroundProcess.echoPid(BackgroundProcess.saveExitCode("sleep 30", exit_file)))
        local pid = tonumber(pipe:read("*l"))
        pipe:close()
        os.execute("sleep 0.2")
        pipe = io.popen("pgrep -P " .. pid)
        local child = tonumber(pipe:read("*l"))
        pipe:close()
        assert.is_true(BackgroundProcess.isPidRunning(child))

        BackgroundProcess.killPid(pid)
        os.execute("sleep 0.3")
        assert.is_false(BackgroundProcess.isPidRunning(child))
        assert.is_false(BackgroundProcess.isPidRunning(pid))
    end)

    it("saves the exit code of what a download runs once it has finished", function()
        local exit_file = CurlUtil.createExitFile()
        os.execute(BackgroundProcess.saveExitCode("sh -c 'exit 22'", exit_file))
        assert.are.equal(22, BackgroundProcess.getExitCode(exit_file))
        -- the shell's own, when curl isn't there to run
        os.execute(BackgroundProcess.saveExitCode("kindlefetch-no-such-command -s", exit_file))
        assert.are.equal(127, BackgroundProcess.getExitCode(exit_file))
    end)

    it("looks in /proc, without starting a shell", function()
        local proc = helper.tmpdir("proc")
        BackgroundProcess.PROC_DIR = proc
        helper.writeFile(proc .. "/self/stat", "100 (luajit) R 1")
        helper.writeFile(proc .. "/4242/stat", "4242 (sh (curl)) S 1 4242")
        helper.writeFile(proc .. "/4343/stat", "4343 (sh) Z 1 4343")
        helper.stubExecute("kill -0", function()
            error("started a shell")
        end)

        assert.is_true(BackgroundProcess.isPidRunning(4242))
        -- finished, but not cleaned up yet
        assert.is_false(BackgroundProcess.isPidRunning(4343))
        assert.is_false(BackgroundProcess.isPidRunning(4444))
    end)

    it("asks kill on systems without /proc", function()
        BackgroundProcess.PROC_DIR = helper.tmpdir("no-proc")
        helper.stubExecute("kill -0 4242", function()
            return 0
        end)
        assert.is_true(BackgroundProcess.isPidRunning(4242))
    end)

    it("ignores missing pids", function()
        assert.is_false(BackgroundProcess.isPidRunning(nil))
        BackgroundProcess.killPid(nil)
    end)

    describe("a process", function()
        local running

        before_each(function()
            running = true
            BackgroundProcess.isPidRunning = function()
                return running
            end
        end)

        it("has an exit code once it has finished, and is running until then", function()
            local exit_file = CurlUtil.createExitFile()
            local process = BackgroundProcess.new(4242, exit_file)
            assert.are.same({ nil, true }, { process:poll() })
            assert.is_true(process:isRunning())

            helper.writeFile(exit_file, "0\n")
            assert.are.same({ 0, false }, { process:poll() })
            assert.is_false(process:isRunning())
        end)

        -- as it may have finished between looking for its exit code and whether it was running
        it("looks for its exit code again once it has stopped, which it can do without one", function()
            local exit_file = CurlUtil.createExitFile()
            BackgroundProcess.isPidRunning = function()
                helper.writeFile(exit_file, "22\n")
                return false
            end
            assert.are.same({ 22, false }, { BackgroundProcess.new(4242, exit_file):poll() })
            assert.are.same({ nil, false }, { BackgroundProcess.new(4343, CurlUtil.createExitFile()):poll() })
        end)

        -- as its pid may have gone to another process since
        it("isn't killed once it has finished or been stopped", function()
            local killed = {}
            BackgroundProcess.killPid = function(pid)
                table.insert(killed, pid)
            end
            local exit_file = CurlUtil.createExitFile()
            local process = BackgroundProcess.new(4242, exit_file)
            process:kill()
            helper.writeFile(exit_file, "0\n")
            process:poll()
            process:kill()

            local stopped = BackgroundProcess.new(4343, CurlUtil.createExitFile())
            stopped:stop()
            stopped:kill()
            assert.are.same({ 4242, 4343 }, killed)
        end)
    end)
end)
