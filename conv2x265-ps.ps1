#Requires -Version 7.6
$ErrorActionPreference = 'Stop'
<#======================================================================================================================
conv2x265-ps v1.0 RELEASE - https://github.com/DcBexter/conv2x265-ps

This Powershell script will recursively search through a user-defined file path and convert all videos of user-specified 
filetypes to MKV with H265 video and AAC audio using ffmpeg. If a conversion failure is detected, the script re-encodes
the file with HandbrakeCLI. Upon successful encoding, Plex libraries are refreshed and source file is deleted. 
The purpose of this script is to reduce the amount of transcoding CPU load on a Plex server.
========================================================================================================================

ffmpeg : https://ffmpeg.org/download.html
handbrakecli : https://handbrake.fr/downloads.php #>

<#----------------------------------------------------------------------------------------------------------------------
User-defined variables
------------------------------------------------------------------------------------------------------------------------#>
#Create a backup of the cfg file
	$cfgFile = Join-Path "$PSScriptRoot" "cfg_conv2x265-ps.ps1"	
	if (Test-Path -LiteralPath $cfgFile) { Copy-Item -LiteralPath $cfgFile -Destination "$cfgFile.bk" -ErrorAction Stop }
	Write-Host "`nCreated a backup of $cfgFile" -Foregroundcolor Green
#Load variables from cfg_conv2x265-ps.ps1
	$testCfg = Test-Path $cfgFile
	If ($testCfg -eq $True)
	{
		. $cfgFile
	}
	else 
	{
		Write-Output "Cannot find $cfgFile. Make sure it's in the same directory as the script."
		Start-Sleep 10
		Exit	
	}
<#----------------------------------------------------------------------------------
Static variables 
----------------------------------------------------------------------------------#>
#Script version information
	$version = "v1.1"
    if ($null -eq $maxHevcMBPerHour) { $maxHevcMBPerHour = 0 }
    if (-not [double]::IsFinite([double]$maxHevcMBPerHour) -or $maxHevcMBPerHour -lt 0) { throw 'maxHevcMBPerHour must be finite and nonnegative.' }
# Atomically acquire the lock; never remove another running instance's lock.
    $lock = Join-Path $PSScriptRoot 'conv2x265-ps.lock'
    $lockHandle = [System.IO.File]::Open($lock, 'CreateNew', 'Write', 'None')
    try {
# Time and format used for timestamps in the log
	$time = {Get-Date -format "MM/dd/yy HH:mm:ss"}
#Join-Path for log file
	$log = Join-Path "$logPath" "$logName"
# Print initial wait notice to console
	Write-Host "`nBuilding file list, please wait. This may take a while, especially for large libraries.`n"
# Get current time to store as start time for script
	$script:scriptDurStart = (Get-Date -format "HH:mm:ss")
# Build and test file paths to executables and log 
	$ffmpeg = Join-Path "$ffmpegBinDir" "ffmpeg.exe"
	$testFFMPath = Test-Path $ffmpeg
		If ($testFFMPath -eq $False)
		{
			Write-Output "`nffmeg.exe could not be found at $($ffmpegBinDir)." | Tee-Object -filepath $log -append
			Write-Output "Ensure the path in `$ffmpegBinDir is correct." | Tee-Object -filepath $log -append
			Write-Output "Aborting script." | Tee-Object -filepath $log -append
			Exit
		}
		Else
		{
		}
	$ffprobe = Join-Path "$ffmpegBinDir" "ffprobe.exe"
	$testFFPPath = Test-Path $ffprobe
		If ($testFFPPath -eq $False)
		{
			Write-Output "`nffprobe.exe could not be found at $($ffmpegBinDir)." | Tee-Object -filepath $log -append
			Write-Output "Ensure the path in `$ffmpegBinDir is correct." | Tee-Object -filepath $log -append
			Write-Output "Aborting script." | Tee-Object -filepath $log -append
			Exit
		}
		Else
		{
		}
	$handbrake = Join-Path "$handbrakeDir" "HandBrakeCLI.exe"
	$testHBPath = Test-Path $handbrake
		If ($testHBPath -eq $False)
		{
			Write-Output "`nhandbrakecli.exe could not be found at $($handbrakeDir)." | Tee-Object -filepath $log -append
			Write-Output "Ensure the path in `$handbrakeDir is correct." | Tee-Object -filepath $log -append
			Write-Output "Aborting script." | Tee-Object -filepath $log -append
			Exit
		}
		Else
		{
		}
# Setup for file list loop
	$testMediaPath = Test-Path $mediaPath
	If ($testMediaPath -eq $True)
	{
		$mPath = Get-Item -LiteralPath $mediaPath
	}
	Else
	{
		Write-Output "`nPath not found: $mediaPath" | Tee-Object -filepath $log -append
		Write-Output "Ensure the path in `$mediaPath exists and is accessible." | Tee-Object -filepath $log -append
		Write-Output "Aborting script." | Tee-Object -filepath $log -append
		Exit
	}
	$b=0
	$fileList = Get-ChildItem -LiteralPath $mPath.FullName -File -Recurse | Where-Object { $name = $_.Name; @($fileTypes | Where-Object { $name -like $_ }).Count -gt 0 -and $name -notlike "*.conv2x265-*.mkv" } | ForEach-Object {$b++; If ($b -eq 1){Write-Host -NoNewLine "`rFound $b file so far..."} Else{Write-Host -NoNewLine "`rFound $b files so far..." -foregroundcolor green};$_}
	$num = $fileList | measure
	$fileCount = $num.count
# Initialize disk usage change to 0
	$diskUsage = 0
# Initialize 'video length converted' to 0
	$durTotal = [timespan]::fromseconds(0)

<#----------------------------------------------------------------------------------
Functions 
----------------------------------------------------------------------------------#>
# Logging and console output
	Function Log
	{
	   Param ([string]$logString)
	   Write-Output $logString | Tee-Object -filepath $log -append
	}
# Prints the current script version header	
	Function PrintVersion
	{
		Log "conv2x265-ps $version - https://github.com/DcBexter/conv2x265-ps"
		Log "------------------------------------------------------------------------------------"
	}
# Append log conditions
	Function AppendLog
	{
		#Check whether log file is empty
			$logEmpty = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log }
		#Should the log append or clear
			If ($appendLog -eq $False)
			{
				Set-Content -LiteralPath $log -Value ''
				PrintVersion
			}
			Elseif ($appendLog -eq $True -AND $logEmpty -eq $Null)
			{
				PrintVersion
			}
			Else
			{
				Log "`n------------------------------------------------------------------------------------"
				Log ">>>>> New Session (started $($time.Invoke()))"
			}
	}
# List files in the queue in the log
	Function ListFiles
	{			 
		If ($fileCount -eq 1)
		{
			AppendLog
			Log ("`nThere is $fileCount file in the queue:`n")
		}
		Elseif ($fileCount -gt 1)
		{
			AppendLog
			Log ("`nThere are $fileCount files in the queue:`n")
		}
		Else
		{
			Write-Host ("`nThere are no files to be converted in $mediaPath. Congrats!`n")
			Exit
		}
		
		$num = 0
			ForEach ($file in $fileList)
				{
					$num++
					Log "$($num). $file"
				}
				Log ""
	}
# Probe once; invalid metadata must never reach the encoder or source deletion.
    Function CodecDiscovery
    {
        $probeText = & $ffprobe -v error -show_format -show_streams -of json $oldFile
        if ($LASTEXITCODE -ne 0) { throw "ffprobe failed: $oldFile" }
        $script:sourceInfo = ($probeText -join "`n") | ConvertFrom-Json
        if (@($script:sourceInfo.streams | Where-Object { $_.codec_type -notin @('video', 'audio', 'subtitle', 'attachment') }).Count -gt 0) {
            throw "Unsupported stream type; source retained: $oldFile"
        }
        $video = @($script:sourceInfo.streams | Where-Object codec_type -eq video)
        if ($video.Count -eq 0) { throw "No video stream: $oldFile" }
        $script:durationSeconds = [double]::Parse($script:sourceInfo.format.duration, [cultureinfo]::InvariantCulture)
        if (-not [double]::IsFinite($script:durationSeconds) -or $script:durationSeconds -le 0) { throw "Invalid duration: $oldFile" }
        $script:vCodecCMD = $video[0].codec_name
        $script:aCodecCMD = [string](@($script:sourceInfo.streams | Where-Object codec_type -eq audio)[0].codec_name)
        $script:durTicks = [timespan]::FromSeconds($script:durationSeconds).Ticks
        $script:duration = [timespan]::FromSeconds($script:durationSeconds)
    }
 
# MB/hour means decimal megabytes for the whole file, including audio/container overhead.
    Function Test-HevcReencode
    {
        return ($maxHevcMBPerHour -gt 0 -and $vCodecCMD -eq 'hevc' -and
            $sourceInfo.format.tags.conv2x265_reencoded -ne '1' -and
            ((Get-Item -LiteralPath $oldFile).Length * 3600 / $durationSeconds / 1000000) -gt $maxHevcMBPerHour)
    }
				
# Check streams, duration and complete audio/video decoding before replacing/deleting source.
    Function Test-Conversion
    {
        if (-not (Test-Path -LiteralPath $newFile) -or (Get-Item -LiteralPath $newFile).Length -eq 0) { return $false }
        $probeText = & $ffprobe -v error -show_format -show_streams -of json $newFile
        if ($LASTEXITCODE -ne 0) { return $false }
        try {
            $info = ($probeText -join "`n") | ConvertFrom-Json
            $seconds = [double]::Parse($info.format.duration, [cultureinfo]::InvariantCulture)
            if (-not [double]::IsFinite($seconds) -or [math]::Abs($seconds - $durationSeconds) -gt [math]::Max(0.5, $durationSeconds * 0.01)) { return $false }
            foreach ($type in @('video', 'audio', 'subtitle', 'attachment')) {
                if ($type -eq 'subtitle' -and -not $keepSubs) { continue }
                $before = @($sourceInfo.streams | Where-Object codec_type -eq $type).Count
                $after = @($info.streams | Where-Object codec_type -eq $type).Count
                if ($after -ne $before) { return $false }
            }
            $video = @($info.streams | Where-Object codec_type -eq video)
            if (@($video | Where-Object codec_name -ne hevc).Count -gt 0) { return $false }
            if ($reencodeHevc -and $info.format.tags.conv2x265_reencoded -ne '1') { return $false }
        } catch { return $false }
        & $ffmpeg -v error -xerror -i $newFile -map '0:v' -map '0:a?' -f null -
        return ($LASTEXITCODE -eq 0)
    }
# If a file video codec is already H265 and audio codec is already AAC, use these arguments
	Function SimpleConvert	
	{	
		Log "$($time.Invoke()) Video: $($script:vCodecCMD.ToUpper()), Audio: $($script:aCodecCMD.ToUpper()). Performing simple container conversion to MKV."
		
		If ($keepSubs -eq $True)
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"
				$ffArgNV1 = "-hwaccel"
				$ffArgNV2 = "cuvid"				
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "copy"
				$ffArg12 = "-c:a"
				$ffArg13 = "copy"
				$ffArg14 = "-c:s"
				$ffArg15 = "copy"
				$ffArg16 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffArg14, $ffArg15, $ffArg16)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
		
			# Begin ffmpeg operation
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
		Else
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArgNV1 = "-hwaccel"
				$ffArgNV2 = "cuvid"			
				$ffArg7 = "8"
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "copy"
				$ffArg12 = "-c:a"
				$ffArg13 = "copy"
				$ffArg14 = "-sn"
				$ffArg15 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffArg14, $ffArg15)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
		
			# Begin ffmpeg operation
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
	}
# If a file video codec is already H265, but audio codec is not AAC, use these arguments
	Function EncodeAudio
	{
		Log "$($time.Invoke()) Video: $($script:vCodecCMD.ToUpper()), Audio: $($script:aCodecCMD.ToUpper()). Encoding audio to AAC"
			
		If ($keepSubs -eq $True)
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "copy"
				$ffArg12 = "-c:a"
				$ffArg13 = "aac"
				$ffArg14 = "-c:s"
				$ffArg15 = "copy"
				$ffArg16 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffArg14, $ffArg15, $ffArg16)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
		
			# Begin ffmpeg operation
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
		Else
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "copy"
				$ffArg12 = "-c:a"
				$ffArg13 = "aac"
				$ffArg14 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffArg14)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
		
			# Begin ffmpeg operation
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
	}
# If a file video codec is not H265, and audio codec is already AAC, use these arguments
	Function EncodeVideo
	{
		Log "$($time.Invoke()) Video: $($script:vCodecCMD.ToUpper()), Audio: $($script:aCodecCMD.ToUpper()). Encoding video to H265."
	
		If ($keepSubs -eq $True)
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"		
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "libx265"
				$ffArg12 = "-preset"
				$ffArg13 = "medium"
				$ffargx265Key = "-x265-params"
				$ffargx265Val = "crf=18"
				$ffArg16 = "-c:a"
				$ffArg17 = "copy"
				$ffArg18 = "-c:s"
				$ffArg19 = "copy"
				$ffArg20 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffargx265Key, $ffargx265Val, $ffArg16, $ffArg17, $ffArg18, $ffArg19, $ffArg20)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
		
			# Begin ffmpeg operation
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
		Else
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"		
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "libx265"
				$ffArg12 = "-preset"
				$ffArg13 = "medium"
				$ffargx265Key = "-x265-params"
				$ffargx265Val = "crf=18"
				$ffArg16 = "-c:a"
				$ffArg17 = "copy"
				$ffArg18 = "-sn"
				$ffArg19 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffargx265Key, $ffargx265Val, $ffArg16, $ffArg17, $ffArg18, $ffArg19)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE

			# Begin ffmpeg operation
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
	}
# If a file video codec is not H265, and audio codec is not AAC, use these arguments
	Function EncodeBoth
	{	
		Log "$($time.Invoke()) Video: $($script:vCodecCMD.ToUpper()), Audio: $($script:aCodecCMD.ToUpper()). Encoding video to H265 and audio to AAC."
	
		If ($keepSubs -eq $True)
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"		
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "libx265"
				$ffArg12 = "-preset"
				$ffArg13 = "medium"
				$ffargx265Key = "-x265-params"
				$ffargx265Val = "crf=18"
				$ffArg16 = "-c:a"
				$ffArg17 = "aac"
				$ffArg18 = "-c:s"
				$ffArg19 = "copy"
				$ffArg20 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffargx265Key, $ffargx265Val, $ffArg16, $ffArg17, $ffArg18, $ffArg19, $ffArg20)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
				
			# Begin ffmpeg operations
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"	
		}
		Else
		{
			# ffmpeg arguments
				$ffargHideBanner = "-hide_banner"
				$ffArg1 = "-n"
				$ffArg2 = "-fflags"
				$ffArg3 = "+genpts"
				$ffArg4 = "-i"
				$ffArg5 = "$oldFile"
				$ffArg6 = "-threads"
				$ffArg7 = "8"		
				$ffArg8 = "-map"
				$ffArg9 = "0"
				$ffArg10 = "-c:v"
				$ffArg11 = "libx265"
				$ffArg12 = "-preset"
				$ffArg13 = "medium"
				$ffargx265Key = "-x265-params"
				$ffargx265Val = "crf=18"
				$ffArg16 = "-c:a"
				$ffArg17 = "aac"
				$ffArg18 = "-sn"
				$ffArg19 = "$newFile"
				$ffArgs = @($ffargHideBanner, $ffArg1, $ffArg2, $ffArg3, $ffArg4, $ffArg5, $ffArg6, $ffArg7, $ffArg8, $ffArg9, $ffArg10, $ffArg11, $ffArg12, $ffArg13, $ffargx265Key, $ffargx265Val, $ffArg16, $ffArg17, $ffArg18, $ffArg19)
				if ($ffArgs -contains 'libx265') { $ffArgs = $ffArgs[0..($ffArgs.Count - 2)] + @('-metadata', 'conv2x265_reencoded=1', $newFile) }
                $ffCMD = &$ffmpeg $ffArgs
                $script:encoderExitCode = $LASTEXITCODE
				
			# Begin ffmpeg operations
				$ffCMD
				Log "$($time.Invoke()) ffmpeg completed"
		}
	}	
# Fallback keeps the same source; validation below still controls promotion/deletion.
    Function EncodeHandbrake
    {
        $hbArgs = @('-i', $oldFile, '-o', $newFile, '-f', 'av_mkv', '-e', 'x265', '-q', '18',
            '--all-audio', '-E', 'av_aac', '--auto-anamorphic')
        if ($keepSubs) { $hbArgs += '--all-subtitles' }
        & $handbrake $hbArgs
        $script:encoderExitCode = $LASTEXITCODE
        if ($encoderExitCode -eq 0) {
            $taggedFile = "$newFile.tagged.mkv"
            try {
                & $ffmpeg -v error -n -i $newFile -map 0 -c copy -metadata conv2x265_reencoded=1 $taggedFile
                $script:encoderExitCode = $LASTEXITCODE
                if ($encoderExitCode -eq 0) { Move-Item -LiteralPath $taggedFile -Destination $newFile -Force -ErrorAction Stop }
            } finally {
                if (Test-Path -LiteralPath $taggedFile) { Remove-Item -LiteralPath $taggedFile -ErrorAction Stop }
            }
        }
    }
# Delete garbage files
	Function GarbageCollection
	{
		$garbageList = Get-ChildItem "$($mPath.FullName)\*" -i $script:garbage -recurse
		$garbageNum = 0

			ForEach ($turd in $garbageList)
			{
				$garbageNum++
			}	
		
				If ($garbageNum -eq 1)
				{
					Log "`nGarbage Collection: The following file was deleted:"
				}
				Elseif ($garbageNum -gt 1)
				{
					Log "`nGarbage Collection: The following $garbageNum files were deleted:"
				}
				Else
				{
					Log ("`nGarbage Collection: No garbage found in $mediaPath. Congrats!")
				}
				Log ""
			
		$garbageNum = 0
		
			ForEach ($turd in $garbageList)
			{
				$garbageNum++
				Log "$($garbageNum). $turd"
					Try
					{
						Remove-Item -LiteralPath $turd -Force -ErrorAction Stop
					}
					Catch
					{
						Log "$($time.Invoke()) ERROR: $turd could not be deleted. Full error below."
						Log $_
					}
			}	
	}
# Log various session statistics 
	Function FinalStatistics
	{
		Log "`n====================================================================================`n"
		#Print total session disk usage changes
			If ($script:diskUsage -gt -1 -AND $script:diskUsage -lt 1)
			{
				$diskUsage_KB = ($script:diskUsage * 1000)
				Log "$($time.Invoke()) Total cumulative storage difference: $($diskUsage_KB)KB"
			}
			Elseif ($script:diskUsage -lt -1000 -OR $script:diskUsage -gt 1000)
			{
				$diskUsage_GB = ($script:diskUsage / 1000)
				Log "$($time.Invoke()) Total cumulative storage difference: $($diskUsage_GB)GB"					
			}
			Else
			{
				Log "$($time.Invoke()) Total cumulative storage difference: $($script:diskUsage)MB"					
			}
		#Do some time math to get total script runtime
			$script:scriptDurTemp = new-timespan $script:scriptDurStart $(get-date -format "HH:mm:ss")
			$script:scriptDurTotal = "$($script:scriptDurTemp.hours):$($script:scriptDurTemp.minutes):$($script:scriptDurTemp.seconds)"
			Log "`n$script:durTotal of video processed in $script:scriptDurTotal"
		#Do some math/rounding to get session average conversion speed	
			Try
			{
				$avgConv = $script:durTicksTotal / $script:scriptDurTemp.Ticks
				$avgConv = [math]::Round($avgConv,2)
				Log "Average conversion speed of $($avgConv)x"
			}
			Catch
			{
				Log "No time elapsed."
			}
			
		Log "`n===================================================================================="
	}
	
<#----------------------------------------------------------------------------------
Begin search loop 
----------------------------------------------------------------------------------#>
# List files in the queue in the log
	ListFiles

# Both new containers and in-place MKV conversions use a fresh temporary sibling.
    $i = 0
    $failedFiles = 0
    foreach ($file in $fileList) {
        $i++
        $oldFile = $file.FullName
        $targetDirectory = if ($useOutPath) { Join-Path $outPath ([IO.Path]::GetRelativePath($mPath.FullName, $file.DirectoryName)) } else { $file.DirectoryName }
        $finalFile = Join-Path $targetDirectory ($file.BaseName + '.mkv')
        $inPlace = [IO.Path]::GetFullPath($oldFile) -eq [IO.Path]::GetFullPath($finalFile)
        if (-not $inPlace -and (Test-Path -LiteralPath $finalFile)) {
            Log "Output exists; retaining source: $oldFile"
            continue
        }
        $newFile = Join-Path ([IO.Path]::GetDirectoryName($finalFile)) ($file.BaseName + '.conv2x265-' + [guid]::NewGuid().ToString('N') + '.mkv')
        try {
            $sourceSnapshot = Get-Item -LiteralPath $oldFile
            $sourceLength = $sourceSnapshot.Length
            $sourceWriteTime = $sourceSnapshot.LastWriteTimeUtc
            CodecDiscovery
            $reencodeHevc = Test-HevcReencode
            if ($file.Extension -eq '.mkv' -and $vCodecCMD -eq 'hevc' -and -not $reencodeHevc) {
                Log "Skipping HEVC MKV (below threshold, disabled, or already encoded): $oldFile"
                continue
            }
            if ($useOutPath) { [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null }
            $script:durTotal += $script:duration
            $script:durTicksTotal += $script:durTicks
            if ($vCodecCMD -eq 'hevc' -and -not $reencodeHevc) {
                if ($aCodecCMD -eq 'aac' -or $aCodecCMD -eq '') { SimpleConvert } else { EncodeAudio }
            } else {
                if ($aCodecCMD -eq 'aac' -or $aCodecCMD -eq '') { EncodeVideo } else { EncodeBoth }
            }
            if ($encoderExitCode -ne 0 -or -not (Test-Conversion)) {
                if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -ErrorAction Stop }
                EncodeHandbrake
                if ($encoderExitCode -ne 0 -or -not (Test-Conversion)) { throw 'Both encoders failed validation; source retained.' }
            }
            if ($reencodeHevc -and (Get-Item -LiteralPath $newFile).Length -ge $file.Length) {
                throw 'HEVC re-encode did not save space; source retained.'
            }
            $savedBytes = $file.Length - (Get-Item -LiteralPath $newFile).Length
            $currentSource = Get-Item -LiteralPath $oldFile
            if ($currentSource.Length -ne $sourceLength -or $currentSource.LastWriteTimeUtc -ne $sourceWriteTime) {
                throw 'Source changed during conversion; source retained.'
            }
            if ($inPlace) {
                [IO.File]::Replace($newFile, $oldFile, [NullString]::Value)
            } else {
                Move-Item -LiteralPath $newFile -Destination $finalFile -ErrorAction Stop
                Remove-Item -LiteralPath $oldFile -ErrorAction Stop
            }
            $script:diskUsage -= $savedBytes / 1MB
            Log "Converted and validated: $finalFile"
            if ($plexToken) {
                try {
                    Invoke-WebRequest -Uri "http://$plexIP/library/sections/all/refresh" -Headers @{ 'X-Plex-Token' = $plexToken } -TimeoutSec 30 | Out-Null
                    Log 'Plex libraries refreshed.'
                } catch { Log 'Plex refresh failed; conversion already completed.' }
            }
        } catch {
            $failedFiles++
            Log "ERROR processing $oldFile : $_"
        } finally {
            if (Test-Path -LiteralPath $newFile) { Remove-Item -LiteralPath $newFile -ErrorAction Stop }
        }
    }
	
<#----------------------------------------------------------------------------------
Wrap-up
-----------------------------------------------------------------------------------#>
FinalStatistics
If ($collectGarbage -eq $True)
{
	GarbageCollection
}
Else
{}
if ($failedFiles -gt 0) { throw "$failedFiles file(s) failed; check log. Sources retained on conversion failure." }
Log "`nFinished"
    } finally {
        $lockHandle.Dispose()
        Remove-Item -LiteralPath $lock -ErrorAction Stop
    }
