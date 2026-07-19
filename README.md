# KindleFetch

<a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/stars/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github star tracker"></a> <a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/downloads/william-spongberg/KindleFetch.koplugin/total.svg" height="25px" alt="Github downloads tracker"></a> <a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/v/release/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github release version tracker"></a>

Download books from Anna's Archive directly to your Kindle, entirely within the KOReader app.

## Overview

KindleFetch integrates Anna's Archive and Library Genesis into KOReader, allowing you to search for and download books without leaving your e-reader. The plugin handles the entire workflow - from search queries to file downloads - with an intuitive interface and robust error handling.

## Features

- **Book Search + Downloads**: Query Anna's Archive from your device with simple text input and download with a tap from Library Genesis
- **Caching**: Minimise network requests and improve performance
  - Search results (2 week expiry, 1000 entries max)
  - Mirror URLs (1 week expiry)
  - Book covers (500 entries max)
- **Preferences**: Filter results by preferred languages, file types, and book types
- **Book Cover Previews**: Display cover images in search results and download previews
- **Download Progress**: Visual download progress bar with real-time file size information
- **Background Downloads**: Downloads run in the background using curl, with non-blocking UI updates
- **Automatic Curl Updates**: Ensures a compatible curl version (8.17.0+) is available
- **Automatic Plugin Updates**: Checks for new plugin releases and prompts to update with release notes
- **Automatic Retry Logic**: Fallback to other available urls if connection fails
- **Safe File Handling**: Automatic filename sanitisation and directory management

## Installation

1. Ensure you have the latest stable release of KOReader installed (the nightly release has been known to cause issues with this plugin)

2. Download the latest release from the [Releases](https://github.com/william-spongberg/KindleFetch.koplugin/releases) tab

3. Unzip and move its contents into the `plugins` folder of KOReader

## Usage

### Downloading books

#### Search → Kindle Fetch → Search Anna's Archive

<img width="400" height="533" alt="FileManager_2026-07-12_135936" src="https://github.com/user-attachments/assets/7cbd408b-a778-48d0-b2cf-faef8fc8064e" />
<img width="400" height="533" alt="FileManager_2026-07-12_135944" src="https://github.com/user-attachments/assets/01568d65-a1ae-4701-b7af-567f57df1f92" />
<img width="400" height="533" alt="FileManager_2026-07-12_135948" src="https://github.com/user-attachments/assets/dc877805-3e67-4a37-b5c8-ea8e08889e4c" />

1. Enter a book title, author, or keyword in the search box.

<img width="400" height="533" alt="Screenshot From 2026-07-19 15-48-12" src="https://github.com/user-attachments/assets/26d9a11c-fcbe-49a4-8420-4c371b2f44b3" />

3. Browse the results and tap a book to download.

<img width="400" height="533" alt="Screenshot From 2026-07-19 15-48-33" src="https://github.com/user-attachments/assets/f7245229-d4aa-4a08-ade7-285fa52282b6" />
<img width="400" height="533" alt="Screenshot From 2026-07-19 16-26-45" src="https://github.com/user-attachments/assets/815d7d60-2d06-4ff8-9560-18dc58ec8e4c" />

5. In the download prompt, optionally tap the book cover for a fullscreen preview or adjust the download location via the download path button

<img width="400" height="533" alt="Screenshot From 2026-07-19 15-48-41" src="https://github.com/user-attachments/assets/3dd1ce46-02b4-45b5-a1c8-ac495f3748eb" />
<img width="400" height="533" alt="Screenshot From 2026-07-19 15-48-44" src="https://github.com/user-attachments/assets/43baaa36-7fb6-4fbb-b632-617874794144" />

6. Confirm the download and monitor progress; tap Hide to run in background or Cancel to stop.

<img width="400" height="533" alt="Screenshot From 2026-07-19 15-51-06" src="https://github.com/user-attachments/assets/e49fcbeb-c1df-413d-be8b-376e60facf19" />
<img width="400" height="533" alt="Screenshot From 2026-07-19 15-56-06" src="https://github.com/user-attachments/assets/49bd7f2e-b707-4337-84ff-3f7efc702b0d" />

Downloaded books are saved to your configured download location.

### Settings

#### Search → Kindle Fetch → Settings

- **Show Book Covers**: Enable or disable cover image display in search results (default: enabled)

<img width="400" height="533" alt="Screenshot From 2026-07-19 16-26-40" src="https://github.com/user-attachments/assets/75589b17-aeaf-4c1c-9ea9-20f9ae75442d" />
<img width="400" height="533" alt="Screenshot From 2026-07-19 15-58-51" src="https://github.com/user-attachments/assets/59dd8a28-cf89-4410-b376-18d534be1913" />

- **Download Folder**: Set the directory where books are saved (defaults to home directory or `/mnt/us/documents`)

<img width="400" height="533" alt="FileManager_2026-07-12_135959" src="https://github.com/user-attachments/assets/a866e96d-0ac1-4bde-a815-38e0fbfbe57a" />
<img width="400" height="533" alt="FileManager_2026-07-12_140015" src="https://github.com/user-attachments/assets/649f50aa-c81c-486e-a38c-c2351db9f720" />

- **Preferred Languages**: Choose which languages to prioritise in search results

<img width="400" height="533" alt="FileManager_2026-07-12_140024" src="https://github.com/user-attachments/assets/6b629965-bb15-4d09-8e63-ec77fe9c260d" />


- **Preferred File Types**: Select desired formats across five categories:
  - Ebooks: EPUB, MOBI, AZW, AZW3, KFX, FB2, LIT, PRC, LRF, SNB, UPDB
  - Comics: CBR, CBZ
  - Documents: PDF, TXT, RTF, DOC, DOCX, ODT, DJVU
  - Images: JPG, TIF, PDB
  - Web: CHM, HTM, HTML, HTMLZ, MHT

<img width="400" height="533" alt="FileManager_2026-07-12_140030" src="https://github.com/user-attachments/assets/2f4cff54-240e-49d6-9293-3982f0a0523b" />


- **Preferred Book Types**: Filter by fiction, non-fiction, unknown, comics, or standards documents

<img width="400" height="533" alt="FileManager_2026-07-12_140038" src="https://github.com/user-attachments/assets/1576b6c1-f5b0-4fd8-b907-841080495950" />

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
│   ├── bookmenu.lua           # Custom menu for displaying search results with cover images and pagination
│   ├── downloadprompt.lua     # Modal dialog for confirming download details, choosing save location, displaying metadata, and fullscreen cover preview
│   └── downloadprogress.lua   # Renders a centered progress widget with cancel and hide buttons
├── cache/
│   ├── cache.lua              # Generic caching system with expiry, size limits, and timestamp-based cleanup
│   ├── searchcache.lua        # Caches search results by query, page, and filter preferences (2 week expiry, 1000-entry limit)
│   ├── urlcache.lua           # Caches mirror URLs to minimize Wikipedia scraping (1 week expiry)
│   └── covercache.lua         # Caches book cover images by MD5 hash (500-entry limit, persists across sessions)
├── updater/
│   ├── curlupdater.lua        # Checks curl version and automatically installs static curl (8.17.0) if needed
│   └── pluginupdater.lua      # Checks for plugin updates from GitHub releases and prompts user with release notes
└── util/
    ├── curlutil.lua           # Manages curl downloads, background processes, parallel downloads, and version checking
    ├── httputil.lua           # HTTP requests with timeout, proxy support, and automatic fallback
    ├── fileutil.lua           # File operations (size, creation, deletion, validation) and directory checks
    ├── stringutil.lua         # String utilities (trimming, validation, emoji removal, HTML entity conversion)
    ├── logutil.lua            # Logger wrapper
    ├── notifyutil.lua         # Notification wrapper
    └── versionutil.lua        # Version parsing and comparison utilities
```

### Workflow

0. **Initialization**
   - Curl version is checked; user is prompted to update if version is below 8.17.0
   - Plugin version is checked against GitHub releases; user is prompted to update if new version available
   - Settings are loaded from persistent storage

1. **Settings & Filtering** (`SettingsPage`)
   - User can customize preferred languages (100+ supported)
   - User can select preferred file types: ebooks (EPUB, MOBI, AZW, etc.), comics (CBR, CBZ), documents (PDF, DOCX, etc.), images, or web formats
   - User can filter by book type: fiction, non-fiction, comics, or standards documents
   - Download directory can be changed from a file browser
   - Book cover loading can be toggled on/off (for efficiency)
   - All settings are persisted and applied to future searches

2. **Search Phase** (`AnnasAPI`)
   - User enters a search query via InputDialog
   - Plugin resolves the current Anna's Archive mirror URL (with weekly caching)
   - Plugin scrapes Anna's Archive HTML search results page
   - HTML table is parsed to extract book metadata (title, authors, year, language, file type, MD5 hash, cover image URL)
   - Results are cached (72 hours max, 100 entries) to minimise requests
   - Search results are displayed in a menu

3. **Cover Loading**
   - On initial search result display, covers are loaded in the background
   - Subsequent pages trigger `onPageChange` callback to load covers for visible items
   - Covers are downloaded in parallel using curl's `--parallel` flag
   - Downloaded covers are cached locally with persistent storage
   - If cover download fails, book entry displays without cover image

4. **Download Phase** (`LlgiAPI`)
   - User selects a book and optionally changes the save location via DownloadPrompt
   - Book cover image is fetched and cached locally
   - Plugin resolves the current Library Genesis mirror URL (with weekly caching)
   - Curl fetches the ads page using the book's MD5 hash to obtain a download URL
   - File size is determined from HTTP headers for progress calculation
   - A curl process is spawned to download the file in the background
   - Progress widget updates every 0.5 seconds with percentage and file size information
   - On completion, file is saved to the configured download directory

5. **Error Handling & Resilience**
   - Network connectivity is verified before searching
   - Failed downloads automatically retry through a configured proxy (if `PROXY_URL` env var is set) and empty or corrupted downloads are detected and deleted
   - Failed mirrors are removed from cache; if all cached URLs fail they are re-scraped from Wikipedia
   - User can cancel downloads at any time via the progress widget
   - Curl exit codes are mapped to human-readable error messages and the user is notified

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
