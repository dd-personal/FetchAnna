# FetchAnna

A [KOReader](https://koreader.rocks) plugin that searches [Anna's Archive](https://open-slum.org/annas.html) and downloads books straight to your e-reader, using your own member secret key. Once it's installed, it needs no computer, Python or browser.

## What you need

- KOReader on an e-reader with Wi-Fi (see [Compatibility](#compatibility)).
- An Anna's Archive **membership with fast downloads**, and its **secret key**, from your account page.
- To search from KOReader, a membership that skips Anna's Archive's browser check, which FetchAnna never tries to get past. Without one, [search in a browser](#searching).

## Installing

1. Download `fetchanna.koplugin.zip` from the [releases page](https://github.com/dd-personal/FetchAnna/releases).
2. Unzip it into `koreader/plugins/` and keep the folder's name. On a Kindle, that folder is on its USB drive.
3. Restart KOReader. FetchAnna is in the **Search** menu (the magnifying glass).

It can sit alongside [KindleFetch](https://github.com/william-spongberg/KindleFetch.koplugin): the two keep their settings and files apart.

## Your key

**FetchAnna → Account → Enter Key**, then **Save and Connect**.

- **Where it's kept.** Only until KOReader restarts, by default. **Remember on This Device** saves it as `fetchanna_key.txt` in KOReader's settings folder, unencrypted. Only KOReader can read it where the storage has file owners. On the FAT storage of Kindles and Kobos, anyone with the device can. **Forget Key and Log Out** deletes it and the login sessions.
- **Where it goes.** Only to [approved Anna's Archive sites](#annas-archives-sites), over HTTPS, without following redirects. It's never in logs, Diagnostics, or curl's command line.

## Searching

**Search → FetchAnna → Search**, type a title or author, and tap **Search**.

- **Settings** chooses the languages and file types. Only types KOReader can open are offered, and only EPUB is chosen to begin with.
- **More by this author** is in a book's menu and its file browser dialog. **Search FetchAnna** is in the dialog for highlighted text.
- The menu at the top of the results filters them by language, file type, year, size, or whether you have them already.

If Anna's Archive asks for its browser check, FetchAnna offers **Search in a Browser**: the search's address, as a QR code where KOReader can show one. To download a book found there, type its MD5 or link (`…/md5/…`) into the search box. Only the MD5 is used.

## Downloading

Tap a book, choose the folder, and tap **Download**.

- Every download is one of your fast downloads. The prompt says how many are left today, and **Diagnostics → Last download link** shows [where the last one came from](docs/downloads.md#checking-that-its-a-fast-download).
- Downloads carry on in the background. **Hide** puts one away, and **Search → FetchAnna → Downloads** brings it back.
- If Wi-Fi drops, the download waits, then carries on or starts again. If its link or server fails, FetchAnna asks for one more link, from another server.
- What arrives is [checked](docs/downloads.md) before it's saved.

## Anna's Archive's sites

FetchAnna finds the sites on [SLUM](https://open-slum.org/annas.html), and keeps the last list for when SLUM is down. **Settings → Anna's Archive Sites** shows them ([details](docs/mirrors.md)).

- It comes with three sites approved to be sent your key. Any other is only sent it once you **Approve** it, after FetchAnna checks it answers as Anna's Archive does.
- **Revoke** stops sending your key to a site. **Reset to Built-in Sites** goes back to the three.
- A site that SLUM stops listing, or that stops answering as Anna's Archive does, is suspended. When one fails, FetchAnna tries the next.

## When something goes wrong

| What it says | What to do |
| --- | --- |
| Anna's Archive asked for a browser check | Use **Search in a Browser**. |
| Your account has no membership with fast downloads | Downloading needs one. **Account** shows what you have. |
| Your account has used all of its fast downloads for today | Try again tomorrow. |
| Anna's Archive took too long to give a download link | Try again. The same book won't count twice. |
| None of Anna's Archive's sites can be found on this network | Tap **Use encrypted DNS**, or try another network. |
| This Kindle's curl is too old | Tap **Update curl**. |
| Anything else | **Search → FetchAnna → Diagnostics** can **Test connection** and **Save** a report without your key or login. |

**Use encrypted DNS** sends DNS lookups to Cloudflare (1.1.1.1). Covers load from the hosts Anna's Archive lists them on, and **Settings → Show Book Covers** turns them off.

## Compatibility

- Tested on a **Kindle Paperwhite 5 SE** with KOReader **v2026.07.1** and curl **8.21.0**. Other KOReader devices should work, but haven't been tested.
- FetchAnna needs curl. Without it, it falls back to KOReader's own HTTP, which doesn't check certificates, so [your key is less safe on that connection](docs/account.md#known-limitation-without-curl-certificates-arent-checked).
- Kindles come with an old curl. FetchAnna offers to install a newer one.

## Updating and uninstalling

- **To update**, tap **Search → FetchAnna → Check for updates**. It updates the plugin, and curl on a Kindle, and keeps your settings, key and sites.
- **To go back** to the version before, **Settings → Go back to v…**, where there is one.
- **To uninstall**, delete `koreader/plugins/fetchanna.koplugin/`. What it saved is in `koreader/settings/`: `fetchanna_settings.lua`, `fetchanna_key.txt`, `fetchanna_mirrors.lua`, `fetchanna_searchcache.lua`, `fetchanna_covercache.lua`, and the `fetchanna_covers` and `fetchanna_tmp` folders.

## Based on KindleFetch

FetchAnna is a fork of [KindleFetch](https://github.com/william-spongberg/KindleFetch.koplugin) by william-spongberg, from its v0.8 (`898352d7`), built on its downloader, caches, results menu, diagnostics and updater. Both are under the MIT licence: see [LICENSE](LICENSE), which keeps KindleFetch's copyright notice.

## More

- [docs/annas-protocol.md](docs/annas-protocol.md)
- [docs/account.md](docs/account.md), [docs/mirrors.md](docs/mirrors.md), [docs/downloads.md](docs/downloads.md)
- [docs/phase7-report.md](docs/phase7-report.md), the test report
- [DEVELOPMENT.md](DEVELOPMENT.md)

If FetchAnna is useful to you, you can [buy me a coffee](https://buymeacoffee.com/ddpersonal).
