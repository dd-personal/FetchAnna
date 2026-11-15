# Downloading from Anna's Archive

How FetchAnna gets a book from Anna's Archive, how it handles the download link, and what's still unverified. The code is in:

- `fetchanna/api/annassearch.lua`: `findDownloadLink`, `md5From`, `allowance`
- `fetchanna/api/annasaccount.lua`: `fastDownload`, the member API call
- `fetchanna/api/downloader.lua`: the transfer, inherited from KindleFetch
- `fetchanna/util/curlutil.lua` and `fetchanna/util/httpdownload.lua`: curl, and KOReader's own HTTP where there's no curl

The protocol facts are in [annas-protocol.md](annas-protocol.md).

## Getting the link

Tapping **Download** asks the member API for the file, on a site trusted with the key (see [mirrors.md](mirrors.md)):

`GET /dyn/api/fast_download.json?md5=<md5>&key=<key>[&domain_index=<n>]`

- The key goes in the address, as Anna's Archive requires. Like every request that carries it, it's passed to curl in a config file, never followed through a redirect, and redacted from the log.
- A success uses one of the account's fast downloads for the day. Asking again for a file already in `recently_downloaded_md5s` is free.
- The answer's `account_fast_download_info` is saved. The download prompt shows **Fast downloads: N of M a day left** for 12 hours after the last answer.
- The link must be `https://` to a public host name. It's usually on a download server, not the site that gave it, and it's allowed there. The key, cookies and Referer are never sent to that server.

When there's no link, the download says why:

| Member API answer | Shown |
| --- | --- |
| 401 "Invalid secret key" | The key isn't accepted, with an **Account** button. Saved sessions are dropped. |
| 403 "Not a member" | The account has no membership with fast downloads, with an **Account** button. |
| 429 "No downloads left" | Today's fast downloads are used up. The prompt's count drops to 0. |
| 404 "Record not found" | Anna's Archive doesn't have this file any more. |
| A site took too long | It may have counted the download, but asking for the same book again soon won't count it twice. |
| Anything else | What `AnnasMirrors.describe` says, e.g. a browser check, or no site answering. |

These are the account's answers, so no other site is tried after them. Site failures (no answer, a 5xx, a browser check) move on to the next trusted site, up to 3 sites in 30 seconds. That's the only retrying: the downloader doesn't ask Anna's Archive again straight away when the lookup fails, though it can for a site whose mirrors may have moved. A timeout may already have been counted, so a lookup is never repeated in a loop.

## The signed link is a secret

The link works alone, for anyone holding it, until it expires two hours later. So FetchAnna treats it like the key (source flag `SECRET_LINKS`):

- It's registered with `LogUtil.addSecret` as soon as it arrives, so it's redacted wherever it would be logged. The log only ever names its host.
- curl gets it in a config file (`url = "..."`, `-K`), not on its command line, where any process on the device could read it. The file is removed when curl finishes, and at the next start if KOReader closed mid-download.
- curl doesn't send it as a Referer, and follows redirects only to https (`--proto =https --proto-redir =https`).
- KOReader's own HTTP, used where there's no curl, does the same: no Referer, and it follows at most 5 redirects, only to https.
- It isn't saved anywhere that outlasts the download.

## When the link stops working

Anna's links expire, and each points at one of several download servers (source flags `LINKS_EXPIRE` and `NEW_LINK_WHEN_SERVER_FAILS`). FetchAnna asks for a new link **once per download** when:

- the server answers 401, 403, 404 or 410, as an expired link does
- the server fails (5xx, no answer, connection dropped)
- what arrived isn't the book (a web page, the wrong file type, or the wrong MD5)

The new link is for the next download server (`domain_index` 1, then 2, and so on), because changing the host in a signed link would invalidate it. If Anna's Archive has no server with that number, it's asked again without one. Asking for the same book again is free, so this doesn't use another download. If the second link fails too, the download fails with the server's answer.

## Checking what arrived

The checks come from the upstream downloader:

- The book downloads to `<name>.part` and is renamed only after every check passes. Half a book never looks like a whole one, and a book being downloaded over is kept until then.
- A web page, or JSON, in place of the book is rejected, even with status 200. So is a file that doesn't start the way its file type does.
- A file smaller than the `Content-Length` the server sent is rejected.
- **The MD5 is checked.** Anna's Archive files are addressed by MD5, so the book's MD5 is passed as the expected one. This confirms the file is the one listed, not that the publisher made it.
- **Free space is checked** once the size is known: when the rest of the book plus 1 MB won't fit, the download stops straight away and says how much more room it needs.

## Carrying on after Wi-Fi drops

When Wi-Fi goes off or the device sleeps, the transfer pauses and keeps what arrived. When it's back, the download carries on with the same link, but only when it can tell the file hasn't changed:

- The server must have sent a strong `ETag` or a `Last-Modified`, and not `Accept-Ranges: none`. FetchAnna sends that back as `If-Range`, so a changed file comes back whole rather than appended to the old part. curl then exits with code 33, and the download starts again from the beginning.
- With neither, what arrived is deleted and the download starts again from the beginning.
- The MD5 check still runs at the end.

## A book found in a browser

Where Anna's Archive asks for its browser check, **Search in a Browser** shows its search to open on a phone. To download a book found there, type its MD5 or its link (`https://<any site>/md5/<md5>`) into the search box. FetchAnna then:

- takes only the MD5 from what was typed, and never opens the link, which could point anywhere
- asks which file type it is. The types searched for come first, then the others KOReader opens. Pick the one Anna's Archive lists.
- downloads it through the member API like any other book, named after its MD5

If the wrong type is picked, the file-type check rejects what arrived. Asking again with the right type is free, because the book is now among those downloaded recently.

## Verified live, and not yet

**Verified on 2026-11-14**, on a Kindle Paperwhite 5 SE: a book was downloaded this way and opened in KOReader. So these work as described:

- the member API's `download_url`, which FetchAnna took as an HTTPS link to a public host
- the download server sending the book, not a web page
- the file-type check, and the MD5 check against the book's MD5

The specs still use a success answer made up from the documented fields (marked SYNTHESIZED), as no real one has been captured.

**Still unconfirmed:**

- what the download servers send: `Content-Type`, `Content-Length`, whether they redirect, whether they take `Range` and send an `ETag`
- what an expired link answers. FetchAnna assumes a 4xx, as the servers give a bare request (403 "Link expired or invalid").
- that `domain_index` 1, 2, … are other servers

To check them, download a public-domain book on the device with debug logging on, then look in `crash.log` for the `the file is … bytes`, `downloaded …` and `asking for another download link` lines, and in Diagnostics for the fast downloads left.

## Checking that it's a fast download

Every link FetchAnna downloads from comes from the member API's `fast_download.json`. There's no other way for it to get one: Anna's Archive is the only site in `Sources`, and its `findDownloadLink` only asks `AnnasAccount:fastDownload`. To see this on the device:

1. **Diagnostics → Last download link** says when the member API last gave a link, which Anna's Archive site gave it, and which download server sent the book, e.g. `2026-11-14 14:02, a fast download from the member API on annas-archive.gd, served by <server>`. It names their hosts, never the link.
2. **The count goes down.** Note the download prompt's **Fast downloads: N of M a day left**, download a book you haven't downloaded in the last day, then tap **Download** on another new one: the count should be one less. Tapping **Download** on the first book again shouldn't change it, as asking again for a recent download is free. Comparing two new books works whether or not the member API's count includes the book being asked for, which is still unconfirmed.
3. **Anna's Archive agrees.** Where your account page on Anna's Archive shows the fast downloads you've used, the books should be among them.

`crash.log` also has `Anna's Archive gave a download link to <server> (N fast downloads left today)` for each link, without debug logging.
