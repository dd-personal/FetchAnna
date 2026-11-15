# Phase 1 report: upstream audit and Anna's Archive feasibility

Date: 2026-11-11.

## Base

- Upstream: `https://github.com/william-spongberg/KindleFetch.koplugin`
- Base commit: **`898352d7fb8be8fe1b93172ba954ce93d26e727e`** ("Release v0.8", 2026-10-15). It is still upstream's HEAD, unchanged since the plan was written. The `version.txt` is 0.8.
- Local layout: this clone *is* the fork's working tree. Its `upstream` remote points at the original repository. No fork remote has been created yet.
- The repository is set to `core.autocrlf=false` and `core.eol=lf`, as StyLua checks for Unix line endings and a Windows checkout with the global `autocrlf=true` turns every file to CRLF.

## Toolchain (WSL Ubuntu 24.04, user space, as in DEVELOPMENT.md)

| Tool | Version | Upstream CI |
| --- | --- | --- |
| LuaJIT (hererocks) | 2.1.1794386141 | `luajit-2.1` |
| LuaRocks | 3.13.0 | latest |
| busted | 2.3.0 | latest |
| luacov | latest from LuaRocks | latest |
| luacheck | 1.2.0 | latest |
| StyLua | 2.5.2 | 2.5.2 (pinned) |
| zip / unzip | 3.0 / 6.00 (Ubuntu packages, unpacked into `~/.local`) | Ubuntu's |

## Baseline test results

Run on 2026-11-11 against the unmodified base commit (the only additions were these docs and `spec/data/`, which none of the tools read):

| Check | Result |
| --- | --- |
| `stylua --check .` | Pass (exit 0) |
| `luacheck .` | Pass: 0 warnings / 0 errors in 92 files |
| `busted --coverage --exclude-tags=live` | Pass: 1056 successes, 0 failures, 0 errors, 2 pending, in 158 s |
| Line coverage (luacov) | 98.42% (6785 lines, 109 missed) |

The 2 pending specs are upstream's live Z-Library login and search tests, which skip themselves without `KINDLEFETCH_ZLIB_EMAIL` and `KINDLEFETCH_ZLIB_PASSWORD`. The live canaries (`busted --tags=live`) were not run.

The commands, from the repository root in WSL:

```bash
export PATH=~/.local/share/hererocks/luajit/bin:~/.local/bin:~/.local/usr/bin:$PATH
stylua --check . && luacheck . && busted --coverage --exclude-tags=live
```

## Upstream audit: what to reuse, and what has to change

Upstream has no Anna's Archive provider. It ships Library Genesis, Internet Archive, Project Gutenberg and Z-Library. The modules to build on:

- **Mirror-based search:** `api/lglisearch.lua`, `api/urlapi.lua` and `cache/urlcache.lua`. These cover mirror lookup on Wikipedia, rest/prefer/drop failover, telling blocked, busy and unresolved apart, and keeping last-known-good mirrors.
- **Searching as a logged-in account:** `api/zlibaccount.lua`, `api/zlibsearch.lua` and `ui/zliblogin.lua`.
- **Search plumbing:** `api/sources.lua` (the source contract) and `api/multisearch.lua`.
- **Downloads:** `api/downloader.lua`, `util/httpdownload.lua` and `util/filecheck.lua`. These cover background transfers, resume, sleep and Wi-Fi handling, HTML-instead-of-book detection, and MD5 checks.

Security gaps that must be fixed before any key is handled:

1. **URLs are logged in full.** `HttpUtil.getBody` logs the whole URL at debug level, and on failure at warn level. Warn lines also go into the diagnostics buffer (`LogUtil.recent`). A `key=` query parameter or a signed download link would leak into `crash.log` and into diagnostics exports. A redaction layer is needed in front of every log call.
2. **URLs are on curl's command line.** `CurlUtil.fetchCommand` and `CurlUtil.getDownloadCMD` pass the URL as an argument, where any process can read it. Upstream already passes proxy, form and cookie data through a `-K` config file. The URL can go there too (`url = "…"`) for sensitive requests.
3. **KOReader's own HTTP follows redirects.** `requestBodyWithKOReader` sets `redirect = true` unless a form or cookies are sent. Credential-bearing requests need redirects off, with each hop checked against the origin policy.
4. **The curl path follows redirects blindly.** It uses `-sL` with the `Cookie:` header. curl doesn't replay a custom Cookie header to another host, but a GET with `key=` in the query keeps the key in the URL until the server redirects. Sensitive requests should use no `-L`, and handle redirects in Lua.
5. **The Z-Library account is stored in ordinary settings.** `settings.lua` keeps it as a plain setting. Anna's key needs its own store, with optional persistence (Phase 4).
6. **A Z-Library-style cookie jar.** `requestBodyWithCurl` turns curl's cookie engine on whenever a form or cookies are sent. DDoS-Guard cookies would then build up per request. That is harmless, but it is state to scope by origin.

## Feasibility

| Plan item | Finding | Status |
| --- | --- | --- |
| Mirror discovery from SLUM | Works. No JSON feed. The HTML cards can be parsed with roles told apart. A fixture is captured. | Feasible |
| Catalogue origins reachable from plain HTTP clients | `/faq` and `/dyn/api/*` answer curl without a challenge on all three origins. | Feasible (LIVE) |
| Key login | `POST /account/` with `key`, setting a 90-day `aa_account_id2` cookie scoped to the domain. | Documented (SOURCE). Live test pending. |
| Key validation without spending quota | `fast_download.json` with a well-formed MD5 that matches nothing: 401 for a bad key, 404 for a good one. | Documented (SOURCE). Live test pending. |
| Download through the member API | Stable, self-documenting JSON API. The key goes in the query. Links are signed and expire after 2 h. Re-asking for the same book is free. | Feasible (LIVE + SOURCE) |
| **Native search** | Anonymous requests are always challenged (DDoS-Guard JS). Members of tier 2 and up skip the challenge: 36 searches/h at tier 2, 180/h at tier 3 and up. Tier 1 is always challenged. | **Feasible only for members of tier 2 and up.** Others get an honest "blocked" state with the browser and paste-a-link fallback. |
| Detail pages | Same gate as search, with a 600/h base allowance. | As search |
| Search-parser fixtures | Can't be captured without a member session. | **Blocked** until a member capture is authorized, or synthesized from templates |
| Download file behaviour (headers, Range, redirects) | Needs one real download. | **Blocked** on an authorized live test |

**Verdict:** the project is feasible as planned. The one big caveat is that native search works only for members whose tier skips browser checks, and FetchAnna must report that account capability truthfully. Nothing found needs, or would justify, getting around DDoS-Guard.

## Open questions for live testing

Each needs the owner's own key, entered locally in the plugin UI or in a local test environment, never in chat or committed files.

1. Does `POST /account/` reach Anna's app from KOReader's curl and from luasocket without a challenge?
2. With the session cookie, are `/search` and `/md5/…` served directly to those clients? What does the results markup look like? Capture one sanitized page.
3. For one public-domain book via `fast_download.json`: the download server's response headers, `Range` support, redirects, and whether the MD5 of the file matches.
4. Is the all-random-MD5 probe for checking a key reliably 404 for a valid key?

## Next

Phase 2 (fork identity and module boundaries) can start without any live access. Phases 3 and 4 can be built and tested offline against the fixtures and the protocol above. Phase 5's parser waits on question 2 above.
