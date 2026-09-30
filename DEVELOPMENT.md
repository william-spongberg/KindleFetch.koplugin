# Developing KindleFetch

These instructions are for Linux.

## Getting the source

```bash
git clone --recurse-submodules https://github.com/william-spongberg/KindleFetch.koplugin.git
cd KindleFetch.koplugin
```

The `koreader` submodule is KOReader itself, for editor autocompletion (see `.luarc.json`) and for building KOReader from source. If you cloned without `--recurse-submodules`, run `git submodule update --init`.

## Running KindleFetch

Install KOReader's desktop app from [Flathub](https://flathub.org/apps/rocks.koreader.KOReader):

```bash
flatpak install flathub rocks.koreader.KOReader
```

Then, from the repository root, copy the plugin into KOReader and start it, saving its log to `crash.log`:

```bash
sudo rsync -av --delete kindlefetch.koplugin /var/lib/flatpak/app/rocks.koreader.KOReader/current/active/files/lib/koreader/plugins && flatpak run rocks.koreader.KOReader 2>&1 | tee crash.log
```

KindleFetch is under **Search → Kindle Fetch**. Run the command again after making changes, and after KOReader updates, as updating replaces its plugins folder.

Alternatively, copy it into KOReader's data folder, which doesn't need `sudo` and isn't replaced by updates. Use one folder or the other, as KOReader loads a plugin found in both twice:

```bash
rsync -av --delete kindlefetch.koplugin ~/.var/app/rocks.koreader.KOReader/config/koreader/plugins && flatpak run rocks.koreader.KOReader 2>&1 | tee crash.log
```

For more detail in the log, turn on **Tools → More tools → Developer options → Enable debug logging**, and look for lines containing `KindleFetch:`. On a computer, KOReader skips the plugin and curl update checks, as they're only for devices.

To debug KOReader itself, build it from source instead, following its [build instructions](koreader/doc/Building.md), and run it with the plugin linked into its own data folder (`.dev-home`, which git ignores):

```bash
cd koreader
./kodev fetch-thirdparty && ./kodev build
mkdir -p ../.dev-home/plugins
ln -sfn ../../kindlefetch.koplugin ../.dev-home/plugins/kindlefetch.koplugin
KO_HOME="$(pwd)/../.dev-home" ./kodev run -s=kindle-paperwhite
```

## Running on a device

Copy the `kindlefetch.koplugin` folder into KOReader's `plugins` folder on the device, e.g. `/mnt/us/koreader/plugins` on a Kindle, and restart KOReader. On a Kindle, KOReader's log is in `/mnt/us/koreader/crash.log`.

## Tests

The unit tests in `spec/` run with [busted](https://lunarmodules.github.io/busted/) on LuaJIT, with KOReader's modules stubbed in `spec/helper.lua`, so KOReader doesn't need to be installed. Some tests need `zip`, `unzip` and internet access, as they scrape the live Wikipedia and Library Genesis pages. They run on every push, along with a coverage report.

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

The end-to-end tests in `e2e/` run KindleFetch in the KOReader Flatpak without a window, tapping through its menus and dialogs as a user would: searching Library Genesis, loading covers and more results, downloading Jane Austen's *Pride and Prejudice* (it's in the public domain) and reading it, hiding and cancelling downloads, changing settings, and checking for updates. They run once for each emulated device in `e2e/profiles.lua`: a basic Kindle, a Kindle Paperwhite, a Kobo Aura One and an Android phone, emulating each one's screen size and resolution. They only load the repository's copy of KindleFetch, even if you've also copied it into the Flatpak.

They use the real sites, so they need internet access, take a few minutes, and aren't run by CI:

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

Run the **Release** workflow from the Actions tab, or with `gh workflow run release.yml -f bump=minor` (`major`, `minor` or `patch`). It runs the tests, increments `version.txt`, tags the release, and publishes `kindlefetch.koplugin.zip` with a list of the commits since the last release.
