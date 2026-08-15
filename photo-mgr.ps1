#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(ValueFromRemainingArguments)]
    [object[]]$Rest = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:Schema       = 1
$Script:ManifestName = '.catalog.jsonl'
$Script:TwinMarker   = '--library--'
$Script:TwinMaxLen   = 180
$Script:Utf8NoBom    = [System.Text.UTF8Encoding]::new($false)
$Script:MinYear      = 1990
$Script:ExifTool     = $null

$Script:RawExts        = @('.nef', '.cr2', '.cr3', '.crw', '.arw', '.dng', '.orf', '.rw2', '.raf', '.pef', '.srw')
$Script:HeicExts       = @('.heic', '.heif')
$Script:JpegExts       = @('.jpg', '.jpeg')
$Script:VideoExts      = @('.mov', '.mp4', '.m4v', '.avi', '.mts', '.m2ts', '.3gp', '.wmv', '.mkv', '.mpg', '.mpeg')
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
        CompleteCopy  = Join-Path $safe 'complete-copy--hash-match'
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

function Read-Manifest {
    param([string]$Folder)
    $records = [System.Collections.Generic.List[object]]::new()
    $path = Get-ManifestPath $Folder
    if (-not (Test-Path -LiteralPath $path)) { return , $records }
    $lines = [System.IO.File]::ReadAllLines($path, $Script:Utf8NoBom)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].Trim()
        if ($line -eq '') { continue }
        try { $records.Add(($line | ConvertFrom-Json)) }
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
    '-QuickTime:CreateDate'
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
        Write-Progress -Activity 'Reading metadata' -Status "$($last + 1) / $($Paths.Count)"
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
    [pscustomobject]@{ Rx = [regex]'^(?:IMG|VID|PANO|PXL)[-_](\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'^(?:IMG|VID)-(\d{4})(\d{2})(\d{2})-WA\d+'; DateOnly = $true }
    [pscustomobject]@{ Rx = [regex]'^Screenshot[_ -](\d{4})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'^(\d{4})-(\d{2})-(\d{2})[ _](\d{2})[.\-](\d{2})[.\-](\d{2})'; DateOnly = $false }
    [pscustomobject]@{ Rx = [regex]'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})(?:[_.]|$)'; DateOnly = $false }
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
    $qt = ConvertFrom-ExifDate (Get-GroupTag $Meta 'QuickTime' 'CreateDate')
    if ($qt -and (Test-SaneDate $qt)) {
        return [pscustomobject]@{ Date = $qt; Source = 'quicktime'; Tz = Get-MachineTzOffset $qt }
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
    [CmdletBinding(SupportsShouldProcess)]
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
    if ($PSCmdlet.ShouldProcess($final, "Move from $Source")) {
        Move-Item -LiteralPath $Source -Destination $final
        return $final
    }
    $null
}

function Move-ToBucket {
    param([string]$File, [string]$SourceRoot, [string]$BucketDir)
    $rel = [System.IO.Path]::GetRelativePath($SourceRoot, $File)
    Move-FileSafe -Source $File -Dest (Join-Path $BucketDir $rel)
}

function Remove-EmptyInboxDirs {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$InboxRoot)
    $removed = 0
    $dirs = @(Get-ChildItem -LiteralPath $InboxRoot -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        if (@(Get-ChildItem -LiteralPath $dir.FullName -Force).Count -gt 0) { continue }
        if ($PSCmdlet.ShouldProcess($dir.FullName, 'Remove empty folder')) {
            try {
                Remove-Item -LiteralPath $dir.FullName
                $removed++
            }
            catch {
                Write-Warning "Could not remove empty folder $($dir.FullName): $($_.Exception.Message)"
            }
        }
    }
    if ($removed -gt 0) { Write-Host "Removed $removed empty folder(s)" }
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

function Copy-LibraryTwin {
    param([string]$SuspectFinalPath, [string]$LibraryFile)
    if (-not (Test-Path -LiteralPath $LibraryFile)) { return }
    $dir = Split-Path -Parent $SuspectFinalPath
    $suspectLeaf = Split-Path -Leaf $SuspectFinalPath
    $libLeaf = Split-Path -Leaf $LibraryFile
    $ext = [System.IO.Path]::GetExtension($libLeaf)
    $name = $suspectLeaf + $Script:TwinMarker + $libLeaf
    if ($name.Length -gt $Script:TwinMaxLen) {
        $tailBudget = $Script:TwinMaxLen - $suspectLeaf.Length - $Script:TwinMarker.Length - $ext.Length
        $libBase = [System.IO.Path]::GetFileNameWithoutExtension($libLeaf)
        if ($tailBudget -lt 1) { $name = $suspectLeaf + $Script:TwinMarker + 'x' + $ext }
        else { $name = $suspectLeaf + $Script:TwinMarker + $libBase.Substring(0, [Math]::Min($libBase.Length, $tailBudget)) + $ext }
    }
    $dest = Join-Path $dir $name
    if (Test-Path -LiteralPath $dest) { return }
    Copy-Item -LiteralPath $LibraryFile -Destination $dest
    Set-FileReadOnly $dest $false
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
        'ingested'        = 0
        'complete-copy'   = 0
        'partial-copy'    = 0
        'suspected-copy'  = 0
        'date-missing'    = 0
        'damaged'         = 0
        'orphan-sidecar'  = 0
        'non-media'       = 0
    }
}

function Write-IngestSummary {
    param($Stats)
    $parts = foreach ($key in @('ingested', 'complete-copy', 'partial-copy', 'suspected-copy', 'date-missing', 'damaged', 'orphan-sidecar', 'non-media')) {
        if ($Stats[$key] -gt 0) { "$key $($Stats[$key])" }
    }
    if (-not $parts) { $parts = @('nothing processed') }
    Write-Host ''
    Write-Host ("Groups: " + ($parts -join '  '))
}

function Get-BucketFileCount {
    param([string]$Dir, [switch]$Recurse)
    if (-not (Test-Path -LiteralPath $Dir)) { return 0 }
    @(Get-ChildItem -LiteralPath $Dir -File -Recurse:$Recurse |
        Where-Object { $_.Name -notlike "*$($Script:TwinMarker)*" -and $_.Name -ne $Script:ManifestName }).Count
}

function Write-PendingSummary {
    param($Paths)
    $partial = Get-BucketFileCount $Paths.PartialCopy
    $suspect = Get-BucketFileCount $Paths.SuspectCopy
    $keep = Get-BucketFileCount $Paths.Keep -Recurse
    $dates = Get-BucketFileCount $Paths.DateMissing -Recurse
    if ($partial -gt 0 -or $suspect -gt 0) {
        Write-Host "_must-decide pending: $partial partial-copy, $suspect suspected-copy"
    }
    if ($keep -gt 0)  { Write-Host "_must-decide\keep holds $keep file(s) awaiting 'ingest resume'" }
    if ($dates -gt 0) { Write-Host "_must-provide holds $dates file(s) awaiting dates ('ingest resume' after dating)" }
}

function Invoke-GroupIngest {
    [CmdletBinding(SupportsShouldProcess)]
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
    foreach ($m in $mediaMembers) {
        $hit = $null
        if ($Index.ByHash.ContainsKey($hashes[$m.FullName])) { $hit = $Index.ByHash[$hashes[$m.FullName]] }
        else {
            $img = Get-ImageDataHash (& $metaOf $m)
            if ($img -and $Index.ByImage.ContainsKey($img)) { $hit = $Index.ByImage[$img] }
        }
        $matchTarget[$m.FullName] = $hit
        if ($null -eq $hit) { $newOnes += $m }
    }

    if ($newOnes.Count -eq 0) {
        foreach ($m in $members) {
            Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.CompleteCopy $m.Name) | Out-Null
        }
        $Stats['complete-copy']++
        return
    }

    if ($newOnes.Count -lt $mediaMembers.Count) {
        foreach ($m in $members) {
            $moved = Move-FileSafe -Source $m.FullName -Dest (Join-Path $Paths.PartialCopy $m.Name)
            if ($moved -and $matchTarget.ContainsKey($m.FullName) -and $matchTarget[$m.FullName]) {
                Copy-LibraryTwin $moved $matchTarget[$m.FullName]
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
                if ($null -eq $moved) { continue }
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
                if ($counterpart) { Copy-LibraryTwin $moved $counterpart.Path }
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
        if ($null -eq $moved) { continue }
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
    }
    $Stats['ingested']++
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
    [CmdletBinding(SupportsShouldProcess)]
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

    Write-Host "Ingesting $($files.Count) files from $inboxFull"
    $meta = Get-MediaMetadata @($files.FullName)
    $index = New-CatalogIndex $Paths.Library
    Write-Host "Index loaded: $($index.Records) records"

    $stats = New-IngestStats
    foreach ($group in (Get-AssetGroups $files)) {
        Invoke-GroupIngest -Paths $Paths -Group $group -Meta $meta -Index $index `
            -InboxRoot $inboxFull -Stats $stats
    }

    Remove-EmptyInboxDirs -InboxRoot $inboxFull
    Write-IngestSummary $stats
    Write-PendingSummary $Paths
}

function Resume-Ingest {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Root = $PSScriptRoot)

    $Script:ExifTool = Resolve-ExifTool
    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths

    $keepFiles = Get-IngestibleFiles $Paths.Keep
    $dateFiles = Get-IngestibleFiles $Paths.DateMissing
    if ($keepFiles.Count -eq 0 -and $dateFiles.Count -eq 0) {
        Write-Host 'Nothing to resume.'
        Write-PendingSummary $Paths
        return
    }

    $allPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $keepFiles) { $allPaths.Add($f.FullName) }
    foreach ($f in $dateFiles) { $allPaths.Add($f.FullName) }
    $meta = Get-MediaMetadata $allPaths.ToArray()
    $index = New-CatalogIndex $Paths.Library
    $stats = New-IngestStats

    if ($keepFiles.Count -gt 0) {
        Write-Host "Resuming $($keepFiles.Count) decided file(s) from keep"
        foreach ($group in (Get-AssetGroups $keepFiles)) {
            Invoke-GroupIngest -Paths $Paths -Group $group -Meta $meta -Index $index `
                -InboxRoot $Paths.Keep -Stats $stats -SkipExifTier
        }
    }

    $stillUndated = 0
    if ($dateFiles.Count -gt 0) {
        Write-Host "Checking $($dateFiles.Count) file(s) awaiting dates"
        foreach ($group in (Get-AssetGroups $dateFiles)) {
            $resolved = $null
            foreach ($m in @($group.Members | Where-Object { (Get-ExtInfo $_.Extension).Kind -eq 'media' })) {
                $resolved = Resolve-DateTaken $meta[$m.FullName.ToLowerInvariant()] $m.Name
                if ($resolved) { break }
            }
            if ($null -eq $resolved) {
                $stillUndated += $group.Members.Count
                continue
            }
            Invoke-GroupIngest -Paths $Paths -Group $group -Meta $meta -Index $index `
                -InboxRoot $Paths.DateMissing -Stats $stats -ForceManualDate
        }
        Remove-EmptyInboxDirs -InboxRoot $Paths.DateMissing
    }

    Write-IngestSummary $stats
    if ($stillUndated -gt 0) { Write-Host "Still need a date: $stillUndated file(s)" }
    Write-PendingSummary $Paths
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Full,
        [string]$Root = $PSScriptRoot
    )

    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    $dryRun = [bool]$WhatIfPreference
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
                $findings.Add([pscustomobject]@{ issue = 'not-readonly'; folder = $folder; name = $record.name; detail = 'run update to restore' })
            }
            if ($file.Length -ne $record.size) {
                $issue = if ($file.Length -eq 0) { 'zeroed' } else { 'size-mismatch' }
                $findings.Add([pscustomobject]@{ issue = $issue; folder = $folder; name = $record.name; detail = "expected $($record.size), found $($file.Length)" })
                continue
            }
            if (-not $Full) { continue }

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
            $findings.Add([pscustomobject]@{ issue = 'orphan'; folder = $folder; name = $name; detail = 'file has no catalog record; run update' })
        }

        if ($Full -and $changed -and -not $dryRun) { Write-Manifest $folder $records }
    }

    $bad = @($findings | Where-Object { $_.issue -in @('missing', 'zeroed', 'size-mismatch', 'corrupt') })
    $mode = if ($Full) { 'full' } else { 'quick' }
    Write-Host "Verify ($mode): $checked records checked, $($bad.Count) problems, $($findings.Count) findings total"
    foreach ($f in $findings) { Write-Host ("  [{0}] {1}\{2} {3}" -f $f.issue, $f.folder, $f.name, $f.detail) }
    Write-PendingSummary $Paths
    $findings
}

function Get-OrigFromName {
    param([string]$Name)
    $m = [regex]::Match($Name, '^\d{8}_\d{6}_(?<orig>.+)$')
    if ($m.Success) { $m.Groups['orig'].Value } else { $Name }
}

function Update-Catalog {
    [CmdletBinding(SupportsShouldProcess)]
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
                if ($PSCmdlet.ShouldProcess($p, 'Restore read-only attribute')) {
                    $item.IsReadOnly = $true
                    $rearmed++
                }
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

                if ($PSCmdlet.ShouldProcess("$folder\$($m.Name)", 'Append catalog record')) {
                    Add-ManifestRecord $folder $record
                    Set-FileReadOnly $m.FullName $true
                }
                $added++
            }
        }
    }
    Write-Host "Update: $added records appended, $rearmed read-only attributes restored, $skipped files left uncataloged"
}

function Reset-Catalog {
    [CmdletBinding(SupportsShouldProcess)]
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
        if (-not $PSCmdlet.ShouldContinue($msg, 'photo-mgr catalog rebuild')) { return }
    }

    $dryRun = [bool]$WhatIfPreference
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

        if (-not $dryRun -and $PSCmdlet.ShouldProcess($folder, 'Rewrite manifest')) {
            Write-Manifest $folder $records
        }
        Write-Host "Reset $folder : $($records.Count) records"
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
        [ValidateSet('primary', 'companion', 'sidecar')]
        [string]$Role,
        [string[]]$Columns,
        [string]$Root = $PSScriptRoot
    )

    $Paths = Get-SotPaths $Root
    Assert-SotRoot $Paths
    if (-not $Out) { Write-Usage 'catalog export'; throw 'catalog export requires -Out' }
    $allColumns = @('name', 'role', 'primary', 'size', 'hash_full', 'hash_imagedata',
        'date_taken', 'date_source', 'tz_offset', 'width', 'height', 'duration',
        'camera_make', 'camera_model', 'camera_serial', 'orig_filename',
        'ingested_at', 'last_verified', 'year', 'month', 'ext')
    $selected = if ($Columns) { @($Columns | Where-Object { $allColumns -contains $_ }) } else { $allColumns }
    if ($selected.Count -eq 0) { throw "No valid columns; available: $($allColumns -join ', ')" }

    $encoding = if ($As -eq 'Csv') { [System.Text.UTF8Encoding]::new($true) } else { $Script:Utf8NoBom }
    $writer = [System.IO.StreamWriter]::new([System.IO.Path]::GetFullPath($Out), $false, $encoding)
    $count = 0
    try {
        if ($As -eq 'Csv') {
            $writer.WriteLine(($selected -join ','))
        }
        foreach ($folder in (Get-LibraryFolders $Paths | Sort-Object)) {
            $leaf = Split-Path -Leaf $folder
            if ($leaf -notmatch '^\d{4}-\d{2}$') { continue }
            if ($From -and $leaf -lt $From) { continue }
            if ($To -and $leaf -gt $To) { continue }

            foreach ($record in (Read-Manifest $folder)) {
                if ($Role -and $record.role -ne $Role) { continue }
                $augmented = [ordered]@{}
                foreach ($prop in $record.PSObject.Properties) { $augmented[$prop.Name] = $prop.Value }
                $augmented['year'] = [int]([string]$record.date_taken).Substring(0, 4)
                $augmented['month'] = ([string]$record.date_taken).Substring(0, 7)
                $augmented['ext'] = [System.IO.Path]::GetExtension([string]$record.name).TrimStart('.').ToLowerInvariant()

                if ($As -eq 'Csv') {
                    $writer.WriteLine((@($selected | ForEach-Object { ConvertTo-CsvField $augmented[$_] }) -join ','))
                }
                else {
                    $writer.WriteLine((ConvertTo-JsonLine $augmented))
                }
                $count++
            }
        }
    }
    finally { $writer.Dispose() }
    Write-Host "Exported $count records to $Out"
}

$Script:UsageText = [ordered]@{
    'ingest'          = 'ingest  -Inbox <folder> [-WhatIf] [-Root <path>]'
    'ingest resume'   = 'ingest  resume [-WhatIf] [-Root <path>]'
    'catalog verify'  = 'catalog verify [-Full] [-WhatIf] [-Root <path>]'
    'catalog fix'     = 'catalog fix [-WhatIf] [-Root <path>]'
    'catalog rebuild' = 'catalog rebuild [-Month <yyyy-MM|all>] [-Force] [-WhatIf] [-Root <path>]'
    'catalog export'  = 'catalog export -Out <file> [-As <Csv|Jsonl>] [-From <yyyy-MM>] [-To <yyyy-MM>] [-Role <primary|companion|sidecar>] [-Columns <a,b,c>] [-Root <path>]'
}

function Write-Usage {
    param([string]$Only)
    if ($Only -and $Script:UsageText.Contains($Only)) {
        Write-Host "usage: photo-mgr.ps1 $($Script:UsageText[$Only])"
        return
    }
    Write-Host 'usage: photo-mgr.ps1 <command> [options]'
    Write-Host ''
    foreach ($key in $Script:UsageText.Keys) {
        Write-Host "  $($Script:UsageText[$key])"
    }
    Write-Host ''
    Write-Host "ingest resume applies your finished work: _must-decide\keep and newly dated _must-provide files"
    Write-Host '-Root defaults to the script folder'
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Command) {
    Write-Usage
    exit 1
}

$Script:UsageKey = $null
try {
    switch ($Command) {
        'ingest' {
            if (@($Rest).Count -gt 0 -and "$($Rest[0])" -eq 'resume') {
                $Script:UsageKey = 'ingest resume'
                $subArgs = @(@($Rest) | Select-Object -Skip 1)
                Resume-Ingest @subArgs
            }
            else {
                $Script:UsageKey = 'ingest'
                Import-Batch @Rest
            }
        }
        'catalog' {
            $sub = if (@($Rest).Count -gt 0) { "$($Rest[0])" } else { '' }
            $subArgs = @(@($Rest) | Select-Object -Skip 1)
            switch ($sub) {
                'verify'  { $Script:UsageKey = 'catalog verify';  Test-Catalog @subArgs }
                'fix'     { $Script:UsageKey = 'catalog fix';     Update-Catalog @subArgs }
                'rebuild' { $Script:UsageKey = 'catalog rebuild'; Reset-Catalog @subArgs }
                'export'  { $Script:UsageKey = 'catalog export';  Export-Catalog @subArgs }
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
