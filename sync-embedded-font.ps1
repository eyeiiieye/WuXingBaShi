# 将主版本的改动同步到「内嵌字体版」与「网页版」
#
# 自动发现：
#   - 主版本：根目录中版本号最高的 眼师五行八识图演示工具v<版本>.html
#   - 字体 CSS：font-family 目录下的全部 .css（小篆、甲骨文/金文/大篆等）
#
# 生成：
#   - <主版本名>(内嵌字体版).html：字体 CSS 转 base64 内嵌，延迟注入
#   - <主版本名>(网页版).html：外链字体 CSS，不内嵌
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File .\sync-embedded-font.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ==== 结构锚点（与版本号无关） ====
$versionConst = 'const APP_VERSION'
$optionPattern = '(?m)^([ \t]*)<option value="fangsong">[^<\r\n]*</option>'
$mapPattern = '(?m)^([ \t]*)fangsong:[^\r\n]*,$'
$embeddedFontId = 'embeddedFontCss'

$bootScript = @'
// 内嵌字体：延后到首帧之后再注入，避免大体积 CSS 阻塞加载动画
window.__eyeFontsReady = new Promise(resolve => {
  let settled = false;
  const done = () => { if (!settled) { settled = true; resolve(); } };
  setTimeout(() => {
    try {
      const source = document.getElementById('@@FONT_ID@@');
      if (!source) { done(); return; }
      const styleEl = document.createElement('style');
      styleEl.textContent = source.textContent;
      document.head.appendChild(styleEl);
      source.remove();
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(done);
      setTimeout(done, 2500);
    } catch (err) {
      done();
    }
  }, 80);
});
'@

function Fail([string]$msg) {
  Write-Host "[同步失败] $msg" -ForegroundColor Red
  exit 1
}

function Write-Utf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function Format-KB([int]$n) { '{0:N1} KB' -f ($n / 1024) }

# ==== 1. 自动发现主版本 ====
$namePattern = '^眼师五行八识图演示工具v(\d+(?:\.\d+)*)\.html$'
$candidates = Get-ChildItem -LiteralPath $root -File -Filter '眼师五行八识图演示工具v*.html' |
  Where-Object { $_.Name -match $namePattern } |
  ForEach-Object {
    [pscustomobject]@{
      File = $_
      Version = [version]([regex]::Match($_.Name, $namePattern).Groups[1].Value)
    }
  } | Sort-Object Version -Descending
if (-not $candidates) { Fail '根目录中找不到主版本 HTML' }
$baseFile = $candidates[0].File
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($baseFile.Name)
$embeddedFile = Join-Path $root ($baseName + '(内嵌字体版).html')
$webFile = Join-Path $root ($baseName + '(网页版).html')

# ==== 2. 自动发现字体 CSS（支持多个） ====
$cssDir = Join-Path $root 'font-family'
$cssFiles = @(Get-ChildItem -LiteralPath $cssDir -Recurse -File -Filter '*.css' -ErrorAction SilentlyContinue)
if ($cssFiles.Count -eq 0) { Fail 'font-family 目录中找不到字体 CSS' }

$cssInfos = @()
foreach ($f in $cssFiles) {
  $text = [System.IO.File]::ReadAllText($f.FullName)
  $faces = ([regex]::Matches($text, '@font-face')).Count
  if ($faces -eq 0) { Fail "字体 CSS 中没有 @font-face：$($f.FullName)" }
  $family = ([regex]::Match($text, '@font-face\s*\{\s*font-family:\s*"([^"]+)"')).Groups[1].Value
  if (-not $family) { Fail "字体 CSS 中找不到 font-family 名称：$($f.FullName)" }
  $cssInfos += [pscustomobject]@{ File = $f; Text = $text; Family = $family; Faces = $faces }
}
$faceCount = ($cssInfos | Measure-Object -Property Faces -Sum).Sum

# 小篆字体用作「显示字体」下拉的 zt 选项：优先家族名含 Chong / 崇羲 的 CSS
$sealCss = $cssInfos | Where-Object { $_.Family -match 'Chong|崇羲' } | Select-Object -First 1
if (-not $sealCss) { $sealCss = $cssInfos[0] }
$sealFontValue = "zt: '`"$($sealCss.Family)`", KaiTi, `"Kaiti SC`", serif',"

$base = [System.IO.File]::ReadAllText($baseFile.FullName).Replace("`r`n", "`n")
$appVersion = ([regex]::Match($base, "const APP_VERSION\s*=\s*'([^']+)'")).Groups[1].Value
if (-not $appVersion) { Fail '主版本中找不到 APP_VERSION' }
if ($base.IndexOf('id="' + $embeddedFontId + '"') -ge 0) {
  Fail '主版本中已存在内嵌字体块，请确认传入的是非内嵌字体版'
}
if ($base.IndexOf('<option value="zt">') -ge 0) {
  Fail '主版本中已存在小篆选项，请确认传入的是非内嵌字体版/网页版'
}

# ==== 3. 公共：注入字体下拉选项 + 字体映射（小篆 zt + 古文字三项） ====
function Add-FontExtras([string]$html, [string]$sealLabel, [string]$ancientSuffix) {
  $state = @{ opt = 0; map = 0 }
  $optionRe = [regex]::new($optionPattern)
  $html = $optionRe.Replace($html, [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    $state.opt++
    $indent = $m.Groups[1].Value
    $add = "`n${indent}<option value=`"jiaguwen`">甲骨文${ancientSuffix}</option>" +
           "`n${indent}<option value=`"jinwen`">金文${ancientSuffix}</option>" +
           "`n${indent}<option value=`"dazhuan`">大篆${ancientSuffix}</option>" +
           "`n${indent}<option value=`"zt`">${sealLabel}</option>"
    return $m.Value + $add
  })
  $mapRe = [regex]::new($mapPattern)
  $html = $mapRe.Replace($html, [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    $state.map++
    $indent = $m.Groups[1].Value
    $add = "`n${indent}jiaguwen: '`"EyeJiaguwen`", KaiTi, `"Kaiti SC`", STKaiti, serif'," +
           "`n${indent}jinwen: '`"EyeJinwen`", KaiTi, `"Kaiti SC`", STKaiti, serif'," +
           "`n${indent}dazhuan: '`"EyeDazhuan`", KaiTi, `"Kaiti SC`", STKaiti, serif'," +
           "`n${indent}${sealFontValue}"
    return $m.Value + $add
  })
  if ($state.opt -ne 2) { Fail "字体下拉中应找到 2 处仿宋选项，实际 $($state.opt) 处" }
  if ($state.map -ne 1) { Fail "字体映射中应找到 1 处仿宋配置，实际 $($state.map) 处" }
  return $html
}

# ==== 4. 生成内嵌字体版：所有字体 CSS 转 base64，插到主脚本前 ====
function Get-InlineCss([pscustomobject]$info) {
  return [regex]::Replace($info.Text, 'url\(\s*[''"]?\.?/?([^)''"\s]+\.woff2)[''"]?\s*\)',
    [System.Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $rel = $m.Groups[1].Value
      $fontPath = Join-Path $info.File.DirectoryName $rel
      if (-not (Test-Path -LiteralPath $fontPath)) { Fail "字体文件缺失：$($info.File.Name) -> $rel" }
      $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fontPath))
      'url("data:font/woff2;base64,' + $b64 + '")'
    })
}

$inlineCss = (($cssInfos | ForEach-Object { Get-InlineCss $_ }) -join "`n")

$mainScriptIdx = $base.IndexOf($versionConst)
if ($mainScriptIdx -lt 0) { Fail '主版本中找不到主脚本（APP_VERSION）' }
$scriptOpenIdx = $base.LastIndexOf('<script>', $mainScriptIdx)
if ($scriptOpenIdx -lt 0) { Fail '主版本中找不到主 <script> 入口' }
$body = $base.Substring($scriptOpenIdx + '<script>'.Length)
if ($body.StartsWith("`n")) { $body = $body.Substring(1) }

$fontCssBlock = '<script type="text/plain" id="' + $embeddedFontId + '">' + "`n" + $inlineCss + '</script>'
$bootBlock = $bootScript.Replace('@@FONT_ID@@', $embeddedFontId).TrimEnd()

$embedded = $base.Substring(0, $scriptOpenIdx) + $fontCssBlock + "`n" + '<script>' + "`n" + $bootBlock + "`n`n" + $body
$embedded = Add-FontExtras $embedded '小篆（内嵌）' '（内嵌）'
if (([regex]::Matches($embedded, [regex]::Escape($versionConst))).Count -ne 1) {
  Fail '内嵌字体版中生成了重复的业务代码（APP_VERSION 出现多次）'
}
Write-Utf8 $embeddedFile $embedded

# ==== 5. 生成网页版：外链字体 CSS，不内嵌 ====
$web = Add-FontExtras $base '小篆' ''
if ($web.IndexOf('</head>') -lt 0) { Fail '主版本中找不到 </head>' }
$linkLines = ($cssInfos | ForEach-Object {
  $rel = $_.File.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
  '  <link rel="stylesheet" href="' + $rel + '">'
}) -join "`n"
$linkHtml = '  <!-- 网页版：外链字体 CSS，不内嵌 -->' + "`n" + $linkLines + "`n</head>"
$web = $web.Replace('</head>', $linkHtml)
foreach ($info in $cssInfos) {
  $rel = $info.File.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
  if (([regex]::Matches($web, [regex]::Escape($rel))).Count -ne 1) {
    Fail "网页版字体外链生成异常：$rel"
  }
}
Write-Utf8 $webFile $web

# ==== 6. 输出摘要 ====
Write-Host '已同步：'
Write-Host ('  主版本：{0}（{1}，@font-face {2} 个）' -f $baseFile.Name, (Format-KB $base.Length), $faceCount)
Write-Host ('  内嵌字体版：{0}（{1}）' -f (Split-Path -Leaf $embeddedFile), (Format-KB $embedded.Length))
Write-Host ('  网页版：{0}（{1}，外链 {2} 个 CSS）' -f (Split-Path -Leaf $webFile), (Format-KB $web.Length), $cssInfos.Count)
