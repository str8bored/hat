# mp4claw

A PowerShell-only YouTube/Vimeo MP4 downloader. No installs required. Windows 10+.

## Features

- **YouTube**: Downloads videos in the highest available quality (muxed or adaptive stream)
- **Vimeo**: Downloads videos via public API
- **Direct MP4 links**: Downloads any direct `.mp4` URL
- **FFmpeg merge**: Automatically merges video+audio streams when a muxed stream isn't available
- **Retry logic**: Exponential backoff on network failures (403, timeout, connection reset)
- **Universal URL detection**: Auto-detects YouTube, Vimeo, and generic MP4 links

## Usage

1. Ensure `ffmpeg.exe` is in the same folder (for adaptive stream merging)
2. Paste your URL(s) into `url.txt` (one per line)
3. Double-click `DOWNLOAD_NOW.bat`

Or run directly:

```powershell
powershell -ExecutionPolicy Bypass -File mp4claw.ps1
```

## How it works

1. **Detect** the URL type (YouTube, Vimeo, direct MP4, or generic HTML page)
2. **Extract** the best available stream (prefers muxed video+audio, falls back to adaptive)
3. **Download** the stream with proper headers (User-Agent, Referer)
4. **Merge** (if needed) using FFmpeg for adaptive streams
5. **Save** to the current directory with a safe filename

## Architecture

```
Resolve-Video
├── YouTube detection → Get-YouTubeFromPage → Select-BestAdaptiveStream
├── Vimeo detection → Vimeo API → proxy URL
├── Direct MP4 detection → download as-is
└── Generic HTML → Find-Mp4UrlsInText → best-scored URL
```

## Notes

- **403 errors** on YouTube are common — the script will retry with a muxed stream or adaptive stream
- **Adaptive streams** (video + audio separate) require FFmpeg to merge into a single MP4
- **Region-locked videos** will fail — the innertube API may not work in your region

## Version

1.0.1 — Added Vimeo support, adaptive stream detection, and retry logic
