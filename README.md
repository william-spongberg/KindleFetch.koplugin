# KindleFetch

<a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/stars/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github star tracker"></a> <a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/downloads/william-spongberg/KindleFetch.koplugin/total.svg" height="25px" alt="Github downloads tracker"></a> <a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/v/release/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github release version tracker"></a>

Download books from Library Genesis directly to your Kindle (or any e-reader running KOReader), entirely within the KOReader app.

## Overview

KindleFetch integrates Library Genesis into KOReader, allowing you to search for and download books without leaving your e-reader. The plugin handles the entire workflow - from search queries to file downloads - with an intuitive interface and robust error handling.

## Features

- **Book Search + Downloads**: Search Library Genesis from your device with simple text input and download with a tap; searches run in the background, and can be cancelled with a tap
- **Caching**: Minimise network requests and improve performance
  - Search results (2 week expiry by default, 100 entries max)
  - Mirror URLs (1 week expiry by default)
  - Book covers (500 entries max, the oldest removed to make room)
- **Preferences**: Filter results by preferred languages, file types, and book types
- **Book Cover Previews**: Display cover images in search results and the download prompt, with placeholders until each one arrives; tap a cover in the download prompt to see it full size
- **Download Progress**: Visual download progress bar with real-time file size information, saying what it's waiting for until the book starts to arrive, and when the download has stalled
- **Background Downloads**: Downloads run in the background using curl, with non-blocking UI updates; hide a download, and see its progress again from Kindle Fetch's Downloads entry or by choosing its book again; downloads are cancelled when KOReader closes
- **Read Now**: Offers to open a book as soon as it has downloaded
- **Wi-Fi and Gestures**: Turns on Wi-Fi to search if it's off, and search can be opened from a gesture (Kindle Fetch, in KOReader's gesture manager)
- **Automatic Curl Updates**: Ensures curl 8.21.0, the latest static build, is available on Kindles, and says how to update it when a download fails because a Kindle's own curl is too old to connect to Library Genesis
- **Automatic Plugin Updates**: Checks for new plugin releases in the background, at most once a day, and prompts to update with release notes, then offers to restart KOReader to use the new version (can be turned off in settings, or checked for manually from the menu); an update you turn down isn't offered again until you check manually
- **Automatic Retry Logic**: Fallback to other available urls if connection fails
- **Safe File Handling**: Automatic filename sanitisation and directory management, asking before downloading over a book that's already there

## Installation

1. Ensure you have the latest stable release of KOReader installed (the nightly release has been known to cause issues with this plugin)

2. Download the latest release from the [Releases](https://github.com/william-spongberg/KindleFetch.koplugin/releases) tab

3. Unzip and move its contents into the `plugins` folder of KOReader

## Usage

### Downloading books

#### Search → Kindle Fetch → Search Library Genesis

<img width="350" alt="Kindle Fetch in KOReader's search menu" src="docs/screenshots/01-search-menu.png" /> <img width="350" alt="Kindle Fetch's menu" src="docs/screenshots/02-kindlefetch-menu.png" />

1. Enter a book title, author, or keyword in the search box. KOReader carries on while Library Genesis answers; tap the message saying it's searching to cancel.

<img width="350" alt="Search box" src="docs/screenshots/03-search-dialog.png" /> <img width="350" alt="Message saying it's searching, which a tap cancels" src="docs/screenshots/04-searching.png" />

2. Browse the results and tap a book to download. The top of the list says what was searched for and how many books have been found, and placeholders show while the covers download.

<img width="350" alt="Search results while covers download" src="docs/screenshots/05-search-results-loading-covers.png" /> <img width="350" alt="Search results with covers" src="docs/screenshots/06-search-results.png" />

3. In the download prompt, optionally tap the book cover to see it full size, or tap the folder it will be saved in (above the name it will be saved as) to choose another, then tap Download. If a book of that name is already there, choose whether to overwrite it or read the one you have.

<img width="350" alt="Download prompt" src="docs/screenshots/07-download-prompt.png" /> <img width="350" alt="Fullscreen cover" src="docs/screenshots/08-download-cover.png" /> <img width="350" alt="Being asked before downloading over a book that's already there" src="docs/screenshots/09-download-overwrite.png" />

4. Monitor the download's progress; tap Hide to keep it downloading in the background (to see its progress again, choose **Search → Kindle Fetch → Downloads**, or the book again) or Cancel to stop it.

<img width="350" alt="Download progress" src="docs/screenshots/10-download-progress.png" />

5. Once the book has downloaded, tap Read now to open it.

<img width="350" alt="Read now prompt" src="docs/screenshots/11-download-finished.png" /> <img width="350" alt="Reading the downloaded book" src="docs/screenshots/12-reading.png" />

Downloaded books are saved to your configured download location.

### Settings

#### Search → Kindle Fetch → Settings

- **Show Book Covers**: Enable or disable cover image display in search results (default: enabled)

<img width="350" alt="Settings" src="docs/screenshots/13-settings.png" /> <img width="350" alt="Search results without covers" src="docs/screenshots/14-search-results-without-covers.png" />

- **Download Folder**: Set the directory where books are saved (defaults to home directory or `/mnt/us/documents`); the settings show the end of a long one, which says the most about it

<img width="350" alt="Choosing the download folder" src="docs/screenshots/15-settings-download-folder.png" />

- **Preferred Languages**: Choose which languages to prioritise in search results (default: English)

<img width="350" alt="Preferred languages" src="docs/screenshots/16-settings-languages.png" />

- **Preferred File Types**: Select desired formats across five categories, from those KOReader can open (default: all of them, which the settings show as All):
  - Ebooks: EPUB, MOBI, AZW, FB2, PRC
  - Comics: CBR, CBZ
  - Documents: PDF, TXT, RTF, DOC, DOCX, ODT, DJVU
  - Images: JPG, TIF, PDB
  - Web: CHM, HTM, HTML, HTMLZ

<img width="350" alt="Preferred file types" src="docs/screenshots/17-settings-file-types.png" />

- **Preferred Book Types**: Filter by fiction, non-fiction, comics, magazines, scientific articles, or standards (default: all of them, which the settings show as All)

<img width="350" alt="Preferred book types" src="docs/screenshots/18-settings-book-types.png" />

When a search finds books, but none in the languages and file types chosen, Kindle Fetch says how many Library Genesis listed, and offers to open the settings or to keep searching through the rest.

<img width="350" alt="Being told that none of the results are in the languages and file types chosen" src="docs/screenshots/19-search-none-chosen.png" />

- **Check for Updates Automatically**: Check for plugin and curl updates at most once a day while connected (default: enabled)

- **Keep Searches For / Keep Mirrors For**: How long search results (default: 14 days) and Library Genesis mirror URLs (default: 7 days) are cached

<img width="350" alt="How long searches are kept" src="docs/screenshots/20-settings-cache.png" />

- **Clear Cache**: Forget the searches, mirrors and book covers that have been saved, e.g. if results look out of date

## How It Works

### Architecture

``` architecture
kindlefetch.koplugin/
├── main.lua                   # Main plugin entry point; manages search UI, results display, and download initiation
├── _meta.lua                  # Plugin metadata and KOReader integration
├── settings/
│   ├── settings.lua           # Persistent storage and management of user preferences
│   └── settingspage.lua       # UI for configuring user preferences, and clearing the caches
├── api/
│   ├── lgliapi.lua            # Handles Library Genesis downloads with progress tracking, proxy fallback, and error recovery
│   ├── lglisearch.lua         # Searches Library Genesis; parses HTML, filters by preferences and caches results
│   └── urlapi.lua             # Scrapes Wikipedia to discover current Library Genesis mirror URLs
├── ui/
│   ├── bookmenu.lua           # Custom menu for displaying search results with cover images and pagination
│   ├── coverplaceholder.lua   # Placeholder shown in place of a cover while it downloads
│   ├── downloadprompt.lua     # Dialog showing a book's details and cover (full size when tapped), where to save it, and a Download button
│   └── downloadprogress.lua   # Renders a centered progress widget with cancel and hide buttons
├── cache/
│   ├── cache.lua              # Generic caching system with expiry, size limits, and timestamp-based cleanup
│   ├── searchcache.lua        # Caches search results by query, page, and filter preferences (2 weeks by default, 100-entry limit)
│   ├── urlcache.lua           # Caches mirror URLs to minimise Wikipedia scraping (1 week by default)
│   └── covercache.lua         # Downloads and caches book covers and full-size covers by MD5 hash (500-entry limit, persists across sessions, removing the oldest covers' files once full)
├── updater/
│   ├── curlupdater.lua        # Checks curl version and automatically installs static curl (8.21.0) if needed
│   └── pluginupdater.lua      # Checks for plugin updates from GitHub releases and prompts user with release notes
└── util/
    ├── curlutil.lua           # Manages curl downloads, background processes and parallel downloads
    ├── httputil.lua           # Fetches web pages with curl (compressed, in the background) or KOReader's own HTTP, with timeouts, proxy support, and automatic fallback
    ├── fileutil.lua           # File operations (size, creation, deletion, validation) and directory checks
    ├── stringutil.lua         # String utilities (trimming, validation, emoji removal, HTML entity conversion)
    ├── logutil.lua            # Logger wrapper
    ├── notifyutil.lua         # Notifications, and error messages that stay until dismissed
    ├── pathutil.lua           # Plugin install location and temporary download directory
    └── versionutil.lua        # Version parsing and comparison utilities
```

### Workflow

0. **Initialization**
   - Unless turned off in settings, updates are checked for at most once a day while connected, or manually via Kindle Fetch → Check for updates
   - The latest release is looked up in the background, so KOReader can be used meanwhile
   - A curl or plugin update that is turned down is only offered again by checking manually
   - On Kindles, curl version is checked; user is prompted to update if version is below 8.21.0
   - Plugin version is checked against GitHub releases; user is prompted to update if new version available
   - Settings are loaded from persistent storage

1. **Settings & Filtering** (`SettingsPage`)
   - User can customize preferred languages (100+ supported)
   - User can select preferred file types: ebooks (EPUB, MOBI, AZW, etc.), comics (CBR, CBZ), documents (PDF, DOCX, etc.), images, or web formats
   - User can filter by book type: fiction, non-fiction, comics, magazines, scientific articles, or standards
   - Download directory can be changed from a file browser
   - Book cover loading can be toggled on/off (for efficiency)
   - All settings are persisted and applied to future searches

2. **Search Phase** (`LlgiSearch`)
   - User enters a search query via InputDialog
   - Plugin resolves the current Library Genesis mirror URL (cached for a week by default)
   - Plugin scrapes the Library Genesis HTML search results page for the preferred book types
   - Pages are fetched with curl where there is one (on a Kindle, once it has been updated): compressed, which Library Genesis sends several times sooner, and in the background, so KOReader isn't held up and a tap on the message cancels the search. Otherwise they're fetched with KOReader's own HTTP, which holds KOReader up until they arrive
   - HTML table is parsed to extract book metadata (title, authors, year, language, file type, MD5 hash, cover image URL), keeping books in the preferred languages and file types
   - As Library Genesis can't filter by language or file type, further pages of its results are read until at least 10 books are found (up to 5 pages at a time), and "Load more" carries on from there, adding the books to the list where it was tapped. Calling the search off while it reads further pages shows the books it has found so far
   - Results are cached (2 weeks by default, 100 entries max) to minimise requests
   - Search results are displayed in a menu
   - When Library Genesis lists results but none are in the preferred languages and file types, the plugin says how many it listed, and offers the settings or to keep searching through the rest

3. **Cover Loading**
   - Covers for the page of results showing are downloaded in the background, in parallel using curl's `--parallel` flag, with placeholders shown until they arrive. A connection is opened for each cover at once (with curl 7.68 or later), rather than curl waiting to see whether they can share one, which Library Genesis doesn't allow, so a page of covers arrives in about a third of the time
   - Turning the page loads the covers for that page, and the next page's are downloaded ahead so they're there when it's turned to
   - Each cover is shown as soon as it has downloaded (with curl 7.63 or later), rather than once the slowest on its page has, at most once a second as each time the screen is refreshed; one that stalls is given up on after 10 seconds
   - Downloaded covers are cached locally with persistent storage
   - If a cover can't be downloaded, its book is shown without one
   - Tapping a cover in the download prompt downloads the full-size cover, showing the thumbnail until it arrives

4. **Download Phase** (`LlgiAPI`)
   - User selects a book and optionally changes the save location via DownloadPrompt
   - If a file of that name is already there, the plugin asks whether to overwrite it or read the existing book
   - The book's cover is fetched if it isn't cached already
   - Plugin resolves the current Library Genesis mirror URL (cached for a week by default)
   - Curl fetches the ads page using the book's MD5 hash to obtain a download URL, in the background (where pages are fetched with curl), so KOReader carries on while the mirrors answer, and Cancel calls it off
   - File size is read from the headers of the download itself for progress calculation, without a separate request
   - A curl process is spawned to download the file in the background, to a `.part` file next to where the book will be saved, so half a book never shows up in your library
   - A download that receives nothing for 30 seconds is tried again, carrying on from where it stopped rather than starting the book again, and given up on after two more tries
   - Progress widget updates every 0.5 seconds with percentage and file size information. Until the book starts to arrive, it says what it's waiting for: a download link, then Library Genesis, which can take several seconds to start sending the book. Once nothing has arrived for 10 seconds, it says the download has stalled
   - On completion, the file is moved into the configured download directory, and the plugin offers to open it

5. **Error Handling & Resilience**
   - Wi-Fi is turned on before searching if it's off
   - Failed searches, cover downloads and book downloads automatically retry through a configured proxy (if `PROXY_URL` env var is set) and empty or corrupted downloads are detected and deleted
   - Failed mirrors are removed from cache; if all cached URLs fail they are re-scraped from Wikipedia
   - The mirror that last answered a search or gave a download link is tried first from then on, rather than asking the ones before it, which may be too busy, every time
   - If Wikipedia answers without listing any mirrors (e.g. once its page has been rearranged), the mirrors known when the plugin was released are used
   - Only site names are accepted as mirrors, and a book cover whose address isn't a plain web address is left out, as Wikipedia can be edited by anyone and a mirror can send anything
   - User can cancel downloads at any time via the progress widget, and downloads are cancelled when KOReader closes
   - Curl exit codes are mapped to human-readable error messages, and what went wrong is shown in a message that stays until it's dismissed

### Environment Variables

The plugin supports an optional `PROXY_URL` environment variable for proxy-based downloads:

```bash
export PROXY_URL="http://proxy.example.com:8080"
```

If a search, book cover or book download fails, the plugin automatically retries it through the proxy.

## Attribution

This plugin is forked from [justrals/KindleFetch](https://github.com/justrals/KindleFetch). It uses a similar underlying logic, but focuses on easy UX and simplicity. The choice was made to only support downloads from Library Genesis due to limitations and complexity surrounding Z-Library downloads, and as Anna's Archive now blocks automated access.

## License

MIT

## Disclaimer

This plugin facilitates downloading books from Library Genesis. Ensure you have the legal right to download any content and respect copyright laws in your jurisdiction. The authors assume no liability for misuse.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request with improvements, bug fixes, or new features.

See [DEVELOPMENT.md](DEVELOPMENT.md) for running KindleFetch on your computer (Linux), running the tests, and releasing.
