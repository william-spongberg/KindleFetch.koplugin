-- Lints the plugin and its tests: luacheck (from the repository root)
-- Based on KOReader's own .luacheckrc (koreader/.luacheckrc)

std = "luajit"
unused_args = false
self = false
max_line_length = 120

-- set up by KOReader
read_globals = {"G_reader_settings", "G_defaults"}

exclude_files = {"koreader/", "spec/.tmp/", "e2e/.tmp/", ".dev-home/"}

files["spec/"] = {
    std = "+busted",
    -- the specs stand in for parts of KOReader and LuaJIT
    globals = {"G_reader_settings", "G_defaults", "io", "os"}
}

files["e2e/"] = {
    std = "+busted",
    read_globals = {"unpack"}
}
-- runs the end-to-end tests, providing their describe/it, and boots KOReader, as reader.lua does
files["e2e/runner.lua"] = {
    globals = {"describe", "it", "before_each", "after_each", "G_reader_settings", "G_defaults"}
}
