# mp4claw.ps1 — PowerShell only, no installs. Windows 10+.
$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

function Write-Status([string]$Message) { Write-Host $Message }

function Show-Mp4ClawBanner {
    $banner = @'
 _____ ______   ________  ___   ___  ________  ___       ________  ___       __      
|\   _ \  _   \|\   __  \|\  \ |\  \|\   ____\|\  \     |\   __  \|\  \     |\  \    
\ \  \\\__\ \  \ \  \|\  \ \  \\_\  \ \  \___|\ \  \    \ \  \|\  \ \  \    \ \  \   
 \ \  \\|__| \  \ \   ____\ \______  \ \  \    \ \  \    \ \   __  \ \  \  __\ \  \  1.0.0.0.0.0.0.0.0.005
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
    $patterns = @(
        'https?://[^\s"''<>\\]+\.mp4(?:\?[^\s"''<>\\]*)?',
        '(?:src|href)\s*=\s*["'']([^"'']+\.mp4[^"'']*)["'']',
        '["'']([^"'']+\.mp4(?:\?[^"'']*)?)["'']',
        '(https?:\\\/\\\/[^"'']+\.mp4)'
    )
    foreach ($pat in $patterns) {
        [regex]::Matches($Text, $pat, 'IgnoreCase') | ForEach-Object {
            $raw = if ($_.Groups.Count -gt 1 -and $_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Value }
            $raw = $raw -replace '\\u0026', '&' -replace '\\/', '/' -replace '&amp;', '&'
            $abs = Resolve-AbsoluteUrl $PageUrl $raw
            if ($abs -and $abs -match '\.mp4(\?|$)') { [void]$found.Add($abs) }
        }
    }
    return @($found)
}

function Get-YouTubeVideoId([string]$Url) {
    if ($Url -match '(?:youtu\.be/|youtube\.com/embed/|youtube\.com/shorts/)([^?&/]+)') { return $Matches[1] }
    if ($Url -match '[?&]v=([^&]+)') { return $Matches[1] }
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
    if ($Html -match 'INNERTUBE_API_KEY["'']\s*:\s*["'']([^"'']+)["'']') { return $Matches[1] }
    if ($Html -match '"INNERTUBE_API_KEY":"([^"]+)"') { return $Matches[1] }
    return 'AIzaSyAO_FJ2SlBJIZkbvQwKc8yS3csKTCNZpGw'
}

function Get-InnertubeClients() {
    @(
        @{
            clientName    = 'ANDROID'
            clientVersion = '20.10.38'
            userAgent     = 'com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip'
            needsKey      = $false
        },
        @{
            clientName    = 'ANDROID_VR'
            clientVersion = '1.60.19'
            userAgent     = 'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12) gzip'
            needsKey      = $false
        },
        @{
            clientName    = 'IOS'
            clientVersion = '20.10.38'
            userAgent     = 'com.google.ios.youtube/20.10.38 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X)'
            needsKey      = $false
        },
        @{
            clientName    = 'TVHTML5_SIMPLY_EMBEDDED_PLAYER'
            clientVersion = '2.0'
            userAgent     = $UserAgent
            needsKey      = $true
        },
        @{
            clientName    = 'WEB'
            clientVersion = '2.20250224.01.00'
            userAgent     = $UserAgent
            needsKey      = $true
        }
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
        if ($s.mimeType -notmatch 'video/mp4') { continue }
        $m = Get-StreamMetrics $s
        [pscustomobject]@{
            Url           = $u
            Mime          = $s.mimeType
            Height        = $m.Height
            Width         = $m.Width
            Bitrate       = $m.Bitrate
            ContentLength = $m.ContentLength
            HasAudio      = $m.HasAudio
            QualityLabel  = $m.QualityLabel
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Height, Width, Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Select-BestYouTubeAudio($PlayerJson) {
    $candidates = foreach ($s in (Get-YouTubeStreams $PlayerJson)) {
        $u = Get-FormatDirectUrl $s
        if (-not $u) { continue }
        if ($s.mimeType -notmatch 'audio/(mp4|mpeg)') { continue }
        $m = Get-StreamMetrics $s
        [pscustomobject]@{
            Url           = $u
            Mime          = $s.mimeType
            Bitrate       = $m.Bitrate
            ContentLength = $m.ContentLength
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
        if ($s.mimeType -notmatch 'video/mp4') { continue }
        $m = Get-StreamMetrics $s
        if (-not $m.HasAudio) { continue }
        [pscustomobject]@{
            Url           = $u
            Height        = $m.Height
            Bitrate       = $m.Bitrate
            ContentLength = $m.ContentLength
            QualityLabel  = $m.QualityLabel
        }
    }
    if (-not $candidates) { return $null }
    return $candidates | Sort-Object Height, Bitrate, ContentLength -Descending | Select-Object -First 1
}

function Invoke-YouTubePlayer([string]$VideoId, [string]$ApiKey) {
    $endpoint = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false'
    foreach ($client in (Get-InnertubeClients)) {
        $ctx = @{
            client = @{
                clientName    = $client.clientName
                clientVersion = $client.clientVersion
                hl            = 'en'
                gl            = 'US'
            }
        }
        if ($client.userAgent) { $ctx.client.userAgent = $client.userAgent }

        $body = @{ context = $ctx; videoId = $VideoId } | ConvertTo-Json -Depth 8 -Compress
        $uri = if ($client.needsKey) { "$endpoint&key=$ApiKey" } else { $endpoint }
        try {
            $json = Invoke-WebJson -Url $uri -BodyJson $body -ExtraHeaders @{ 'User-Agent' = $client.userAgent }
            if ($json.playabilityStatus.status -eq 'OK' -and $json.streamingData) {
                $video = Select-BestYouTubeVideo $json
                if ($video) {
                    return @{
                        Json        = $json
                        Video       = $video
                        Title       = $json.videoDetails.title
                        Client      = $client.clientName
                        UserAgent   = $client.userAgent
                    }
                }
            }
        } catch {
            continue
        }
    }
    return $null
}

function Get-YouTubeFromPage([string]$VideoId, [string]$WatchUrl) {
    $html = Invoke-WebText -Url $WatchUrl
    $apiKey = Get-YouTubeApiKey $html

    $player = Invoke-YouTubePlayer -VideoId $VideoId -ApiKey $apiKey
    if ($player) { return $player }

    $embedded = Get-JsonFromHtml $html 'ytInitialPlayerResponse'
    if ($embedded -and $embedded.streamingData) {
        $video = Select-BestYouTubeVideo $embedded
        if ($video) {
            return @{
                Json      = $embedded
                Video     = $video
                Title     = $embedded.videoDetails.title
                Client    = 'PAGE'
                UserAgent = $UserAgent
            }
        }
    }
    return $null
}

function Get-PageTitle([string]$Html) {
    if ($Html -match '<title[^>]*>([^<]*)</title>') {
        $t = ($Matches[1] -replace '\s+', ' ').Trim()
        if ($t) { return $t }
    }
    return 'video'
}

function Get-FfmpegPath() {
    $p = Join-Path $Root 'ffmpeg.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Save-RemoteFile([string]$Url, [string]$OutPath, [string]$Referer, [string]$Ua) {
    if (-not $Ua) { $Ua = $UserAgent }
    $headers = @{
        'User-Agent'      = $Ua
        'Accept'          = '*/*'
        'Accept-Language' = 'en-US,en;q=0.9'
    }
    if ($Referer) {
        $headers['Referer'] = $Referer
        if ($Referer -match 'youtube\.com') { $headers['Origin'] = 'https://www.youtube.com' }
    }

    $prev = [System.Net.ServicePointManager]::SecurityProtocol
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutPath -Headers $headers -UseBasicParsing -TimeoutSec 7200
    } finally {
        [System.Net.ServicePointManager]::SecurityProtocol = $prev
    }
}

function Quote-ProcessArg([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Merge-WithFfmpeg([string]$VideoPath, [string]$AudioPath, [string]$OutPath) {
    $ffmpeg = Get-FfmpegPath
    if (-not $ffmpeg) { throw 'ffmpeg.exe not found next to mp4claw.' }

    $tempOut = Join-Path $env:TEMP ("mp4claw_out_{0}.mp4" -f [guid]::NewGuid().ToString('N'))
    $argList = @(
        '-hide_banner', '-loglevel', 'error',
        '-i', $VideoPath,
        '-i', $AudioPath,
        '-c', 'copy',
        '-map', '0:v:0',
        '-map', '1:a:0',
        '-movflags', '+faststart',
        '-y', $tempOut
    )
    $argStr = ($argList | ForEach-Object { Quote-ProcessArg $_ }) -join ' '
    $proc = Start-Process -FilePath $ffmpeg -ArgumentList $argStr -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "ffmpeg merge failed (exit $($proc.ExitCode))." }
    Move-Item -LiteralPath $tempOut -Destination $OutPath -Force
}

function New-YouTubeInfo([hashtable]$Fields, [object]$Yt, [string]$VideoId) {
    $Fields['Title'] = $Yt.Title
    $Fields['Referer'] = 'https://www.youtube.com/'
    $Fields['Ua'] = if ($Yt.UserAgent) { $Yt.UserAgent } else { $UserAgent }
    $Fields['YouTubeJson'] = $Yt.Json
    $Fields['VideoId'] = $VideoId
    return $Fields
}

function Resolve-YouTube([object]$Yt, [string]$VideoId) {
    $ffmpeg = Get-FfmpegPath
    $audio = Select-BestYouTubeAudio $Yt.Json
    $video = $Yt.Video

    if ($ffmpeg -and $audio -and -not $video.HasAudio) {
        $label = if ($video.QualityLabel) { $video.QualityLabel } else { "$($video.Height)p" }
        Write-Status "crispy video: $label + separate audio (ffmpeg merge)"
        return (New-YouTubeInfo @{
            Merge    = $true
            VideoUrl = $video.Url
            AudioUrl = $audio.Url
        } $Yt $VideoId)
    }

    if ($ffmpeg -and $audio -and $video.HasAudio) {
        $muxed = Select-BestYouTubeMuxed $Yt.Json
        if ($muxed -and $video.Height -gt $muxed.Height) {
            $label = if ($video.QualityLabel) { $video.QualityLabel } else { "$($video.Height)p" }
            Write-Status "crispy video: $label + separate audio (ffmpeg merge)"
            return (New-YouTubeInfo @{
                Merge    = $true
                VideoUrl = $video.Url
                AudioUrl = $audio.Url
            } $Yt $VideoId)
        }
    }

    if ($video.HasAudio) {
        return (New-YouTubeInfo @{
            Merge  = $false
            Mp4Url = $video.Url
        } $Yt $VideoId)
    }

    $muxed = Select-BestYouTubeMuxed $Yt.Json
    if ($muxed) {
        Write-Status "Using best muxed stream ($($muxed.QualityLabel))"
        return (New-YouTubeInfo @{
            Merge  = $false
            Mp4Url = $muxed.Url
        } $Yt $VideoId)
    }

    Write-Status 'Note: only a video-only stream was available; file may have no sound.'
    return (New-YouTubeInfo @{
        Merge  = $false
        Mp4Url = $video.Url
    } $Yt $VideoId)
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
    $vid = Get-YouTubeVideoId $Link
    if ($vid) {
        Write-Status 'YouTube link detected, i just knew it...'
        $watch = "https://www.youtube.com/watch?v=$vid"
        $yt = Get-YouTubeFromPage -VideoId $vid -WatchUrl $watch
        if (-not $yt) { throw 'YouTube: could not get a playable MP4 URL (video may be restricted or region-locked).' }
        return Resolve-YouTube $yt $vid
    }

    Write-Status 'let me see the page...'
    $html = Invoke-WebText -Url $Link
    $urls = Find-Mp4UrlsInText -Text $html -PageUrl $Link
    if ($urls.Count -eq 0) { throw 'No .mp4 URL found in page HTML or embedded data.' }

    $scored = foreach ($u in $urls) {
        $score = 0
        if ($u -match '(?:^|[/?&])(2160|4k)(?:[p_/-]|$)') { $score = 2160 }
        elseif ($u -match '(?:^|[/?&])1440(?:[p_/-]|$)') { $score = 1440 }
        elseif ($u -match '(?:^|[/?&])1080(?:[p_/-]|$)') { $score = 1080 }
        elseif ($u -match '(?:^|[/?&])720(?:[p_/-]|$)') { $score = 720 }
        elseif ($u -match '(?:^|[/?&])480(?:[p_/-]|$)') { $score = 480 }
        elseif ($u -match '(?:^|[/?&])360(?:[p_/-]|$)') { $score = 360 }
        [pscustomobject]@{ Url = $u; Score = $score; Len = $u.Length }
    }
    $best = ($scored | Sort-Object Score, Len -Descending | Select-Object -First 1).Url
    $title = Get-PageTitle $html
    if ($title -eq 'video') {
        try {
            $leaf = [uri]::new($best).Segments[-1] -replace '\.mp4.*$', ''
            if ($leaf) { $title = [uri]::UnescapeDataString($leaf) }
        } catch { }
    }
    return @{
        Merge   = $false
        Mp4Url  = $best
        Title   = $title
        Referer = $Link
        Ua      = $UserAgent
    }
}

function Get-UrlsToProcess() {
    $urlFile = Join-Path $Root 'url.txt'
    if (Test-Path -LiteralPath $urlFile) {
        $lines = Get-Content -LiteralPath $urlFile -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^\s*#' }
        if ($lines.Count -gt 0) {
            Write-Status "Found $($lines.Count) link(s) in url.txt"
            return $lines
        }
    }

    Write-Host 'version 1.0.0.0.0.0.0.0.0.005' -ForegroundColor White
    Write-Host 'type out http(s) encrypted link please thanks a lot (paste URL and pressed Enter):' -ForegroundColor Gray
    Write-Host '  just the Tip: or put link(s) in the url.txt in this very folder, one per line or else...' -ForegroundColor DarkGray
    $typed = Read-Host
    if (-not $typed.Trim()) { throw 'paste... ctrl+v...' }
    return @($typed.Trim())
}

function Process-OneUrl([string]$Link) {
    if ($Link -notmatch '^https?://') { throw 'Link must start with http:// or https://' }

    $info = Resolve-Video -Link $Link
    $safeTitle = Get-SafeFileName $info.Title
    $outPath = Get-UniquePath -Dir $Root -BaseName $safeTitle

    Write-Status 'jackpot...mp4 just found there downloading to root dir type shit'
    Write-Status "  $(Split-Path -Leaf $outPath)"

    Invoke-Download -Info $info -OutPath $outPath

    Write-Status 'Mission Accomplished.'
    Write-Status 'Deleting Shaders...'
}

# --- main ---
try {
    Show-Mp4ClawBanner
    $urls = Get-UrlsToProcess
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
