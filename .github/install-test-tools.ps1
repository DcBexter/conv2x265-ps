$ErrorActionPreference = 'Stop'
$versions = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-versions.json') -Raw | ConvertFrom-Json
$tools = Join-Path $env:RUNNER_TEMP 'converter-tools'
New-Item -ItemType Directory -Path $tools -Force | Out-Null
$headers = @{ Accept = 'application/vnd.github+json'; Authorization = "Bearer $env:GH_TOKEN" }
foreach ($tool in @(
    @{ Name = 'powershell'; Repo = 'PowerShell/PowerShell'; Tag = "v$($versions.powershell)"; Asset = "PowerShell-$($versions.powershell)-win-x64.zip" },
    @{ Name = 'handbrake'; Repo = 'HandBrake/HandBrake'; Tag = $versions.handbrake; Asset = "HandBrakeCLI-$($versions.handbrake)-win-x86_64.zip" }
)) {
    $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$($tool.Repo)/releases/tags/$($tool.Tag)"
    $asset = @($release.assets | Where-Object name -eq $tool.Asset)
    if ($asset.Count -ne 1 -or $asset[0].digest -notmatch '^sha256:([a-f0-9]{64})$') { throw "Missing vendor SHA256: $($tool.Name)" }
    $expected = $Matches[1]
    $zip = Join-Path $tools "$($tool.Name).zip"
    Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $zip
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) { throw "Checksum mismatch: $($tool.Name)" }
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tools $tool.Name)
}
$url = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-$($versions.ffmpeg)-essentials_build.zip"
$expected = (Invoke-RestMethod "$url.sha256").Trim()
if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid FFmpeg vendor checksum.' }
$zip = Join-Path $tools 'ffmpeg.zip'
Invoke-WebRequest -Uri $url -OutFile $zip
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $expected) { throw 'Checksum mismatch: ffmpeg' }
Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tools 'ffmpeg')
foreach ($tool in @(
    @{ Name = 'PWSH'; Dir = 'powershell'; Exe = 'pwsh.exe' },
    @{ Name = 'FFMPEG'; Dir = 'ffmpeg'; Exe = 'ffmpeg.exe' },
    @{ Name = 'HANDBRAKE'; Dir = 'handbrake'; Exe = 'HandBrakeCLI.exe' }
)) {
    $exe = @(Get-ChildItem -LiteralPath (Join-Path $tools $tool.Dir) -Recurse -File -Filter $tool.Exe)
    if ($exe.Count -ne 1) { throw "Expected exactly one $($tool.Exe)" }
    "$($tool.Name)=$($exe[0].FullName)" | Out-File -LiteralPath $env:GITHUB_ENV -Append -Encoding utf8
}
