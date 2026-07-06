# KindleFetch

A KOReader plugin that enables downloading books directly from Library Genesis to your Kindle device without ever leaving the KOReader app.

## Overview

KindleFetch integrates Anna's Archive and Library Genesis into KOReader, allowing you to search for and download books without leaving your e-reader. The plugin handles the entire workflow - from search queries to file downloads - with an intuitive interface and robust error handling.

## Features

- **Direct Book Search**: Query Anna's Archive from your device with simple text input
- **Rich Metadata Display**: View book titles, authors, publication year, language, file type, and size before downloading
- **Progress Tracking**: Visual download progress bar with real-time file size information
- **Automatic Retry Logic**: Fallback to proxy-based downloads if direct connections fail
- **Background Downloads**: Downloads run in the background using curl, with non-blocking UI updates
- **Safe File Handling**: Automatic filename sanitization and directory management

## How It Works

### Architecture

The plugin is organised into (mostly) modular components:

### Workflow

1. **Search Phase** (`AnnasAPI`)
   - User enters a search query in the InputDialog
   - Plugin scrapes HTML search results page from Anna's Archive via HTTP request
   - HTML table is parsed to extract book metadata (title, authors, year, language, file type, MD5 hash)
   - Results are displayed in an interactive menu

2. **Download Phase** (`LlgiAPI`)
   - User selects a book from search results
   - Plugin uses curl to fetch the ads page using the book's MD5 hash
   - Download URL is extracted from the ads page HTML
   - File size is parsed from the download page's http headers
   - A curl process is spawned to download the file in the background
   - Progress widget updates every 0.5 seconds with download percentage and file size
   - Upon completion, the file is saved to the configured documents directory

3. **Error Handling**
   - Network connectivity is verified before searching
   - Failed downloads automatically retry through a configured proxy (if available)
   - User can cancel downloads at any time
   - All temporary files and processes are cleaned up on completion or cancellation

### Key Components

| Module | Responsibility |
| ------ | -------------- |
| [`main.lua`](kindlefetch.koplugin/main.lua) | Main plugin entry point; manages UI flow and book selection |
| [`_meta.lua`](kindlefetch.koplugin/_meta.lua) | Plugin configuration for KOReader |
| [`annasapi.lua`](kindlefetch.koplugin/api/annasapi.lua) | Searches Anna's Archive and parses results into book objects |
| [`lgliapi.lua`](kindlefetch.koplugin/api/lgliapi.lua) | Handles Library Genesis downloads with progress tracking and retry logic |
| [`downloadprogress.lua`](kindlefetch.koplugin/ui/downloadprogress.lua) | Renders a centered progress widget with cancel button |
| [`httputil.lua`](kindlefetch.koplugin/util/httputil.lua) | Wrapper around socket.http with proxy support and error handling |
| [`stringutil.lua`](kindlefetch.koplugin/util/stringutil.lua) | String utilities (trimming, validation, whitespace normalization) |

## Installation

1. Download the the latest release from the [Releases](https://github.com/william-spongberg/KindleFetch.koplugin/releases) tab

2. Unzip and move its contents into the `plugins` folder of KOReader

## Usage

1. Select Tools → Kindle Fetch from the main menu.

2. Enter a book title, author, or keyword in the search box.

3. Browse the results and tap a book to download.

4. Monitor the download progress; tap Cancel to stop.

Downloaded books are saved to your configured home directory.

## Configuration

### Download Directory

The plugin attempts to read the home directory from your KOReader settings. If not found, it defaults to:

   ``` folder
    /mnt/us/documents (primary Kindle books path)
    /mnt/us (fallback)
   ```

## Attribution

This plugin is forked from [justrals/KindleFetch](https://github.com/justrals/KindleFetch). It uses a similar underlying logic, but focuses on easy UX and simplicity. The choice was made to only support downloads from Library Genesis due to limitiations and complexity surrounding Z-Library downloads.

## License

MIT

## Disclaimer

This plugin facilitates downloading books from Anna's Archive and Library Genesis. Ensure you have the legal right to download any content and respect copyright laws in your jurisdiction. The authors assume no liability for misuse.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request with improvements, bug fixes, or new features.
