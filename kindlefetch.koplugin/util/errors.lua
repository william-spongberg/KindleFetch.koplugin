local _ = require("gettext")

-- what went wrong, when it's something the code that's told acts on, rather than only saying it: compared by value
-- as it's passed up from module to module, and kept here so each is said one way wherever it comes from
local Errors = {
    -- called off with a Cancel button, which isn't said, as it was asked for
    CANCELLED = _("request cancelled"),
    -- curl, or the shell that runs it, couldn't be started, which isn't the same as being called off
    START_FAILED = _("could not start curl"),
    -- a mistake in Kindle Fetch itself, logged with where it happened (see Guard)
    UNEXPECTED = _("something went wrong, see crash.log"),
    -- neither the mirrors nor Wikipedia answered at all, as when the device isn't connected to the internet
    NO_CONNECTION = _("no internet connection"),
    -- Z-Library no longer accepts the account's key, e.g. once it has been logged out of elsewhere, or there isn't
    -- one, e.g. when a book found before logging out is downloaded
    LOGGED_OUT = _("Z-Library has logged Kindle Fetch out, so log in again"),
    -- a Kindle's own curl, which is too old to connect to Library Genesis
    OUTDATED_CURL = _(
        "this Kindle's curl is too old to download books. Update it from "
            .. "Search → Kindle Fetch → Check for updates"
    ),
    -- Library Genesis' DDoS protection answered in place of its mirrors
    BLOCKED = _("Library Genesis is blocking automated searches right now, try again later"),
    -- Library Genesis' database is refusing connections, as it does while it's very busy
    BUSY = _("Library Genesis is too busy to send books right now, try again in a few minutes"),
    BUSY_SEARCH = _("Library Genesis is too busy to search right now, try again in a few minutes"),
    BLOCKED_DOWNLOAD = _("Library Genesis is blocking automated downloads right now, try again later"),
    -- nothing on a site's page of results could be read, as when it has changed how its pages are laid out
    UNREADABLE = _(
        "the site's results couldn't be read, as its pages may have changed, so check for updates to Kindle " .. "Fetch"
    ),
    -- a site has none of the file types chosen in the settings, so nothing can be found on it
    NO_FILE_TYPES = _("none of the file types chosen in the settings"),
    -- none of Z-Library's addresses' names could be looked up, though Wikipedia's could, as for Library Genesis below
    ZLIB_UNFOUND = _(
        "none of Z-Library's addresses can be found on this network, which may be blocking them. Try another Wi-Fi "
            .. "network or DNS server"
    ),
    -- none of Library Genesis' mirrors' names could be looked up, though Wikipedia's could (#55)
    UNFOUND = _(
        "none of Library Genesis' sites can be found on this network, which may be blocking them. Try "
            .. "another Wi-Fi network or DNS server"
    ),
}

return Errors
