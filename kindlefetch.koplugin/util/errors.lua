-- what went wrong, when it's something the code that's told acts on, rather than only saying it: compared by value
-- as it's passed up from module to module, and kept here so each is said one way wherever it comes from
local Errors = {
    -- called off with a Cancel button, which isn't said, as it was asked for
    CANCELLED = "request cancelled",
    -- curl, or the shell that runs it, couldn't be started, which isn't the same as being called off
    START_FAILED = "could not start curl",
    -- a mistake in Kindle Fetch itself, logged with where it happened (see Guard)
    UNEXPECTED = "something went wrong, see crash.log",
    -- neither the mirrors nor Wikipedia answered at all, as when the device isn't connected to the internet
    NO_CONNECTION = "no internet connection",
    -- Z-Library no longer accepts the account's key, e.g. once it has been logged out of elsewhere, or there isn't
    -- one, e.g. when a book found before logging out is downloaded
    LOGGED_OUT = "Z-Library has logged Kindle Fetch out, so log in again",
    -- a Kindle's own curl, which is too old to connect to Library Genesis
    OUTDATED_CURL = "this Kindle's curl is too old to download books. Update it from "
        .. "Search → Kindle Fetch → Check for updates",
    -- Library Genesis' DDoS protection answered in place of its mirrors
    BLOCKED = "Library Genesis is blocking automated searches right now, try again later",
    -- Library Genesis' database is refusing connections, as it does while it's very busy
    BUSY = "Library Genesis is too busy to send books right now, try again in a few minutes",
    BUSY_SEARCH = "Library Genesis is too busy to search right now, try again in a few minutes",
    -- none of Library Genesis' mirrors' names could be looked up, though Wikipedia's could (#55)
    UNFOUND = "none of Library Genesis' sites can be found on this network, which may be blocking them. Try "
        .. "another Wi-Fi network or DNS server",
}

return Errors
