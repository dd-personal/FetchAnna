# Anna's Archive's sites: discovery, trust and failover

How FetchAnna finds Anna's Archive's sites, decides which may be sent your secret key, and moves between them when one fails. The code is in:

- `fetchanna/util/originpolicy.lua`: what counts as a site at all
- `fetchanna/api/slumparser.lua`: reading SLUM
- `fetchanna/api/annasmirrors.lua`: the registry
- `fetchanna/ui/mirrorspage.lua`: Settings → Anna's Archive Sites

The protocol facts behind it are in [annas-protocol.md](annas-protocol.md).

## What a site is

A site is an **origin**: `https://` plus a DNS name, nothing else. `OriginPolicy` turns down anything that:

- isn't https
- has a login in it (`user:pass@`)
- uses a port other than 443
- is a numeric address, or a name with invalid labels or a non-alphabetic top-level domain
- has spaces, control characters or backslashes in it

Two addresses are the same site only when their origins are exactly equal. `annas-archive.gl.evil.example`, `evilannas-archive.gl` and `software.annas-archive.gl` are all different sites from `annas-archive.gl`. Nothing is trusted for having "annas" in its name, a valid certificate, or for looking right.

Before a site is asked anything, its name is looked up with luasocket. If any address it leads to isn't on the public internet, the site is not asked. That covers loopback, private, link-local, carrier-grade NAT, multicast, documentation and reserved ranges, and IPv4 inside IPv6 (mapped, NAT64, 6to4). A name that can't be looked up on the device passes, because curl may resolve it with encrypted DNS where the network's own DNS blocks Anna's Archive.

## Roles

Each site has one role:

- **Catalogue sites** (`annas-archive.gl`, `.pk`, `.gd`): searched, logged into, and asked for download links. The only sites that can ever receive the key.
- **The software host** (`software.annas-archive.gl`): Anna's source code. Never asked anything by the plugin.
- **Download servers** (`yqrii5.org`, `wbsg8v.xyz`, …): only ever sent the signed links the member API returns. SLUM's expected 403 "Link expired or invalid" from them is a health signal, not a file.

SLUM's cards don't say what a site is for, so `SlumParser` works it out:

1. First from what SLUM *expects the site to answer*: "in one place - Anna" → catalogue, "AnnaArchivist" → software, "Link expired or invalid" → download.
2. Otherwise from the card id, which can only mark a site as software or download, never catalogue.
3. A card whose id and expected content disagree, or that says neither, is left out.

Only each card's own title link is read. That link must pass `OriginPolicy` and must name the same site as the card's logs button and title, or the card is left out. The role of a site FetchAnna was released with never changes because of what SLUM says.

## Trust

| State | Sent the key? | How it gets there |
| --- | --- | --- |
| Built in (`seed`) | Yes | A catalogue site FetchAnna was released with, checked by hand on 2026-11-11 (`AnnasMirrors.SEEDS_REVIEWED`). |
| Approved | Yes | You approved it under Anna's Archive Sites. Approval first checks that the site answers Anna's member API exactly as Anna's Archive does, without sending it anything of yours. |
| Not approved | No | Found on SLUM but not approved. **Discovery never grants trust.** |
| Revoked | No | You revoked it, even if it's built in. |
| Suspended | No | It was trusted, but SLUM stopped listing it, or it answered the API probe as Anna's Archive doesn't (as a taken-over domain might). Clears by itself when SLUM lists it again or it passes a check again; approving it again also clears it. |

Approvals and revocations are kept in the settings file (`mirror_trust`), so Clear Cache doesn't touch them. **Reset to Built-in Sites** forgets them, along with every site found on SLUM and all health records.

## Discovery

- SLUM's page (`https://open-slum.org/annas.html`) is fetched without following redirects; only a redirect within SLUM is followed.
- It has no machine-readable feed. `/api.json`, `/annas.json`, `/status.json` and `/feed.json` all return 404 (checked 2026-11-11).
- It's looked up **when an operation needs sites and the last lookup is over 24 hours old**, or when you tap Refresh. Never in the background. After a failed lookup, SLUM isn't asked again for an hour.
- **A good list is never replaced by a bad one.** Any of these keeps the sites already known: SLUM can't be reached, a bot check answers instead, the page has changed so nothing can be read, or the page lists no catalogue site. The failure and its time are recorded and shown.
- A site SLUM stops listing is marked delisted. It isn't tried, and loses trust as above. A site found only on SLUM is forgotten after a month off the list, unless you approved it.
- The menu shows how long ago SLUM was last read, and SLUM's own generation time is kept for each site's status.

## Choosing a site, and failing over

`AnnasMirrors:run(capability, attempt)` tries up to **3** sites, starting no new attempt after **30 seconds**. Capabilities are tracked separately per site, because one site can search but fail to log in:

- `probe`, `search`, `account` and `api`, on catalogue sites
- `transfer`, on download servers

Searching, logging in and the member API go only to trusted sites.

Order of preference:

1. the site where this capability last worked
2. sites where it has worked since it last failed
3. sites checked to be Anna's Archive
4. built-in sites
5. by SLUM status (up or protected, then degraded, then the rest)

A site cooling down after a failure goes after all the others, but is still tried if nothing else is left, so a cooldown never blocks something you asked for.

Failures are classified:

- **Site failures; the next site is tried:**
  - name not found
  - couldn't connect
  - timed out
  - TLS failure
  - server error
  - bot check
  - asked to wait (429 or 503 with `Retry-After`)
  - answered with something unreadable
  - redirected to another site
  - private address

  The failed site cools down for 1 minute, doubling with each failure in a row up to 1 hour, or for as long as `Retry-After` asked (capped at 6 hours).
- **Not the site's fault; other sites are not tried:** invalid key, not a member, no downloads left, record not found, file unavailable. Rotating sites wouldn't change these, and would only spend more of the account's allowance.
- **Called off:** stops at once and isn't counted against the site.

When everything fails, `AnnasMirrors.describe(outcome)` says why in plain words.

## Not done yet

- **Searching and download links both use `run`.** Searching stops at a browser check (`opts.stop_on`), which is the account's doing, not the site's. Asking for a download link stops at the account's own answers (no membership, no downloads left, file not found), and isn't repeated by the downloader (see [downloads.md](downloads.md)). Searches that fail offer the fixes that apply: the Account screen, encrypted DNS, Wi-Fi, or Anna's own search to open in a browser (with a QR code). Choosing another site from the screen where everything failed is left to Settings → Anna's Archive Sites.
- **The address check is separate from curl's own lookup.** `OriginPolicy.checkHost` resolves the name itself, so a name whose DNS answer changes between the check and curl's request (DNS rebinding) isn't caught. Pinning curl to the checked address with `--resolve` would close this.
- **Revoking a site doesn't yet drop its login session.** Phase 4 adds sessions; revoking must then delete that site's cookie too.
- **Redirects aren't yet checked on credential-bearing requests.** Only discovery and checks use the no-redirect transport so far. Phase 4 moves every request that carries the key or session onto it, and checks each hop against the origin policy.
