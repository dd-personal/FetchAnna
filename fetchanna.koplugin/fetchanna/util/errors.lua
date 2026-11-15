local _ = require("gettext")

-- Errors that code acts on, not only shows. They're compared by value as they pass up from module to module, and kept
-- here so each is worded one way.
local Errors = {
    -- Called off with a Cancel button. Not shown, as it was asked for.
    CANCELLED = _("request cancelled"),
    -- curl, or the shell that runs it, couldn't be started. Not the same as being called off.
    START_FAILED = _("could not start curl"),
    -- A bug in FetchAnna, logged with where it happened (see Guard).
    UNEXPECTED = _("something went wrong, see crash.log"),
    -- A Kindle's own curl is too old to connect to the sites securely.
    OUTDATED_CURL = _(
        "this Kindle's curl is too old to download books. Update it from "
            .. "Search → FetchAnna → Check for updates"
    ),
    -- Nothing on a site's results page could be read, as when its layout has changed.
    UNREADABLE = _(
        "the site's results couldn't be read, as its pages may have changed, so check for updates to FetchAnna"
    ),
    -- A site has none of the file types chosen in the settings.
    NO_FILE_TYPES = _("none of the file types chosen in the settings"),
    -- Anna's Archive can only be searched with the key, which hasn't been entered (see AccountPage).
    ANNAS_NO_KEY = _("enter your Anna's Archive secret key under FetchAnna → Account first"),
    -- Anna's Archive doesn't accept the key.
    ANNAS_KEY_REJECTED = _("Anna's Archive doesn't accept your secret key. Check it under FetchAnna → Account"),
    -- Anna's Archive sent its browser check in place of results. FetchAnna never tries to get past it: only members
    -- whose membership skips it can search, up to so many searches an hour (see docs/annas-protocol.md).
    ANNAS_BLOCKED = _(
        "Anna's Archive asked for a browser check, which FetchAnna doesn't do. It only lets members whose membership "
            .. "skips it search from here, up to so many searches an hour"
    ),
    -- None of Anna's Archive's sites' names could be looked up, as when the network's DNS blocks them.
    ANNAS_UNFOUND = _(
        "none of Anna's Archive's sites can be found on this network, which may be blocking them. Try another Wi-Fi "
            .. "network, or encrypted DNS"
    ),
    -- Downloads go through the member API, which only gives members download links, so many a day (see
    -- AnnasAccount:fastDownload).
    ANNAS_NOT_MEMBER = _(
        "your Anna's Archive account has no membership with fast downloads, which FetchAnna downloads books with"
    ),
    ANNAS_NO_DOWNLOADS_LEFT = _("your Anna's Archive account has used all of its fast downloads for today"),
    ANNAS_FILE_GONE = _("Anna's Archive doesn't have this file any more"),
    -- A site was asked for a download link but didn't answer in time, and may still have counted it as a download.
    -- Asking for the same book again doesn't count twice while it's among those downloaded recently.
    ANNAS_LINK_TIMED_OUT = _(
        "Anna's Archive took too long to give a download link. It may have counted it as one of today's fast "
            .. "downloads, but asking for the same book again soon won't count it twice"
    ),
}

return Errors
