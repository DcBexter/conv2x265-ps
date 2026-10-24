#Requires -Version 7.6
param(
    [string]$Ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source,
    [string]$Handbrake = (Get-Command HandBrakeCLI -ErrorAction Stop).Source
)
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('conv2x265-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
    $source = Join-Path $PSScriptRoot '..\conv2x265-ps.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$errors)
    Assert ($errors.Count -eq 0) 'Converter must parse.'
    # Load function definitions only; never load user's config or touch user's media/Plex.
    $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        ForEach-Object { Invoke-Expression $_.Extent.Text }
    $ffprobe = Join-Path (Split-Path $Ffmpeg) 'ffprobe.exe'
    $ffmpeg = $Ffmpeg
    $handbrake = $Handbrake
    $oldFile = Join-Path $root 'source [1].mkv'
    & $ffmpeg -v error -f lavfi -i 'testsrc2=size=128x96:rate=12' -f lavfi -i 'sine=frequency=440' -t 2 -c:v libx265 -preset ultrafast -x265-params 'lossless=1:log-level=error:pools=1' -c:a aac $oldFile
    Assert ($LASTEXITCODE -eq 0) 'Synthetic fixture creation failed.'
    CodecDiscovery
    $maxHevcMBPerHour = (Get-Item -LiteralPath $oldFile).Length * 3600 / $durationSeconds / 1000000
    Assert (-not (Test-HevcReencode)) 'Exact threshold must not re-encode.'
    $maxHevcMBPerHour -= 0.01
    Assert (Test-HevcReencode) 'HEVC above threshold must re-encode.'
    $sourceInfo.format | Add-Member -NotePropertyName tags -NotePropertyValue @{ conv2x265_reencoded = '1' } -Force
    Assert (-not (Test-HevcReencode)) 'Output marker must prevent feedback loop above threshold.'
    CodecDiscovery
    $maxHevcMBPerHour = 0
    Assert (-not (Test-HevcReencode)) 'Zero must disable HEVC re-encoding.'
    $maxHevcMBPerHour = 1
    $vCodecCMD = 'h264'
    Assert (-not (Test-HevcReencode)) 'Threshold must only select HEVC.'
    CodecDiscovery
    $keepSubs = $true
    $reencodeHevc = $true
    $newFile = Join-Path $root 'handbrake.mkv'
    EncodeHandbrake
    Assert ($encoderExitCode -eq 0) 'Real HandBrake fallback must complete.'
    Assert (Test-Conversion) 'Real HandBrake output must validate, including marker.'
    $durationSeconds += 10
    Assert (-not (Test-Conversion)) 'Truncated duration must fail validation.'
    CodecDiscovery
    Set-Content -LiteralPath $newFile -Value 'broken media'
    Assert (-not (Test-Conversion)) 'Corrupt output must fail validation.'

    $sandbox = Join-Path $root 'sandbox'
    $media = Join-Path $sandbox 'media'
    New-Item -ItemType Directory -Path $media | Out-Null
    Copy-Item -LiteralPath $source -Destination $sandbox
    function Write-Config([double]$threshold, [bool]$subs = $true, [string]$destination = '') {
        $config = @{
            mediaPath = $media; fileTypes = @('*.mp4', '*.mkv', '*.ts'); logPath = $sandbox
            logName = 'test.log'; plexToken = ''; ffmpegBinDir = (Split-Path $Ffmpeg)
            handbrakeDir = (Split-Path $Handbrake); collectGarbage = $false
            appendLog = $false; keepSubs = $subs; useOutPath = ($destination -ne ''); outPath = $destination; maxHevcMBPerHour = $threshold
        }
        $lines = foreach ($key in $config.Keys) {
            $value = $config[$key]
            $literal = if ($value -is [bool]) { '$' + $value.ToString().ToLowerInvariant() }
                elseif ($value -is [array]) { ($value | ForEach-Object { "'$_'" }) -join ',' }
                elseif ($value -is [double]) { $value.ToString([cultureinfo]::InvariantCulture) }
                else { "'" + $value.Replace("'", "''") + "'" }
            '$' + $key + ' = ' + $literal
        }
        Set-Content -LiteralPath (Join-Path $sandbox 'cfg_conv2x265-ps.ps1') -Value $lines
    }
    function Run-Converter {
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $sandbox 'conv2x265-ps.ps1') *> (Join-Path $root 'process.log')
        if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath (Join-Path $root 'process.log'); throw 'Converter process failed.' }
        Assert (-not (Test-Path -LiteralPath (Join-Path $sandbox 'conv2x265-ps.lock'))) 'Lock must be released.'
    }
    $fixture = Join-Path $media 'episode [1].mkv'
    Copy-Item -LiteralPath $oldFile -Destination $fixture
    $originalHash = (Get-FileHash -LiteralPath $fixture).Hash
    Write-Config 1000000
    Run-Converter
    Assert ((Get-FileHash -LiteralPath $fixture).Hash -eq $originalHash) 'Below-threshold HEVC must remain unchanged.'
    Write-Config 1
    Run-Converter
    $encodedHash = (Get-FileHash -LiteralPath $fixture).Hash
    if ($encodedHash -eq $originalHash) { Get-Content -LiteralPath (Join-Path $root 'process.log') }
    Assert ($encodedHash -ne $originalHash) 'Above-threshold HEVC must be replaced.'
    Assert ((Get-Item -LiteralPath $fixture).Length -lt (Get-Item -LiteralPath $oldFile).Length) 'HEVC output must save space.'
    Run-Converter
    Assert ((Get-FileHash -LiteralPath $fixture).Hash -eq $encodedHash) 'Second scan must never re-encode marked HEVC.'

    $h264 = Join-Path $media 'h264.mp4'
    & $ffmpeg -v error -f lavfi -i 'testsrc2=size=128x96:rate=12' -f lavfi -i 'sine=frequency=440' -t 2 -c:v libx264 -c:a aac $h264
    Assert ($LASTEXITCODE -eq 0) 'H264 fixture creation failed.'
    $collision = Join-Path $media 'h264.mkv'
    Copy-Item -LiteralPath $fixture -Destination $collision
    $h264Hash = (Get-FileHash -LiteralPath $h264).Hash
    Run-Converter
    Assert ((Get-FileHash -LiteralPath $h264).Hash -eq $h264Hash) 'Existing destination must not delete source.'
    Remove-Item -LiteralPath $collision
    Write-Config 1 $false
    Run-Converter
    Assert (-not (Test-Path -LiteralPath $h264)) 'Validated H264 conversion must complete without subtitles.'
    Assert (Test-Path -LiteralPath $collision) 'H264 MKV output must exist.'

    $destination = Join-Path $root 'output [1]'
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $nestedSources = foreach ($folder in @("show [1]'s", 'show [2]')) {
        $directory = Join-Path $media $folder
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $inputPath = Join-Path $directory "episode [1]'s.mp4"
        Copy-Item -LiteralPath $collision -Destination $inputPath
        $inputPath
    }
    Write-Config 0 $true $destination
    Run-Converter
    foreach ($inputPath in $nestedSources) {
        $relative = [IO.Path]::GetRelativePath($media, $inputPath)
        $outputPath = Join-Path $destination ([IO.Path]::ChangeExtension($relative, '.mkv'))
        Assert (Test-Path -LiteralPath $outputPath) 'Output must preserve subfolders for equal names, brackets and apostrophes.'
        Assert (-not (Test-Path -LiteralPath $inputPath)) 'Only validated nested conversion may remove its source.'
        $outputHash = (Get-FileHash -LiteralPath $outputPath).Hash
        Copy-Item -LiteralPath $collision -Destination $inputPath
        $inputHash = (Get-FileHash -LiteralPath $inputPath).Hash
        Run-Converter
        Assert ((Get-FileHash -LiteralPath $inputPath).Hash -eq $inputHash) 'Existing nested output must preserve source.'
        Assert ((Get-FileHash -LiteralPath $outputPath).Hash -eq $outputHash) 'Existing nested output must remain unchanged.'
        Remove-Item -LiteralPath $inputPath
    }

    $fileRoot = Join-Path $media 'file-root.mp4'
    Copy-Item -LiteralPath $collision -Destination $fileRoot
    $fileRootHash = (Get-FileHash -LiteralPath $fileRoot).Hash
    Write-Config 0 $true $destination
    Add-Content -LiteralPath (Join-Path $sandbox 'cfg_conv2x265-ps.ps1') -Value ('$mediaPath = ' + "'" + $fileRoot.Replace("'", "''") + "'")
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $sandbox 'conv2x265-ps.ps1') *> (Join-Path $root 'file-root.log')
    Assert ($LASTEXITCODE -ne 0) 'A file cannot be the media root for relative output paths.'
    Assert ((Get-FileHash -LiteralPath $fileRoot).Hash -eq $fileRootHash) 'Invalid media root must preserve source.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $root 'file-root.mkv'))) 'Output must not escape destination root.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $sandbox 'conv2x265-ps.lock'))) 'Invalid media root must release lock.'
    Remove-Item -LiteralPath $fileRoot

    $subtitles = Join-Path $root 'captions.srt'
    Set-Content -LiteralPath $subtitles -Value "1`n00:00:00,000 --> 00:00:01,000`nSynthetic caption`n"
    $withSubs = Join-Path $media 'silent-subtitles.mkv'
    & $ffmpeg -v error -f lavfi -i 'testsrc2=size=128x96:rate=12' -i $subtitles -t 2 -c:v libx264 -c:s srt $withSubs
    Assert ($LASTEXITCODE -eq 0) 'Silent subtitle fixture creation failed.'
    Write-Config 1 $true
    Run-Converter
    $info = (& $ffprobe -v error -show_streams -of json $withSubs | ConvertFrom-Json)
    Assert (@($info.streams | Where-Object codec_name -eq hevc).Count -eq 1) 'Silent H264 must convert to HEVC.'
    Assert (@($info.streams | Where-Object codec_name -eq subrip).Count -eq 1) 'Native MKV subtitle must survive.'

    $telemetry = Join-Path $root 'telemetry.bin'
    [IO.File]::WriteAllBytes($telemetry, [byte[]](1..128))
    $withData = Join-Path $media 'broadcast.ts'
    & $ffmpeg -v error -f lavfi -i 'testsrc2=size=128x96:rate=12' -f lavfi -i 'sine=frequency=440' -f data -i $telemetry -t 2 -map 0:v -map 1:a -map 2:0 -c:v libx264 -c:a aac -c:d copy -f mpegts $withData
    Assert ($LASTEXITCODE -eq 0) 'Data-stream fixture creation failed.'
    $info = (& $ffprobe -v error -show_streams -of json $withData | ConvertFrom-Json)
    Assert (@($info.streams | Where-Object codec_type -eq data).Count -eq 1) 'Fixture must contain a real data stream.'
    $dataHash = (Get-FileHash -LiteralPath $withData).Hash
    Write-Config 0
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $sandbox 'conv2x265-ps.ps1') *> (Join-Path $root 'data-failure.log')
    Assert ($LASTEXITCODE -ne 0) 'Unsupported data stream must fail before encoding.'
    Assert ((Get-FileHash -LiteralPath $withData).Hash -eq $dataHash) 'Data-stream source must remain byte-identical.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $media 'broadcast.mkv'))) 'Rejected data stream must produce no final output.'
    Assert (@(Get-ChildItem -LiteralPath $media -Filter '*.conv2x265-*.mkv').Count -eq 0) 'Rejected data stream must leave no temporary output.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $sandbox 'conv2x265-ps.lock'))) 'Rejected data stream must release lock.'
    $dataLog = Get-Content -Raw -LiteralPath (Join-Path $root 'data-failure.log')
    Assert ($dataLog -match 'Unsupported stream type; source retained') 'Unsupported stream must report a clear refusal.'
    Assert ($dataLog -notmatch 'Converted and validated|HandBrake|Finished') 'Rejected stream must not encode or report successful conversion.'
    Remove-Item -LiteralPath $withData # This test's synthetic fixture; isolate later failure checks.

    $badFile = Join-Path $media 'invalid.mp4'
    Set-Content -LiteralPath $badFile -Value 'invalid source'
    $badHash = (Get-FileHash -LiteralPath $badFile).Hash
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $sandbox 'conv2x265-ps.ps1') *> (Join-Path $root 'failure.log')
    Assert ($LASTEXITCODE -ne 0) 'Failed input must return nonzero to scheduler.'
    Assert ((Get-FileHash -LiteralPath $badFile).Hash -eq $badHash) 'Invalid source must be retained.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $sandbox 'conv2x265-ps.lock'))) 'Failure must release lock.'
    Assert (@(Get-ChildItem -LiteralPath $media -Filter '*.conv2x265-*.mkv').Count -eq 0) 'Temporary output must be removed.'
    $lock = Join-Path $sandbox 'conv2x265-ps.lock'
    Set-Content -LiteralPath $lock -Value 'another instance'
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $sandbox 'conv2x265-ps.ps1') *> (Join-Path $root 'lock.log')
    Assert ($LASTEXITCODE -ne 0) 'Existing instance lock must prevent execution.'
    Assert (Test-Path -LiteralPath $lock) 'Converter must not remove another instance lock.'
    Write-Output 'PASS: threshold boundaries, opt-out, codec selection, anti-loop marker, real HandBrake, validation rejection, in-place HEVC, H264, subtitles, silent video, data-stream source retention, collisions, invalid-source preservation and instance locks.'
} finally {
    # Only this test's newly created, absolute temp directory may be deleted.
    $resolved = [IO.Path]::GetFullPath($root)
    Assert ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) 'Unsafe test cleanup path.'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
