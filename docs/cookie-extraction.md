# Cookie Extraction for yt-dlp

This guide covers extracting YouTube cookies for use with the trailer download script. Cookies allow yt-dlp to access age-restricted content and appear as an authenticated user.

## Configuration

Set the `YT_DLP_COOKIE_FILE` variable in `scripts.conf` to the path of your cookie file:

```sh
YT_DLP_COOKIE_FILE="/path/to/cookies.txt"
```

The cookie file must be in Netscape format (the standard `.txt` format used by yt-dlp and most browser extensions).

## Method 1: Browser Extension (Cross-Platform, Recommended for Docker)

This method works on any operating system and is the best option for Docker users (extract on a desktop, copy the file to the container).

### Chrome / Edge / Brave / Opera (Chromium-based)

1. Install the "Get cookies.txt LOCALLY" extension (or similar "cookies.txt" extension)
   - Chrome Web Store: search for "Get cookies.txt"
   - Edge Add-ons: search for "cookies.txt"
2. Visit [youtube.com](https://www.youtube.com) and log in
3. Click the extension icon in your browser toolbar
4. Export cookies for the current site (youtube.com)
5. Save the `.txt` file to the path configured in `YT_DLP_COOKIE_FILE`

### Firefox

1. Install the "cookies.txt" extension
   - Firefox Add-ons: search for "cookies.txt"
2. Visit [youtube.com](https://www.youtube.com) and log in
3. Click the extension icon in the toolbar
4. Export cookies for the current site
5. Save the `.txt` file to the path configured in `YT_DLP_COOKIE_FILE`

### Safari (macOS)

1. Safari does not have a direct cookies.txt extension
2. Use Method 2 (yt-dlp self-export) with `--cookies-from-browser safari`
3. Or use a standalone tool like `safari-cookies-to-netscape` (search GitHub)

## Method 2: yt-dlp Self-Export (Requires Local Browser)

yt-dlp can read cookies directly from your browser's cookie store and write them to a file. This requires a local browser installation (not suitable for Docker containers).

### Linux

```sh
# Chrome
yt-dlp --cookies-from-browser chrome --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Firefox
yt-dlp --cookies-from-browser firefox --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Brave
yt-dlp --cookies-from-browser brave --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Chromium
yt-dlp --cookies-from-browser chromium --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

### macOS

```sh
# Chrome
yt-dlp --cookies-from-browser chrome --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Safari
yt-dlp --cookies-from-browser safari --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Firefox
yt-dlp --cookies-from-browser firefox --cookies /path/to/cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

### Windows

```sh
# Chrome
yt-dlp --cookies-from-browser chrome --cookies C:\path\to\cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Edge
yt-dlp --cookies-from-browser edge --cookies C:\path\to\cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Firefox
yt-dlp --cookies-from-browser firefox --cookies C:\path\to\cookies.txt "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
```

The URL at the end can be any YouTube video. yt-dlp reads the browser cookies and writes them to the file specified by `--cookies`.

## Docker Considerations

If running Radarr in a Docker container:

1. Extract cookies on a desktop machine using Method 1 (browser extension)
2. Copy the resulting `.txt` file to a path accessible inside the container
3. Mount the file as a volume (e.g., `-v /host/path/cookies.txt:/config/cookies.txt:ro`)
4. Set `YT_DLP_COOKIE_FILE=/config/cookies.txt` in your `scripts.conf`

Browser-based extraction (Method 2) will not work inside a Docker container as there is no browser installed.

## Cookie Refresh

YouTube cookies expire periodically. If you start seeing age-restriction errors again:

1. Re-export cookies using either method above
2. Replace the old cookie file with the new one
3. No script restart needed - the file is read on each download attempt

## Supported Browsers

| Browser | `--cookies-from-browser` name | Linux | macOS | Windows |
|---------|-------------------------------|-------|-------|---------|
| Chrome | `chrome` | Yes | Yes | Yes |
| Firefox | `firefox` | Yes | Yes | Yes |
| Safari | `safari` | No | Yes | No |
| Edge | `edge` | Yes | Yes | Yes |
| Brave | `brave` | Yes | Yes | Yes |
| Opera | `opera` | Yes | Yes | Yes |
| Chromium | `chromium` | Yes | Yes | Yes |
