# KindleFetch

<a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/stars/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github star tracker"></a>

Download books from Anna's Archive directly to your Kindle, entirely within the KOReader app.

## Overview

KindleFetch integrates Anna's Archive and Library Genesis into KOReader, allowing you to search for and download books without leaving your e-reader. The plugin handles the entire workflow - from search queries to file downloads - with an intuitive interface and robust error handling.

## Features

- **Book Search + Downloads**: Query Anna's Archive from your device with simple text input and download with a tap from Library Genesis
- **Caching**: Caches search results (72 hours), mirror URLs (7 days), and book covers (for length of search) to minimise network requests and improve performance
- **Preferences**: Filter results by preferred languages, file types, and book types
- **Book Cover Previews**: Display cover images in download previews
- **Download Progress**: Visual download progress bar with real-time file size information
- **Background Downloads**: Downloads run in the background using curl, with non-blocking UI updates
- **Automatic Curl Updates**: Ensures a compatible curl version (8.17.0+) is available
- **Automatic Retry Logic**: Fallback to other available urls if connection fails
- **Safe File Handling**: Automatic filename sanitisation and directory management

## Installation

1. Download the latest release from the [Releases](https://github.com/william-spongberg/KindleFetch.koplugin/releases) tab

2. Unzip and move its contents into the `plugins` folder of KOReader

## Usage

### Downloading books

#### Search → Kindle Fetch → Search Anna's Archive

1. Enter a book title, author, or keyword in the search box.

2. Browse the results and tap a book to download. Optionally, adjust the download location first.

3. Confirm the download and monitor progress; tap Hide to run in background or Cancel to stop.

Downloaded books are saved to your configured download directory.

### Settings

#### Search → Kindle Fetch → Settings

- **Download Folder**: Set the directory where books are saved (defaults to home directory or `/mnt/us/documents`)
- **Preferred Languages**: Choose which languages to prioritise in search results
- **Preferred File Types**: Select desired formats across five categories:
  - Ebooks: EPUB, MOBI, AZW, AZW3, KFX, FB2, LIT, PRC, LRF, SNB, UPDB
  - Comics: CBR, CBZ
  - Documents: PDF, TXT, RTF, DOC, DOCX, ODT, DJVU
  - Images: JPG, TIF, PDB
  - Web: CHM, HTM, HTML, HTMLZ, MHT
- **Preferred Book Types**: Filter by fiction, non-fiction, unknown, comics, or standards documents

## How It Works

### Architecture

``` architecture
kindlefetch.koplugin/
├── main.lua                   # Main plugin entry point; manages search UI, results display, and download initiation
├── _meta.lua                  # Plugin metadata and KOReader integration
├── settings/
│   ├── settings.lua           # Persistent storage and management of user preferences
│   └── settingspage.lua       # UI for configuring user preferences
├── api/
│   ├── annasapi.lua           # Searches Anna's Archive; parses HTML and caches results
│   ├── lgliapi.lua            # Handles Library Genesis downloads with progress tracking, proxy fallback, and error recovery
│   └── urlapi.lua             # Scrapes Wikipedia to discover current mirror URLs for Anna's Archive and Library Genesis
├── ui/
│   ├── downloadprompt.lua     # Modal dialog for confirming download details, choosing save location, and displaying book metadata
│   └── downloadprogress.lua   # Renders a centered progress widget with cancel and hide buttons
├── cache/
│   ├── cache.lua              # Generic caching system with expiry and size limits
│   ├── searchcache.lua        # Caches search results keyed by query, page, and filter preferences (72-hour expiry, 100-entry limit)
│   ├── urlcache.lua           # Caches mirror URLs to minimise Wikipedia scraping (one week expiry)
│   └── covercache.lua         # Caches book cover images by MD5 hash (deleted on plugin restart)
└── util/
    ├── curlutil.lua           # Manages curl version checking, automatic static curl installation, and background downloads
    ├── httputil.lua           # HTTP requests with timeout, proxy support, and automatic fallback
    ├── fileutil.lua           # File operations (size, creation, deletion, validation) and directory checks
    └── stringutil.lua         # String utilities (trimming, validation, emoji removal, HTML entity conversion, extension/parentheses removal)
```

### Workflow

1. **Settings & Filtering** (`SettingsPage`)
   - User can customise preferred languages
   - User can select preferred file types: ebooks (EPUB, MOBI, AZW, etc.), comics (CBR, CBZ), documents (PDF, DOCX, etc.), images, or web formats
   - User can filter by book type: fiction, non-fiction, comics, or standards documents
   - Download directory can be changed from a file browser
   - All settings are persisted and applied to future searches

2. **Search Phase** (`AnnasAPI`)
   - User enters a search query via InputDialog
   - Plugin resolves the current Anna's Archive mirror URL (with weekly caching)
   - Plugin scrapes Anna's Archive HTML search results page
   - HTML table is parsed to extract book metadata (title, authors, year, language, file type, MD5 hash, cover image URL)
   - Results are cached (72 hours max, 100 entries) to minimise requests
   - Search results are displayed in a menu

3. **Download Phase** (`LlgiAPI`)
   - User selects a book and optionally changes the save location via DownloadPrompt
   - Book cover image is fetched and cached locally
   - Plugin resolves the current Library Genesis mirror URL (with weekly caching)
   - Curl fetches the ads page using the book's MD5 hash to obtain a download URL
   - File size is determined from HTTP headers for progress calculation
   - A curl process is spawned to download the file in the background
   - Progress widget updates every 0.5 seconds with percentage and file size information
   - On completion, file is saved to the configured download directory

4. **Error Handling & Resilience**
   - Network connectivity is verified before searching
   - Failed downloads automatically retry through a configured proxy (if `PROXY_URL` env var is set)
   - Mirror URLs are dynamically scraped from Wikipedia if cached URLs fail
   - User can cancel downloads at any time via the progress widget
   - All temporary files, exit code files, and background processes are cleaned up on completion or cancellation
   - Curl version is checked on startup; static curl (8.17.0) is automatically installed if needed

### Environment Variables

The plugin supports an optional `PROXY_URL` environment variable for proxy-based downloads:

```bash
export PROXY_URL="http://proxy.example.com:8080"
```

If a direct download fails, the plugin automatically retries through the proxy.

## Attribution

This plugin is forked from [justrals/KindleFetch](https://github.com/justrals/KindleFetch). It uses a similar underlying logic, but focuses on easy UX and simplicity. The choice was made to only support downloads from Library Genesis due to limitiations and complexity surrounding Z-Library downloads.

## License

MIT

## Disclaimer

This plugin facilitates downloading books from Anna's Archive and Library Genesis. Ensure you have the legal right to download any content and respect copyright laws in your jurisdiction. The authors assume no liability for misuse.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request with improvements, bug fixes, or new features.
