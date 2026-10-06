# PSVR2 Upscaler

[日本語](README.md) · [Download](https://github.com/ioridev/psvr2-upscaler/releases/tag/v0.1.0) · [Report an issue](https://github.com/ioridev/psvr2-upscaler/issues)

Apply **AMD FSR 1 EASU spatial upscaling** to PSVR2 PCVR output through SteamVR. The tool lowers VRChat's rendering resolution and reconstructs the image with an edge-adaptive filter.

It uses [CustomHeadsetOpenVR](https://github.com/sboys3/CustomHeadsetOpenVR)'s display shader replacement in SteamVR's `vrcompositor.exe`. It does not modify game files or inject a DLL into the VRChat process.

## Requirements

- 64-bit Windows and a PSVR2 already working in PCVR.
- [SteamVR](https://store.steampowered.com/app/250820/SteamVR/) and the [PlayStation VR2 App](https://store.steampowered.com/app/2580190/PlayStationVR2_App/). Check normal headset operation first.
- **[CustomHeadsetOpenVR 1.3.0](https://github.com/sboys3/CustomHeadsetOpenVR/releases/tag/1.3.0)**. Extract the entire official release ZIP and run `CustomHeadsetGUI/custom-headset-gui.exe` to install the driver. When updating it, reinstall the driver from its About page. [Official installation instructions](https://github.com/sboys3/CustomHeadsetOpenVR#installing)
- Windows PowerShell 5.1, included with Windows. Visual Studio and Python are not required for normal use.

This release supports the **original CustomHeadsetOpenVR 1.3.0 shader**. Installation stops if a different version or an unknown shader modification is detected. SteamVR, CustomHeadsetOpenVR, and other external software are not bundled.

## Quick start

1. Download `PSVR2-Upscaling-v0.1.0.zip` from [Releases](https://github.com/ioridev/psvr2-upscaler/releases/tag/v0.1.0) and extract the entire folder.
2. **Exit SteamVR and VRChat.**
3. Double-click `Start-PSVR2-Upscaling.cmd`.
4. Start with **67%** rendering resolution and click **「導入する」 (Install)**. For later resolution changes, click **「設定を適用」 (Apply settings)**.
5. Start SteamVR and VRChat, then inspect the image in your headset.

The interface currently uses Japanese. **「状態を更新」 (Refresh status)** checks saved files and settings. An installed status does not by itself prove that the current SteamVR process is executing the shader. Changes take effect on the next SteamVR start.

### Resolution and performance

**67% refers to pixel count.** Each dimension is approximately **81.9%** of the equivalent 100% setting. Raise it to prioritize image quality, or lower it to reduce the number of rendered pixels.

FPS depends on the world, avatars, and GPU and CPU load. Running at half the headset's refresh rate also depends on workload and SteamVR reprojection settings. This is not frame generation, and it does not guarantee a particular FPS improvement or full-refresh-rate rendering.

For a useful comparison, keep the world, avatars, and viewpoint unchanged and compare frame times. Controlled FPS comparisons have not yet been performed.

### What changes

- CustomHeadsetOpenVR's shader and custom-filter settings.
- **VRChat's per-application rendering resolution** in SteamVR. Global SteamVR resolution and refresh rate are left unchanged.

The custom filter is shared by CustomHeadsetOpenVR and may affect other games and supported headsets. VRChat's per-application resolution is not headset-specific either. EASU is excluded from SteamVR overlays and the dashboard.

## Restore or update

Exit SteamVR and VRChat, then click **「元に戻す」 (Restore)**. This restores the original shader and the managed settings from before installation. Unrelated settings changed afterward are preserved.

Backups are stored in `%LOCALAPPDATA%\PSVR2Upscaling`. Keep them until restoration is complete. If another tool has changed a managed shader or setting, restoration reports the conflict instead of overwriting it.

**Before installing a newer release, restore with your current release first.** Also check compatibility after updating SteamVR or CustomHeadsetOpenVR.

## Troubleshooting

| Problem | Action |
| --- | --- |
| CustomHeadsetOpenVR is not found | Install its driver through the official GUI; extracting its ZIP alone is insufficient. |
| Version or original shader does not match | Check that the original 1.3.0 files are installed. Do not stack this patch on unknown modifications. |
| Running processes are reported | Exit SteamVR and VRChat, then retry. |
| Access is denied | Check write permissions for the reported location. This tool does not automatically elevate to administrator. |
| The image looks wrong | Exit SteamVR and VRChat, restore, and check normal headset output. |
| Restoration reports a conflict | Inspect the listed setting and the backup. Do not delete the backup to retry. |

Include Windows, GPU, SteamVR, and CustomHeadsetOpenVR versions and the error in an [issue](https://github.com/ioridev/psvr2-upscaler/issues). Redact usernames and personal paths from logs.

## How it works and validation

The pipeline is: low-resolution stereo images → EASU resampling combined with SteamVR distortion correction → PSVR2. It does not allocate a separate high-resolution intermediate image. It preserves distortion coordinates for each RGB channel, clamps taps to the current eye's region, and uses ordinary sampling where the mapping locally minifies the image.

This is the **EASU portion of FSR 1**. It does not include the separate RCAS sharpening pass, FSR 2/3/4, frame generation, or eye-tracked foveated rendering.

Verified on 2026-10-06:

- 36 GPU readback checks passed on an AMD Radeon RX 9070, including black and flat images, eye boundaries, alpha, minification, and comparison with AMD's original implementation.
- Nine shader permutations compiled using actual SteamVR shader declarations.
- Shader replacement inside the compositor and stereo rendering were verified with a physical PSVR2.
- VRChat launched through its normal Steam/EAC route and continued producing frames. A headset user reported that the resulting image looked good.

Long-duration stability and controlled FPS comparisons remain untested. These observations are **not official EAC approval or a guarantee of future compatibility**. This project is not an official Sony, Valve, AMD, or VRChat product.

## Command line

Run from the repository or extracted folder:

```powershell
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Status
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Install -ResolutionScale 67
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Configure -ResolutionScale 80
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Uninstall
```

Add `-DryRun` to inspect planned changes. On initial installation, `-SkipResolutionScale` preserves VRChat's existing per-application resolution.

The wrapper starts a hidden Windows PowerShell process through WMI to access the settings used by normal SteamVR. This avoids AppData virtualization differences when launched from an MSIX app. It does not automatically elevate or persistently change PowerShell execution policy.

## Development

Fetch the pinned upstream source and regenerate the derived shader:

```powershell
git clone https://github.com/sboys3/CustomHeadsetOpenVR.git external/CustomHeadsetOpenVR
git -C external/CustomHeadsetOpenVR checkout 21185da63a9e4307ae876b3702a43a43044d451c
git -C external/CustomHeadsetOpenVR submodule update --init --depth 1 ThirdParty/openvr
.\scripts\Build-CompositorShader.ps1
```

- `Build-CompositorShader.ps1 -Compile` requires Windows SDK `fxc` and actual SteamVR shader declarations captured by CustomHeadsetOpenVR.
- `Test-Psvr2Gpu.ps1` builds a D3D11 validation program with Visual Studio C++ tools and reads back GPU results.
- `Test-Psvr2Vr.ps1` builds and checks shaders. `-Probe` reads headset state; explicit `-Run` displays a test scene.

Developer scripts are included in the full repository. The user release ZIP contains only the files needed to install, configure, and restore. Validation outputs are written to directories such as `artifacts/`.

## License and credits

The project is distributed under [GNU GPL v2](LICENSE). The AMD EASU-derived file retains its MIT license notice. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for component sources, modifications, and licenses.

Thanks to [CustomHeadsetOpenVR](https://github.com/sboys3/CustomHeadsetOpenVR), [AMD FidelityFX-FSR](https://github.com/GPUOpen-Effects/FidelityFX-FSR), and [Valve OpenVR](https://github.com/ValveSoftware/openvr).
