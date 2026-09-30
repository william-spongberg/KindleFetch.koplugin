-- Devices the end-to-end tests emulate. KOReader always runs as its desktop version here, so each profile sets
-- the device's screen, and the device checks KindleFetch makes (e.g. whether to update curl on Kindles).
-- Screen sizes match KOReader's own `./kodev run -s=...` presets.

return {
    ["kindle"] = {
        description = "basic Kindle",
        width = 600,
        height = 800,
        dpi = 167,
        kindle = true
    },
    ["kindle-paperwhite"] = {
        description = "Kindle Paperwhite",
        width = 1072,
        height = 1448,
        dpi = 300,
        kindle = true
    },
    ["kobo-aura-one"] = {
        description = "Kobo Aura One",
        width = 1404,
        height = 1872,
        dpi = 300,
        kobo = true
    },
    ["android"] = {
        description = "Android phone",
        width = 1080,
        height = 2340,
        dpi = 420,
        android = true
    }
}
