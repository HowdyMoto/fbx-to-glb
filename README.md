# fbx-to-glb

A PowerShell script that batch-converts FBX models to GLB (binary glTF 2.0) using Blender in the background.

Point it at a folder and it finds every `.fbx` underneath, converts each one in a fresh Blender process, checks the output, and logs everything. You can write the GLBs next to the source files or mirror the folder tree into a separate output folder.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7, on Windows
- [Blender](https://www.blender.org/download/) 3.6 or later, with its FBX importer and glTF 2.0 exporter (both ship with Blender)

The Python that drives Blender is embedded in the script, so you don't need a separate Python install.

Tested with Blender 5.2.2 under both Windows PowerShell 5.1 and PowerShell 7.

## Quick start

```powershell
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models'
```

This searches `D:\Models` and all its subfolders and writes each GLB beside its FBX, so `D:\Models\Vehicles\Car.fbx` becomes `D:\Models\Vehicles\Car.glb`. Existing GLBs are skipped, and source FBX files are never modified.

To write into a separate folder with the same structure:

```powershell
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models' -OutputFolder 'D:\Converted'
# D:\Models\Vehicles\Car.fbx  ->  D:\Converted\Vehicles\Car.glb
```

To replace existing GLBs:

```powershell
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models' -OutputFolder 'D:\Converted' -Overwrite
```

To point at a specific Blender install:

```powershell
.\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models' -BlenderPath 'C:\Program Files\Blender Foundation\Blender 4.5\blender.exe'
```

Without `-BlenderPath`, the script looks in this order:

1. `PATH`
2. The `Blender Foundation` folders under Program Files, picking the highest version
3. Steam libraries on any drive (Blender installed through Steam)

Portable or custom installs usually need `-BlenderPath`.

If script execution is disabled on your machine, you can bypass the execution policy for this one process (organization policy permitting):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Convert-FBXtoGLB.ps1 -InputFolder 'D:\Models'
```

Use `pwsh.exe` instead of `powershell.exe` to run it under PowerShell 7. Run the script normally; don't dot-source it, because it reports results through its exit code.

## Options

| Parameter         | Description                                                                                              |
| ----------------- | -------------------------------------------------------------------------------------------------------- |
| `-InputFolder`    | **Required.** Folder to search recursively. Paths are taken literally, brackets included.                |
| `-OutputFolder`   | Output root. Defaults to writing each GLB beside its source FBX.                                         |
| `-BlenderPath`    | Full path to `blender.exe`.                                                                              |
| `-Overwrite`      | Replace existing GLBs, but only after the new export succeeds and passes its checks.                    |
| `-LogDirectory`   | Parent folder for the timestamped run logs. Defaults to `_FBXtoGLB_logs` in the output (or input) folder. |
| `-TimeoutSeconds` | Per-file Blender timeout. Default `900` (15 minutes). Use `0` for no timeout.                            |

Full built-in help:

```powershell
Get-Help .\Convert-FBXtoGLB.ps1 -Full
```

## Logs and exit codes

Each run creates its own log folder and prints where it is. By default that's:

```
<OutputFolder>\_FBXtoGLB_logs\<timestamp>_<id>\
```

If you don't pass `-OutputFolder`, the logs go under the input folder instead. Each run folder contains:

- `run.log`: progress, skipped files, errors, and final counts
- `results.csv`: one row per FBX, with its status, duration, output path, error message, Blender exit code, and paths to its Blender logs
- `000001.stdout.log` / `000001.stderr.log`: raw Blender output for each conversion. Use `results.csv` to match them to source files, and check both logs when something fails.
- `convert-worker.py`: the Python worker Blender ran, saved for inspection

A failed file doesn't stop the batch. Unreadable directories are logged and count as failures. Symlinks, junctions, and other reparse points are skipped so the scan can't loop. Hidden files and folders are included.

| Exit code | Meaning                                                                         |
| --------- | ------------------------------------------------------------------------------- |
| `0`       | No conversion or scan failures (this includes "everything skipped" and "no FBX files found") |
| `1`       | At least one conversion or directory scan failed                                |
| `2`       | Setup or logging failed                                                          |

Check `$LASTEXITCODE` right after the script finishes.

## How it works

Each FBX is opened in a new background Blender process with an empty scene, so nothing carries over from one file to the next. The export includes materials, animation, skins, morph targets, cameras, and lights; all other settings use Blender's glTF defaults.

Blender writes to a uniquely named temporary file (`.fbx2glb-*.glb`) in the destination folder. The Python worker checks the GLB's JSON and makes sure it contains nodes, then PowerShell checks the GLB header before moving the file into place. These checks catch broken or empty output. They don't validate full glTF conformance or check how the model looks.

With `-Overwrite`, the existing GLB is swapped out with an atomic filesystem replace instead of being deleted first, so a failed conversion leaves the old file intact. Without `-Overwrite`, if a GLB appears at the target while a conversion is running, that file is kept. Temporary files are cleaned up after failures where possible, but force-closing PowerShell mid-run can leave one behind.

Skipped GLBs aren't validated. Use `-Overwrite` if you want to regenerate them.

## Limitations

How faithful a conversion is depends on the FBX data and on Blender's FBX importer and glTF exporter. Keep external textures where the FBX expects them. A missing texture shows up as a warning in Blender's log but doesn't fail the export. Some materials, animation setups, or FBX variants may need manual fixes in Blender, so open a few converted models in the viewer you plan to use.

## Blender references

- [FBX import operator (`import_scene.fbx`)](https://docs.blender.org/api/main/bpy.ops.import_scene.html)
- [Native FBX import operator (`wm.fbx_import`)](https://docs.blender.org/api/4.5/bpy.ops.wm.html)
- [glTF export operator](https://docs.blender.org/api/3.6/bpy.ops.export_scene.html)
- [Command-line arguments and Python exit codes](https://docs.blender.org/manual/en/3.3/advanced/command_line/arguments.html)
- [glTF 2.0 add-on manual](https://docs.blender.org/manual/en/5.1/addons/import_export/scene_gltf2.html)

## License

[CC0 1.0 Universal](LICENSE). This project is dedicated to the public domain, so you can use it for anything without asking or giving credit.
