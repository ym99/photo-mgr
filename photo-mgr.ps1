#requires -Version 7.0
# plain param block on purpose: [CmdletBinding()] rejects options that prefix a common parameter (-Out)
param([string]$Command)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Schema       = 1
$Script:ManifestName = '.catalog.jsonl'
$Script:TwinMarker   = '--library--'
$Script:TwinLinkExt  = '.lnk'
$Script:TwinMaxLen   = 180
$Script:Shell        = $null
$Script:Utf8NoBom    = [System.Text.UTF8Encoding]::new($false)
$Script:MinYear      = 1990
$Script:ExifTool     = $null

$Script:RawExts        = @('.nef', '.cr2', '.cr3', '.crw', '.arw', '.dng', '.orf', '.rw2', '.raf', '.pef', '.srw')
$Script:HeicExts       = @('.heic', '.heif')
$Script:JpegExts       = @('.jpg', '.jpeg')
$Script:VideoExts      = @('.mov', '.qt', '.mp4', '.m4v', '.avi', '.mts', '.m2ts', '.3gp', '.wmv', '.mkv', '.mpg', '.mpeg')
$Script:OtherImageExts = @('.png', '.gif', '.bmp', '.tif', '.tiff', '.webp')
$Script:SidecarExts    = @('.xmp', '.aae', '.thm')
$Script:JunkNames      = @('thumbs.db', 'desktop.ini', '.ds_store')

function Get-SotPaths {
    param([string]$RootPath)
    $full = [System.IO.Path]::GetFullPath($RootPath)
    $decide  = Join-Path $full '_must-decide'
    $provide = Join-Path $full '_must-provide'
    $safe    = Join-Path $full '_safe-to-delete'
    [pscustomobject]@{
        Root          = $full
        Library       = Join-Path $full 'library'
        MustDecide    = $decide
        MustProvide   = $provide
        SafeToDelete  = $safe
        Keep          = Join-Path $decide 'keep'
        PartialCopy   = Join-Path $decide 'partial-copy--group-has-new-files'
        SuspectCopy   = Join-Path $decide 'suspected-copy--same-time-and-camera-but-diff-hash'
        DateMissing   = Join-Path $provide 'date-missing--no-exif-or-filename'
        CompleteBytes  = Join-Path $safe 'complete-copy--same-bytes'
        CompletePixels = Join-Path $safe 'complete-copy--same-pixels'
        Damaged       = Join-Path $safe 'damaged--zero-bytes'
        NonMedia      = Join-Path $safe 'non-media'
        OrphanSidecar = Join-Path $safe 'orphan-sidecar'
    }
}

function Assert-SotRoot {
    param($Paths)
    if (-not (Test-Path -LiteralPath $Paths.Library -PathType Container)) {
        Write-Host "library\ not found under $($Paths.Root)"
        Write-Host '  wrong -Root? (default is the script folder)'
        Write-Host "  for a brand-new SoT create it manually: mkdir `"$($Paths.Library)`""
        throw 'library folder not found'
    }
    $lp = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue
    if (-not $lp -or $lp.LongPathsEnabled -ne 1) {
        Write-Warning 'LongPathsEnabled is off; paths over 260 chars will fail'
    }
}

function Confirm-KeepFolder {
    param($Paths)
    if ((Test-Path -LiteralPath $Paths.MustDecide) -and -not (Test-Path -LiteralPath $Paths.Keep)) {
        New-Item -ItemType Directory -Path $Paths.Keep -Force | Out-Null
    }
}

function ConvertTo-Nfc {
    param([string]$Value)
    $Value.Normalize([System.Text.NormalizationForm]::FormC)
}

function Get-SanitizedName {
    param([string]$Name)
    $clean = ConvertTo-Nfc $Name
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $clean = $clean.Replace([string]$ch, '_')
    }
    $clean
}

function Get-UtcNowStamp {
    [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

function Format-Count {
    param([long]$Value)
    $Value.ToString('N0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Size {
    param([long]$Bytes)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1TB) { return '{0} TB' -f ($Bytes / 1TB).ToString('N2', $inv) }
    if ($Bytes -ge 1GB) { return '{0} GB' -f ($Bytes / 1GB).ToString('N2', $inv) }
    if ($Bytes -ge 1MB) { return '{0} MB' -f ($Bytes / 1MB).ToString('N2', $inv) }
    '{0} bytes' -f (Format-Count $Bytes)
}

function ConvertTo-JsonLine {
    param($Value)
    $json = $Value | ConvertTo-Json -Compress -Depth 4
    if ($json.Contains("`n")) { throw 'Serialized record spans multiple lines' }
    $json
}

function Get-ManifestPath {
    param([string]$Folder)
    Join-Path $Folder $Script:ManifestName
}

# ConvertFrom-Json turns ISO-8601 strings into [datetime]; put them back as written
function Restore-RecordDates {
    param($Record)
    if ($Record.date_taken -is [datetime]) {
        $Record.date_taken = $Record.date_taken.ToString("yyyy-MM-dd'T'HH:mm:ss")
    }
    foreach ($name in @('ingested_at', 'last_verified')) {
        if ($Record.$name -is [datetime]) {
            $Record.$name = $Record.$name.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
    }
    $Record
}

function Read-Manifest {
    param([string]$Folder)
    $records = [System.Collections.Generic.List[object]]::new()
    $path = Get-ManifestPath $Folder
    if (-not (Test-Path -LiteralPath $path)) { return , $records }
    $lines = [System.IO.File]::ReadAllLines($path, $Script:Utf8NoBom)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        try { $records.Add((Restore-RecordDates ($line | ConvertFrom-Json))) }
        catch {
            if ($i -eq $lines.Count - 1) { Write-Warning "Dropping torn final line in $path"; continue }
            throw "Damaged manifest $path at line $($i + 1)"
        }
    }
    , $records
}

function Add-ManifestRecord {
    param([string]$Folder, $Record)
    $text = (ConvertTo-JsonLine $Record) + "`n"
    [System.IO.File]::AppendAllText((Get-ManifestPath $Folder), $text, $Script:Utf8NoBom)
}

function Write-Manifest {
    param([string]$Folder, $Records)
    $path = Get-ManifestPath $Folder
    $tmp = "$path.tmp"
    $lines = @($Records | Sort-Object { $_.name } | ForEach-Object { ConvertTo-JsonLine $_ })
    [System.IO.File]::WriteAllLines($tmp, [string[]]$lines, $Script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function New-FileRecord {
    param(
        [string]$Name, [string]$RoleName, $PrimaryName, [long]$Size,
        [string]$HashFull, $HashImage,
        [datetime]$DateTaken, [string]$DateSource, $TzOffset,
        $Width, $Height, $Duration,
        $CameraMake, $CameraModel, $CameraSerial,
        [string]$OrigFilename, [string]$IngestedAt
    )
    [ordered]@{
        schema         = $Script:Schema
        name           = $Name
        role           = $RoleName
        primary        = $PrimaryName
        size           = $Size
        hash_full      = $HashFull
        hash_imagedata = $HashImage
        date_taken     = $DateTaken.ToString("yyyy-MM-dd'T'HH:mm:ss")
        date_source    = $DateSource
        tz_offset      = $TzOffset
        width          = $Width
        height         = $Height
        duration       = $Duration
        camera_make    = $CameraMake
        camera_model   = $CameraModel
        camera_serial  = $CameraSerial
        orig_filename  = $OrigFilename
        ingested_at    = $IngestedAt
        last_verified  = $IngestedAt
    }
}

function Get-FileSha256 {
    param([string]$Path)
    'sha256:' + (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Set-FileReadOnly {
    param([string]$Path, [bool]$Value)
    (Get-Item -LiteralPath $Path -Force).IsReadOnly = $Value
}

function Resolve-ExifTool {
    $local = Join-Path $PSScriptRoot 'exiftool.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command exiftool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    Write-Host 'exiftool not found next to the script or on PATH'
    Write-Host '  install:  winget install OliverBetz.ExifTool   (then open a new terminal)'
    Write-Host '  or copy exiftool.exe plus its exiftool_files\ folder next to photo-mgr.ps1'
    throw 'exiftool not found'
}

$Script:ExifToolArgs = @(
    '-json', '-n', '-G'
    '-charset', 'filename=UTF8'
    '-api', 'QuickTimeUTC=1'
    '-api', 'ImageHashType=SHA256'
    '-EXIF:DateTimeOriginal', '-EXIF:CreateDate', '-EXIF:OffsetTimeOriginal'
    '-MakerNotes:DateTimeOriginal', '-RIFF:DateTimeOriginal'
    '-QuickTime:CreateDate', '-Matroska:DateTimeOriginal'
    '-Make', '-Model', '-SerialNumber', '-BodySerialNumber'
    '-ImageWidth', '-ImageHeight', '-Duration'
    '-ImageDataHash'
)

function Get-MediaMetadata {
    param([string[]]$Paths)
    $map = @{}
    if (-not $Paths -or $Paths.Count -eq 0) { return $map }
    $batchSize = 500
    for ($offset = 0; $offset -lt $Paths.Count; $offset += $batchSize) {
        $last = [Math]::Min($offset + $batchSize, $Paths.Count) - 1
        $batch = $Paths[$offset..$last]
        $argFile = Join-Path ([System.IO.Path]::GetTempPath()) ('photo-mgr-' + [guid]::NewGuid().ToString('n') + '.args')
        [System.IO.File]::WriteAllLines($argFile, [string[]]($Script:ExifToolArgs + $batch), $Script:Utf8NoBom)
        try {
            $raw = & $Script:ExifTool -@ $argFile 2>$null
            $parsed = $null
            if ($raw) { $parsed = $raw -join "`n" | ConvertFrom-Json }
            if (-not $parsed) {
                throw "exiftool returned no metadata for a batch of $($batch.Count) files starting at $($batch[0])"
            }
            foreach ($entry in $parsed) {
                $key = [System.IO.Path]::GetFullPath($entry.SourceFile).ToLowerInvariant()
                $map[$key] = $entry
            }
        }
        finally { Remove-Item -LiteralPath $argFile -ErrorAction SilentlyContinue }
        Write-Progress -Activity 'Reading metadata' -Status "$(Format-Count ($last + 1)) / $(Format-Count $Paths.Count)"
    }
    Write-Progress -Activity 'Reading metadata' -Completed
    $map
}

function Get-Tag {
    param($Entry, [string[]]$Names)
    if ($null -eq $Entry) { return $null }
    foreach ($name in $Names) {
        foreach ($prop in $Entry.PSObject.Properties) {
            $plain = $prop.Name
            $idx = $plain.IndexOf(':')
            if ($idx -ge 0) { $plain = $plain.Substring($idx + 1) }
            if ($plain -eq $name -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') {
                return $prop.Value
            }
        }
    }
    $null
}

function Get-GroupTag {
    param($Entry, [string]$Group, [string]$Name)
    if ($null -eq $Entry) { return $null }
    $prop = $Entry.PSObject.Properties["${Group}:${Name}"]
    if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne '') { return $prop.Value }
    $null
}

function ConvertFrom-ExifDate {
    param([string]$Value)
    if (-not $Value) { return $null }
    $m = [regex]::Match($Value, '^(\d{4}):(\d{2}):(\d{2}) (\d{2}):(\d{2}):(\d{2})')
    if (-not $m.Success) { return $null }
    try {
        [datetime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value,
            [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value)
    }
    catch { $null }
}

function Test-SaneDate {
    param([datetime]$Date)
    ($Date.Year -ge $Script:MinYear) -and ($Date -le [DateTime]::Now.AddDays(1))
}

function Get-MachineTzOffset {
    param([datetime]$Local)
    $span = [TimeZoneInfo]::Local.GetUtcOffset($Local)
    $sign = if ($span.Ticks -lt 0) { '-' } else { '+' }
    '{0}{1:d2}:{2:d2}' -f $sign, [Math]::Abs($span.Hours), [Math]::Abs($span.Minutes)
}

$Script:NamePatterns = @(
    [pscustomobject]@{ Rx = [regex]'(?i)^(?:IMG|VID|PANO|PXL)[-_](\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'(?i)^(?:IMG|VID)-(\d{4})(\d{2})(\d{2})-WA\d+'; DateOnly = $true }
    [pscustomobject]@{ Rx = [regex]'(?i)^Screenshot[_ -](\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'(?i)^video-(\d{4})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'(?i)^(\d{4})-(\d{2})-(\d{2})[ _](\d{2})[.\-](\d{2})[.\-](\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'(?i)^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?:[_.]|$)'; DateOnly = $false }
)

function Resolve-NameDate {
    param([string]$Name)
    foreach ($pat in $Script:NamePatterns) {
        $m = $pat.Rx.Match($Name)
        if (-not $m.Success) { continue }
        try {
            if ($pat.DateOnly) {
                $date = [datetime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, 12, 0, 0)
            }
            else {
                $date = [datetime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value,
                    [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value)
            }
        }
        catch { continue }
        if (Test-SaneDate $date) { return $date }
    }
    $null
}

function Resolve-DateTaken {
    param($Meta, [string]$FileName)
    foreach ($tag in @('DateTimeOriginal', 'CreateDate')) {
        $date = ConvertFrom-ExifDate (Get-GroupTag $Meta 'EXIF' $tag)
        if ($date -and (Test-SaneDate $date)) {
            $tz = $null
            $offset = Get-GroupTag $Meta 'EXIF' 'OffsetTimeOriginal'
            if ($offset -and $offset -match '^[+-]\d{2}:\d{2}$') { $tz = $offset }
            return [pscustomobject]@{ Date = $date; Source = 'exif'; Tz = $tz }
        }
    }
    foreach ($group in @('MakerNotes', 'RIFF')) {
        $date = ConvertFrom-ExifDate (Get-GroupTag $Meta $group 'DateTimeOriginal')
        if ($date -and (Test-SaneDate $date)) {
            return [pscustomobject]@{ Date = $date; Source = $group.ToLowerInvariant(); Tz = $null }
        }
    }

    $qt = ConvertFrom-ExifDate (Get-GroupTag $Meta 'QuickTime' 'CreateDate')
    if ($qt -and (Test-SaneDate $qt)) {
        return [pscustomobject]@{ Date = $qt; Source = 'quicktime'; Tz = Get-MachineTzOffset $qt }
    }
    # Matroska stamps UTC (trailing Z); QuickTime is pre-localized by the QuickTimeUTC api flag
    $mkvRaw = Get-GroupTag $Meta 'Matroska' 'DateTimeOriginal'
    $mkv = ConvertFrom-ExifDate $mkvRaw
    if ($mkv -and "$mkvRaw" -match 'Z\s*$') { $mkv = [datetime]::SpecifyKind($mkv, 'Utc').ToLocalTime() }
    if ($mkv -and (Test-SaneDate $mkv)) {
        return [pscustomobject]@{ Date = $mkv; Source = 'matroska'; Tz = Get-MachineTzOffset $mkv }
    }

    $named = Resolve-NameDate $FileName
    if ($named) {
        return [pscustomobject]@{ Date = $named; Source = 'filename'; Tz = $null }
    }
    $null
}

function Get-ImageDataHash {
    param($Meta)
    $value = Get-Tag $Meta @('ImageDataHash')
    if ($value) { 'sha256:' + "$value".ToLowerInvariant() } else { $null }
}

function Get-ExtInfo {
    param([string]$Ext)
    $e = $Ext.ToLowerInvariant()
    if ($Script:RawExts -contains $e)        { return [pscustomobject]@{ Kind = 'media'; Rank = 0 } }
    if ($Script:HeicExts -contains $e)       { return [pscustomobject]@{ Kind = 'media'; Rank = 1 } }
    if ($Script:JpegExts -contains $e)       { return [pscustomobject]@{ Kind = 'media'; Rank = 2 } }
    if ($Script:VideoExts -contains $e)      { return [pscustomobject]@{ Kind = 'media'; Rank = 3 } }
    if ($Script:OtherImageExts -contains $e) { return [pscustomobject]@{ Kind = 'media'; Rank = 4 } }
    if ($Script:SidecarExts -contains $e)    { return [pscustomobject]@{ Kind = 'sidecar'; Rank = 99 } }
    [pscustomobject]@{ Kind = 'other'; Rank = -1 }
}

function Get-AssetGroups {
    param([System.IO.FileInfo[]]$Files)
    $byKey = [ordered]@{}
    foreach ($file in $Files) {
        $base = (ConvertTo-Nfc ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))).ToLowerInvariant()
        $key = $file.DirectoryName.ToLowerInvariant() + '|' + $base
        if (-not $byKey.Contains($key)) { $byKey[$key] = [System.Collections.Generic.List[object]]::new() }
        $byKey[$key].Add($file)
    }
    $groups = foreach ($key in $byKey.Keys) {
        $members = @($byKey[$key] | Sort-Object { (Get-ExtInfo $_.Extension).Rank })
        $primary = $members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'media' } | Select-Object -First 1
        [pscustomobject]@{ Key = $key; Primary = $primary; Members = $members }
    }
    , @($groups)
}

function Get-RecordExifKey {
    param($Record)
    if ($Record.date_source -ne 'exif' -or -not $Record.camera_model) { return $null }
    '{0}|{1}|{2}' -f $Record.date_taken, $Record.camera_model, $Record.camera_serial
}

function Get-MetaExifKey {
    param($Resolved, $Meta)
    if ($null -eq $Resolved -or $Resolved.Source -ne 'exif') { return $null }
    $model = Get-Tag $Meta @('Model')
    if (-not $model) { return $null }
    $serial = Get-Tag $Meta @('SerialNumber', 'BodySerialNumber')
    '{0}|{1}|{2}' -f $Resolved.Date.ToString("yyyy-MM-dd'T'HH:mm:ss"), $model, $serial
}

function New-CatalogIndex {
    param([string]$Library)
    $index = [pscustomobject]@{
        ByHash  = [System.Collections.Generic.Dictionary[string, string]]::new()
        ByImage = [System.Collections.Generic.Dictionary[string, string]]::new()
        ByExif  = [System.Collections.Generic.Dictionary[string, string]]::new()
        Records = 0
    }
    if (Test-Path -LiteralPath $Library) {
        foreach ($manifest in @(Get-ChildItem -LiteralPath $Library -Recurse -Filter $Script:ManifestName -File -Force)) {
            $folder = $manifest.DirectoryName
            foreach ($record in (Read-Manifest $folder)) {
                Add-RecordToIndex $index $record $folder
            }
        }
    }
    $index
}

function Add-RecordToIndex {
    param($Index, $Record, [string]$Folder)
    $Index.Records++
    if ($Record.role -eq 'sidecar') { return }
    $where = Join-Path $Folder $Record.name
    if ($Record.hash_full)      { $Index.ByHash[$Record.hash_full] = $where }
    if ($Record.hash_imagedata) { $Index.ByImage[$Record.hash_imagedata] = $where }
    $key = Get-RecordExifKey $Record
    if ($key) { $Index.ByExif[$key] = $where }
}

function Move-FileSafe {
    param([string]$Source, [string]$Dest)
    $destDir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $final = $Dest
    $i = 0
    while (Test-Path -LiteralPath $final) {
        $i++
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Dest)
        $ext = [System.IO.Path]::GetExtension($Dest)
        $final = Join-Path $destDir ('{0}_{1:d3}{2}' -f $base, $i, $ext)
    }
    Move-Item -LiteralPath $Source -Destination $final
    $final
}

function Move-ToBucket {
    param([string]$File, [string]$SourceRoot, [string]$BucketDir)
    $rel = [System.IO.Path]::GetRelativePath($SourceRoot, $File)
    Move-FileSafe -Source $File -Dest (Join-Path $BucketDir $rel)
}

function Remove-EmptyInboxDirs {
    param([string]$InboxRoot)
    $removed = 0
    $dirs = @(Get-ChildItem -LiteralPath $InboxRoot -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -gt 0) { continue }
        try {
            Remove-Item -LiteralPath $dir.FullName
            $removed++
        }
        catch {
            Write-Warning "Could not remove empty folder $($dir.FullName): $($_.Exception.Message)"
        }
    }
    if ($removed -gt 0) { Write-Host "Removed empty folders: $(Format-Count $removed)" }
}

function Resolve-GroupBaseName {
    param([string]$DestDir, [string]$BaseName, $Members)
    for ($i = 0; $i -le 999; $i++) {
        $candidate = if ($i -eq 0) { $BaseName } else { '{0}_{1:d3}' -f $BaseName, $i }
        $clash = $false
        foreach ($m in $Members) {
            if (Test-Path -LiteralPath (Join-Path $DestDir ($candidate + $m.Extension))) { $clash = $true; break }
        }
        if (-not $clash) { return $candidate }
    }
    throw "No free name for $BaseName in $DestDir"
}

function New-LibraryTwin {
    param([string]$SuspectFinalPath, [string]$LibraryFile)
    if (-not (Test-Path -LiteralPath $LibraryFile)) { return }
    $dir = Split-Path -Parent $SuspectFinalPath
    $suspectLeaf = Split-Path -Leaf $SuspectFinalPath
    $libLeaf = Split-Path -Leaf $LibraryFile
    $ext = [System.IO.Path]::GetExtension($libLeaf)
    # shortcuts go through COM, which is not long-path aware: keep the whole path inside MAX_PATH
    $maxName = [Math]::Min($Script:TwinMaxLen, 258 - $dir.Length)
    $name = $suspectLeaf + $Script:TwinMarker + $libLeaf + $Script:TwinLinkExt
    if ($name.Length -gt $maxName) {
        $tailBudget = $maxName - $suspectLeaf.Length - $Script:TwinMarker.Length - $ext.Length - $Script:TwinLinkExt.Length
        $libBase = [System.IO.Path]::GetFileNameWithoutExtension($libLeaf)
        if ($tailBudget -lt 1) { $name = $suspectLeaf + $Script:TwinMarker + 'x' + $ext + $Script:TwinLinkExt }
        else { $name = $suspectLeaf + $Script:TwinMarker + $libBase.Substring(0, [Math]::Min($libBase.Length, $tailBudget)) + $ext + $Script:TwinLinkExt }
    }
    $dest = Join-Path $dir $name
    if (Test-Path -LiteralPath $dest) { return }
    if ($null -eq $Script:Shell) { $Script:Shell = New-Object -ComObject WScript.Shell }
    $link = $Script:Shell.CreateShortcut($dest)
    $link.TargetPath = $LibraryFile
    $link.Save()
}
function Get-LibraryGroupFiles {
    param([string]$LibraryFilePath)
    $folder = Split-Path -Parent $LibraryFilePath
    $name = Split-Path -Leaf $LibraryFilePath
    $records = Read-Manifest $folder
    $rec = $records | Where-Object { [string]$_.name -eq $name } | Select-Object -First 1
    if (-not $rec) {
        return , @([pscustomobject]@{
            Path = $LibraryFilePath; Role = 'primary'; Ext = [System.IO.Path]::GetExtension($name)
        })
    }
    $primaryName = if ($rec.primary) { [string]$rec.primary } else { [string]$rec.name }
    $group = @($records | Where-Object { [string]$_.name -eq $primaryName -or [string]$_.primary -eq $primaryName })
    , @($group | ForEach-Object {
        [pscustomobject]@{
            Path = Join-Path $folder ([string]$_.name)
            Role = [string]$_.role
            Ext  = [System.IO.Path]::GetExtension([string]$_.name)
        }
    })
}

function New-IngestStats {
    @{
        'added'                      = 0
        'complete-copy--same-bytes'  = 0
        'complete-copy--same-pixels' = 0
        'partial-copy'               = 0
        'suspected-copy'             = 0
        'date-missing'               = 0
        'damaged'                    = 0
        'orphan-sidecar'             = 0
        'non-media'                  = 0
    }
}

function Write-Stats {
    param($Paths, [int]$Ingested = -1, [int]$Added = -1)
    Write-Host ''
    if ($Ingested -ge 0) { Write-Host "Ingested: $(Format-Count $Ingested)" -ForegroundColor Gray }
    if ($Added -ge 0) { Write-Host "Added to library: $(Format-Count $Added)" -ForegroundColor Green }
    $buckets = @(
        [pscustomobject]@{ Path = $Paths.Keep;           Color = 'Cyan';   Hint = "  run 'ingest resume'" }
        [pscustomobject]@{ Path = $Paths.PartialCopy;    Color = 'Yellow'; Hint = '' }
        [pscustomobject]@{ Path = $Paths.SuspectCopy;    Color = 'Yellow'; Hint = '' }
        [pscustomobject]@{ Path = $Paths.DateMissing;    Color = 'Yellow'; Hint = '' }
        [pscustomobject]@{ Path = $Paths.CompleteBytes;  Color = 'Gray';   Hint = '' }
        [pscustomobject]@{ Path = $Paths.CompletePixels; Color = 'Gray';   Hint = '' }
        [pscustomobject]@{ Path = $Paths.Damaged;        Color = 'Yellow'; Hint = '' }
        [pscustomobject]@{ Path = $Paths.NonMedia;       Color = 'Yellow'; Hint = '' }
        [pscustomobject]@{ Path = $Paths.OrphanSidecar;  Color = 'Yellow'; Hint = '' }
    )
    $rootLen = $Paths.Root.TrimEnd('\').Length + 1
    foreach ($bucket in $buckets) {
        $count = Get-BucketFileCount $bucket.Path -Recurse
        if ($count -gt 0) {
            Write-Host ('{0}: {1}{2}' -f $bucket.Path.Substring($rootLen), (Format-Count $count), $bucket.Hint) -ForegroundColor $bucket.Color
        }
    }
}

function Get-BucketFileCount {
    param([string]$Dir, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    @(Get-ChildItem -LiteralPath $Dir -File -Recurse:$Recurse |
        Where-Object { $_.Name -notlike "*$($Script:TwinMarker)*" -and $_.Name -ne $Script:ManifestName }).Count
}

function Invoke-GroupIngest {
    [CmdletBinding()]
    param(
        $Paths, $Group, $Meta, $Index, [string]$InboxRoot, $Stats,
        [switch]$SkipExifTier, [switch]$ForceManualDate
    )

    $metaOf = { param($f) $Meta[$f.FullName.ToLowerInvariant()] }

    if ($null -eq $Group.Primary) {
        foreach ($m in $Group.Members) {
            Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.OrphanSidecar $m.Name) | Out-Null
        }
        $Stats['orphan-sidecar']++
        return
    }

    if (@($Group.Members | Where-Object Length -eq 0).Count -gt 0) {
        foreach ($m in $Group.Members) {
            Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.Damaged $m.Name) | Out-Null
        }
        $Stats['damaged']++
        return
    }

    $extras = @($Group.Members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'other' })
    foreach ($m in $extras) {
        Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.NonMedia $m.Name) | Out-Null
        $Stats['non-media']++
    }
    $members = @($Group.Members | Where-Object { (Get-ExtInfo $_.Extension).Kind -ne 'other' })
    if ($members.Count -eq 0) { return }

    $hashes = @{}
    foreach ($m in $members) { $hashes[$m.FullName] = Get-FileSha256 $m.FullName }

    $mediaMembers = @($members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'media' })
    $matchTarget = @{}
    $newOnes = @()
    $pixelOnly = $false
    foreach ($m in $mediaMembers) {
        $hit = $null
        if ($Index.ByHash.ContainsKey($hashes[$m.FullName])) { $hit = $Index.ByHash[$hashes[$m.FullName]] }
        else {
            $img = Get-ImageDataHash (& $metaOf $m)
            if ($img -and $Index.ByImage.ContainsKey($img)) {
                $hit = $Index.ByImage[$img]
                $pixelOnly = $true
            }
        }
        $matchTarget[$m.FullName] = $hit
        if ($null -eq $hit) { $newOnes += $m }
    }

    if ($newOnes.Count -eq 0) {
        $bucket = if ($pixelOnly) { $Paths.CompletePixels } else { $Paths.CompleteBytes }
        $statKey = if ($pixelOnly) { 'complete-copy--same-pixels' } else { 'complete-copy--same-bytes' }
        foreach ($m in $members) {
            $moved = Move-FileSafe -Source $m.FullName -Dest (Join-Path $bucket $m.Name)
            if ($matchTarget.ContainsKey($m.FullName) -and $matchTarget[$m.FullName]) {
                New-LibraryTwin $moved $matchTarget[$m.FullName]
            }
        }
        $Stats[$statKey]++
        return
    }

    if ($newOnes.Count -lt $mediaMembers.Count) {
        foreach ($m in $members) {
            $moved = Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.PartialCopy $m.Name)
            if ($matchTarget.ContainsKey($m.FullName) -and $matchTarget[$m.FullName]) {
                New-LibraryTwin $moved $matchTarget[$m.FullName]
            }
        }
        Confirm-KeepFolder $Paths
        $Stats['partial-copy']++
        return
    }

    $resolved = $null
    foreach ($m in $mediaMembers) {
        $resolved = Resolve-DateTaken (& $metaOf $m) $m.Name
        if ($resolved) { break }
    }

    if ($null -eq $resolved) {
        foreach ($m in $members) {
            Move-ToBucket $m.FullName $InboxRoot $Paths.DateMissing | Out-Null
        }
        $Stats['date-missing']++
        return
    }

    if (-not $SkipExifTier) {
        $exifKey = Get-MetaExifKey $resolved (& $metaOf $Group.Primary)
        if ($exifKey -and $Index.ByExif.ContainsKey($exifKey)) {
            $matched = $Index.ByExif[$exifKey]
            $libGroup = Get-LibraryGroupFiles $matched
            $libPrimary = $libGroup | Where-Object { $_.Role -eq 'primary' } | Select-Object -First 1
            if (-not $libPrimary) { $libPrimary = $libGroup | Select-Object -First 1 }
            foreach ($m in $members) {
                $moved = Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.SuspectCopy $m.Name)
                $info = Get-ExtInfo $m.Extension
                $isPrimary = $m.FullName -eq $Group.Primary.FullName
                $counterpart = $null
                if ($isPrimary) { $counterpart = $libPrimary }
                elseif ($info.Kind -eq 'sidecar') {
                    $counterpart = $libGroup | Where-Object { $_.Role -eq 'sidecar' -and $_.Ext -ieq $m.Extension } | Select-Object -First 1
                }
                else {
                    $counterpart = $libGroup | Where-Object { $_.Role -eq 'companion' -and $_.Ext -ieq $m.Extension } | Select-Object -First 1
                }
                if ($counterpart) { New-LibraryTwin $moved $counterpart.Path }
            }
            Confirm-KeepFolder $Paths
            $Stats['suspected-copy']++
            return
        }
    }

    $destDir = Join-Path $Paths.Library (Join-Path ([string]$resolved.Date.Year) $resolved.Date.ToString('yyyy-MM'))
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    $origBase = Get-SanitizedName ([System.IO.Path]::GetFileNameWithoutExtension($Group.Primary.Name))
    $stamp = $resolved.Date.ToString('yyyyMMdd_HHmmss')
    $base = if ($origBase -eq $stamp -or $origBase.StartsWith($stamp + '_')) { $origBase }
            else { '{0}_{1}' -f $stamp, $origBase }
    $base = Resolve-GroupBaseName $destDir $base $members
    $primaryTargetName = $base + $Group.Primary.Extension
    $now = Get-UtcNowStamp
    $dateSource = if ($ForceManualDate) { 'manual' } else { $resolved.Source }

    foreach ($m in $members) {
        $isSidecar = (Get-ExtInfo $m.Extension).Kind -eq 'sidecar'
        $isPrimary = $m.FullName -eq $Group.Primary.FullName
        $mMeta = & $metaOf $m
        $size = $m.Length
        $origName = ConvertTo-Nfc $m.Name

        $moved = Move-FileSafe -Source $m.FullName -Dest (Join-Path $destDir ($base + $m.Extension))
        [System.IO.File]::SetLastWriteTime($moved, $resolved.Date)
        Set-FileReadOnly $moved $true

        $duration = Get-Tag $mMeta @('Duration')
        if ($null -ne $duration) { $duration = [double]$duration }
        $width = Get-Tag $mMeta @('ImageWidth')
        if ($null -ne $width) { $width = [int]$width }
        $height = Get-Tag $mMeta @('ImageHeight')
        if ($null -ne $height) { $height = [int]$height }

        $record = New-FileRecord `
            -Name ([System.IO.Path]::GetFileName($moved)) `
            -RoleName ($(if ($isSidecar) { 'sidecar' } elseif ($isPrimary) { 'primary' } else { 'companion' })) `
            -PrimaryName ($(if ($isPrimary) { $null } else { $primaryTargetName })) `
            -Size $size `
            -HashFull $hashes[$m.FullName] `
            -HashImage ($(if ($isSidecar) { $null } else { Get-ImageDataHash $mMeta })) `
            -DateTaken $resolved.Date -DateSource $dateSource -TzOffset $resolved.Tz `
            -Width ($(if ($isSidecar) { $null } else { $width })) `
            -Height ($(if ($isSidecar) { $null } else { $height })) `
            -Duration ($(if ($isSidecar) { $null } else { $duration })) `
            -CameraMake ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('Make') })) `
            -CameraModel ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('Model') })) `
            -CameraSerial ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('SerialNumber', 'BodySerialNumber') })) `
            -OrigFilename $origName -IngestedAt $now

        Add-ManifestRecord $destDir $record
        Add-RecordToIndex $Index $record $destDir
        $Stats['added']++
    }
}

function Get-IngestibleFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return , @() }
    , @(Get-ChildItem -LiteralPath $Dir -Recurse -File | Where-Object {
        $_.Name -ne $Script:ManifestName -and
        -not ($Script:JunkNames -contains $_.Name.ToLowerInvariant()) -and
        -not $_.Name.StartsWith('._') -and
        $_.Name -notlike "*$($Script:TwinMarker)*"
    })
}

function Import-Batch {
    [CmdletBinding()]
    param(
        [string]$Inbox,
        [string]$Root = $PSScriptRoot
    )

    if (-not $Inbox) { Write-Usage 'ingest'; throw 'ingest requires -Inbox' }
    $Script:ExifTool = Resolve-ExifTool
    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths

    $inboxFull = [System.IO.Path]::GetFullPath($Inbox)
    if (-not (Test-Path -LiteralPath $inboxFull -PathType Container)) { throw "Inbox not found: $inboxFull" }
    if ([System.IO.Path]::GetPathRoot($inboxFull) -ne [System.IO.Path]::GetPathRoot($Paths.Root)) {
        throw 'Inbox must be on the same volume as the SoT root (moves must be atomic)'
    }
    foreach ($managed in @($Paths.Library, $Paths.MustDecide, $Paths.MustProvide, $Paths.SafeToDelete)) {
        $prefix = $managed.TrimEnd('\') + '\'
        if (($inboxFull.TrimEnd('\') + '\').StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Inbox cannot be inside the managed folder $managed"
        }
    }

    $files = Get-IngestibleFiles $inboxFull
    if ($files.Count -eq 0) { Write-Host 'Nothing to ingest.'; return }

    Write-Host "Ingesting $(Format-Count $files.Count) files from $inboxFull"
    $meta = Get-MediaMetadata @($files.FullName)
    $index = New-CatalogIndex $Paths.Library
    Write-Host "Catalog loaded: $(Format-Count $index.Records) records"

    $stats = New-IngestStats
    foreach ($group in (Get-AssetGroups $files)) {
        Invoke-GroupIngest -Paths $Paths -Group $group -Meta $meta -Index $index `
            -InboxRoot $inboxFull -Stats $stats
    }

    Remove-EmptyInboxDirs -InboxRoot $inboxFull
    Write-Stats $Paths -Ingested $files.Count -Added $stats['added']
}

function Resume-Ingest {
    [CmdletBinding()]
    param([string]$Root = $PSScriptRoot)

    $Script:ExifTool = Resolve-ExifTool
    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths

    $keepFiles = Get-IngestibleFiles $Paths.Keep
    $dateFiles = Get-IngestibleFiles $Paths.DateMissing
    if ($keepFiles.Count -eq 0 -and $dateFiles.Count -eq 0) {
        Write-Host 'Nothing to resume.'
        Write-Stats $Paths
        return
    }

    $allPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $keepFiles) { $allPaths.Add($f.FullName) }
    foreach ($f in $dateFiles) { $allPaths.Add($f.FullName) }
    $meta = Get-MediaMetadata $allPaths.ToArray()
    $index = New-CatalogIndex $Paths.Library
    $stats = New-IngestStats

    if ($keepFiles.Count -gt 0) {
        Write-Host "Resuming $(Format-Count $keepFiles.Count) decided file(s) from keep"
        foreach ($group in (Get-AssetGroups $keepFiles)) {
            Invoke-GroupIngest -Paths $Paths -Group $group -Meta $meta -Index $index `
                -InboxRoot $Paths.Keep -Stats $stats -SkipExifTier
        }
    }

    if ($dateFiles.Count -gt 0) {
        Write-Host "Checking $(Format-Count $dateFiles.Count) file(s) awaiting dates"
        foreach ($group in (Get-AssetGroups $dateFiles)) {
            $resolved = $null
            foreach ($m in @($group.Members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'media' })) {
                $resolved = Resolve-DateTaken $meta[$m.FullName.ToLowerInvariant()] $m.Name
                if ($resolved) { break }
            }
            if ($null -eq $resolved) { continue }
            Invoke-GroupIngest -Paths $Paths -Group $group -Meta $meta -Index $index `
                -InboxRoot $Paths.DateMissing -Stats $stats -ForceManualDate
        }
        Remove-EmptyInboxDirs -InboxRoot $Paths.DateMissing
    }

    Write-Stats $Paths -Ingested ($keepFiles.Count + $dateFiles.Count) -Added $stats['added']
}

function Get-LibraryFolders {
    param($Paths)
    if (-not (Test-Path -LiteralPath $Paths.Library)) { return , @() }
    $dirs = @(Get-ChildItem -LiteralPath $Paths.Library -Recurse -Directory | Where-Object {
        @(Get-ChildItem -LiteralPath $_.FullName -File).Count -gt 0
    })
    , @($dirs | ForEach-Object FullName)
}

function Test-Catalog {
    [CmdletBinding()]
    param(
        [switch]$Deep,
        [string]$Root = $PSScriptRoot
    )

    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    $now = Get-UtcNowStamp
    $findings = [System.Collections.Generic.List[object]]::new()
    $checked = 0

    foreach ($folder in (Get-LibraryFolders $Paths)) {
        $records = Read-Manifest $folder
        $actual = @{}
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Name -ne $Script:ManifestName })) {
            $actual[(ConvertTo-Nfc $f.Name)] = $f
        }
        $changed = $false

        foreach ($record in $records) {
            $checked++
            $file = $actual[[string]$record.name]
            if ($null -eq $file) {
                $findings.Add([pscustomobject]@{ issue = 'missing'; folder = $folder; name = $record.name; detail = $null })
                continue
            }
            $actual.Remove([string]$record.name)
            if (-not $file.IsReadOnly) {
                $findings.Add([pscustomobject]@{ issue = 'not-readonly'; folder = $folder; name = $record.name; detail = 'run catalog fix to restore' })
            }
            if ($file.Length -ne $record.size) {
                $issue = if ($file.Length -eq 0) { 'zeroed' } else { 'size-mismatch' }
                $findings.Add([pscustomobject]@{ issue = $issue; folder = $folder; name = $record.name; detail = "expected $($record.size), found $($file.Length)" })
                continue
            }
            if (-not $Deep) { continue }

            $hash = Get-FileSha256 $file.FullName
            if ($hash -ne $record.hash_full) {
                $findings.Add([pscustomobject]@{ issue = 'corrupt'; folder = $folder; name = $record.name; detail = 'hash mismatch' })
            }
            else {
                $record.last_verified = $now
                $changed = $true
            }
        }

        foreach ($name in $actual.Keys) {
            $findings.Add([pscustomobject]@{ issue = 'orphan'; folder = $folder; name = $name; detail = 'file has no catalog record; run catalog fix' })
        }

        if ($Deep -and $changed) { Write-Manifest $folder $records }
    }

    $bad = @($findings | Where-Object { $_.issue -in @('missing', 'zeroed', 'size-mismatch', 'corrupt') })
    $mode = if ($Deep) { 'deep' } else { 'quick' }
    Write-Host "Verify ($mode): $(Format-Count $checked) records checked, $(Format-Count $bad.Count) problems, $(Format-Count $findings.Count) findings total"
    foreach ($f in $findings) {
        $color = if ($f.issue -in @('corrupt', 'missing', 'zeroed', 'size-mismatch')) { 'Red' } else { 'Yellow' }
        Write-Host ("  [{0}] {1}\{2} {3}" -f $f.issue, $f.folder, $f.name, $f.detail) -ForegroundColor $color
    }
    Write-Stats $Paths
    $findings
}

function Get-OrigFromName {
    param([string]$Name)
    $m = [regex]::Match($Name, '^\d{8}_\d{6}_(?<orig>.+)$')
    if ($m.Success) { $m.Groups['orig'].Value } else { $Name }
}

function Update-Catalog {
    [CmdletBinding()]
    param([string]$Root = $PSScriptRoot)

    $Script:ExifTool = Resolve-ExifTool
    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    $added = 0
    $skipped = 0
    $rearmed = 0

    foreach ($folder in (Get-LibraryFolders $Paths)) {
        $records = Read-Manifest $folder
        $known = @{}
        foreach ($r in $records) { $known[[string]$r.name] = $r }

        foreach ($r in $records) {
            $p = Join-Path $folder ([string]$r.name)
            if (-not (Test-Path -LiteralPath $p)) {
                Write-Warning "Record without file (reset required to remove): $folder\$($r.name)"
                continue
            }
            $item = Get-Item -LiteralPath $p
            if (-not $item.IsReadOnly) {
                $item.IsReadOnly = $true
                $rearmed++
            }
        }

        $orphans = @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
            $_.Name -ne $Script:ManifestName -and -not $known.ContainsKey((ConvertTo-Nfc $_.Name))
        })
        if ($orphans.Count -eq 0) { continue }

        $meta = Get-MediaMetadata @($orphans.FullName)
        foreach ($group in (Get-AssetGroups $orphans)) {
            $mediaMembers = @($group.Members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'media' })

            $primaryName = $null
            $resolved = $null
            if ($null -ne $group.Primary) {
                $primaryName = ConvertTo-Nfc $group.Primary.Name
                foreach ($m in $mediaMembers) {
                    $resolved = Resolve-DateTaken $meta[$m.FullName.ToLowerInvariant()] $m.Name
                    if ($resolved) { break }
                }
            }
            else {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($group.Members[0].Name)
                $match = $records | Where-Object {
                    $_.role -eq 'primary' -and [System.IO.Path]::GetFileNameWithoutExtension([string]$_.name) -eq $base
                } | Select-Object -First 1
                if ($match) {
                    $primaryName = [string]$match.name
                    $resolved = [pscustomobject]@{
                        Date   = [datetime]::ParseExact([string]$match.date_taken, "yyyy-MM-dd'T'HH:mm:ss", $null)
                        Source = [string]$match.date_source
                        Tz     = $match.tz_offset
                    }
                }
            }

            if ($null -eq $resolved) {
                Write-Warning "Cannot date orphan group, leaving uncataloged: $($group.Key)"
                $skipped += $group.Members.Count
                continue
            }

            $now = Get-UtcNowStamp
            foreach ($m in $group.Members) {
                $info = Get-ExtInfo $m.Extension
                if ($info.Kind -eq 'other') {
                    Write-Warning "Non-media orphan left uncataloged: $($m.FullName)"
                    $skipped++
                    continue
                }
                $isSidecar = $info.Kind -eq 'sidecar'
                $isPrimary = ($null -ne $group.Primary) -and ($m.FullName -eq $group.Primary.FullName)
                $mMeta = $meta[$m.FullName.ToLowerInvariant()]

                $duration = Get-Tag $mMeta @('Duration')
                if ($null -ne $duration) { $duration = [double]$duration }
                $width = Get-Tag $mMeta @('ImageWidth')
                if ($null -ne $width) { $width = [int]$width }
                $height = Get-Tag $mMeta @('ImageHeight')
                if ($null -ne $height) { $height = [int]$height }

                $record = New-FileRecord `
                    -Name (ConvertTo-Nfc $m.Name) `
                    -RoleName ($(if ($isSidecar) { 'sidecar' } elseif ($isPrimary) { 'primary' } else { 'companion' })) `
                    -PrimaryName ($(if ($isPrimary) { $null } else { $primaryName })) `
                    -Size $m.Length `
                    -HashFull (Get-FileSha256 $m.FullName) `
                    -HashImage ($(if ($isSidecar) { $null } else { Get-ImageDataHash $mMeta })) `
                    -DateTaken $resolved.Date -DateSource $resolved.Source -TzOffset $resolved.Tz `
                    -Width ($(if ($isSidecar) { $null } else { $width })) `
                    -Height ($(if ($isSidecar) { $null } else { $height })) `
                    -Duration ($(if ($isSidecar) { $null } else { $duration })) `
                    -CameraMake ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('Make') })) `
                    -CameraModel ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('Model') })) `
                    -CameraSerial ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('SerialNumber', 'BodySerialNumber') })) `
                    -OrigFilename (Get-OrigFromName $m.Name) -IngestedAt $now

                Add-ManifestRecord $folder $record
                Set-FileReadOnly $m.FullName $true
                $added++
            }
        }
    }
    Write-Host "Update: $(Format-Count $added) records appended, $(Format-Count $rearmed) read-only attributes restored, $(Format-Count $skipped) files left uncataloged"
}

function Reset-Catalog {
    [CmdletBinding()]
    param(
        [string]$Month = 'all',
        [switch]$Force,
        [string]$Root = $PSScriptRoot
    )

    $Script:ExifTool = Resolve-ExifTool
    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    $folders = Get-LibraryFolders $Paths
    if ($Month -ne 'all') {
        if ($Month -notmatch '^\d{4}-\d{2}$') { Write-Usage 'catalog rebuild'; throw "catalog rebuild -Month expects 'yyyy-MM' or 'all'" }
        $folders = @($folders | Where-Object { (Split-Path -Leaf $_) -eq $Month })
        if ($folders.Count -eq 0) { throw "No library folder found for $Month" }
    }

    if (-not $Force) {
        $msg = "Rebuild will regenerate catalog records in $($folders.Count) folder(s), discarding stored hashes (corruption evidence)."
        $choice = $Host.UI.PromptForChoice('photo-mgr catalog rebuild', $msg, @('&Yes', '&No'), 1)
        if ($choice -ne 0) { return }
    }

    foreach ($folder in $folders) {
        $old = @{}
        foreach ($r in (Read-Manifest $folder)) { $old[[string]$r.hash_full] = $r }

        $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
            $_.Name -ne $Script:ManifestName -and (Get-ExtInfo $_.Extension).Kind -ne 'other'
        })
        if ($files.Count -eq 0) { continue }

        $meta = Get-MediaMetadata @($files.FullName)
        $now = Get-UtcNowStamp
        $records = [System.Collections.Generic.List[object]]::new()

        foreach ($group in (Get-AssetGroups $files)) {
            $mediaMembers = @($group.Members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'media' })
            $resolved = $null
            foreach ($m in $mediaMembers) {
                $resolved = Resolve-DateTaken $meta[$m.FullName.ToLowerInvariant()] $m.Name
                if ($resolved) { break }
            }
            if ($null -eq $resolved) {
                Write-Warning "Cannot date group, leaving uncataloged: $($group.Key)"
                continue
            }
            $primaryTargetName = if ($null -ne $group.Primary) { ConvertTo-Nfc $group.Primary.Name } else { $null }

            foreach ($m in $group.Members) {
                $info = Get-ExtInfo $m.Extension
                $isSidecar = $info.Kind -eq 'sidecar'
                $isPrimary = ($null -ne $group.Primary) -and ($m.FullName -eq $group.Primary.FullName)
                $mMeta = $meta[$m.FullName.ToLowerInvariant()]
                $hash = Get-FileSha256 $m.FullName
                $carry = if ($old.ContainsKey($hash)) { $old[$hash] } else { $null }

                $dateTaken = $resolved.Date
                $dateSource = $resolved.Source
                $tz = $resolved.Tz
                if ($carry -and $carry.date_source -eq 'manual') {
                    $dateTaken = [datetime]::ParseExact([string]$carry.date_taken, "yyyy-MM-dd'T'HH:mm:ss", $null)
                    $dateSource = 'manual'
                    $tz = $carry.tz_offset
                }

                $duration = Get-Tag $mMeta @('Duration')
                if ($null -ne $duration) { $duration = [double]$duration }
                $width = Get-Tag $mMeta @('ImageWidth')
                if ($null -ne $width) { $width = [int]$width }
                $height = Get-Tag $mMeta @('ImageHeight')
                if ($null -ne $height) { $height = [int]$height }

                $record = New-FileRecord `
                    -Name (ConvertTo-Nfc $m.Name) `
                    -RoleName ($(if ($isSidecar) { 'sidecar' } elseif ($isPrimary) { 'primary' } else { 'companion' })) `
                    -PrimaryName ($(if ($isPrimary) { $null } else { $primaryTargetName })) `
                    -Size $m.Length `
                    -HashFull $hash `
                    -HashImage ($(if ($isSidecar) { $null } else { Get-ImageDataHash $mMeta })) `
                    -DateTaken $dateTaken -DateSource $dateSource -TzOffset $tz `
                    -Width ($(if ($isSidecar) { $null } else { $width })) `
                    -Height ($(if ($isSidecar) { $null } else { $height })) `
                    -Duration ($(if ($isSidecar) { $null } else { $duration })) `
                    -CameraMake ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('Make') })) `
                    -CameraModel ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('Model') })) `
                    -CameraSerial ($(if ($isSidecar) { $null } else { Get-Tag $mMeta @('SerialNumber', 'BodySerialNumber') })) `
                    -OrigFilename ($(if ($carry) { [string]$carry.orig_filename } else { Get-OrigFromName $m.Name })) `
                    -IngestedAt ($(if ($carry) { [string]$carry.ingested_at } else { $now }))
                $record.last_verified = $now
                $records.Add($record)
            }
        }

        Write-Manifest $folder $records
        Write-Host "Rebuilt $folder : $(Format-Count $records.Count) records"
    }
}

function ConvertTo-CsvField {
    param($Value)
    if ($null -eq $Value) { return '' }
    $s = "$Value"
    if ($s -match '[",\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s }
}

function Export-Catalog {
    [CmdletBinding()]
    param(
        [ValidateSet('Jsonl', 'Csv')]
        [string]$As = 'Csv',
        [string]$Out,
        [string]$From,
        [string]$To,
        [string]$Root = $PSScriptRoot
    )

    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    if (-not $Out) { Write-Usage 'catalog export'; throw 'catalog export requires -Out' }
    $columns = @('name', 'role', 'primary', 'size', 'hash_full', 'hash_imagedata',
        'date_taken', 'date_source', 'tz_offset', 'width', 'height', 'duration',
        'camera_make', 'camera_model', 'camera_serial', 'orig_filename',
        'ingested_at', 'last_verified', 'year', 'month', 'ext')

    $encoding = if ($As -eq 'Csv') { [System.Text.UTF8Encoding]::new($true) } else { $Script:Utf8NoBom }
    $writer = [System.IO.StreamWriter]::new([System.IO.Path]::GetFullPath($Out), $false, $encoding)
    $count = 0
    try {
        if ($As -eq 'Csv') {
            $writer.WriteLine(($columns -join ','))
        }
        foreach ($folder in (Get-LibraryFolders $Paths | Sort-Object)) {
            $leaf = Split-Path -Leaf $folder
            if ($leaf -notmatch '^\d{4}-\d{2}$') { continue }
            if ($From -and $leaf -lt $From) { continue }
            if ($To -and $leaf -gt $To) { continue }

            foreach ($record in (Read-Manifest $folder)) {
                $augmented = [ordered]@{}
                foreach ($prop in $record.PSObject.Properties) { $augmented[$prop.Name] = $prop.Value }
                $augmented['year'] = [int]([string]$record.date_taken).Substring(0, 4)
                $augmented['month'] = ([string]$record.date_taken).Substring(0, 7)
                $augmented['ext'] = [System.IO.Path]::GetExtension([string]$record.name).TrimStart('.').ToLowerInvariant()

                if ($As -eq 'Csv') {
                    $writer.WriteLine((@($columns | ForEach-Object { ConvertTo-CsvField $augmented[$_] }) -join ','))
                }
                else {
                    $writer.WriteLine((ConvertTo-JsonLine $augmented))
                }
                $count++
            }
        }
    }
    finally { $writer.Dispose() }
    Write-Host "Exported $(Format-Count $count) records to $Out"
}

function Show-Status {
    [CmdletBinding()]
    param(
        [string]$Year,
        [string]$Root = $PSScriptRoot
    )

    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    if ($Year -and $Year -notmatch '^\d{4}$') { throw "Invalid -Year '$Year'; expected yyyy" }

    $counts = @{}
    $files = 0
    $bytes = [long]0
    $first = $null
    $last = $null

    foreach ($manifest in @(Get-ChildItem -LiteralPath $Paths.Library -Recurse -Filter $Script:ManifestName -File -Force)) {
        foreach ($record in (Read-Manifest $manifest.DirectoryName)) {
            $month = ([string]$record.date_taken).Substring(0, 7)
            if ($Year -and -not $month.StartsWith($Year)) { continue }
            $files++
            $bytes += [long]$record.size
            $key = if ($Year) { $month } else { $month.Substring(0, 4) }
            if (-not $counts.ContainsKey($key)) { $counts[$key] = 0 }
            $counts[$key]++
            if (-not $first -or $month -lt $first) { $first = $month }
            if (-not $last -or $month -gt $last) { $last = $month }
        }
    }

    Write-Host ''
    $label = if ($Year) { "Library $Year" } else { 'Library' }
    Write-Host ('{0}: {1} files' -f $label, (Format-Count $files)) -ForegroundColor White
    if ($files -gt 0) {
        Write-Host ('Size: {0}' -f (Format-Size $bytes)) -ForegroundColor Gray
        if (-not $Year) { Write-Host ('Span: {0} .. {1}' -f $first, $last) -ForegroundColor Gray }
        Write-Host ''
        foreach ($key in @($counts.Keys | Sort-Object)) {
            Write-Host ('{0}: {1}' -f $key, (Format-Count $counts[$key])) -ForegroundColor Gray
        }
    }

    Write-Stats $Paths
}

$Script:UsageText = [ordered]@{
    'status'          = 'status  [-Year <yyyy>] [-Root <path>]'
    'ingest'          = 'ingest  -Inbox <folder> [-Root <path>]'
    'ingest resume'   = 'ingest  resume [-Root <path>]'
    'catalog verify'  = 'catalog verify [-Deep] [-Root <path>]'
    'catalog fix'     = 'catalog fix [-Root <path>]'
    'catalog rebuild' = 'catalog rebuild [-Month <yyyy-MM|all>] [-Force] [-Root <path>]'
    'catalog export'  = 'catalog export -Out <file> [-As <Csv|Jsonl>] [-From <yyyy-MM>] [-To <yyyy-MM>] [-Root <path>]'
}

function Write-Usage {
    param([string]$Only)
    if ($Only -and $Script:UsageText.Contains($Only)) {
        Write-Host "usage: photo-mgr.ps1 $($Script:UsageText[$Only])"
        return
    }
    Write-Host 'usage:'
    foreach ($key in $Script:UsageText.Keys) {
        Write-Host "  photo-mgr.ps1 $($Script:UsageText[$key])"
    }
    Write-Host ''
    Write-Host "ingest resume applies your finished work: _must-decide\keep and newly dated _must-provide files"
    Write-Host '-Root defaults to the script folder'
}

# array splatting binds positionally, so remaining args must become a hashtable to stay named
function ConvertTo-ParamTable {
    param([object[]]$Tokens)
    $table = @{}
    $i = 0
    while ($i -lt $Tokens.Count) {
        $token = "$($Tokens[$i])"
        if (-not $token.StartsWith('-')) {
            throw [System.Management.Automation.ParameterBindingException]::new("Unexpected argument '$token'; options must be named")
        }
        $next = if ($i + 1 -lt $Tokens.Count) { "$($Tokens[$i + 1])" } else { $null }
        if ($null -eq $next -or $next.StartsWith('-')) { $table[$token.TrimStart('-')] = $true; $i++ }
        else { $table[$token.TrimStart('-')] = $next; $i += 2 }
    }
    $table
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Command) {
    Write-Usage
    exit 1
}

$Script:UsageKey = $null
$Rest = $args
try {
    switch ($Command) {
        'status' {
            $Script:UsageKey = 'status'
            $subArgs = ConvertTo-ParamTable $Rest
            Show-Status @subArgs
        }
        'ingest' {
            if (@($Rest).Count -gt 0 -and "$($Rest[0])" -eq 'resume') {
                $Script:UsageKey = 'ingest resume'
                $subArgs = ConvertTo-ParamTable @(@($Rest) | Select-Object -Skip 1)
                Resume-Ingest @subArgs
            }
            else {
                $Script:UsageKey = 'ingest'
                $subArgs = ConvertTo-ParamTable $Rest
                Import-Batch @subArgs
            }
        }
        'catalog' {
            $sub = if (@($Rest).Count -gt 0) { "$($Rest[0])" } else { '' }
            $Script:UsageKey = "catalog $sub"
            $subArgs = ConvertTo-ParamTable @(@($Rest) | Select-Object -Skip 1)
            switch ($sub) {
                'verify'  { Test-Catalog @subArgs }
                'fix'     { Update-Catalog @subArgs }
                'rebuild' { Reset-Catalog @subArgs }
                'export'  { Export-Catalog @subArgs }
                default {
                    Write-Host "Unknown catalog command: $sub"
                    Write-Host ''
                    Write-Usage
                    exit 1
                }
            }
        }
        default {
            Write-Host "Unknown command: $Command"
            Write-Host ''
            Write-Usage
            exit 1
        }
    }
}
catch [System.Management.Automation.ParameterBindingException] {
    Write-Host $_.Exception.Message
    Write-Host ''
    Write-Usage $Script:UsageKey
    exit 1
}
