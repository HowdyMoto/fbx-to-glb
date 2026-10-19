#Requires -Version 5.1
<#
.SYNOPSIS
Recursively converts FBX files to GLB using Blender in the background.
.DESCRIPTION
Runs one clean Blender process per file. With no OutputFolder, GLBs are saved
beside their FBXs. Otherwise, the input folder structure is mirrored underneath
OutputFolder. Existing GLBs are skipped unless Overwrite is supplied.

Exports to a temporary file in the destination directory, checks its GLB header,
then commits it. A failed conversion does not replace an existing GLB. Errors
are logged and the batch continues. Junctions and symbolic links are skipped.

Requires Windows PowerShell 5.1 or PowerShell 7 on Windows, and Blender with its
FBX importer and glTF exporter. Designed for Blender 3.6 and later. Python is
embedded in this script and is run by Blender; no separate Python is needed.
.PARAMETER InputFolder
Folder to search recursively. Paths are treated literally, including brackets.
.PARAMETER OutputFolder
Optional destination root. Subfolders and filenames are preserved.
.PARAMETER BlenderPath
Path to blender.exe. If omitted, searches PATH and standard Blender Foundation
directories under Program Files. Supply this for portable or custom installs.
.PARAMETER Overwrite
Replace existing GLBs only after successful export and validation.
.PARAMETER LogDirectory
Parent directory for a new timestamped log folder. Defaults to
_FBXtoGLB_logs underneath OutputFolder, or InputFolder if no output is specified.
.PARAMETER TimeoutSeconds
Maximum time for each Blender process. Default: 900 (15 minutes). 0 disables it.
.EXAMPLE
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models'
.EXAMPLE
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models' -OutputFolder 'D:\Converted'
.EXAMPLE
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models' -OutputFolder 'D:\Converted' -BlenderPath 'C:\Program Files\Blender Foundation\Blender 4.5\blender.exe' -Overwrite
.NOTES
Exit codes: 0 = success (including skipped files / no FBXs), 1 = one or more
conversion or folder-scan failures, 2 = setup or logging failure.
Each run contains run.log, results.csv, the generated Python worker, and
separate Blender stdout/stderr logs for every attempted conversion.
Materials, textures, rigs, and animation are limited by Blender/glTF support.
Missing source textures may yield incomplete materials; inspect Blender logs.
Existing files skipped without Overwrite are not validated.
Run normally with & or -File; do not dot-source this script (it uses exit).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('RootFolder', 'InputPath')]
    [ValidateNotNullOrEmpty()]
    [string]$InputFolder,

    [ValidateNotNullOrEmpty()]
    [string]$OutputFolder,

    [ValidateNotNullOrEmpty()]
    [string]$BlenderPath,

    [switch]$Overwrite,

    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory,

    [ValidateRange(0, 2147483)]
    [int]$TimeoutSeconds = 900
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:RunLog = $null
$script:ScanFailures = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-FullFileSystemPath([string]$Path) {
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $Path, [ref]$provider, [ref]$drive)
    if ($provider.Name -ne 'FileSystem') { throw "Not a filesystem path: $Path" }
    return [System.IO.Path]::GetFullPath($resolved)
}

function Write-RunLog([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'), $Level, $Message
    if ($script:RunLog) {
        [System.IO.File]::AppendAllText($script:RunLog, $line + [Environment]::NewLine, $utf8)
    }
    Write-Host $line
}

function Find-Blender([string]$RequestedPath) {
    if ($RequestedPath) {
        $candidate = Get-FullFileSystemPath $RequestedPath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Blender executable not found: $candidate"
        }
        if ([System.IO.Path]::GetExtension($candidate) -ine '.exe') {
            throw 'BlenderPath must point to blender.exe, not a folder or shell script.'
        }
        return $candidate
    }
    $command = Get-Command blender.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { return $command.Source }

    $candidates = @()
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $programRoot) { continue }
        $foundation = Join-Path $programRoot 'Blender Foundation'
        if (-not (Test-Path -LiteralPath $foundation -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $foundation -Directory -ErrorAction SilentlyContinue)) {
            $executable = Join-Path $directory.FullName 'blender.exe'
            if (Test-Path -LiteralPath $executable -PathType Leaf) {
                $version = [version]'0.0'
                if ($directory.Name -match '(\d+\.\d+(?:\.\d+)?)') { $version = [version]$Matches[1] }
                $candidates += [pscustomobject]@{ Path = $executable; Version = $version }
            }
        }
    }
    $latest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($latest) { return $latest.Path }
    throw 'Blender was not found. Install Blender or pass -BlenderPath with the full path to blender.exe.'
}

function Get-FbxFiles([string]$Root) {
    # Explicit traversal avoids junction cycles and reports inaccessible folders.
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $scanErrors = @()
        $entries = @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue -ErrorVariable scanErrors)
        foreach ($scanError in $scanErrors) {
            $script:ScanFailures++
            Write-RunLog 'ERROR' "Cannot fully scan '$directory': $scanError"
        }
        foreach ($entry in $entries) {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Write-RunLog 'WARN' "Skipping link/reparse point: $($entry.FullName)"
                continue
            }
            if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
            elseif ($entry.Extension -ieq '.fbx') { $entry }
        }
    }
}

function ConvertTo-WindowsArgument([string]$Value) {
    # ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.1.
    # Quote for Windows argv parsing, doubling backslashes before quotes/end.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-BlenderFile(
    [string]$Executable, [string[]]$ArgumentValues,
    [string]$StdoutPath, [string]$StderrPath, [string]$WorkingDirectory
) {
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $Executable
    $process.StartInfo.Arguments = ($ArgumentValues | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    $process.StartInfo.WorkingDirectory = $WorkingDirectory
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $process.StartInfo.EnvironmentVariables['PYTHONUNBUFFERED'] = '1'
    $outStream = $null
    $errStream = $null
    $outTask = $null
    $errTask = $null
    $started = $false
    try {
        $outStream = [System.IO.File]::Open($StdoutPath, 'CreateNew', 'Write', 'Read')
        $errStream = [System.IO.File]::Open($StderrPath, 'CreateNew', 'Write', 'Read')
        $started = $process.Start()
        if (-not $started) { throw 'Blender process could not be started.' }
        # Drain both pipes concurrently, directly to disk, without deadlocks or
        # accumulating potentially large Blender output in PowerShell memory.
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outStream)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($errStream)
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(200)) {
            if ($TimeoutSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw "Blender exceeded the per-file timeout of $TimeoutSeconds seconds."
            }
        }
        [void]$outTask.GetAwaiter().GetResult()
        [void]$errTask.GetAwaiter().GetResult()
        return $process.ExitCode
    }
    finally {
        # Also runs on cancellation; never kill unrelated Blender instances.
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            $process.WaitForExit()
        }
        try {
            if ($outTask) { [void]$outTask.GetAwaiter().GetResult() }
            if ($errTask) { [void]$errTask.GetAwaiter().GetResult() }
        }
        finally {
            if ($outStream) { $outStream.Dispose() }
            if ($errStream) { $errStream.Dispose() }
            $process.Dispose()
        }
    }
}

function Assert-GlbHeader([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { throw 'Blender did not produce an output GLB.' }
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = New-Object System.IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 20) { throw 'Exported GLB is empty or truncated.' }
        if ($reader.ReadUInt32() -ne 0x46546C67 -or $reader.ReadUInt32() -ne 2) {
            throw 'Exported file is not a GLB version 2 file.'
        }
        if ($reader.ReadUInt32() -ne $stream.Length) { throw 'GLB declared size does not match its file size.' }
        $jsonLength = $reader.ReadUInt32()
        if ($reader.ReadUInt32() -ne 0x4E4F534A -or $jsonLength -eq 0 -or
            ($jsonLength % 4) -ne 0 -or (20L + $jsonLength) -gt $stream.Length) {
            throw 'GLB has an invalid JSON chunk header.'
        }
    }
    finally { $reader.Dispose() }
}

# This worker is written into the run log folder and executed by Blender.
$pythonWorker = @'
import json
import os
import struct
import sys
import bpy


def operator_available(operator):
    try:
        operator.get_rna_type()
        return True
    except (AttributeError, RuntimeError):
        return False


def enable_if_needed(operator, module):
    if not operator_available(operator):
        import addon_utils
        addon_utils.enable(module, default_set=False, persistent=False)
    return operator_available(operator)


def main():
    args = sys.argv[sys.argv.index('--') + 1:]
    if len(args) != 2:
        raise RuntimeError('Expected source FBX and temporary destination GLB.')
    source, destination = args
    print('Blender:', bpy.app.version_string, flush=True)
    print('Source:', source, flush=True)
    print('Temporary destination:', destination, flush=True)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    # Prefer the established importer when present. Newer builds may provide
    # the native wm.fbx_import operator instead; detect rather than assume.
    legacy = bpy.ops.import_scene.fbx
    try:
        have_legacy = enable_if_needed(legacy, 'io_scene_fbx')
    except Exception as exc:
        print('Legacy FBX importer unavailable:', exc, flush=True)
        have_legacy = False
    if have_legacy:
        result = legacy(filepath=source, use_image_search=True, use_anim=True)
    elif operator_available(bpy.ops.wm.fbx_import):
        result = bpy.ops.wm.fbx_import(filepath=source, use_anim=True)
    else:
        raise RuntimeError('No FBX importer is available in this Blender installation.')
    if 'FINISHED' not in result:
        raise RuntimeError('FBX import did not finish: ' + repr(result))
    if not bpy.data.objects:
        raise RuntimeError('The FBX imported no objects.')

    for image in bpy.data.images:
        if image.source == 'FILE' and not image.packed_file and image.filepath:
            image_path = bpy.path.abspath(image.filepath)
            if not os.path.isfile(image_path):
                print('WARNING: Missing image:', image_path, flush=True)

    if not enable_if_needed(bpy.ops.export_scene.gltf, 'io_scene_gltf2'):
        raise RuntimeError('The glTF exporter is not available in this Blender installation.')
    result = bpy.ops.export_scene.gltf(
        filepath=destination,
        check_existing=False,
        export_format='GLB',
        use_selection=False,
        export_materials='EXPORT',
        export_animations=True,
        export_frame_range=False,
        export_skins=True,
        export_morph=True,
        export_cameras=True,
        export_lights=True,
        export_yup=True,
    )
    if 'FINISHED' not in result:
        raise RuntimeError('GLB export did not finish: ' + repr(result))

    # Basic structural checks, not a full glTF conformance/visual validation.
    size = os.path.getsize(destination)
    with open(destination, 'rb') as handle:
        magic, version, declared_size = struct.unpack('<4sII', handle.read(12))
        if magic != b'glTF' or version != 2 or declared_size != size:
            raise RuntimeError('Invalid or truncated GLB header.')
        chunk_size, chunk_type = struct.unpack('<II', handle.read(8))
        if chunk_type != 0x4E4F534A or chunk_size % 4 or chunk_size > size - 20:
            raise RuntimeError('Invalid GLB JSON chunk.')
        document = json.loads(handle.read(chunk_size).decode('utf-8'))
        if document.get('asset', {}).get('version') != '2.0' or not document.get('nodes'):
            raise RuntimeError('GLB has no exported nodes or an invalid asset version.')
    print('EXPORT OK:', size, 'bytes', flush=True)


# Leave exceptions uncaught: --python-exit-code turns them into process failures
# and Blender writes the traceback into this file's captured logs.
main()
'@

$converted = 0
$skipped = 0
$failed = 0
$exitCode = 2
try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script targets Windows.'
    }
    $inputRoot = Get-FullFileSystemPath $InputFolder
    if (-not (Test-Path -LiteralPath $inputRoot -PathType Container)) {
        throw "Input folder does not exist: $inputRoot"
    }
    # Keep the separator on drive/UNC roots and use it as a path boundary.
    $inputPrefix = $inputRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $outputRoot = $inputRoot
    if ($OutputFolder) { $outputRoot = Get-FullFileSystemPath $OutputFolder }
    $logRoot = Join-Path $outputRoot '_FBXtoGLB_logs'
    if ($LogDirectory) { $logRoot = Get-FullFileSystemPath $LogDirectory }
    $runName = '{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), [guid]::NewGuid().ToString('N')
    $runDirectory = Join-Path $logRoot $runName
    [void][System.IO.Directory]::CreateDirectory($runDirectory)
    $script:RunLog = Join-Path $runDirectory 'run.log'
    $csvPath = Join-Path $runDirectory 'results.csv'
    $workerPath = Join-Path $runDirectory 'convert-worker.py'
    [System.IO.File]::WriteAllText($workerPath, $pythonWorker, $utf8)
    [System.IO.File]::WriteAllText($csvPath,
        '"Input","Output","Status","Seconds","BlenderExitCode","Message","StdoutLog","StderrLog"' + [Environment]::NewLine, $utf8)
    Write-RunLog 'INFO' "Input: $inputRoot"
    Write-RunLog 'INFO' "Output: $outputRoot"
    Write-RunLog 'INFO' "Overwrite: $Overwrite; per-file timeout: $TimeoutSeconds seconds (0 = unlimited)"
    Write-RunLog 'INFO' "Logs: $runDirectory"
    $blenderExecutable = Find-Blender $BlenderPath
    Write-RunLog 'INFO' "Blender: $blenderExecutable"

    $files = @(Get-FbxFiles $inputRoot | Sort-Object FullName)
    Write-RunLog 'INFO' "Found $($files.Count) FBX file(s)."
    if ($files.Count -eq 0) { Write-RunLog 'WARN' 'No FBX files found.' }
    $index = 0
    foreach ($file in $files) {
        $index++
        if (-not $file.FullName.StartsWith($inputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Scanned path falls outside input root: $($file.FullName)"
        }
        $relativePath = $file.FullName.Substring($inputPrefix.Length)
        $target = Join-Path $outputRoot ([System.IO.Path]::ChangeExtension($relativePath, '.glb'))
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        $temporary = $null
        $record = [pscustomobject][ordered]@{
            Input = $file.FullName; Output = $target; Status = ''; Seconds = 0
            BlenderExitCode = ''; Message = ''; StdoutLog = ''; StderrLog = ''
        }
        try {
            if (-not $Overwrite -and (Test-Path -LiteralPath $target -PathType Leaf)) {
                $record.Status = 'Skipped'
                $record.Message = 'Destination already exists; use -Overwrite to replace.'
                $skipped++
                Write-RunLog 'SKIP' "[$index/$($files.Count)] $relativePath"
                continue
            }
            if (Test-Path -LiteralPath $target -PathType Container) {
                throw "A directory occupies the GLB output path: $target"
            }
            $parent = [System.IO.Path]::GetDirectoryName($target)
            [void][System.IO.Directory]::CreateDirectory($parent)
            $temporary = Join-Path $parent ('.fbx2glb-' + [guid]::NewGuid().ToString('N') + '.glb')
            $record.StdoutLog = Join-Path $runDirectory ('{0:D6}.stdout.log' -f $index)
            $record.StderrLog = Join-Path $runDirectory ('{0:D6}.stderr.log' -f $index)
            Write-RunLog 'INFO' "[$index/$($files.Count)] Converting: $relativePath"
            $blenderArguments = @('--background', '--factory-startup', '--disable-autoexec',
                '--python-exit-code', '10', '--python', $workerPath, '--', $file.FullName, $temporary)
            $processCode = Invoke-BlenderFile $blenderExecutable $blenderArguments `
                $record.StdoutLog $record.StderrLog $file.DirectoryName
            $record.BlenderExitCode = $processCode
            if ($processCode -ne 0) { throw "Blender exited with code $processCode. See this file's stdout/stderr logs." }
            Assert-GlbHeader $temporary

            # Move is no-clobber. Replace commits on the destination filesystem;
            # never delete an old GLB first. Unsupported filesystems report failure.
            if ($Overwrite -and [System.IO.File]::Exists($target)) {
                # PowerShell 5.1 coerces ordinary $null to an empty string here.
                [System.IO.File]::Replace($temporary, $target, [System.Management.Automation.Language.NullString]::Value)
            }
            else {
                try { [System.IO.File]::Move($temporary, $target) }
                catch {
                    if (-not $Overwrite -and [System.IO.File]::Exists($target)) {
                        $record.Status = 'Skipped'
                        $record.Message = 'Destination appeared during conversion; preserved it.'
                        $skipped++
                        Write-RunLog 'SKIP' $record.Message
                        continue
                    }
                    throw
                }
            }
            $record.Status = 'Converted'
            $record.Message = 'Exported and checked GLB header.'
            $converted++
            Write-RunLog 'OK' $target
        }
        catch {
            $record.Status = 'Failed'
            $record.Message = $_.Exception.Message
            $failed++
            Write-RunLog 'ERROR' "$relativePath : $($record.Message)"
        }
        finally {
            if ($temporary -and [System.IO.File]::Exists($temporary)) {
                try { [System.IO.File]::Delete($temporary) }
                catch { Write-RunLog 'WARN' "Could not remove temporary output '$temporary': $_" }
            }
            $record.Seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 3)
            $record | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Append
        }
    }
    Write-RunLog 'INFO' "Completed. Converted: $converted; skipped: $skipped; failed: $failed; scan errors: $script:ScanFailures."
    Write-RunLog 'INFO' "Results: $csvPath"
    $exitCode = 0
    if ($failed -gt 0 -or $script:ScanFailures -gt 0) { $exitCode = 1 }
}
catch {
    $message = $_.Exception.Message
    try { Write-RunLog 'FATAL' $message }
    catch { [Console]::Error.WriteLine('FATAL: ' + $message + '; unable to write run log.') }
    $exitCode = 2
}
exit $exitCode
