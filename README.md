# KindleFetch

<a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/stars/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github star tracker"></a> <a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/downloads/william-spongberg/KindleFetch.koplugin/total.svg" height="25px" alt="Github downloads tracker"></a> <a href="https://github.com/william-spongberg/KindleFetch.koplugin"><img src="https://img.shields.io/github/v/release/william-spongberg/KindleFetch.koplugin" height="25px" alt="Github release version tracker"></a>

Download books from Library Genesis, Internet Archive, Project Gutenberg, Z-Library and your own Calibre library directly to your Kindle (or any e-reader running KOReader), entirely within the KOReader app.

## Overview

KindleFetch integrates Library Genesis, Internet Archive, Project Gutenberg, Z-Library and your own libraries, such as Calibre's, into KOReader, allowing you to search for and download books without leaving your e-reader. The plugin handles the entire workflow - from search queries to file downloads - with an intuitive interface and robust error handling.

## Features

- **Four sites, searched at once**: Z-Library (with your account), Library Genesis, Internet Archive and Project Gutenberg, each site's books shown as soon as it finds them
- **Your own libraries**: Calibre, Calibre-Web and other OPDS catalogues, searched along with the sites
- **Narrower searches**: search only titles, authors or ISBNs (Library Genesis, Internet Archive and Calibre)
- **Filters**: search in the languages, file types and book types you choose, then narrow the books found down by site, language, decade, size and more, without searching again
- **Search from your books**: find more by a book's author, or search for text you've highlighted
- **Covers**: in the results, and full size with a tap
- **Background downloads**: hide a download and carry on, then check on it from the menu
- **Downloads that survive sleep**: the device stays awake while books download, and a download carries on once Wi-Fi is back
- **Checked downloads**: a web page or incomplete file isn't saved as the book
- **Read now**: open a book as soon as it's downloaded, or show its folder, add it to a collection or see its information
- **Errors that offer the fix**: log in, turn on Wi-Fi, use encrypted DNS, update curl, or search another site
- **Blocked sites**: says which mirror it's trying and why the last one failed, with encrypted DNS and a proxy in the settings
- **Saved searches**: results show again straight away, even offline
- **No curl needed**: uses KOReader's own HTTP on devices without curl, such as some Kobos
- **Updates**: updates itself, can go back to the version before, and offers a newer curl on Kindles
- **Diagnostics**: to copy or save when reporting a problem

## Installation

1. Ensure you have the latest stable release of KOReader installed (the nightly release has been known to cause issues with this plugin)

2. Download the latest release from the [Releases](https://github.com/william-spongberg/KindleFetch.koplugin/releases) tab

3. Unzip and move its contents into the `plugins` folder of KOReader

## Usage

### Downloading books

#### Search → Kindle Fetch → Search

Search can also be opened from a gesture, in KOReader's gesture manager: Kindle Fetch, for the sites ticked last, or Kindle Fetch: search Internet Archive or Z-Library, for that site.

Z-Library can only be searched with an account, so it's left out of searches until you log in: tap it in Sites, where it says (log in), and Kindle Fetch asks for its email and password, and keeps the key Z-Library logs it in with rather than your password (you can log out in the settings). Z-Library limits how many books an account can download a day; once they've all been downloaded, Kindle Fetch says so, rather than asking for another.

<img width="350" alt="Logging in to Z-Library, then searching it, and downloading and reading a book from it" src="docs/gifs/z-library.gif" />

Internet Archive only has the books that anyone can download, rather than borrow, which Kindle Fetch can't do: mostly older books, many of them scans, whose EPUBs were made by reading the scanned pages, which can leave mistakes in them. Its search doesn't say how big each book is, so the size shows once the download starts, and a large one can be cancelled straight away.

<img width="350" alt="Searching Internet Archive, then downloading and reading a book from it" src="docs/gifs/internet-archive.gif" />

Project Gutenberg has over 75,000 free ebooks, mostly older books whose US copyright has expired, as EPUB, MOBI and TXT. Its search can't be narrowed down to the books' titles or authors.

<img width="350" alt="Kindle Fetch in KOReader's search menu" src="docs/screenshots/01-search-menu.png" /> <img width="350" alt="Kindle Fetch's menu" src="docs/screenshots/02-kindlefetch-menu.png" />

1. Enter a book title, author, or keyword in the search box, or tap Recent to search again for one of your last 10 searches. Tap Sites to tick the sites to search (all of them, to begin with): they're searched at once, and each one's books are shown as soon as it has found them, with the site each was found on, while the sites still being searched are listed at the end. On Library Genesis and Internet Archive, Search in narrows the search down to the books' titles, authors or ISBNs. KOReader carries on while the sites answer; tap Cancel on the message saying it's searching to call the search off.

<img width="350" alt="Search box" src="docs/screenshots/03-search-dialog.png" /> <img width="350" alt="Message saying it's searching, with a button to cancel" src="docs/screenshots/04-searching.png" />

2. Browse the results and tap a book to download. The top of the list says what was searched for and how many books have been found, and placeholders show while the covers download. To show only some of them, such as those from one site or in one file type, use the menu at the top left of the list (see [Showing only some of the books found](#showing-only-some-of-the-books-found)).

<img width="350" alt="Search results while covers download" src="docs/screenshots/05-search-results-loading-covers.png" /> <img width="350" alt="Search results with covers" src="docs/screenshots/06-search-results.png" /> <img width="350" alt="Searching Internet Archive and Z-Library at once: opening Kindle Fetch, ticking Z-Library in Sites, typing a search, each site's books and covers arriving, and loading more books" src="docs/gifs/searching.gif" />

3. In the download prompt, optionally tap the book cover to see it full size, or tap the folder it will be saved in (above the name it will be saved as) to choose another, then tap Download. If a book of that name is already there, choose whether to overwrite it or read the one you have.

<img width="350" alt="Download prompt" src="docs/screenshots/07-download-prompt.png" /> <img width="350" alt="Fullscreen cover" src="docs/screenshots/08-download-cover.png" /> <img width="350" alt="Being asked before downloading over a book that's already there" src="docs/screenshots/09-download-overwrite.png" />

4. Monitor the download's progress; tap Hide to keep it downloading in the background (to see its progress again, choose **Search → Kindle Fetch → Downloads**, or the book again) or Cancel to stop it.

<img width="350" alt="Download progress" src="docs/screenshots/10-download-progress.png" /> <img width="350" alt="Downloading a book: its full-size cover, the download's progress, hiding it and choosing the book again to see it, then reading the book" src="docs/gifs/downloading.gif" />

5. Once the book has downloaded, tap Read now to open it, or Show folder, Collections… or Book information beneath.

<img width="350" alt="Read now prompt" src="docs/screenshots/11-download-finished.png" /> <img width="350" alt="Reading the downloaded book" src="docs/screenshots/12-reading.png" />

Downloaded books are saved to the download folder in the settings, unless you choose another in the download prompt.

#### Showing only some of the books found

Tap the menu at the top left of the results to narrow the books found down, without searching again:

- **Sites**, **Languages**, **File types**, **Book types**, **Years** and **Sizes** each list what the books found have, such as the sites they were found on or the decades they're from, with how many of the books have each. Untick what to hide, then close the list. Each is offered where the books found don't all have the same: only Library Genesis sorts its books into types, and only Library Genesis and Z-Library say how big each book is.
- **Downloaded** hides the books that are in the download folder already, or shows only those.
- **Look through the books found** shows only those with some text in their title, authors or file type. Tapping the page number, typing the text and tapping Search does the same.
- **Show all** brings back every book that's hidden.
- **Search again** changes the languages, file types or book types in Kindle Fetch's settings, then searches again with them.

The menu says what each one shows, such as "Sites: Z-Library, Internet Archive", and the top of the results how many of the books found are showing. Books that arrive later, from a site still being searched or from Load more, show unless what they have is unticked, and Load more only loads from the sites shown. A change that would hide every book isn't taken.

<img width="350" alt="The menu at the top left of the results, which shows only some of the books found" src="docs/screenshots/13-search-results-menu.png" /> <img width="350" alt="The decades the books found are from, each with how many of the books are from it, to untick those to hide" src="docs/screenshots/14-search-results-years.png" /> <img width="350" alt="Only the books from the decades ticked, with how many of the books found are showing" src="docs/screenshots/15-search-results-shown.png" />

### Settings

#### Search → Kindle Fetch → Settings

- **Show Book Covers**: Enable or disable cover image display in search results (default: enabled)

<img width="350" alt="Settings" src="docs/screenshots/16-settings.png" /> <img width="350" alt="Search results without covers" src="docs/screenshots/17-search-results-without-covers.png" /> <img width="350" alt="Changing the settings: ticking another language, and keeping searches for longer" src="docs/gifs/settings.gif" />

- **Download Folder**: Set the directory where books are saved (defaults to home directory or `/mnt/us/documents`); the settings show the end of a long one, which says the most about it

<img width="350" alt="Choosing the download folder" src="docs/screenshots/18-settings-download-folder.png" />

- **Z-Library Account**: Log in to the Z-Library account to search it with, or out of the one logged into. Kindle Fetch keeps the key Z-Library logs it in with, rather than your password

- **Your Libraries**: Add your own libraries to search, such as Calibre's content server, or edit or remove those added (see [Your own libraries](#your-own-libraries)). Kindle Fetch keeps their usernames and passwords in its settings, as they ask for them every time

- **Preferred Languages**: Choose the languages of the books shown in search results (default: English)

<img width="350" alt="Preferred languages" src="docs/screenshots/19-settings-languages.png" />

- **Preferred File Types**: Select desired formats across five categories, from those KOReader can open (default: all of them, which the settings show as All):
  - Ebooks: EPUB, MOBI, AZW, FB2, PRC
  - Comics: CBR, CBZ
  - Documents: PDF, TXT, RTF, DOC, DOCX, ODT, DJVU
  - Images: JPG, TIF, PDB
  - Web: CHM, HTM, HTML, HTMLZ

<img width="350" alt="Preferred file types" src="docs/screenshots/20-settings-file-types.png" />

- **Preferred Book Types**: Filter Library Genesis' results by fiction, non-fiction, comics, magazines, scientific articles, or standards (default: all of them, which the settings show as All); the other sites don't sort their books into these

<img width="350" alt="Preferred book types" src="docs/screenshots/21-settings-book-types.png" />

When a search finds books, but none in the languages and file types chosen, Kindle Fetch says how many the site listed, and offers to open the settings or to keep searching through the rest. When the site has none of the file types chosen at all (Internet Archive only has EPUB, MOBI, PDF, DJVU, TXT, CBZ and CBR), it says so, and offers the settings or the other sites.

<img width="350" alt="Being told that Internet Archive has none of the file types chosen" src="docs/screenshots/22-search-none-chosen.png" />

- **Check for Updates Automatically**: Check for plugin and curl updates at most once a day while connected (default: enabled)

- **Keep Searches For / Keep Mirrors For**: How long search results (default: 14 days), and Library Genesis' mirrors and Z-Library's addresses (default: 7 days) are cached
- **Encrypted DNS**: Look the sites up with Cloudflare's DNS over HTTPS (at 1.1.1.1), rather than the network's own DNS, which can be what's blocking them (needs curl 7.62 or later, so not where KOReader's own HTTP fetches in its place; default: off). Kindle Fetch offers to turn it on when a network can't find any of Library Genesis' or Z-Library's sites
- **HTTP Proxy**: KOReader's HTTP proxy, the same setting as in KOReader's network settings, which Kindle Fetch goes through for everything (searches, covers and books, with curl too) as KOReader does: turn it on with its address, e.g. `http://proxy.example:8080`, or off (default: off)

<img width="350" alt="How long searches are kept" src="docs/screenshots/23-settings-cache.png" />

- **Clear Cache**: Forget the searches (and the recent ones the search box offers), mirrors and book covers that have been saved, e.g. if results look out of date
- **Go back to v…**: After an update, while the version before it is kept, go back to that version, if the new one doesn't work on your device

### Your own libraries

#### Search → Kindle Fetch → Settings → Your Libraries

Kindle Fetch searches your own books too, on a server of your own with an OPDS catalogue, as Calibre's content server, Calibre-Web and most others have. Tap Add a library…, then type its address, e.g. `192.168.1.10:8080`, and its username and password, if it asks for them. Kindle Fetch finds the catalogue there (at `/opds`, for Calibre's and Calibre-Web's), and adds the library by its name, ticked in Sites, where it's listed first. Where Calibre has several libraries, it asks which to add.

<img width="350" alt="Your Libraries in the settings, with a Calibre library added" src="docs/screenshots/24-libraries.png" /> <img width="350" alt="Adding a library at its address, with its username and password" src="docs/screenshots/25-library-add.png" /> <img width="350" alt="Pride and Prejudice and Emma, with their covers, found in a Calibre library" src="docs/screenshots/26-library-search-results.png" />

- Calibre's content server is started in Calibre, with **Connect/share → Start Content server**, at port 8080 of the computer it's on by default. Its searches can be narrowed down to titles, authors or ISBNs. Calibre doesn't say which language each book is in, so they show as Unknown in Languages, though only those in the languages chosen in the settings are found
- Calibre-Web is at port 8083 by default
- A book in AZW3, as Calibre makes them for Kindles, is downloaded as an AZW, which KOReader opens
- A library that's only on your home network can't be searched away from it. Where the other sites find books, Kindle Fetch only says so over them the first time, until KOReader is restarted
- Tap a library to change its name, address or login, or to remove it

## Troubleshooting

### None of Library Genesis' sites can be found on this network

Kindle Fetch looks Library Genesis' sites up on Wikipedia, then searches them in turn. When Wikipedia answers, but none of the sites can be found, the network or its internet provider is most likely blocking Library Genesis, as many do. To check, open one of them, such as [libgen.li](https://libgen.li), on a phone or computer on the same network. If it doesn't open there either, try:

- Encrypted DNS in the [settings](#settings), which Kindle Fetch offers when it can't find them, as it looks them up with Cloudflare's DNS rather than the network's
- another Wi-Fi network, such as a phone's hotspot
- another DNS server on your router, such as 1.1.1.1 or 8.8.8.8, as the Kindle uses the one its Wi-Fi network gives it
- a proxy (HTTP Proxy in the [settings](#settings)) or VPN

### Your library can't be added or reached

- Check its server is running (for Calibre, **Connect/share → Start Content server**), and that the e-reader is on the same network
- Check the address and port: open the address on a phone or computer on that network, e.g. `http://192.168.1.10:8080` for Calibre, whose content server says its address in **Connect/share**
- Allow the port through the computer's firewall, as it may only let the computer itself in
- Where it "didn't accept the username and password", check them in Calibre's **Preferences → Sharing over the net → User accounts**, or Calibre-Web's users. Calibre can be set up to stop letting a device log in for a while after several wrong passwords
- An HTTPS address whose certificate isn't trusted, such as one a home server made itself, can't be used, so use its `http://` address on your home network instead

### Updating curl fails

Kindle Fetch downloads the new curl from GitHub with KOReader's own HTTP, as a Kindle's own curl can be too old to connect to it. If updating it fails all the same, curl can be updated by hand:

1. On a computer, download [`curl-armhf`](https://github.com/moparisthebest/static-curl/releases/download/v8.21.0/curl-armhf), and copy it to the Kindle over USB, next to its `documents` folder

2. On the Kindle, open a terminal: KOReader's own (**Tools → More tools → Terminal emulator**), kterm, or SSH with KOReader's SSH server (**Settings → Network → SSH server**)

3. Check that it runs on the Kindle, which should say `curl 8.21.0`:

   ```sh
   cp /mnt/us/curl-armhf /tmp/curl && chmod +x /tmp/curl && /tmp/curl --version
   ```

4. Install it, keeping the old one as `/usr/bin/curl.system.bak`, then restart KOReader:

   ```sh
   mntroot rw
   [ -f /usr/bin/curl.system.bak ] || cp /usr/bin/curl /usr/bin/curl.system.bak
   cp /tmp/curl /usr/bin/curl
   chmod 755 /usr/bin/curl
   mntroot ro
   ```

To put the old curl back, run `mntroot rw`, then `cp /usr/bin/curl.system.bak /usr/bin/curl`, then `mntroot ro`.

### Anything else

Kindle Fetch → Diagnostics shows what's needed to work out what went wrong: the versions of Kindle Fetch, KOReader and curl, the device, the settings, the mirrors, your libraries (by their names), and what Kindle Fetch has logged since KOReader started. Tap Test connection to see which of the sites (Wikipedia, each of Library Genesis' mirrors, Internet Archive, Project Gutenberg, Z-Library and your libraries) the device can reach, then Copy or Save (to `kindlefetch-diagnostics.txt` in KOReader's folder) to attach it to an [issue](https://github.com/william-spongberg/KindleFetch.koplugin/issues). It has nothing in it that would let anyone into your Z-Library account or your libraries.

<img width="350" alt="Kindle Fetch's diagnostics" src="docs/screenshots/27-diagnostics.png" />

KOReader's `crash.log`, in its `koreader` folder, says what Kindle Fetch was doing when something went wrong too.

## How It Works

### Architecture

``` architecture
kindlefetch.koplugin/
├── main.lua                   # Loads Kindle Fetch, or when it can't be loaded or started, what safemode.lua leaves
├── kindlefetch.lua            # The plugin itself; manages search UI, results display, and download initiation
├── safemode.lua               # What's left when Kindle Fetch can't start (e.g. after an update that doesn't work with your KOReader): its menu, saying why, and going back to the version before
├── _meta.lua                  # Plugin metadata and KOReader integration
├── settings/
│   ├── settings.lua           # Persistent storage and management of user preferences
│   └── settingspage.lua       # UI for configuring user preferences, and clearing the caches
├── api/
│   ├── downloader.lua         # Downloads books from the site they were found on, with progress tracking and error recovery
│   ├── site.lua               # What every site does: searching it a page at a time, saving the results and explaining failures, so each site only says how to search it and read its results
│   ├── book.lua               # The books the sites find: the names their files download as, their titles and authors as shown, and their sizes
│   ├── sites.lua              # The sites books can be searched for and downloaded from
│   ├── multisearch.lua        # Searches the sites ticked at once, each in a coroutine of its own, passing on each one's books as soon as it has found them
│   ├── libgensearch.lua       # Searches Library Genesis and finds its download links, reading its pages of results until enough books are found
│   ├── iasearch.lua           # Searches Internet Archive's books that anyone can download, and finds their files, with its search API
│   ├── gutenbergsearch.lua    # Searches Project Gutenberg's free ebooks with its catalogue's search, and finds their files in the catalogue
│   ├── opdssearch.lua         # Finds the OPDS catalogue of a library of your own, such as Calibre's content server's or Calibre-Web's, and searches it in its own way, finding its books' files
│   ├── libraries.lua          # The libraries you've added, each searched as a site of its own, before the others
│   ├── zlibaccount.lua        # Logs in to Z-Library, keeping the key it logs in with rather than the password, and asks its API as the account
│   ├── zlibsearch.lua         # Searches Z-Library and finds its download links with the API its app uses, while the account can download more today
│   └── urlapi.lua             # Scrapes Wikipedia to discover the current Library Genesis mirrors and Z-Library addresses
├── ui/
│   ├── bookmenu.lua           # Custom menu for displaying search results with cover images and pagination
│   ├── bookfilter.lua         # What the books found can be shown by without searching again (their sites, languages, file types, book types, decades, sizes, and whether they're downloaded), with how many have each
│   ├── coverplaceholder.lua   # Placeholder shown in place of a cover while it downloads
│   ├── downloadprompt.lua     # Dialog showing a book's details and cover (full size when tapped), where to save it, and a Download button
│   ├── diagnostics.lua        # What's known about Kindle Fetch, KOReader and the device, with a test of the connection to the sites and the recent log, to copy or save
│   ├── waitingmessage.lua     # Message saying what's being waited for, with a Cancel button that calls the wait off
│   ├── backgroundtask.lua     # Runs what waits on the sites without holding KOReader up, with a message and Cancel where it's shown, saying what went wrong
│   ├── zliblogin.lua          # Dialog asking for the email and password of a Z-Library account, and logging in with them
│   ├── librarysettings.lua    # Your Libraries, in the settings: adding a library at its address, and changing or removing those added
│   └── downloadprogress.lua   # Renders a centered progress widget with cancel and hide buttons
├── cache/
│   ├── cache.lua              # Generic caching system with expiry, size limits, and timestamp-based cleanup
│   ├── searchcache.lua        # Caches each site's search results by query, page, and filter preferences (2 weeks by default, 100-entry limit)
│   ├── urlcache.lua           # Caches mirror URLs to minimise Wikipedia scraping (1 week by default)
│   └── covercache.lua         # Downloads and caches book covers and full-size covers by book (500-entry limit, persists across sessions, removing the oldest covers' files once full)
├── updater/
│   ├── rollback.lua           # Keeps the version installed before an update, to go back to (and forward again) if the new one doesn't work
│   ├── curlupdater.lua        # Checks curl version on Kindles and offers to install static curl (8.21.0) if it's older, downloading it with KOReader's own HTTP, checking it's the build that was released, and that it runs
│   └── pluginupdater.lua      # Checks for plugin updates from GitHub releases and prompts user with release notes, unzipping the update with KOReader's own archiver (or unzip, where it has none) next to the plugin, and keeping the installed version until the new one is in place
└── util/
    ├── curlutil.lua           # Manages curl downloads, background processes and parallel downloads
    ├── errors.lua             # What went wrong, when the code told acts on it rather than only saying it, said one way wherever it comes from
    ├── guard.lua              # Runs what KOReader runs later (scheduled tasks, Trapper's functions, event handlers), catching errors, logging where they happened and cleaning up
    ├── httpdownload.lua       # Downloads books and covers with KOReader's own HTTP in a process of its own, where curl can't, followed and stopped as curl's downloads are
    ├── httputil.lua           # Fetches web pages with curl (compressed, in the background) or KOReader's own HTTP, with timeouts, proxy support, and automatic fallback; posts forms and sends cookies, giving them to curl in a file rather than on its command line; downloads files with curl, or KOReader's own HTTP where curl can't connect
    ├── httplogin.lua          # Logs in to your libraries' sites with KOReader's own HTTP, the Basic or the Digest way, following where they send requests itself, so the login only goes to its own site
    ├── librarysites.lua       # Your libraries' sites, with the logins for each, which are only sent to their own site, and never logged
    ├── opdsfeed.lua           # Reads OPDS catalogues' feeds, as each server writes them its own way
    ├── languagecodes.lua      # The codes sites give books' languages in, as Internet Archive's, Calibre-Web's and other OPDS catalogues' are
    ├── fileutil.lua           # File operations (size, reading, writing and deleting files, listing folders) and directory checks
    ├── filecheck.lua          # Tells what a file that has downloaded is by how it starts (a book in its file type, an image, or a web page sent in its place), and works out its MD5 a piece at a time
    ├── stringutil.lua         # String utilities (trimming, validation, cleaning titles and file names, HTML entity conversion, checking web addresses)
    ├── logutil.lua            # Logger wrapper
    ├── notifyutil.lua         # Notifications, and error messages that stay until dismissed
    ├── pathutil.lua           # Plugin install location and temporary download directory
    ├── proxyutil.lua          # The proxy everything goes through: KOReader's HTTP proxy, where it's on
    ├── shellutil.lua          # Runs a step of installing an update with shell commands, saying what went wrong in the command's own words
    └── versionutil.lua        # Version parsing and comparison utilities
```

### Workflow

0. **Initialization**
   - Unless turned off in settings, updates are checked for at most once a day while connected (whether or not the latest release could be looked up), or manually via Kindle Fetch → Check for updates
   - The latest release is looked up in the background, so KOReader can be used meanwhile. Where curl can't look it up (on a Kindle until it has been updated, or a device without curl), it's looked up with KOReader's own HTTP instead, only when checking manually, as that holds KOReader up until GitHub answers
   - A curl or plugin update that is turned down is only offered again by checking manually
   - On Kindles, curl version is checked; user is prompted to update if version is below 8.21.0. The new curl is downloaded with KOReader's own HTTP (a Kindle's own curl can be too old to connect to GitHub), checked to be the build that was released, and the old one kept until the new one has been copied over in full and runs
   - Plugin version is checked against GitHub releases; user is prompted to update with the release notes, then offered a restart. The version installed before is kept, to go back to from the settings (Go back to v…), and if a new version can't start, Kindle Fetch's menu says so and offers to go back
   - Settings are loaded from persistent storage

1. **Settings & Filtering** (`SettingsPage`)
   - User can customize preferred languages (100 supported)
   - User can select preferred file types: ebooks (EPUB, MOBI, AZW, etc.), comics (CBR, CBZ), documents (PDF, DOCX, etc.), images, or web formats
   - User can filter by book type: fiction, non-fiction, comics, magazines, scientific articles, or standards
   - Download directory can be changed from a file browser
   - Book cover loading can be toggled on/off (for efficiency)
   - All settings are persisted and applied to future searches

2. **Search Phase** (`MultiSearch`, and each `Site`: `LibgenSearch`, `IaSearch`, `GutenbergSearch`, `ZlibSearch`, `OpdsSearch`)
   - User enters a search query via InputDialog, or chooses one of the last 10 from its Recent button
   - The sites ticked in the search box (`MultiSearch`) are searched at once, each in a coroutine of its own, so each one's books are shown as soon as it has found them, with the sites still being searched listed at the end. Where pages are fetched with KOReader's own HTTP, which holds KOReader up, they're searched one after another instead, with what has been found shown in between. A site that fails is said to have over the books the others found, Load more carries on from each site that has more, and Cancel calls them all off
   - Plugin resolves the current Library Genesis mirror URL (cached for a week by default)
   - Plugin scrapes the Library Genesis HTML search results page for the preferred book types
   - Pages are fetched with curl where there is one (on a Kindle, once it has been updated): compressed, which Library Genesis sends several times sooner, and in the background, so KOReader isn't held up, and Cancel on the message saying it's searching calls the search off. Otherwise they're fetched with KOReader's own HTTP, which holds KOReader up until they arrive
   - HTML table is parsed to extract book metadata (title, authors, year, language, file type, MD5 hash, cover image URL), keeping books in the preferred languages and file types
   - As Library Genesis can't filter by language or file type, and sends 25 results a page, further pages of its results are read until at least 10 books are found (up to 5 pages at a time), and "Load more" carries on from there, for as long as Library Genesis says it has more pages, adding the books to the list where it was tapped. Calling the search off while it reads further pages shows the books it has found so far
   - Results are cached (2 weeks by default, 100 entries max) to minimise requests
   - Search results are displayed in a menu, marking the books that are in the download folder already
   - The books found can be narrowed down without searching again (`BookFilter`), by the values they have for their site, languages, file type, book type, decade, size (where the site says, in bands from under 1 MB to over 100 MB) and whether they're in the download folder already. What's unticked is what's hidden, so books with other values, from a site that answers later or from loading more, are shown, and what would hide every book isn't taken
   - When Library Genesis lists results but none are in the preferred languages and file types, the plugin says how many it listed, and offers the settings or to keep searching through the rest
   - Z-Library (`ZlibSearch`) is searched with the API its own app uses, as the account logged into, in the preferred languages and file types, 50 books at a time. As it moves between addresses as they're taken down, they're looked up on its Wikipedia page, like Library Genesis' mirrors (kept for a week by default), and the next is asked when one doesn't answer
   - Internet Archive (`IaSearch`) is searched with its search API for the books with each word searched for in their title or author's name, in the preferred languages (or no known language) and the formats of the preferred file types, that anyone can download, the most downloaded first, 50 at a time. Each is given the first of the preferred file types it's in, as most are in several
   - Project Gutenberg (`GutenbergSearch`) is searched with its catalogue's search (its OPDS feed), 25 books at a time, in the one language chosen, where only one is. Otherwise the books are kept to the languages chosen by the language the catalogue adds after the titles of those not in English. Each is given the first of the preferred file types of EPUB, MOBI and TXT, and once it's chosen, its file in that type is looked up in the catalogue, with how big it is, which what arrives is checked against
   - Your libraries (`OpdsSearch`) are searched with the search their OPDS catalogues give, found once when each is added: a link with `{searchTerms}` in it, or its OpenSearch description. Calibre's content server is searched in Calibre's own search syntax, narrowed down there to the file types and languages chosen (or no language), and to titles, authors or ISBNs where asked, with its "not found" (HTTP 404) taken as no books. The others' books are kept to the file types chosen, and to the languages chosen where they say. Each book is given the first of the preferred file types it's in, with how big its file is. Load more follows each page's link to the next, and the searches aren't saved, as a library's books change

3. **Cover Loading**
   - Covers for the page of results showing are downloaded in the background, in parallel using curl's `--parallel` flag, with placeholders shown until they arrive. A connection is opened for each cover at once (with curl 7.68 or later), rather than curl waiting to see whether they can share one, which Library Genesis doesn't allow, so a page of covers arrives in about a third of the time
   - Turning the page loads the covers for that page, and the next page's are downloaded ahead so they're there when it's turned to
   - Each cover is shown as soon as it has downloaded (with curl 7.63 or later), rather than once the slowest on its page has, at most once a second as each time the screen is refreshed; one that stalls is given up on after 10 seconds
   - Downloaded covers are cached locally with persistent storage
   - If a cover can't be downloaded, or what arrives isn't an image, its book is shown without one
   - Tapping a cover in the download prompt downloads the full-size cover, showing the thumbnail until it arrives

4. **Download Phase** (`Downloader`)
   - User selects a book and optionally changes the save location via DownloadPrompt
   - If a file of that name is already there, the plugin asks whether to overwrite it or read the existing book
   - Before the book's link is looked up, the folder is checked: that it's there and can be written to (downloading to the default folder for now when the one chosen in the settings is missing, as on an SD card that has been taken out), and that no other book is downloading to the same name
   - The book's cover is fetched if it isn't cached already
   - Plugin resolves the current Library Genesis mirror URL (cached for a week by default)
   - Curl fetches the ads page using the book's MD5 hash to obtain a download URL, in the background (where pages are fetched with curl), so KOReader carries on while the mirrors answer, and Cancel calls it off
   - For a book on Z-Library, its API is asked how many more books the account can download today, and then for the book's download link, which counts as one of them. Each link goes to one of Z-Library's servers, picked at random, some of which can fail for a while, so if the one it went to fails, Z-Library is asked for links until one goes to another server (which doesn't count again)
   - For a book on Internet Archive, the list of its files is fetched instead, and the file in the best format for its file type is downloaded, e.g. a PDF of a scan's text rather than one of only its pictures
   - For a book in one of your libraries, its file's link in the catalogue is downloaded, logging in to its site where it asks to, and checked against how big the catalogue says it is
   - File size is read from the headers of the download itself for progress calculation, without a separate request
   - A curl process is spawned to download the file in the background, to a `.part` file next to where the book will be saved, so half a book never shows up in your library
   - A download that receives nothing for 30 seconds is tried again, carrying on from where it stopped rather than starting the book again, and given up on after two more tries
   - Progress widget updates every 0.5 seconds with percentage and file size information. Until the book starts to arrive, it says what it's waiting for: a download link, then the site, which can take several seconds to start sending the book. Once nothing has arrived for 10 seconds, it says the download has stalled
   - The device is kept from going to sleep while books download, as that turns Wi-Fi off: no standby between taps, and no suspending while it isn't used (by KOReader's AutoSuspend, or a Kindle's own screensaver), each put back as it was once the last download is over
   - Once it has arrived, the book is checked: by how it starts (rather than a web page sent in its place, or a file that isn't its file type), that all of it arrived, and, where the site lists its MD5 (Library Genesis and Internet Archive), that it's the very file listed, a piece at a time so KOReader carries on. One that isn't is downloaded again with another link where the site gives one (Z-Library), otherwise the download fails saying why
   - On completion, the `.part` file is renamed to the book's name, in the folder chosen in the download prompt, and the plugin offers to open it

5. **Error Handling & Resilience**
   - Wi-Fi is turned on before searching if it's off
   - When something fails for a reason with a fix, the message offers it, then tries again: Log in, Update curl, Use encrypted DNS, Turn on Wi-Fi, or Try again. The other sites are offered when a search finds nothing or fails
   - A download waits while the device sleeps or Wi-Fi is off, rather than failing as if the site had, then carries on from what had arrived, with the same link, once Wi-Fi is back (so Z-Library isn't asked for another, which can count as another download)
   - Everything goes through KOReader's HTTP proxy, where it's turned on (in KOReader's network settings or Kindle Fetch's), given to curl in a file rather than on its command line, as it can have a password in it. Empty or failed downloads are deleted
   - A library's login is only ever sent to its own site. It's given to curl in a file, never on its command line or in an address, with curl logging in whichever way the site asks: the Basic way, or the Digest way, as Calibre's content server does without HTTPS. KOReader's own HTTP can only log in the Basic way, so Kindle Fetch logs in the Digest way itself, following where the site sends requests itself, so the login doesn't go on with them. Covers on a library's site are downloaded apart from the rest, and passwords are never logged
   - A library on the network the device is on (e.g. at 192.168.1.10, or nas.local) is reached without encrypted DNS or the proxy, which can't find or reach it, and, with curl, given up on after 5 seconds without connecting, as it can be one that's only there at home. A library's site whose HTTPS certificate curl can't check isn't fetched with KOReader's own HTTP instead, as other sites are
   - Mirrors that answer with something other than Library Genesis are removed from cache; one that doesn't answer is tried after the others for an hour (and from then on, until it answers again), rather than removed, as it may only not have for a moment; if all cached URLs fail they are re-scraped from Wikipedia
   - When none of Library Genesis' sites can be found, though Wikipedia can, as when the network is blocking them, the plugin says so, rather than only that the last couldn't be found (see [Troubleshooting](#troubleshooting))
   - When Library Genesis' database is too busy for its mirrors to search or give download links, which they all say at once as they share it, the plugin says so, keeping the mirrors rather than looking them up again
   - The mirror that last answered a search or gave a download link is tried first from then on, rather than asking the ones before it, which may be too busy, every time
   - While the mirrors (or Z-Library's addresses) are tried in turn, the search's message or the download's progress says which is being tried, and why the one before didn't work: it couldn't be found, didn't answer, answered with an error, or sent something else. A site that takes the connection but sends nothing for 20 seconds is given up on, rather than waited for for a whole minute, and once every mirror has failed, only those that looking them up again finds are tried, rather than every one again
   - If Wikipedia answers without listing any mirrors (e.g. once its page has been rearranged), the mirrors known when the plugin was released are used, and when it can't be reached at all (e.g. where it's blocked), the mirrors looked up before, however long ago, or otherwise those known when the plugin was released
   - Only site names are accepted as mirrors, and a book cover whose address isn't a plain web address is left out, as Wikipedia can be edited by anyone and a mirror can send anything. Z-Library's addresses are only taken from the website row of its Wikipedia page, and only those named as its addresses have been (such as z-lib.sk or 1lib.sk), as your password is sent to them when logging in
   - User can cancel downloads at any time via the progress widget, and downloads are cancelled when KOReader closes (which it does when the device is powered off or restarted, or its storage is shared over USB, as well as when it exits), rather than curl carrying on, writing to the storage being shared
   - Curl exit codes are mapped to human-readable error messages, and what went wrong is shown in a message that stays until it's dismissed
   - A mistake in Kindle Fetch itself, in what KOReader runs later and doesn't catch errors in (such as checking on a download), is logged to crash.log with where it happened, and stops what was going on, cleaning up after it, rather than KOReader exiting

## Attribution

This plugin is forked from [justrals/KindleFetch](https://github.com/justrals/KindleFetch). It uses a similar underlying logic, but focuses on easy UX and simplicity. Anna's Archive isn't supported, as it now blocks automated access.

## License

MIT

## Disclaimer

This plugin facilitates downloading books from Library Genesis, Internet Archive, Project Gutenberg, Z-Library and your own libraries. Ensure you have the legal right to download any content and respect copyright laws in your jurisdiction. The authors assume no liability for misuse.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request with improvements, bug fixes, or new features.

See [DEVELOPMENT.md](DEVELOPMENT.md) for running KindleFetch on your computer (Linux), running the tests, and releasing.
