# Developing FetchAnna

These instructions are for Linux.
On Windows, the same commands work in WSL. Clone with `git -c core.autocrlf=false`, or set `core.autocrlf=false` and `core.eol=lf` in the clone, as StyLua checks for Unix line endings. Without `sudo`, `zip` and `unzip` (which LuaRocks and some specs need) can be unpacked into `~/.local` with `apt-get download zip unzip` and `dpkg-deb -x`.

## Getting the source

```bash
git clone --recurse-submodules <this repository's URL> FetchAnna
cd FetchAnna
git remote add --no-tags upstream https://github.com/william-spongberg/KindleFetch.koplugin.git
```

FetchAnna is a fork of [KindleFetch](https://github.com/william-spongberg/KindleFetch.koplugin), forked at `898352d7fb8be8fe1b93172ba954ce93d26e727e` (its v0.8). The `upstream` remote is for bringing in its fixes (`git fetch upstream`, then merge or cherry-pick). It leaves out KindleFetch's tags, as its `v0.1` to `v0.8` would clash with FetchAnna's own. Comments refer to KindleFetch's issues as `KindleFetch #55`.

The `koreader` submodule is KOReader itself, for editor autocompletion (see `.luarc.json`) and for building KOReader from source. If you cloned without `--recurse-submodules`, run `git submodule update --init`.

## Running FetchAnna

Install KOReader's desktop app from [Flathub](https://flathub.org/apps/rocks.koreader.KOReader):

```bash
flatpak install flathub rocks.koreader.KOReader
```

Then, from the repository root, copy the plugin into KOReader and start it, saving its log to `crash.log`:

```bash
sudo rsync -av --delete fetchanna.koplugin /var/lib/flatpak/app/rocks.koreader.KOReader/current/active/files/lib/koreader/plugins && flatpak run rocks.koreader.KOReader 2>&1 | tee crash.log
```

FetchAnna is under **Search → FetchAnna**. Run the command again after making changes, and after KOReader updates, as updating replaces its plugins folder.

Alternatively, copy it into KOReader's data folder, which doesn't need `sudo` and isn't replaced by updates. Use one folder or the other, as KOReader loads a plugin found in both twice:

```bash
rsync -av --delete fetchanna.koplugin ~/.var/app/rocks.koreader.KOReader/config/koreader/plugins && flatpak run rocks.koreader.KOReader 2>&1 | tee crash.log
```

For more detail in the log, turn on **Tools → More tools → Developer options → Enable debug logging**, and look for lines containing `FetchAnna:`. On a computer, KOReader skips the plugin and curl update checks, as they're only for devices.

To debug KOReader itself, build it from source instead, following its [build instructions](koreader/doc/Building.md), and run it with the plugin linked into its own data folder (`.dev-home`, which git ignores):

```bash
cd koreader
./kodev fetch-thirdparty && ./kodev build
mkdir -p ../.dev-home/plugins
ln -sfn ../../fetchanna.koplugin ../.dev-home/plugins/fetchanna.koplugin
KO_HOME="$(pwd)/../.dev-home" ./kodev run -s=kindle-paperwhite
```

## Running on a device

Copy the `fetchanna.koplugin` folder into KOReader's `plugins` folder on the device, e.g. `/mnt/us/koreader/plugins` on a Kindle, and restart KOReader. On a Kindle, KOReader's log is in `/mnt/us/koreader/crash.log`.

To build the zip a release has, from the repository root:

```sh
cp LICENSE fetchanna.koplugin/ && zip -qr fetchanna.koplugin.zip fetchanna.koplugin && rm fetchanna.koplugin/LICENSE
```

## Layout, and installing alongside KindleFetch

KOReader loads every plugin's Lua modules into the one `package.loaded`, and once plugins have loaded, finds modules along every plugin's folder. A module named like one of another plugin's is that plugin's, if it loaded first, so KindleFetch's `util.httputil` would be used in place of ours, or ours in place of its. So everything but the two files KOReader looks for at a plugin's root is in `fetchanna.koplugin/fetchanna/`, and is required by its name there:

```
fetchanna.koplugin/
  main.lua, _meta.lua, version.txt
  fetchanna/
    plugin.lua                      require("fetchanna.plugin") (KindleFetch's kindlefetch.lua)
    safemode.lua, api/, cache/, settings/, ui/, updater/, util/
```

Its settings (`settings/fetchanna_settings.lua`), caches (`settings/fetchanna_*cache.lua`, `settings/fetchanna_covers/`), temporary files (`settings/fetchanna_tmp/`, `cache/fetchanna/`), events (`FetchAnna…`) and Dispatcher actions (`fetchanna_…`) are its own too. It doesn't read KindleFetch's settings, such as its Z-Library login. `spec/coexistence_spec.lua` checks all of this.

What is shared is the Kindle's own curl: both plugins offer to replace `/usr/bin/curl` with the same static build (see `updater/curlupdater.lua`), keeping the original as `/usr/bin/curl.system.bak` only once.

## Tests

The unit tests in `spec/` run with [busted](https://lunarmodules.github.io/busted/) on LuaJIT, with KOReader's modules stubbed in `spec/helper.lua`, so KOReader doesn't need to be installed. They need no account, key or internet access: Anna's Archive's pages and answers come from the sanitized captures in `spec/data/annas/` (see its `PROVENANCE.md`), and no spec reaches the network unless it says so. Some need `zip`, `unzip`, `sha256sum` and `md5sum`.

They run on every push, along with a coverage report, other than those against the live sites (tagged `#live`), which would fail a push whenever a site is down. Those run every day instead, in the Canary workflow, and can be run with `busted --tags=live`:

- SLUM still lists Anna's Archive's sites in a way FetchAnna can read
- at least one of the sites FetchAnna is released with answers its member API as Anna's Archive does, asked for nothing, which sends no key and uses up nothing
- the static curl build Kindles are given still has the SHA-256 FetchAnna expects

They're never given a key. Searching and downloading with a member's key isn't tested automatically: it would need a key in CI, and each download uses up one of the account's fast downloads. It's tested by hand on a device instead (see [docs/phase7-report.md](docs/phase7-report.md)).

If you don't have LuaJIT and luarocks, [hererocks](https://github.com/luarocks/hererocks) installs both into your home folder:

```bash
curl -fsSL -o hererocks.py https://raw.githubusercontent.com/luarocks/hererocks/master/hererocks.py
python3 hererocks.py ~/.local/share/hererocks/luajit -j 2.1 -r latest
~/.local/share/hererocks/luajit/bin/luarocks install busted luacov
```

Then, from the repository root:

```bash
~/.local/share/hererocks/luajit/bin/busted                              # run the tests
~/.local/share/hererocks/luajit/bin/busted --coverage && ~/.local/share/hererocks/luajit/bin/luacov   # coverage report in luacov.report.out
```

### End-to-end tests

The end-to-end tests in `e2e/` run FetchAnna in the KOReader Flatpak without a window, tapping through its menus and dialogs as a user would: opening it from the menu and a gesture, changing settings, and checking for updates. They run once for each emulated device in `e2e/profiles.lua`: a basic Kindle, a Kindle Paperwhite, a Kobo Aura One and an Android phone, emulating each one's screen size and resolution. They only load the repository's copy of FetchAnna, even if you've also copied it into the Flatpak.

KindleFetch's end-to-end tests also searched and downloaded from its sites. FetchAnna's don't search Anna's Archive, for the same reasons as above. They need internet access for the update check, and aren't run by CI:

```bash
e2e/run.sh                          # every device
e2e/run.sh -p kindle-paperwhite     # one device
e2e/run.sh -p kindle Downloading    # only tests whose name contains "Downloading"
```

To use KOReader built from source instead of the Flatpak, pass its folder with `-k`, e.g. `-k koreader/koreader-emulator-x86_64-linux-gnu-debug/koreader`.

Screenshots of each step, the downloaded book and KOReader's log end up in `e2e/.tmp/<device>/`, including a screenshot whenever a test fails.

## Formatting and linting

The code is formatted with [StyLua](https://github.com/JohnnyMorganz/StyLua) (see `stylua.toml`) and linted with [luacheck](https://github.com/lunarmodules/luacheck) (see `.luacheckrc`, based on KOReader's). CI checks both on every push. To install them:

```bash
gh release download --repo JohnnyMorganz/StyLua v2.5.2 --pattern 'stylua-linux-x86_64.zip'
unzip stylua-linux-x86_64.zip -d ~/.local/bin
~/.local/share/hererocks/luajit/bin/luarocks install luacheck
```

Then, from the repository root:

```bash
stylua .                                        # format everything
~/.local/share/hererocks/luajit/bin/luacheck .  # lint everything
```

## Releasing

Run the **Release** workflow from the Actions tab, or with `gh workflow run release.yml -f bump=minor` (`major`, `minor` or `patch`). It runs the tests, increments `version.txt`, tags the release, and publishes `fetchanna.koplugin.zip` with a list of the commits since the last release. The `v0.0` tag marks KindleFetch v0.8, where FetchAnna starts, so the first release lists only FetchAnna's commits.

It refuses to release until `fetchanna.koplugin/fetchanna/updater/releasesource.lua` names the repository it's running in, as `owner/name`. That is where the released plugin looks for its own updates, so a build can never update itself from another project's releases, KindleFetch's included. A fork should name its own repository there, or `nil`, which turns update checks off. The zip has the licence in it, and is checked to be the one `fetchanna.koplugin/` folder.
