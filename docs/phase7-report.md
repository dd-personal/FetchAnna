# Phase 7 report: tests and release acceptance

Date: 2026-11-14. Branch `fetchanna`, forked from KindleFetch v0.8 (`898352d7`).

## What Phase 7 changed

- **FetchAnna is now Anna's Archive only, as the plan asks.** Downloads work on a real device, so KindleFetch's other sites were removed:
  - the code for Library Genesis, Internet Archive, Project Gutenberg and Z-Library: `lglisearch`, `iasearch`, `gutenbergsearch`, `zlibsearch`, `zlibaccount`, `zliblogin`, `urlapi` and `urlcache`
  - their settings: Z-Library account, book types, how long to keep mirrors, which sites to search
  - their UI: the Sites and Search in buttons, the per-site gesture actions, "Search <other site>" offers
  - their entries in Diagnostics, where the connection test now asks SLUM and each known Anna's Archive site, sending nothing of the account's
  - their specs and end-to-end tests

  Shared code (downloader, results menu, filters, caches, updater, curl) stays. Its specs now use Anna's Archive, or a small fake site where they test the downloader in general.
- **A keyless live canary** (`spec/annas_live_spec.lua`, tagged `#live`, run daily by the Canary workflow) checks two things: that SLUM still lists Anna's Archive's sites in a form FetchAnna reads, and that at least one released site answers the member API as Anna's Archive does. It never has a key, and uses up nothing. The workflow's Z-Library secrets are gone.
- **New tests:**
  - a book whose title would lead out of the download folder (`../../../etc/passwd`) is saved inside it
  - signed download links never reach curl's command line, the log, or Diagnostics (end to end in `spec/secrets_spec.lua`)
- **The README** now covers installing, the key and how it's stored, searching, downloading, the sites and their controls, troubleshooting, compatibility, and updating and uninstalling.

## Toolchain

WSL Ubuntu 24.04.4 LTS, in user space, as in Phase 1: LuaJIT 2.1 (hererocks), LuaRocks 3.13.0, busted 2.3.0, luacov 0.17.0, luacheck 1.2.0, StyLua 2.5.2.

## Results

The commands are upstream's CI, run from the repository root:

| Check | Result |
| --- | --- |
| `stylua --check .` | Pass (exit 0) |
| `luacheck .` | Pass: 0 warnings / 0 errors in 96 files |
| `busted --coverage --exclude-tags=live` | Pass: 1139 successes, 0 failures, 0 errors, 0 pending, in 183 s |
| Line coverage (luacov) | 98.65% (8303 lines, 114 missed) |
| `busted --tags=live spec/annas_live_spec.lua` | Pass: 2 successes, against the live SLUM and Anna's Archive sites |
| Release zip, built as `release.yml` builds it | 50 files, 157 KB, all under `fetchanna.koplugin/`, with `LICENSE`, and none of the removed modules |

The pending count dropped from 2 to 0 because the 2 pending specs were the live Z-Library ones.

The other live check, the curl build's SHA-256 on GitHub, wasn't run this time.

## The plan's test list

The **Where** column names files under `spec/`.

| Area | What the plan lists | Where |
| --- | --- | --- |
| SLUM | mixed roles, duplicates, down and unknown statuses, malformed or empty pages, a site no longer listed, the last good list kept, links to anywhere but a site, a changed page | `slumparser_spec`, `annasmirrors_spec` |
| Choosing a site | health kept per capability, cooling down, at most 3 sites in 30 s, calling off, every site down | `annasmirrors_spec` |
| Account | right, wrong and unchecked keys, no membership, a check that couldn't be made, cookies kept per site, logging out, remembering the key only when asked | `keystore_spec`, `annasaccount_spec`, `accountpage_spec` |
| Security | exact origins, no credentials through redirects, redaction of encoded secrets and of signed links, curl and KOReader's HTTP doing the same, private addresses, nothing secret in Diagnostics or on a command line | `originpolicy_spec`, `httputil_spec`, `logutil_spec`, `secrets_spec`, `curlutil_spec`, `httpdownload_spec` |
| Search | a real member's page of results, no results, other alphabets and entities, missing details, more pages, duplicates, the browser check, pages that can't be read, saved searches kept per site and parser version | `annasparser_spec`, `annassearch_spec`, `cache_spec` |
| Download | expired link, no downloads left, a timeout that may have counted, one free new link, Wi-Fi dropping and carrying on, a web page in place of the book, wrong MD5, full storage, a title leading out of the folder, cancelling, renaming only once it's checked | `downloader_spec`, `annasaccount_spec`, `annassearch_spec`, `main_spec` |
| Fork | its own files, settings, caches and update source; installed alongside KindleFetch; updating and going back; one folder in the zip | `coexistence_spec`, `pluginupdater_spec`, `rollback_spec`, `release.yml`'s zip check |

## Where it was tested

**On a real device: a Kindle Paperwhite 5 SE** with KOReader v2026.07.1, curl 8.21.0 and a tier 2 membership, by the owner.

- 2026-11-12: entering the key, logging in on `annas-archive.gd`, reading the membership ("about 25 fast downloads a day, and 36 searches an hour without a browser check"), refreshing from SLUM, and Diagnostics without the key or session in it
- 2026-11-13: searching, with the results as Anna's Archive lists them
- 2026-11-14: downloading a book through the member API and opening it in KOReader

**Simulated only:**

- Everything else, in the unit tests, which stand in for KOReader (`spec/helper.lua`).
- The other device profiles (basic Kindle, Kobo, Android) weren't exercised on hardware.
- Downloading without curl, with KOReader's own HTTP, is covered by unit tests only.
- The end-to-end tests in `e2e/` weren't run: this environment has no KOReader build or Flatpak to run them in.

**Not exercised live:**

- Seeing the fast downloads count drop by one per new book, and **Diagnostics → Last download link** (added after the device test), as [downloads.md](downloads.md#checking-that-its-a-fast-download) describes.
- Failing over to another site when one is down. Every site was up during testing.
- Carrying on after Wi-Fi drops during a download.
- The one new link after a failed download.

## Definition of done

| | Item | State |
| --- | --- | --- |
| 1 | Installable zip and a source fork with attribution and its own identity | **Partly.** The zip builds and passes the release workflow's checks. The fork is on GitHub (private), with the licence and README attribution. No release has been published. |
| 2 | Anna's-only search returns correct results on a reachable site | **Done**, on the device. |
| 3 | Key login and checking follow the verified protocol, and say truthfully what the account can do | **Done**, on the device. |
| 4 | Selecting a book, downloading it, and opening the checked file | **Done**, on the device. |
| 5 | Failing over between sites without leaking credentials or corrupting files | **Unit-tested**, not live (see above). |
| 6 | A SLUM failure keeps the last good list, and new sites need approval before they're sent the key | **Unit-tested.** |
| 7 | Deterministic tests pass, live checks are reported accurately, the browser-check limitation is documented | **Done.** |
| 8 | README covers installing, the key, the sites, troubleshooting, compatibility, and updating and uninstalling | **Done.** |

## Left to do

- **Releasing.** `release.yml` only releases from `main`, and only when `fetchanna/updater/releasesource.lua` names the repository releasing it. That file names none yet, so this build never updates itself.
  - The repository is private. GitHub's API doesn't show a private repository's releases without signing in, so self-update can't work until it's public, even once the file names it.
  - Until then, the zip has to be built and installed by hand.
- **DNS rebinding:** the address check is still separate from curl's own lookup (see [mirrors.md](mirrors.md)).
- **Saved results** aren't yet marked as such when they're shown without a connection.
- **What the download servers send** is still unconfirmed: their headers, whether they take `Range` and send an `ETag`, and what an expired link answers (see [downloads.md](downloads.md)).
- **A real-device check of failover and recovery:**
  - search with the first approved site revoked
  - turn Wi-Fi off partway through a download and back on
  - relaunch KOReader mid-download
