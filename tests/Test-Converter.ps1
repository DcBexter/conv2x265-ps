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
    function Write-Config([double]$threshold, [bool]$subs = $true) {
        $config = @{
            mediaPath = $media; fileTypes = @('*.mp4', '*.mkv'); logPath = $sandbox
            logName = 'test.log'; plexToken = ''; ffmpegBinDir = (Split-Path $Ffmpeg)
            handbrakeDir = (Split-Path $Handbrake); collectGarbage = $false
            appendLog = $false; keepSubs = $subs; useOutPath = $false; maxHevcMBPerHour = $threshold
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
    Write-Output 'PASS: threshold boundaries, opt-out, codec selection, anti-loop marker, real HandBrake, validation rejection, in-place HEVC, H264, subtitles, silent video, collisions, invalid-source preservation and instance locks.'
} finally {
    # Only this test's newly created, absolute temp directory may be deleted.
    $resolved = [IO.Path]::GetFullPath($root)
    Assert ($resolved.StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) 'Unsafe test cleanup path.'
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
