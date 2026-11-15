-- The sites books come from, by the name a book's source is saved as. There's only Anna's Archive. Each has these.
-- NAME, to show. SOURCE, the saved name (see SearchCache). CACHE_VERSION, its parser's version, which saved searches
-- are kept by.
-- search and isCached (see AnnasSearch). SCOPES are the fields a search can be narrowed to (e.g. "author"), passed
-- after the page.
-- findDownloadLink (see Downloader) returns the link (or nil and an error), whether a site failed (so the sites are
-- looked up again for one more try), and the md5 and size in bytes the site lists, which the download is checked
-- against.
-- NEW_LINK_WHEN_SERVER_FAILS: a new link can be asked for once the server fails. LINKS_EXPIRE: also once the server no
-- longer takes it. SECRET_LINKS: the link is itself a secret (see Downloader).
-- NEEDS_KEY: searching needs the key (see AccountPage). allowance: how many more downloads the account has (see
-- DownloadPrompt).
return {
    annas = require("fetchanna.api.annassearch"),
}
