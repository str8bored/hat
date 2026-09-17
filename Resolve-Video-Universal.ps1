function Resolve-Video([string]$Link) {
    # YouTube
    if ($Link -match '(?:youtu\.be/|youtube\.com/embed/|youtube\.com/shorts/)([^?&/]+)') {
        $vid = $Matches[1]
        Write-Status "YouTube link detected: $vid"
        $watch = "https://www.youtube.com/watch?v=$vid"
        $yt = Get-YouTubeFromPage -VideoId $vid -WatchUrl $watch
        if (-not $yt) { throw "YouTube: could not get a playable MP4 URL (video may be restricted or region-locked)." }
        return Resolve-YouTube $yt $vid
    }

    # Vimeo
    if ($Link -match 'vimeo\.com/(?:channels/[^/]+/)?videos/(\d+)') {
        $vid = $Matches[1]
        Write-Status "Vimeo link detected: $vid"
        $json = Invoke-WebRequest -Uri "https://vimeo.com/api/oembed.json?url=https://vimeo.com/$vid" -Method Post -Body '{"url":"https://vimeo.com/$vid"}' -ContentType 'application/json' | ConvertFrom-Json
        if (-not $json -or -not $json.video) { throw "Vimeo: could not retrieve video data." }
        $videoUrl = $json.video
        if ($videoUrl -match 'vimeo\.com/proxy/file/([a-zA-Z0-9]+)\.(mp4|webm)') {
            $streamId = $Matches[1]
            $ext = $Matches[2]
            $streamUrl = "https://player.vimeo.com/external/$streamId.$ext"
            Write-Status "Vimeo stream URL: $streamUrl"
            return @{
                Merge  = $false
                Mp4Url = $streamUrl
                Title  = $json.title
                Referer = $Link
                Ua     = $UserAgent
            }
        }
        throw "Vimeo: could not find direct MP4 stream. Video URL: $($json.video)"
    }

    # Generic .mp4 URL (direct link)
    if ($Link -match '\.mp4($|[?&])') {
        Write-Status "Direct MP4 URL detected"
        return @{
            Merge  = $false
            Mp4Url = $Link
            Title  = Get-PageTitle $Link
            Referer = $Link
            Ua     = $UserAgent
        }
    }

    # Generic HTML page — scrape for .mp4 URLs
    Write-Status "Generic page detected, scraping for .mp4 links..."
    $html = Invoke-WebText -Url $Link
    $urls = Find-Mp4UrlsInText -Text $html -PageUrl $Link
    if ($urls.Count -eq 0) {
        throw "No .mp4 URL found in page HTML. Try pasting a direct .mp4 link or a supported video site URL."
    }

    # Score and pick best candidate
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
            $leaf = [uri]::new($best).Segments[-1] -replace '\.mp4.*', ''
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
