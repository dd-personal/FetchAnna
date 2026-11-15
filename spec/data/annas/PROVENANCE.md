# Anna's Archive and SLUM test fixtures

Captured 2026-11-11 (around 23:13–23:20 UTC) with curl and a desktop Firefox User-Agent, without any account key or cookie of our own. No request in this set carried a secret key. Response headers are not stored: DDoS-Guard's `Set-Cookie` headers carry the client's public IP address (`__ddg9_`), so any header fixture is written by hand with placeholder values instead.

| File | Request | Status | Sanitized |
| --- | --- | --- | --- |
| `slum-annas.html` | `GET https://open-slum.org/annas.html` | 200 | Scripts and styles removed (including the CDN beacon with per-request tokens); each card's timeline cut to its last 3 checks. Card markup otherwise unchanged. |
| `fast-download-400-invalid-md5.json` | `GET https://annas-archive.pk/dyn/api/fast_download.json` (no parameters) | 400 | Verbatim body. Identical on `.gl` and `.gd`. |
| `fast-download-401-invalid-key.json` | `GET https://annas-archive.pk/dyn/api/fast_download.json?md5=d6e1dc51a50726f00ec438af21952a45` (no `key`) | 401 | Verbatim body. The MD5 is the example from Anna's own API documentation. |
| `db-aarecord-403-not-member.json` | `GET https://annas-archive.pk/db/aarecord_elasticsearch/md5:d6e1dc51a50726f00ec438af21952a45.json` (no session) | 403 | Verbatim body. |
| `search-302-check-redirect.html` | `GET https://annas-archive.pk/search?q=pride+and+prejudice` (no session) | 302, `Location: /search?q=pride+and+prejudice&check=1` | Verbatim body. |
| `md5-302-check-redirect.html` | `GET https://annas-archive.pk/md5/d6e1dc51a50726f00ec438af21952a45` (no session) | 302, `Location: /md5/d6e1dc51a50726f00ec438af21952a45?&check=1` | Verbatim body. |
| `ddos-guard-403-challenge.html` | The `&check=1` search URL above, following the redirect with a cookie jar | 403 | Verbatim body (no per-request tokens in it). |

The same three requests returned the same status codes and sizes on `annas-archive.gl`, `annas-archive.pk` and `annas-archive.gd`.

## From a member's session

`search-results-member.html` comes from the owner's own logged-in (tier 2) search for "pride and prejudice." on `annas-archive.gl`, in the default list view, page 1 of 10. The owner saved it from a desktop browser on 2026-11-11.

What it keeps:

- the search form
- the first 12 of its 50 results
- the pagination

What was changed or removed:

- scripts and styles removed
- book descriptions replaced with "Placeholder description."
- covers pointed at `https://covers.example/N.jpg`
- the links the browser made absolute made relative again, as Anna's template (`allthethings/templates/macros/aarecord_list.html` at `a15b123c`) renders them

There were no account details on the page: no account id, profile link, email or cookies. The raw server HTML for this view has no results hidden in comments, so the saved page matches what FetchAnna receives.

## Not captured

- **Book detail pages (`/md5/…`).** Without a member session they stop at the DDoS-Guard challenge above.
- **Any response to a real secret key** (login, the account page, fast-download success, 403 "Not a member", 429 "No downloads left"). Their shape is documented from Anna's source in `docs/annas-protocol.md`, and the fixtures for them are synthesized. Logging in and reading the account page have since worked live on a Kindle (see `docs/account.md`), but their responses weren't captured.
