# mp4claw.ps1 — PowerShell only, no installs. Windows 10+.
# Downloads MP4 files from YouTube, Vimeo, Rumble, and direct URLs.
# Rumble API Key: set $env:RUMBLE_API_KEY or use the bundled key.
# Features: progress bar, dry-run mode, circuit breaker, circuit breaker, circuit breaker
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

function Write-Status { Write-Host $Message }

function Write-ProgressBar {
    param(
        [string]$Filename,
        [int]$CurrentBytes,
        [int]$TotalBytes,
        [string]$Status = 'Downloading...'
    )
    $barLength = 50
    $filled = [int]($barLength * $CurrentBytes / $TotalBytes)
    $empty = $barLength - $filled
    $bar = "#" * $filled + "-" * $empty
    $percentStr = "{0:P1}" -f ($CurrentBytes / $TotalBytes)
    $mb = $CurrentBytes / 1MB
    $totalMB = $TotalBytes / 1MB
    Write-Host "  [$bar] $percentStr $mb MB / $totalMB MB - $Status" -NoNewline -ForegroundColor Cyan
    Write-Host $Filename -NoNewline
    Write-Host " ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Gray
}

function Write-ProgressBarStart([string]$Filename) {
    Write-Host "  [STARTING] $Filename" -ForegroundColor Cyan
}

function Write-ProgressBarComplete([string]$Filename) {
    Write-Host "  [COMPLETE] $Filename" -ForegroundColor Green
}

function Clear-ProgressLine {
    $host.UI.RawUI.WindowTitle = $host.UI.RawUI.WindowTitle
    $host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size 100 100
}

function Write-ProgressWithBar([string]$Filename, [int]$CurrentBytes, [int]$TotalBytes, [string]$Status = 'Downloading...') {
    if ($TotalBytes -gt 0) {
        $percent = $CurrentBytes / $TotalBytes
        $barLength = 50
        $filled = [int]($barLength * $percent)
        $empty = $barLength - $filled
        $bar = "#" * $filled + "-" * $empty
        $percentStr = "{0:P1}" -f $percent
        $mb = $CurrentBytes / 1MB
        $totalMB = $TotalBytes / 1MB
        Write-Host "  [$bar] $percentStr $mb MB / $totalMB MB - $Status" -NoNewline -ForegroundColor Cyan
        Write-Host $Filename -NoNewline
        Write-Host " ($(Get-Date -Format 'HH:mm:ss'))" -ForegroundColor Gray
    } else {
        Write-Host "  [STARTING] $Filename (size unknown)" -ForegroundColor Cyan
    }
}

$ProgressId = 1

function Show-Mp4ClawBanner {
    $banner = @'
 _____ ______   ________  ___   ___  ________  ___       ________  ___       __      
|\   _ \  _   \|\   __  \|\  \ |\  \|\   ____\|\  \     |\   __  \|\  \     |\  \    
\ \  \\\__\ \  \ \  \|\  \ \  \\_\  \ \  \___|\ \  \    \ \  \|\  \ \  \    \ \  \   
 \ \  \\|__| \  \ \   ____\ \______  \ \  \    \ \  \    \ \   __  \ \  \  __\ \  \  1.0.1
  \ \  \    \ \  \ \  \___|\|_____|\  \ \  \____\ \  \____\ \  \ \  \ \  \|\__\_\  \ 
   \ \__\    \ \__\ \__\          \ \__\ \_______\ \_______\ \__\ \__\ \____________\
    \|__|     \|__|\|__|           \|__|\|_______|\|_______|\|__|\|__|\|____________|
'@
    Write-Host ''
    Write-Host $banner -ForegroundColor DarkCyan
    Write-Host ''
}

function Get-SafeFileName([string]$Name) {
    $n = ($Name -replace '[<>:"/\\|?*\x00-\x1f]', '').Trim()
    if (-not $n) { $n = 'video' }
    if ($n.Length -gt 180) { $n = $n.Substring(0, 180) }
    return $n
}

function Get-UniquePath([string]$Dir, [string]$BaseName) {
    $path = Join-Path $Dir ($BaseName + '.mp4')
    if (-not (Test-Path -LiteralPath $path)) { return $path }
    for ($i = 2; $i -lt 1000; $i++) {
        $path = Join-Path $Dir ($BaseName + " ($i).mp4")
        if (-not (Test-Path -LiteralPath $path)) { return $path }
    }
    return Join-Path $Dir ($BaseName + " $(Get-Date -Format 'yyyyMMddHHmmss').mp4")
}

function Get-ErrorCategory([string]$Message) {
    if ($Message -match '403|Forbidden') { return 'Forbidden' }
    if ($Message -match 'timeout|timed out|operation.*timed out') { return 'Timeout' }
    if ($Message -match 'connection.*reset|connection.*refused|connection.*closed') { return 'ConnectionReset' }
    if ($Message -match 'DNS|DNS lookup|could not resolve') { return 'DNS' }
    if ($Message -match 'SSL|certificate|ssl') { return 'SSL' }
    if ($Message -match 'request.*failed|failed to connect') { return 'ConnectionFailed' }
    if ($Message -match '404|Not Found') { return 'NotFound' }
    return 'Unknown'
}

function Get-RumbleApiKey([string]$ApiKey) {
    if (-not $ApiKey) {
        $ApiKey = if ($env:RUMBLE_API_KEY) { $env:RUMBLE_API_KEY } else { '22b1f667-6881-4828-8c77-53fb229be448' }
    }
    return $ApiKey
}

function Get-RumbleStreams([string]$VideoId) {
    $apiKey = Get-RumbleApiKey
    try {
        $json = Invoke-WebRequest -Uri "https://api.rumble.com/v2/videos/$VideoId" -Method Get -Headers @{ 'X-RUM-APITOKEN' = $apiKey } -TimeoutSec 30 | ConvertFrom-Json
    } catch {
        Write-Status "Rumble API error: $($_.Exception.Message)"
        return $null
    }

    $streams = [System.Collections.ArrayList]@()
    if ($json.video -and $json.video.video_versions) {
        foreach ($v in $json.video.video_versions) {
            if ($v.mime_type -match 'video/[mvp][a-z]+') {
                [void]$streams.Add($v) | Out-Null
            }
        }
    }
    return $streams
}

function Select-BestRumbleVideo($RumbleJson) {
    $candidates = foreach ($s in (Get-RumbleStreams $RumbleJson)) {
        if (-not $s) { continue }
        $u = if ($s.url) { $s.url } else { $null }
        if (-not $u) { continue }
        $m = @{
            Height  = if ($s.height) { [int]$s.height } else { 0 }
            Width   = if ($s.width) { [int]$s.width } else { 0 }
            Bitrate = if ($s.filesize) { [int]$s.filesize / 1024 } else { 0 }
            ContentLength = if ($s.filesize) { [long]$s.filesize } else { 0 }
            HasAudio  = $s.audio_info
            QualityLabel = if ($s.height) { "${$s.height}p" } else { "${$s.width}x${$s.height}" }
        }
        [pscustomobject]@{ Url=$u; Mime=$s.mime_type; Height=$m.Height; Width=$m.Width; Bitrate=$m.Bitrate; ContentLength=$m.ContentLength; HasAudio=$m.HasAudio; QualityLabel=$m.QualityLabel }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Height, Width, Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestRumbleAudio($RumbleJson) {
    $candidates = foreach ($s in (Get-RumbleStreams $RumbleJson)) {
        if (-not $s) { continue }
        $u = if ($s.url) { $s.url } else { $null }
        if (-not $u) { continue }
        $m = @{
            Bitrate = if ($s.filesize) { [int]$s.filesize / 1024 } else { 0 }
            ContentLength = if ($s.filesize) { [long]$s.filesize } else { 0 }
            QualityLabel = if ($s.height) { "${$s.height}p" } else { "${$s.width}x${$s.height}" }
        }
        [pscustomobject]@{ Url=$u; Mime=$s.mime_type; Bitrate=$m.Bitrate; ContentLength=$m.ContentLength; QualityLabel=$m.QualityLabel }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestRumbleMuxed($RumbleJson) {
    $candidates = foreach ($s in (Get-RumbleStreams $RumbleJson)) {
        if (-not $s) { continue }
        $u = if ($s.url) { $s.url } else { $null }
        if (-not $u) { continue }
        $m = @{
            Height  = if ($s.height) { [int]$s.height } else { 0 }
            Width   = if ($s.width) { [int]$s.width } else { 0 }
            Bitrate = if ($s.filesize) { [int]$s.filesize / 1024 } else { 0 }
            ContentLength = if ($s.filesize) { [long]$s.filesize } else { 0 }
            HasAudio  = $s.audio_info
            QualityLabel = if ($s.height) { "${$s.height}p" } else { "${$s.width}x${$s.height}" }
        }
        if (-not $m.HasAudio) { continue }
        [pscustomobject]@{ Url=$u; Height=$m.Height; Bitrate=$m.Bitrate; ContentLength=$m.ContentLength; QualityLabel=$m.QualityLabel }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Height, Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestRumbleAdaptive($RumbleJson) {
    $muxed = Select-BestRumbleMuxed $RumbleJson
    if ($muxed) { return $muxed }

    Write-Status "No muxed stream found. Searching for adaptive video+audio..."
    $video = Select-BestRumbleVideo $RumbleJson
    if (-not $video) {
        Write-Status "No video stream available."
        return $null
    }
    $audio = Select-BestRumbleAudio $RumbleJson
    if (-not $audio) {
        Write-Status "No audio stream available. Video-only stream selected."
        return $video
    }
    return @{ Merge=$true; VideoUrl=$video.Url; AudioUrl=$audio.Url; Title=$video.QualityLabel; Height=$video.Height; Width=$video.Width; Bitrate=$video.Bitrate; ContentLength=$video.ContentLength }
}

function Resolve-Rumble([string]$VideoId) {
    $json = Get-RumbleStreams -VideoId $VideoId
    if (-not $json) { throw "Rumble: could not retrieve video data."
    }
    $muxed = Select-BestRumbleMuxed $json
    if ($muxed) {
        return @{ Merge=$false; Mp4Url=$muxed.Url; Title=$muxed.QualityLabel; Referer="https://rumble.com/v${VideoId}"; Ua=$UserAgent }
    }
    Write-Status 'No muxed stream available. Searching for adaptive stream...'
    $adaptive = Select-BestRumbleAdaptive $json
    if ($adaptive) {
        return @{ Merge=$adaptive.Merge; VideoUrl=$adaptive.VideoUrl; AudioUrl=$adaptive.AudioUrl; Title=$adaptive.Title; Referer="https://rumble.com/v${VideoId}"; Ua=$UserAgent }
    }
    $video = Select-BestRumbleVideo $json
    if ($video) {
        return @{ Merge=$false; Mp4Url=$video.Url; Title=$video.QualityLabel; Referer="https://rumble.com/v${VideoId}"; Ua=$UserAgent }
    }
    throw "Rumble: could not find any playable stream for video $VideoId"
}

function Resolve-Video([string]$Link) {
    if ($Link -notmatch '^https?://') { throw 'Link must start with http:// or https://' }

    # YouTube
    if ($Link -match '(?:youtu\.be\/|youtube\.com\/embed\/|youtube\.com\/shorts\/)([^?&\/]+)') {
        $vid = $Matches[1]
        Write-Status "YouTube link detected: $vid"
        $watch = "https://www.youtube.com/watch?v=$vid"
        $yt = Get-YouTubeFromPage -VideoId $vid -WatchUrl $watch
        if (-not $yt) { throw "YouTube: could not get a playable MP4 URL (video may be restricted or region-locked)." }
        return Resolve-YouTube $yt $vid
    }

    # Vimeo
    if ($Link -match 'vimeo\.com\/(?:channels\/[^\/]+\/)?videos\/(\d+)') {
        $vid = $Matches[1]
        Write-Status "Vimeo link detected: $vid"
        try {
            $json = Invoke-WebRequest -Uri "https://vimeo.com/api/oembed.json?url=https://vimeo.com/$vid" -Method Post -Body '{"url":"https://vimeo.com/$vid"}' -ContentType 'application/json' -TimeoutSec 30 | ConvertFrom-Json
        } catch {
            throw "Vimeo API request failed: $($_.Exception.Message)"
        }
        if (-not $json -or -not $json.video) { throw "Vimeo: could not retrieve video data." }
        $videoUrl = $json.video
        if ($videoUrl -match 'vimeo\.com\/proxy\/file\/([a-zA-Z0-9]+)\.(mp4|webm)') {
            $streamId = $Matches[1]; $ext = $Matches[2]
            $streamUrl = "https://player.vimeo.com/external/$streamId.$ext"
            Write-Status "Vimeo stream URL: $streamUrl"
            return @{ Merge=$false; Mp4Url=$streamUrl; Title=$json.title; Referer=$Link; Ua=$UserAgent }
        }
        throw "Vimeo: could not find direct MP4 stream. Video URL: $($json.video)"
    }

    # Rumble
    if ($Link -match 'rumble\.com\/v\/([a-zA-Z0-9]+)') {
        $videoId = $Matches[1]
        Write-Status "Rumble link detected: $videoId"
        $rumbleResult = Resolve-Rumble $videoId
        return $rumbleResult
    }

    # Direct .mp4 URL
    if ($Link -match '\.mp4($|[?&])') {
        Write-Status "Direct MP4 URL detected"
        return @{ Merge=$false; Mp4Url=$Link; Title=Get-PageTitle $Link; Referer=$Link; Ua=$UserAgent }
    }

    # Generic HTML page — scrape for .mp4 URLs
    Write-Status "Generic page detected, scraping for .mp4 links..."
    $html = Invoke-WebText -Url $Link
    $urls = Find-Mp4UrlsInText -Text $html -PageUrl $Link
    if ($urls.Count -eq 0) {
        throw "No .mp4 URL found in page HTML. Try pasting a direct .mp4 link or a supported video site URL."
    }

    $scored = foreach ($u in $urls) {
        $score = 0
        if ($u -match '(?:^|[\/?&])(2160|4k)(?:[p_\/ -]|$)') { $score = 2160 }
        elseif ($u -match '(?:^|[\/?&])1440(?:[p_\/ -]|$)') { $score = 1440 }
        elseif ($u -match '(?:^|[\/?&])1080(?:[p_\/ -]|$)') { $score = 1080 }
        elseif ($u -match '(?:^|[\/?&])720(?:[p_\/ -]|$)') { $score = 720 }
        elseif ($u -match '(?:^|[\/?&])480(?:[p_\/ -]|$)') { $score = 480 }
        elseif ($u -match '(?:^|[\/?&])360(?:[p_\/ -]|$)') { $score = 360 }
        [pscustomobject]@{ Url=$u; Score=$score; Len=$u.Length }
    }
    $best = ($scored | Sort-Object Score, Len -Descending | Select-Object -First 1).Url
    $title = Get-PageTitle $html
    if ($title -eq 'video') {
        try { $leaf = [uri]::new($best).Segments[-1] -replace '\.mp4.*$', ''; if ($leaf) { $title = [uri]::UnescapeDataString($leaf) } } catch { }
    }
    return @{ Merge=$false; Mp4Url=$best; Title=$title; Referer=$Link; Ua=$UserAgent }
}

function Get-ErrorMessage([string]$Category, [string]$OriginalMessage) {
    switch ($Category) {
        'Forbidden' { return "YouTube/Vimeo is blocking this video. Try: watching from a different network, using a VPN, or checking if the video is region-locked." }
        'Timeout' { return "Request timed out. The server may be slow or overloaded. Retrying with increased delay..." }
        'ConnectionReset' { return "Connection was reset by the server. This often happens with anti-bot measures. Retrying..." }
        'DNS' { return "Could not resolve the host. Check your internet connection and DNS settings." }
        'SSL' { return "SSL/TLS error connecting to the server. Your system may need updated root certificates." }
        'ConnectionFailed' { return "Could not establish connection to the server." }
        'NotFound' { return "The requested resource was not found. The URL may be invalid or the video was deleted." }
        'Unknown' { return $OriginalMessage }
    }
}

# Circuit breaker state
$CircuitBreakerOpen = $false
$CircuitBreakerFailures = 0
$CircuitBreakerResetSeconds = 30

function Set-CircuitBreakerOpen([string]$Url) {
    global $CircuitBreakerOpen, $CircuitBreakerFailures
    $CircuitBreakerOpen = $true
    $CircuitBreakerFailures++
    $cbFile = Join-Path $env:TEMP ".mp4claw_cb_${Url.GetHashCode()}"
    [System.IO.File]::WriteAllText($cbFile, (Get-Date -Format 'O'), [System.Text.Encoding]::UTF8)
    if ($CircuitBreakerFailures -ge 3) {
        Write-Status "WARNING: Circuit breaker OPEN after $CircuitBreakerFailures consecutive failures. Skipping $Url."
        Write-Status "  Circuit will reset after $CircuitBreakerResetSeconds seconds."
    }
}

function Clear-CircuitBreaker([string]$Url) {
    global $CircuitBreakerFailures
    $cbFile = Join-Path $env:TEMP ".mp4claw_cb_${Url.GetHashCode()}"
    if (Test-Path $cbFile) {
        Remove-Item $cbFile -Force -ErrorAction SilentlyContinue
    }
    $CircuitBreakerFailures = 0
}

function Invoke-WebText([string]$Url, [hashtable]$ExtraHeaders = @{}) {
    $headers = @{
        'User-Agent' = $UserAgent
        'Accept'     = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
    }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 10 -Headers $headers -TimeoutSec 60
    return [string]$resp.Content
}

function Invoke-WebJson([string]$Url, [string]$BodyJson, [hashtable]$ExtraHeaders = @{}) {
    $headers = @{
        'User-Agent'     = $UserAgent
        'Accept'         = 'application/json'
        'Content-Type'   = 'application/json'
        'Origin'         = 'https://www.youtube.com'
        'Accept-Language' = 'en-US,en;q=0.9'
    }
    foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }
    $resp = Invoke-WebRequest -Uri $Url -Method Post -Body $BodyJson -UseBasicParsing -Headers $headers -TimeoutSec 60
    return $resp.Content | ConvertFrom-Json
}

function Resolve-AbsoluteUrl([string]$Base, [string]$MaybeRelative) {
    try { return ([uri]$MaybeRelative, [uri]$Base).AbsoluteUri } catch { return $null }
}
function Find-Mp4UrlsInText([string]$Text, [string]$PageUrl) {
    $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $patterns = @'
https?:\/\/[^\s"\'\t<>]+\.mp4(?:\?[^\s"\'\t<>]*)?
(?:src|href)\s*=\s*["\']([^"\'\']+\.mp4[^"\'\']*)["\']
["\']([^"\'\']+\.mp4(?:\?[^"\'\']*)?)["\']
(https?:\/\/[^\s"\'\t<>]+\.mp4)
'@
    foreach ($pat in $patterns) {
        $reg = [regex]::Create($pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $reg.Matches($Text) | ForEach-Object {
            $raw = if ($_.Groups.Count -gt 1 -and $_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Value }
            $raw = $raw -replace '\u0026', '&' -replace '\u002F', '/' -replace '&amp;', '&'
            try {
                $abs = [uri]::new($PageUrl).CombineUri($raw)
                if ($abs -and $abs -match '\.mp4(\?|$)') { [void]$found.Add($abs) }
            } catch { }
        }
    }
    return @($found)
}
    return $null
}

function Get-JsonFromHtml([string]$Html, [string]$Marker) {
    $idx = $Html.IndexOf($Marker)
    if ($idx -lt 0) { return $null }
    $start = $Html.IndexOf('{', $idx)
    if ($start -lt 0) { return $null }
    $depth = 0
    $inStr = $false
    $esc = $false
    for ($i = $start; $i -lt $Html.Length; $i++) {
        $c = $Html[$i]
        if ($inStr) {
            if ($esc) { $esc = $false; continue }
            if ($c -eq '\') { $esc = $true; continue }
            if ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                $json = $Html.Substring($start, $i - $start + 1)
                try { return $json | ConvertFrom-Json } catch { return $null }
            }
        }
    }
    return $null
}
function Get-YouTubeApiKey([string]$Html) {
    $pat = @"INNERTUBE_API_KEY["']\s*:\s*["']([^"']+)["']"@
    if ($Html -match $pat) { return $Matches[1] }
    if ($Html -match '"INNERTUBE_API_KEY":"([^"]+)"') { return $Matches[1] }
    return 'AIzaSyAO_FJ2SlBJIZkbvQwKc8yS3csKTCNZpGw'
}

function Get-InnertubeClients() {
    @(
        @{ clientName='ANDROID'; clientVersion='20.10.38'; userAgent='com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip'; needsKey=$false },
        @{ clientName='ANDROID_VR'; clientVersion='1.60.19'; userAgent='com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12) gzip'; needsKey=$false },
        @{ clientName='IOS'; clientVersion='20.10.38'; userAgent='com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X)'; needsKey=$false },
        @{ clientName='TVHTML5_SIMPLY_EMBEDDED_PLAYER'; clientVersion='2.0'; userAgent=$UserAgent; needsKey=$true },
        @{ clientName='WEB'; clientVersion='2.20250224.01.00'; userAgent=$UserAgent; needsKey=$true }
    )
}

function Get-FormatDirectUrl($Format) {
    if ($Format.PSObject.Properties['url'] -and $Format.url) { return [string]$Format.url }
    if ($Format.signatureCipher) {
        $q = @{}
        foreach ($pair in ($Format.signatureCipher -split '&')) {
            if ($pair -match '^([^=]+)=(.*)$') { $q[$Matches[1]] = [uri]::UnescapeDataString($Matches[2]) }
        }
        if ($q.url) { return [string]$q.url }
    }
    return $null
}

function Get-YouTubeStreams($PlayerJson) {
    $streams = [System.Collections.ArrayList]@()
    if ($PlayerJson.streamingData.formats) {
        foreach ($f in $PlayerJson.streamingData.formats) { [void]$streams.Add($f) }
    }
    if ($PlayerJson.streamingData.adaptiveFormats) {
        foreach ($f in $PlayerJson.streamingData.adaptiveFormats) { [void]$streams.Add($f) }
    }
    return $streams
}

function Get-StreamMetrics($Stream) {
    $br = 0
    if ($Stream.bitrate) { $br = [int]$Stream.bitrate }
    elseif ($Stream.averageBitrate) { $br = [int]$Stream.averageBitrate }
    return @{
        Height        = if ($Stream.height) { [int]$Stream.height } else { 0 }
        Width         = if ($Stream.width) { [int]$Stream.width } else { 0 }
        Bitrate       = $br
        ContentLength = if ($Stream.contentLength) { [long]$Stream.contentLength } else { 0 }
        HasAudio      = ($null -ne $Stream.audioQuality) -or ($Stream.mimeType -match 'mp4a')
        QualityLabel  = $Stream.qualityLabel
    }
}

function Select-BestYouTubeVideo($PlayerJson) {
    $candidates = foreach ($s in (Get-YouTubeStreams $PlayerJson)) {
        $u = Get-FormatDirectUrl $s
        if (-not $u) { continue }
        if ($s.mimeType -notmatch 'video\/mp4') { continue }
        $m = Get-StreamMetrics $s
        [pscustomobject]@{
            Url           = $u; Mime=$s.mimeType; Height=$m.Height; Width=$m.Width
            Bitrate       = $m.Bitrate; ContentLength=$m.ContentLength
            HasAudio      = $m.HasAudio; QualityLabel=$m.QualityLabel
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Height, Width, Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestYouTubeAudio($PlayerJson) {
    $candidates = foreach ($s in (Get-YouTubeStreams $PlayerJson)) {
        $u = Get-FormatDirectUrl $s
        if (-not $u) { continue }
        if ($s.mimeType -notmatch 'audio\/(mp4|mpeg)') { continue }
        $m = Get-StreamMetrics $s
        [pscustomobject]@{
            Url           = $u; Mime=$s.mimeType; Bitrate=$m.Bitrate; ContentLength=$m.ContentLength
            QualityLabel  = $m.QualityLabel
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestYouTubeMuxed($PlayerJson) {
    $candidates = foreach ($s in (Get-YouTubeStreams $PlayerJson)) {
        $u = Get-FormatDirectUrl $s
        if (-not $u) { continue }
        if ($s.mimeType -notmatch 'video\/mp4') { continue }
        $m = Get-StreamMetrics $s
        if (-not $m.HasAudio) { continue }
        [pscustomobject]@{
            Url           = $u; Height=$m.Height; Bitrate=$m.Bitrate; ContentLength=$m.ContentLength
            QualityLabel  = $m.QualityLabel
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Height, Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestAdaptiveStream($PlayerJson) {
    $muxed = Select-BestYouTubeMuxed $PlayerJson
    if ($muxed) { return $muxed }

    Write-Status "No muxed stream found. Searching for adaptive video+audio..."
    $video = Select-BestYouTubeVideo $PlayerJson
    if (-not $video) {
        Write-Status "No video stream available."
        return $null
    }
    $audio = Select-BestYouTubeAudio $PlayerJson
    if (-not $audio) {
        Write-Status "No audio stream available. Video-only stream selected."
        return $video
    }
    return @{
        Merge     = $true; VideoUrl=$video.Url; AudioUrl=$audio.Url
        Title     = $video.QualityLabel; Height=$video.Height; Width=$video.Width
        Bitrate   = $video.Bitrate; ContentLength=$video.ContentLength
    }
}

function Get-AdaptiveUrl($VideoStream, $AudioStream) {
    $videoCipher = $VideoStream.signatureCipher
    $audioCipher = $AudioStream.signatureCipher
    if ($videoCipher -and $videoCipher -ne $null) {
        $cipherParams = $videoCipher -split '&'
        $cipherMap = @{}
        foreach ($pair in $cipherParams) {
            if ($pair -match '^([^=]+)=(.*)$') {
                $cipherMap[$Matches[1]] = [uri]::UnescapeDataString($Matches[2])
            }
        }
        try {
            $cipherText = [uri]::UnescapeDataString($cipherMap.sig)
            $sig = [Convert]::FromBase64String($cipherText)
            $s = [Convert]::FromBase64String($cipherMap.s)
            $decoded = [System.Text.Encoding]::UTF8.GetString($s -bor $sig)
            return [uri]::UnescapeDataString($decoded)
        } catch {
            if ($cipherMap.url) { return [uri]::UnescapeDataString($cipherMap.url) }
        }
    }
    return $VideoStream.url
}

function Test-IsHttp403([object]$Err) {
    $ex = $Err.Exception
    while ($ex) {
        if ($ex -is [System.Net.WebException] -and $ex.Response) {
            if ([int]$ex.Response.StatusCode -eq 403) { return $true }
        }
        if ($ex.Message -match '\(403\)|Forbidden') { return $true }
        $ex = $ex.InnerException
    }
    return $false
}

function Get-FreshYouTubeJson([string]$VideoId) {
    $watch = "https://www.youtube.com/watch?v=$VideoId"
    $yt = Get-YouTubeFromPage -VideoId $VideoId -WatchUrl $watch
    if ($yt) { return $yt.Json }
    return $null
}

function Invoke-MuxedFallback([object]$Info, [string]$OutPath, [string]$Referer, [string]$Ua) {
    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force -ErrorAction SilentlyContinue }
    Write-Status '403 Forbidden because of course it is... retrying with my best haxxor skills this time...'
    $json = $Info.YouTubeJson
    $muxed = Select-BestYouTubeMuxed $json
    if (-not $muxed -and $Info.VideoId) {
        Write-Status 'Refreshing stream list...'
        $json = Get-FreshYouTubeJson $Info.VideoId
        if ($json) { $muxed = Select-BestYouTubeMuxed $json }
    }
    if (-not $muxed) { throw '403 Forbidden and no muxed MP4 stream available.' }
    $label = if ($muxed.QualityLabel) { $muxed.QualityLabel } else { "$($muxed.Height)p" }
    Write-Status "secret video unlocked: $label"
    try {
        Save-RemoteFile -Url $muxed.Url -OutPath $OutPath -Referer $Referer -Ua $Ua
    } catch {
        if ((Test-IsHttp403 $_) -and $Info.VideoId) {
            Write-Status 'Retrying muxed download with refreshed URLs...'
            $json = Get-FreshYouTubeJson $Info.VideoId
            $muxed = Select-BestYouTubeMuxed $json
            if (-not $muxed) { throw }
            Save-RemoteFile -Url $muxed.Url -OutPath $OutPath -Referer $Referer -Ua $UserAgent
            return
        }
        throw
    }
}

function Invoke-Download([object]$Info, [string]$OutPath) {
    $referer = if ($Info.Referer) { $Info.Referer } else { '' }
    $ua = if ($Info.Ua) { $Info.Ua } else { $UserAgent }
    try {
        if ($Info.Merge) {
            $tempV = Join-Path $env:TEMP ("mp4claw_v_{0}.mp4" -f [guid]::NewGuid().ToString('N'))
            $tempA = Join-Path $env:TEMP ("mp4claw_a_{0}.m4a" -f [guid]::NewGuid().ToString('N'))
            try {
                Write-Status 'heh downloading video stream...'
                Save-RemoteFile -Url $info.VideoUrl -OutPath $tempV -Referer $referer -Ua $ua
                Write-Status 'Downloading audio stream...'
                Save-RemoteFile -Url $info.AudioUrl -OutPath $tempA -Referer $referer -Ua $ua
                Write-Status 'Merging to MP4...'
                Merge-WithFfmpeg -VideoPath $tempV -AudioPath $tempA -OutPath $outPath
            } finally {
                foreach ($t in @($tempV, $tempA)) {
                    if ($t -and (Test-Path -LiteralPath $t)) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
                }
            }
        } else {
            Save-RemoteFile -Url $Info.Mp4Url -OutPath $OutPath -Referer $referer -Ua $ua
        }
    } catch {
        if ((Test-IsHttp403 $_) -and $Info.YouTubeJson) {
            Invoke-MuxedFallback -Info $Info -OutPath $OutPath -Referer $referer -Ua $ua
            return
        }
        throw
    }
}

function Resolve-Video([string]$Link) {
    if ($Link -notmatch '^https?://') { throw 'Link must start with http:// or https://' }

    # YouTube
    if ($Link -match '(?:youtu\.be\/|youtube\.com\/embed\/|youtube\.com\/shorts\/)([^?&\/]+)') {
        $vid = $Matches[1]
        Write-Status "YouTube link detected: $vid"
        $watch = "https://www.youtube.com/watch?v=$vid"
        $yt = Get-YouTubeFromPage -VideoId $vid -WatchUrl $watch
        if (-not $yt) { throw "YouTube: could not get a playable MP4 URL (video may be restricted or region-locked)." }
        return Resolve-YouTube $yt $vid
    }

    # Vimeo
    if ($Link -match 'vimeo\.com\/(?:channels\/[^\/]+\/)?videos\/(\d+)') {
        $vid = $Matches[1]
        Write-Status "Vimeo link detected: $vid"
        try {
            $json = Invoke-WebRequest -Uri "https://vimeo.com/api/oembed.json?url=https://vimeo.com/$vid" -Method Post -Body '{"url":"https://vimeo.com/$vid"}' -ContentType 'application/json' -TimeoutSec 30 | ConvertFrom-Json
        } catch {
            throw "Vimeo API request failed: $($_.Exception.Message)"
        }
        if (-not $json -or -not $json.video) { throw "Vimeo: could not retrieve video data." }
        $videoUrl = $json.video
        if ($videoUrl -match 'vimeo\.com\/proxy\/file\/([a-zA-Z0-9]+)\.(mp4|webm)') {
            $streamId = $Matches[1]; $ext = $Matches[2]
            $streamUrl = "https://player.vimeo.com/external/$streamId.$ext"
            Write-Status "Vimeo stream URL: $streamUrl"
            return @{ Merge=$false; Mp4Url=$streamUrl; Title=$json.title; Referer=$Link; Ua=$UserAgent }
        }
        throw "Vimeo: could not find direct MP4 stream. Video URL: $($json.video)"
    }

    # Direct .mp4 URL
    if ($Link -match '\.mp4($|[?&])') {
        Write-Status "Direct MP4 URL detected"
        return @{ Merge=$false; Mp4Url=$Link; Title=Get-PageTitle $Link; Referer=$Link; Ua=$UserAgent }
    }

    # Generic HTML page â€” scrape for .mp4 URLs
    Write-Status "Generic page detected, scraping for .mp4 links..."
    $html = Invoke-WebText -Url $Link
    $urls = Find-Mp4UrlsInText -Text $html -PageUrl $Link
    if ($urls.Count -eq 0) {
        throw "No .mp4 URL found in page HTML. Try pasting a direct .mp4 link or a supported video site URL."
    }

    $scored = foreach ($u in $urls) {
        $score = 0
        if ($u -match '(?:^|[\/?&])(2160|4k)(?:[p_\/-]|$)') { $score = 2160 }
        elseif ($u -match '(?:^|[\/?&])1440(?:[p_\/-]|$)') { $score = 1440 }
        elseif ($u -match '(?:^|[\/?&])1080(?:[p_\/-]|$)') { $score = 1080 }
        elseif ($u -match '(?:^|[\/?&])720(?:[p_\/-]|$)') { $score = 720 }
        elseif ($u -match '(?:^|[\/?&])480(?:[p_\/-]|$)') { $score = 480 }
        elseif ($u -match '(?:^|[\/?&])360(?:[p_\/-]|$)') { $score = 360 }
        [pscustomobject]@{ Url=$u; Score=$score; Len=$u.Length }
    }
    $best = ($scored | Sort-Object Score, Len -Descending | Select-Object -First 1).Url
    $title = Get-PageTitle $html
    if ($title -eq 'video') {
        try { $leaf = [uri]::new($best).Segments[-1] -replace '\.mp4.*$', ''; if ($leaf) { $title = [uri]::UnescapeDataString($leaf) } } catch { }
    }
    return @{ Merge=$false; Mp4Url=$best; Title=$title; Referer=$Link; Ua=$UserAgent }
}

function Get-UrlsToProcess {
    $dryRun = $false
    if ($args -match '^--dry-run$') { $dryRun = $true }

    if ($dryRun) {
        Write-Host 'mp4claw (Dry Run Mode)' -ForegroundColor DarkCyan
        Write-Host '========================' -ForegroundColor DarkCyan
        $allArgs = @()
        $currentArg = $null
        foreach ($a in $args) {
            if ($a -match '^--?[^ ]+' -or $a -match '^-') {
                if ($currentArg) { $allArgs += $currentArg }
                $currentArg = $a
            } else {
                if ($currentArg) { $allArgs += $currentArg + ' ' + $a }
                $currentArg = $a
            }
        }
        if ($currentArg) { $allArgs += $currentArg }
        return $allArgs | Where-Object { $_ -and $_ -notmatch '^\s*#' }
    }

    Write-Status "Processing $([int]$args.Count) URL(s) from command line..."
    $allArgs = @()
    $currentArg = $null
    foreach ($a in $args) {
        if ($a -match '^--?[^ ]+' -or $a -match '^-') {
            if ($currentArg) { $allArgs += $currentArg }
            $currentArg = $a
        } else {
            if ($currentArg) { $allArgs += $currentArg + ' ' + $a }
            $currentArg = $a
        }
    }
    if ($currentArg) { $allArgs += $currentArg }
    return $allArgs | Where-Object { $_ -and $_ -notmatch '^\s*#' }
}

function Get-PageTitle([string]$Html) {
    if ($Html -match '<title>(.*?)</title>') { return $Matches[1] }
    return 'video'
}

function Get-PageTitle([string]$Url) {
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        return Get-PageTitle $resp.Content
    } catch { return 'video' }
}

function Save-RemoteFile([string]$Url, [string]$OutPath, [string]$Referer = '', [string]$Ua = $UserAgent) {
    $headers = @{ 'User-Agent' = $Ua }
    if ($Referer) { $headers['Referer'] = $Referer }
    $stream = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $reader = [System.Net.WebClient]::new()
    try { $reader.DownloadFile($Url, $stream) } finally { $stream.Close(); $reader.Dispose() }
}

function Resolve-YouTube($yt, [string]$VideoId) {
    $json = $yt.Json
    $muxed = Select-BestYouTubeMuxed $json
    if ($muxed) {
        return @{ Merge=$false; Mp4Url=$muxed.Url; Title=$muxed.QualityLabel; Referer="https://www.youtube.com/watch?v=$VideoId"; Ua=$UserAgent }
    }
    Write-Status 'No muxed stream available. Searching for adaptive stream...'
    $adaptive = Select-BestAdaptiveStream $json
    if ($adaptive) {
        return @{ Merge=$adaptive.Merge; VideoUrl=$adaptive.VideoUrl; AudioUrl=$adaptive.AudioUrl
                  Title=$adaptive.Title; Referer="https://www.youtube.com/watch?v=$VideoId"; Ua=$UserAgent }
    }
    $video = Select-BestYouTubeVideo $json
    if ($video) {
        return @{ Merge=$false; Mp4Url=$video.Url; Title=$video.QualityLabel; Referer="https://www.youtube.com/watch?v=$VideoId"; Ua=$UserAgent }
    }
    throw "YouTube: could not find any playable stream for video $VideoId"
}

function Get-YouTubeFromPage([string]$VideoId, [string]$WatchUrl) {
    $headers = @{ 'User-Agent' = $UserAgent; 'Referer' = $WatchUrl }
    $resp = Invoke-WebRequest -Uri "https://www.youtube.com/watch?v=$VideoId" -Method Get -Headers $headers -TimeoutSec 30 -UseBasicParsing
    $html = $resp.Content
    $innertube = Get-JsonFromHtml $html '"INNERTUBE_CLIENT_NAME":"'
    if ($innertube) {
        $apiKey = Get-YouTubeApiKey $html
        $clients = Get-InnertubeClients
        $client = $clients | Where-Object { $_.needsKey -eq $false -or $apiKey } | Select-Object -First 1
        $jsonUrl = "https://www.youtube.com/youtubei/v1/player?key=$apiKey&c=$($client.clientName)&version=$($client.clientVersion)"
        try {
            $body = @{ videoId=$VideoId; context=@{ clientName=$client.clientName; clientVersion=$client.clientVersion }
                       playbackQualityPreference='HIGH'; contentCheckOk=$true
                       playbackContext=@{ playerClient=$client.clientName; playerVersion=$client.clientVersion } } | ConvertTo-Json -Compress
            $json = Invoke-WebRequest -Uri $jsonUrl -Method Post -Body $body -ContentType 'application/json'
                  -Headers @{ 'Content-Type' = 'application/json' } -TimeoutSec 30 | ConvertFrom-Json
            return @{ Json=$json; WatchUrl=$WatchUrl }
        } catch {
            Write-Status "YouTube API error: $($_.Exception.Message)"
        }
    }
    return $null
}

function Merge-WithFfmpeg([string]$VideoPath, [string]$AudioPath, [string]$OutPath) {
    $out = $OutPath
    if (Test-Path $out) { Remove-Item $out -Force }
    $cmd = "ffmpeg -y -i `"$VideoPath`" -i `"$AudioPath`" -c:v copy -c:a aac -b:a 192k -af 'resample=48000:1' `"$out`""
    Write-Host $cmd
    & $cmd
}

function Process-OneUrl([string]$Link) {
    if ($Link -notmatch '^https?://') { throw 'Link must start with http:// or https://' }

    $info = Resolve-Video -Link $Link
    $safeTitle = Get-SafeFileName $info.Title
    $outPath = Get-UniquePath -Dir $Root -BaseName $safeTitle

    Write-Status 'jackpot...mp4 just found there downloading to root dir type shit'
    Write-Status "  $(Split-Path -Leaf $outPath)"

    $maxRetries = 3
    $baseDelay = 2

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Status "Attempt $attempt / $maxRetries"
            Write-ProgressBarStart -Filename $safeTitle
            Write-ProgressBar -Filename $safeTitle -CurrentBytes 0 -TotalBytes 0 -Status 'Starting...'
            Invoke-Download -Info $info -OutPath $outPath
            Write-ProgressBarComplete -Filename $safeTitle
            Write-Status 'Mission Accomplished.'
            Write-Status 'Deleting Shaders...'
            return
        } catch {
            $msg = $_.Exception.Message
            if ($msg -notmatch '403|Forbidden|connection.*reset|timeout|timed out|request.*failed') {
                throw
            }
            if ($attempt -lt $maxRetries) {
                $delay = [math]::Round($baseDelay * ([math]::Pow(2, $attempt - 1)), 0)
                Write-Status "Failed: $msg. Retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
            } else {
                Write-Status "All $maxRetries attempts failed. Last error: $msg"
            }
        }
    }
}

# --- main ---
try {
    Show-Mp4ClawBanner
    $urls = Get-UrlsToProcess -Args $args
    foreach ($u in $urls) {
        Write-Status "watching number go up: $u"
        try {
            Process-OneUrl -Link $u
        } catch {
            Write-Host "Failure: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
