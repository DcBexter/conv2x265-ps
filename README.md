# conv2x265-ps

Recursively convert configured media to MKV with H.265 video and AAC audio using FFmpeg, with HandBrakeCLI fallback. **Successful conversions replace/delete their source. Back up your media first.** Existing destination files never authorize deleting a source.

## Requirements

- Windows x64 and [PowerShell 7.6 LTS](https://learn.microsoft.com/powershell/scripting/install/powershell-support-lifecycle). Use `pwsh.exe`; Windows PowerShell 3/5 is no longer supported.
- [FFmpeg](https://ffmpeg.org/download.html), including `ffmpeg.exe` and `ffprobe.exe`, with the `libx265` encoder. Current CI baseline: 9.0.2, using the Gyan build linked by FFmpeg.
- [HandBrakeCLI](https://handbrake.fr/downloads2.php). Current CI baseline: 1.11.2. CLI options follow the [official reference](https://handbrake.fr/docs/en/latest/cli/command-line-reference.html).

CI downloads pinned tools into its temporary directory and checks vendor SHA256 digests. It never installs or updates tools on your media server. Version pins live in `.github/runtime-versions.json`.

## Configure and run

Edit `cfg_conv2x265-ps.ps1`, then run:

```powershell
pwsh.exe -NoProfile -File "C:\path\to\conv2x265-ps.ps1"
```

| Setting | Meaning |
| --- | --- |
| `$mediaPath` | Media root; use UNC paths for scheduled network access. |
| `$fileTypes` | Filename patterns to scan. Include `*.mkv` to check existing HEVC libraries. |
| `$maxHevcMBPerHour` | Re-encode HEVC strictly above this whole-file size/hour threshold. Default `0` disables HEVC re-encoding. |
| `$ffmpegBinDir` | Directory containing `ffmpeg.exe` and `ffprobe.exe`. |
| `$handbrakeDir` | Directory containing `HandBrakeCLI.exe`. |
| `$logPath`, `$logName`, `$appendLog` | Log location and whether to append. |
| `$keepSubs` | Keep subtitle streams when true; remove them when false. |
| `$useOutPath`, `$outPath` | Write to this existing output directory when enabled; otherwise use source directory. Output names must be unique. |
| `$plexIP` | Plex host and port, for optional refresh after validated conversion. |
| `$plexToken` | Read from `PLEX_TOKEN` environment variable by default. Empty disables refresh. Never commit your token. |
| `$collectGarbage`, `$script:garbage` | Optional deletion of matching ancillary files. Disabled by default. |

### HEVC bitrate threshold (request #1)

```powershell
# Example: eligible when whole file exceeds 1,000 decimal MB per hour.
$maxHevcMBPerHour = 1000
$fileTypes = "*.mkv", "*.mp4", "*.avi", "*.flv", "*.mpeg", "*.ts"
```

Rate is `file bytes * 3600 / duration seconds / 1,000,000`, including audio and container overhead. Equality skips re-encoding. H.264 and other video codecs still convert normally. HEVC MKVs below the threshold, with re-encoding disabled, or already marked as converted are left unchanged. HEVC in another container can still be remuxed/audio-converted to MKV.

Video re-encodes use existing CRF 18 quality setting: **threshold selects inputs; it is not an output bitrate limit**. A HEVC re-encode must save space or source is retained and run reports failure. Successful video encodes store `conv2x265_reencoded=1` in MKV metadata. Later scans skip their video even if still above threshold, preventing a lossy feedback loop. Removing that metadata makes the file eligible again. An unsuccessful attempt retains unmarked source and can be retried next run.

### Source protection

Encoding writes to a unique temporary sibling. Exit status, HEVC codec, stream counts, duration (within 1% or 0.5 seconds, whichever is larger), and complete audio/video decoding must pass before promotion. Subtitle streams are copied in their native format for MKV. HandBrake output passes the same validation; unsupported streams cause failure with source retained.

In-place MKV conversion uses atomic `File.Replace`; unsupported filesystems fail while retaining source. Other containers are deleted only after validated MKV is moved to its final name. Existing unrelated outputs are skipped. Failures return nonzero for Task Scheduler, and normal/error exits release instance lock. A hard kill or power loss can leave lock/temp files: verify no converter is running before removing its lock, and review temporary files before deleting them. Temporary names are excluded from scans.

Plex refresh runs after successful conversion, sends token in HTTP header, and logs no token. Use only a trusted network for configured HTTP Plex endpoint. A refresh failure does not undo conversion.

## Scheduled operation

Create Windows Task Scheduler task under a user with access to configured paths:

- Program: full path to `pwsh.exe`.
- Arguments: `-NoProfile -File "C:\path\to\conv2x265-ps.ps1"`.
- Trigger: schedule suitable for your server. Disallow overlapping task instances.
- Elevated privileges are unnecessary unless your configured file permissions require them.

## Tests and maintenance

```powershell
pwsh -NoProfile -File .\tests\Test-Converter.ps1 -Ffmpeg C:\ffmpeg\bin\ffmpeg.exe -Handbrake C:\HandBrake\HandBrakeCLI.exe
```

Tests use new temporary synthetic media only: threshold boundaries/opt-out, codec selection, output marker, real HandBrake fallback, corrupt/truncated outputs, source retention, in-place HEVC, H.264, destination collision and lock cleanup. Plex refresh, production libraries, hardware encoders and network-filesystem behavior are not exercised.

GitHub Actions runs Windows media tests and strict Renovate configuration validation on PRs, pushes to `master`, and weekly. Dependency review checks supported dependency manifests on PRs. Renovate updates pinned CI tools, Node and action digests. Minor/patch/pin/digest updates request automatic merge subject to branch-required checks; major updates require manual merge. These workflows/schedules take effect after merge.

PowerShell is not a supported CodeQL language. This repository has no supported application package manifest for automatic dependency submission; FFmpeg/HandBrake executables and their native libraries are not covered by GitHub dependency vulnerability scanning. Renovate version checks and actual media CI cover those version pins instead. GitHub secret scanning/push protection, vulnerability alerts/security updates and private vulnerability reporting are repository settings, independent from this branch.
