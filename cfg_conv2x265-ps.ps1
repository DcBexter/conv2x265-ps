<#======================================================================================================================
cfg_conv2x265-ps v1.0 RELEASE - https://github.com/DcBexter/conv2x265-ps
This script stores user-defined variables for use by conv2x265-ps.ps1. 
========================================================================================================================
Dependencies:
PowerShell 7.6 LTS+
ffmpeg : https://ffmpeg.org/download.html
handbrakecli : https://handbrake.fr/downloads.php

<#----------------------------------------------------------------------------------------------------------------------
User-defined variables
------------------------------------------------------------------------------------------------------------------------
$mediaPath = the path to the media you want to convert (no trailing "\")
NOTE: For network shares, use UNC path if you plan on running this script as a scheduled task.
----- If running manually and using a mapped drive, you must run "net use z: \\server\share /persistent:yes" as the user
----- you're going to run the script as (generally Administrator) prior to running the script.
$fileTypes = the extensions of the files you want to convert in the format "*.ex1", "*.ex2". Include *.mkv to scan HEVC bitrate.
$logPath = path you want the log file to save to. defaults to your desktop. (no trailing "\")
$logName = the filename of the log file
$plexIP = the IP address and port of your Plex server (for the purpose of refreshing its libraries)
$plexToken = your Plex server's token (for the purpose of refreshing its libraries).
NOTE: Plex server token - See https://support.plex.tv/hc/en-us/articles/204059436-Finding-your-account-token-X-Plex-Token
----- Plex server token is also easy to retrieve with PlexPy, Ombi, Couchpotato, or SickRage 
$ffmpegBinDir = path to ffmpeg bin folder (no trailing "\"). This is the directory containing ffmpeg.exe and ffprobe.exe 
$handbrakeDir = path to Handbrake directory (no trailing "\"). This is the directory containing HandBrakeCLI.exe
$collectGarbage = $True enables garbage collection. $False disables garbage collection.
$script:garbage = the extensions of the files you want to delete in the format "*.ex1", "*.ex2"
$appendLog = $False will clear log at the beginning of every session, $True will append new session log to old session log 
$keepSubs = $False will remove subtitles from converted files. $True will keep subtitles.
$useOutPath = $False will use #mediaPath as the output folder. $True will output converted files to $outPath
$outPath = If $useOutPath = $True, converted files retain their relative subfolders below this directory
-----------------------------------------------------------------------------------------------------------------------#>
$mediaPath = "C:\Path\To\Media\"
$fileTypes = "*.mkv", "*.mp4", "*.avi", "*.flv", "*.mpeg", "*.ts"
$logPath = "$PSScriptRoot"
$logName= "conv2x265-ps.log"
$plexIP = 'localhost:32400'
$plexToken = $env:PLEX_TOKEN # Optional; blank disables Plex refresh.
$ffmpegBinDir = "C:\ffmpeg\bin"
$handbrakeDir = "C:\Program Files\HandBrake"
$collectGarbage = $False
$script:garbage = "*.nfo"
$appendLog = $False
$keepSubs = $True
$useOutPath = $False
$outPath = "C:\outeput\path"

# Re-encode HEVC above decimal MB/hour (whole file); 0 disables HEVC re-encoding.
$maxHevcMBPerHour = 0
