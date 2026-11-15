# Your Anna's Archive key

How FetchAnna handles your Anna's Archive secret key, what it asks Anna's Archive with it, and what's still unverified or left to do. The code is in:

- `fetchanna/api/keystore.lua`: storage
- `fetchanna/api/annasaccount.lua`: the protocol
- `fetchanna/ui/accountpage.lua`: FetchAnna → Account
- `fetchanna/util/logutil.lua`: redaction

The protocol facts are in [annas-protocol.md](annas-protocol.md).

## What's sent, and where

Only to a site trusted with the key (see [mirrors.md](mirrors.md)), only over https, and never following a redirect:

| What | How | Why |
| --- | --- | --- |
| Log in | `POST /account/` with form field `key` | Anna's Archive answers with a login session (cookie `aa_account_id2`, 90 days), needed to search without a browser check. |
| Check the key | `GET /dyn/api/fast_download.json?md5=<random>&key=<key>` | Anna's checks the key *before* looking up the file, so asking for a file no one has gives 404 "Record not found" for a good key and 401 "Invalid secret key" for a bad one. **No download is used up.** It doesn't say whether the account is a member. |
| Read the membership | `GET /account/` with the session cookie | The logged-in account page lists memberships. |

There's no Bearer token or other made-up authentication: these are the only ways Anna's Archive takes the key. The session cookie is kept for, and only ever sent to, the exact site that gave it, even though Anna's sets it for the whole domain.

**Connect** logs in first. If every site asks for a browser check or doesn't answer, it falls back to the quota-free key check, so you can still learn whether the key is right. A site that asks for a browser check is never taken to mean the key is wrong.

## What the Account screen can say

| Status | Meaning |
| --- | --- |
| No key | None entered. |
| Key saved, not checked yet | Entered, never checked. |
| Key saved, couldn't be checked | No trusted site could be asked: bot check, no answer, and so on. The reason is kept and shown. |
| Key accepted, not logged in | The member API took it, but no login session was obtained (or it expired). |
| Logged in | A session that hasn't expired, on at least one trusted site. |
| Key not accepted | Anna's Archive turned it down. Its sessions are dropped. |

Membership is read from the account page:

- **Logged in** means the page shows the logout form.
- **The tier** is the highest membership row that isn't struck through as expired.
- **No membership** only when the page invites you to become a member *and* doesn't show the fast-downloads counter. Otherwise the membership is reported as **not known yet**, rather than as none.

The tier is turned into "about N fast downloads a day, M searches an hour without a browser check" using the figures in Anna's published code. The member API's own counts (downloads left today) replace those once a real download reports them.

## Where it's kept

- **By default, only in memory.** The key and its sessions are gone when KOReader restarts.
- **"Remember on This Device"** (opt-in, after a warning) writes them to `settings/fetchanna_key.txt`, outside the plugin's folder, so plugin updates and rollbacks never copy it. That file:
  - is plain text with a header saying what it is, never a Lua settings file, so it's never executed and gets no `.old` backup copies
  - is written as a new file, restricted to its owner (0600, set with `chmod` through LuaJIT's FFI rather than a shell command), then renamed into place
  - is **not encrypted**, because whatever decrypted it would have to sit beside it. The UI says so, and says that on most e-readers anyone who connects the device to a computer can read it. The FAT storage of Kindles and Kobos has no owners, so the 0600 restriction does nothing there.
  - is validated line by line when read back. Anything that isn't a valid key, origin and session, or a known account fact, is left out.
- **Forget Key and Log Out** removes the key, its sessions and the file. The UI says that removing a file from flash storage doesn't guarantee its contents are erased. Anna's sessions can't be ended on Anna's side: they're signed tokens it only checks, and its logout just deletes the cookie. So deleting the session on the device *is* logging out.
- Revoking a site, or resetting the sites, drops the sessions those sites gave.
- None of this is ever in FetchAnna's settings, caches or diagnostics.

## Never logged, never on a command line

- **Redaction (`LogUtil.redact`)** runs on every log line at every level, on the diagnostics buffer, and finally on the whole diagnostics report. It removes:
  - the whole query of any address that has a `key`, `token`, `password` (…) parameter
  - the value of such fields anywhere in a line
  - the `aa_account_id2` cookie's value
  - every secret registered this session (the key, sessions, and later download links), as written and URL-encoded
- **Requests that carry the key in their address** (`opts.sensitive`) give curl the address in its config file (`-K`), not on its command line, where any process could read it, and send no Referer. The form body and cookies were already passed that way. These requests never follow a redirect, on curl or on KOReader's own HTTP.
- **Both transports behave alike.** Repeated `Set-Cookie` headers are joined the same way, and neither follows redirects for these requests. `spec/secrets_spec.lua` runs the real login and key check through each, and checks that the key and session appear in no command line, log line, setting or diagnostics report, and only ever go to the trusted site.

## Verified on a device

On 2026-11-11, on a Kindle Paperwhite 5 Signature Edition with KOReader v2026.07.1, fetching with curl 8.21.0, using the owner's own key:

- **Logging in works as the source says.** **Save and Connect** posted the key to `annas-archive.gd/account/` and got a login session. The diagnostics show `Anna's Archive account: logged_in` and `Logged into Anna's Archive on: annas-archive.gd`.
- **Reading the membership works on the live page.** It read tier 2, shown as "about 25 fast downloads a day, and 36 searches an hour without a browser check".
- **The diagnostics report has neither the key nor the session in it.**
- **Refresh from SLUM works on the device.**

Still not checked live:

- debug-level `crash.log` lines (they should show `?[redacted]` and `aa_account_id2=[redacted]`, never the key)
- the fallback to the quota-free key check when every site asks for a browser check
- a key that isn't accepted

## Left to do

- **Download links get the same protection as the key.** Signed download links are passed to curl in a file, registered as secrets, and never sent as a Referer. See [downloads.md](downloads.md).
- **Interrupted requests leave files behind for a while.** curl's temporary files for a request (`settings/fetchanna_tmp/`: its config, the page, the headers with any `Set-Cookie`) are removed as soon as each request finishes. If KOReader is closed in the middle of one, they stay until the next start, which removes them (`CurlUtil.removeLeftovers`). They're created with the default permissions.
- **A site's address could change between the check and the request (DNS rebinding).** See [mirrors.md](mirrors.md).

## Known limitation: without curl, certificates aren't checked

FetchAnna is meant to run with curl, and offers to install a newer one on Kindles whose own is too old. Where curl can't be used, it falls back to KOReader's own HTTP. That's luasocket handing `https://` to LuaSec, whose default is `verify = "none"`, and neither KOReader nor FetchAnna sets `verify` or a CA file.

So on that path, the key, the session and signed download links are sent over TLS without the server's certificate being checked. Anyone who can intercept the network could read them.

curl checks certificates, and FetchAnna never turns that off. This is left as it is on purpose: devices without a working curl aren't a supported way to run FetchAnna. To change it, pass `verify = "peer"` and a `cafile`/`capath` in `HttpUtil` and `HttpDownload`, and refuse key-bearing requests where no CA store is found.
