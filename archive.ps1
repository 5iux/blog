param([switch]$Refresh, [switch]$SkipDownloads)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Save-Text($path, $text) { [IO.File]::WriteAllText((Join-Path $PSScriptRoot $path), $text, $utf8) }
function Encode($text) { [Net.WebUtility]::HtmlEncode($text) }
function Test-SavedMedia([string]$path) {
    if (!(Test-Path -LiteralPath $path) -or (Get-Item -LiteralPath $path).Length -eq 0) { return $false }
    $stream = [IO.File]::OpenRead((Join-Path $PSScriptRoot $path))
    try {
        $first = New-Object byte[] 12
        $n = $stream.Read($first,0,12)
        if ($n -lt 4) { return $false }
        [void]$stream.Seek([Math]::Max(0,$stream.Length-16),[IO.SeekOrigin]::Begin)
        $tail = New-Object byte[] 16
        $n = $stream.Read($tail,0,16)
        $hex = [BitConverter]::ToString($tail,0,$n)
        if ($first[0] -eq 255 -and $first[1] -eq 216) { return $hex -match 'FF-D9' }
        if ([Text.Encoding]::ASCII.GetString($first,0,3) -eq 'GIF') { return $hex -match '3B(-00)*$' }
        if ($first[0] -eq 137 -and $first[1] -eq 80) { return $hex -match '49-45-4E-44-AE-42-60-82' }
        if ([Text.Encoding]::ASCII.GetString($first,4,4) -eq 'ftyp') {
            $offset = [long]0
            while ($offset -lt $stream.Length) {
                [void]$stream.Seek($offset,[IO.SeekOrigin]::Begin)
                $box = New-Object byte[] 8
                if ($stream.Read($box,0,8) -ne 8) { return $false }
                $size = [long]$box[0]*16777216+[long]$box[1]*65536+[long]$box[2]*256+$box[3]
                if ($size -eq 0) { return $true }
                if ($size -eq 1) { return $true } # Extended boxes are uncommon; curl checks transfer length.
                if ($size -lt 8 -or $offset+$size -gt $stream.Length) { return $false }
                $offset += $size
            }
        }
        return $true
    } finally { $stream.Dispose() }
}
New-Item -ItemType Directory -Force '.archive', 'assets' | Out-Null
$posts = @()
$excludedPostIds = @()
if (Test-Path 'excluded-posts.json') {
    $excludedPostIds = Get-Content -Raw -Encoding UTF8 'excluded-posts.json' | ConvertFrom-Json
}
for ($page = 1; ; $page++) {
    $file = ".archive/posts-$page.json"
    if ($Refresh -or !(Test-Path $file)) {
        & curl.exe -fLsS --retry 2 --connect-timeout 15 --max-time 90 "https://blog.5iux.cn/wp-json/wp/v2/posts?per_page=100&page=$page&_fields=id,link,title,date,content,excerpt" -o $file
        if ($LASTEXITCODE) { throw "Cannot fetch posts page $page" }
    }
    $batch = Get-Content -Raw -Encoding UTF8 $file | ConvertFrom-Json
    $kept = @($batch | Where-Object { $_.id -notin $excludedPostIds })
    if ($kept.Count -ne $batch.Count) {
        Save-Text $file (ConvertTo-Json -InputObject $kept -Depth 20)
    }
    $posts += $kept
    if ($batch.Count -lt 100 -and ($Refresh -or !(Test-Path ".archive/posts-$($page+1).json"))) { break }
}
$posts = @($posts | Sort-Object date -Descending)
$articleCount = $posts.Count
$pagesFile = '.archive/pages.json'
if ($Refresh -or !(Test-Path $pagesFile)) {
    & curl.exe --ssl-revoke-best-effort -fLsS --retry 2 --max-time 90 'https://blog.5iux.cn/wp-json/wp/v2/pages?per_page=100&_fields=id,link,title,date,content,excerpt' -o $pagesFile
    if ($LASTEXITCODE) { throw 'Cannot fetch independent pages' }
}
$pages = Get-Content -Raw -Encoding UTF8 $pagesFile | ConvertFrom-Json
$posts += $pages
$script:media = @{}
$script:tasks = New-Object 'System.Collections.Generic.List[object]'
function Local-Media([string]$raw, [string]$id) {
    $url = [Net.WebUtility]::HtmlDecode($raw)
    if ($url -match '^(data:|blob:|#)' -or !$url.Trim()) { return $raw }
    try { $uri = [uri]::new([uri]'https://blog.5iux.cn/', $url) } catch { return $raw }
    if ($uri.Scheme -notin @('http','https')) { return $raw }
    $url = $uri.AbsoluteUri
    # WordPress adds a different query to each video source; the file is identical.
    if ($uri.AbsolutePath -match '\.(mp4|mp3|webm|ogg)$') { $url = $uri.GetLeftPart([UriPartial]::Path) }
    $key = "$id|$url"
    if (!$script:media.ContainsKey($key)) {
        $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes($url))).Replace('-','').Substring(0,12).ToLower()
        $name = [uri]::UnescapeDataString([IO.Path]::GetFileName($uri.AbsolutePath)) -replace '[<>:"/\\|?*\x00-\x1f]', '_'
        if (!$name -or $name.Length -gt 110) { $name = 'media' + [IO.Path]::GetExtension($uri.AbsolutePath) }
        if (![IO.Path]::GetExtension($name)) { $name += '.img' }
        $local = "$id/$hash-$name"
        $script:media[$key] = $local
        New-Item -ItemType Directory -Force $id | Out-Null
        $script:tasks.Add([pscustomobject]@{url=$url;path=$local;article=$id})
    }
    return $script:media[$key]
}
function Rewrite-Content([string]$html, [string]$id) {
    # Keep code samples intact: rewrite attributes only on actual media/link tags.
    $html = [regex]::Replace($html, '(?is)<(img|source|video|audio|a)\b[^>]*>', {
        param($tag)
        $kind = $tag.Groups[1].Value.ToLower()
        $text = [regex]::Replace($tag.Value, '(?is)\b(src|poster|href|srcset|data-src|data-srcset|data-original)\s*=\s*(["''])(.*?)\2', {
            param($attr)
            $name = $attr.Groups[1].Value.ToLower()
            $value = $attr.Groups[3].Value
            if ($name -eq 'href' -and ($kind -ne 'a' -or $value -notmatch '\.(png|jpe?g|gif|webp|svg|avif|bmp|mp4|mp3|webm|ogg|pdf)(\?|$)')) { return $attr.Value }
            if ($name -eq 'srcset' -or $name -eq 'data-srcset') {
                $value = (($value -split ',\s*' | ForEach-Object {
                    $part = $_.Trim() -split '\s+', 2
                    if ($part[0]) { (Local-Media $part[0] $id) + $(if ($part.Length -gt 1) { ' ' + $part[1] }) }
                }) -join ', ')
            } else { $value = Local-Media $value $id }
            return $name + '=' + $attr.Groups[2].Value + $value + $attr.Groups[2].Value
        })
        if ($kind -eq 'img' -and $text -notmatch '\ssrc\s*=') {
            $lazy = [regex]::Match($text, '(?is)\b(?:data-src|data-original|data-srcset)=["'']([^"'']+)')
            if ($lazy.Success) { $text = $text -replace '\s*/?>$', (' src="' + ($lazy.Groups[1].Value -split '[,\s]')[0] + '">') }
        }
        return $text
    })
    $html = [regex]::Replace($html, 'https?://blog\.5iux\.cn/(\d+)\.html', '$1.html')
    $html = [regex]::Replace($html, 'https?://blog\.5iux\.cn/\?p=(\d+)', '$1.html')
    foreach ($pageEntry in $pages) { $html = $html.Replace($pageEntry.link, "$($pageEntry.id).html") }
    return $html
}
$head = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{0} · 5IUX博客</title><link rel="stylesheet" href="assets/style.css"></head><body><header><a href="index.html">5IUX博客</a><span>本地静态归档</span></header><main>'
$cards = New-Object Text.StringBuilder
for ($i=0; $i -lt $posts.Count; $i++) {
    $post = $posts[$i]
    $id = [string]$post.id
    $title = $post.title.rendered
    $date = $post.date.Substring(0,10)
    $body = Rewrite-Content $post.content.rendered $id
    if (!$body.Trim()) { $body = '<p>此页面原为 WordPress 动态功能页，请通过<a href="index.html">本地文章目录</a>浏览和搜索全部文章。</p>' }
    $previous = if ($i -gt 0) { '<a href="'+$posts[$i-1].id+'.html">较新：'+$posts[$i-1].title.rendered+'</a>' } else { '' }
    $next = if ($i+1 -lt $posts.Count) { '<a href="'+$posts[$i+1].id+'.html">较早：'+$posts[$i+1].title.rendered+'</a>' } else { '' }
    Save-Text "$id.html" (($head -f $title) + "<article><h1>$title</h1><p class=`"meta`">$date · 文章 $id · <a href=`"$($post.link)`">原文</a></p><div class=`"content`">$body</div></article><nav>$previous $next</nav></main><footer>5IUX博客 · 本地归档</footer></body></html>")
    $plain = [Net.WebUtility]::HtmlDecode(([regex]::Replace($post.excerpt.rendered, '<[^>]+>', '') -replace '\s+', ' ')).Trim()
    if ($plain.Length -gt 180) { $plain = $plain.Substring(0,180) + '…' }
    [void]$cards.AppendLine("<article class=`"card`"><p class=`"meta`">$date · $id</p><h2><a href=`"$id.html`">$title</a></h2><p>$(Encode $plain)</p></article>")
}
Save-Text 'index.html' (($head -f '文章目录') + '<h1>文章目录</h1><p class="meta">共 '+$articleCount+' 篇文章、'+$pages.Count+' 个独立页面 · 文章按发布时间倒序</p><label class="search">搜索文章 <input id="search" type="search" placeholder="输入标题或关键词"></label><section id="posts">'+$cards.ToString()+'</section></main><footer>5IUX博客 · 本地归档</footer><script>document.getElementById("search").addEventListener("input",function(){const q=this.value.toLocaleLowerCase();document.querySelectorAll(".card").forEach(e=>e.hidden=!e.textContent.toLocaleLowerCase().includes(q))})</script></body></html>')
Save-Text 'assets/style.css' @'
:root{color-scheme:light;--ink:#253044;--muted:#748095;--line:#e5eaf0;--accent:#2864bd}*{box-sizing:border-box}body{margin:0;background:#f5f7fa;color:var(--ink);font:16px/1.85 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}header{max-width:1080px;margin:auto;padding:28px 32px;display:flex;justify-content:space-between;align-items:center}header>a{font-size:24px;font-weight:750;color:var(--ink)}header span,.meta,footer{color:var(--muted);font-size:14px}main{max-width:1000px;margin:0 auto;padding:32px 48px 48px;background:white;border:1px solid var(--line);border-radius:12px}h1{font-size:30px;line-height:1.5;margin:8px 0 16px}h2{font-size:22px;line-height:1.5}.meta{margin:4px 0 24px}.content{overflow-wrap:anywhere}.content img{max-width:100%;height:auto}.content video,.content audio,.content iframe,.wp-video{max-width:100%!important}video{height:auto}pre{overflow:auto;background:#f3f5f8;padding:20px;border-radius:6px;line-height:1.6}code{font-family:Consolas,monospace}blockquote{border-left:3px solid #99b7df;margin:24px 0;padding:4px 24px;color:#586578;background:#f8faff}table{display:block;max-width:100%;overflow:auto;border-collapse:collapse}td,th{padding:8px;border:1px solid var(--line)}figure{margin:24px 0}nav{display:flex;justify-content:space-between;gap:24px;border-top:1px solid var(--line);margin-top:40px;padding-top:24px}nav a{max-width:48%}footer{text-align:center;padding:28px}.card{padding:22px 0;border-bottom:1px solid var(--line)}.card .meta{margin:0}.card h2{margin:8px 0}.card p:last-child{color:#647085;margin:8px 0}.search{display:block;padding:16px 0}input{font:inherit;border:1px solid #cbd5e1;border-radius:6px;padding:8px 12px;margin-left:12px;width:min(75%,480px)}[hidden]{display:none!important}@media(max-width:650px){header{padding:18px}header span{font-size:12px}main{padding:22px 18px;border-radius:0}h1{font-size:24px}nav{flex-direction:column}nav a{max-width:100%}}
'@
Save-Text '.archive/media.json' (ConvertTo-Json -InputObject $script:tasks.ToArray() -Depth 5)
$pending = @($script:tasks | Where-Object { !(Test-SavedMedia $_.path) })
$config = New-Object Text.StringBuilder
foreach ($task in $pending) {
    if ($config.Length) { [void]$config.AppendLine('next') }
    [void]$config.AppendLine("location`nfail`nsilent`nshow-error`nssl-revoke-best-effort`nconnect-timeout = 12`nmax-time = 120`nretry = 1")
    [void]$config.AppendLine('remove-on-error')
    $downloadUrl = $task.url -replace '^https?://cdn\.jsdelivr\.net/gh/5iux/dyimg(?:@[^/]+)?/blog/', 'https://blog.5iux.cn/wp-content/uploads/'
    $downloadUrl = $downloadUrl -replace '^https?://5iux\.cn/wp-content/uploads/', 'https://blog.5iux.cn/wp-content/uploads/'
    $downloadUrl = $downloadUrl -replace '^https?://cdn\.jsdelivr\.net/gh/([^/]+)/([^/@]+)(?:@([^/]+))?/', 'https://raw.githubusercontent.com/$1/$2/master/'
    [void]$config.AppendLine('url = "'+$downloadUrl.Replace('"','%22')+'"')
    [void]$config.AppendLine('output = "'+$task.path.Replace('\','/')+'"')
}
Save-Text '.archive/download.curl' $config.ToString()
Write-Host "Generated $($posts.Count) articles; media $($script:tasks.Count), pending $($pending.Count)."
if ($pending.Count -and !$SkipDownloads) {
    $ErrorActionPreference = 'Continue'
    & curl.exe --parallel --parallel-max 8 --location --fail --silent --show-error --connect-timeout 12 --max-time 120 --retry 1 --config .archive/download.curl 2> .archive/download-errors.log
    $ErrorActionPreference = 'Stop'
}
$failed = @($script:tasks | Where-Object { !(Test-SavedMedia $_.path) })
if (!$SkipDownloads) {
    foreach ($task in $failed) {
        if ($task.url -match '/gh/5iux/dyimg/blog/.*-1-1\.') {
            $fallback = ($task.url -replace '^https?://cdn\.jsdelivr\.net/gh/5iux/dyimg/blog/', 'https://blog.5iux.cn/wp-content/uploads/') -replace '-1-1(\.[^.]+)$', '$1'
            & curl.exe --ssl-revoke-best-effort --remove-on-error -fLsS --connect-timeout 12 --max-time 45 $fallback -o $task.path
        }
    }
}
$failed = @($script:tasks | Where-Object { !(Test-SavedMedia $_.path) })
Save-Text '.archive/failed-media.json' (ConvertTo-Json -InputObject $failed -Depth 5)
foreach ($group in ($failed | Group-Object article)) {
    $file = "$($group.Name).html"
    $html = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $html = $html.Replace('<div class="content">', '<aside class="archive-notice">本页有 '+$group.Count+' 个原始媒体链接已失效或拒绝访问，未能保存。详见 <a href="archive-report.md">归档报告</a>。</aside><div class="content">')
    Save-Text $file $html
}
$report = New-Object Text.StringBuilder
[void]$report.AppendLine("# 博客静态归档报告`n")
[void]$report.AppendLine("来源：https://blog.5iux.cn/`n`n文章：$articleCount；独立页面：$($pages.Count)。`n`n媒体引用：$($script:tasks.Count)；成功保存：$($script:tasks.Count-$failed.Count)；无法保存：$($failed.Count)。`n")
[void]$report.AppendLine("保留文章正文、日期和编号，使用本地阅读版样式。图片、视频和音频位于对应数字目录，HTML 使用相对路径。旧 CDN 失效资源优先从博客上传目录恢复。媒体数量包括响应式尺寸和不同文章各自保存的副本。`n`n原站的登录、评论提交、投稿、第三方嵌入与外部链接需要联网；空的 WordPress 动态页面已提示使用本地文章目录。目录支持标题和摘要搜索。`n")
[void]$report.AppendLine("## 未能保存的媒体`n")
foreach ($task in $failed) { [void]$report.AppendLine("- 文章 [$($task.article)](./$($task.article).html)：$($task.url)") }
Save-Text 'archive-report.md' $report.ToString()
Write-Host "Archive ready: $($posts.Count) articles; $($script:tasks.Count - $failed.Count)/$($script:tasks.Count) media files. Failed: $($failed.Count)."
