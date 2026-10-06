# Third-party notices

PSVR2 Upscaler is distributed under the GNU General Public License, version 2; see [LICENSE](LICENSE). The following upstream notices and component licenses are retained. An individual component's permissive license does not change the license of the combined GPL-covered shader.

## CustomHeadsetOpenVR

- Project: <https://github.com/sboys3/CustomHeadsetOpenVR>
- Upstream authors: sboys3 and CustomHeadsetOpenVR contributors.
- Version: 1.3.0, commit `21185da63a9e4307ae876b3702a43a43044d451c`.
- Source: [`distort_ps_layered.hlsl`](https://github.com/sboys3/CustomHeadsetOpenVR/blob/21185da63a9e4307ae876b3702a43a43044d451c/CustomHeadsetOpenVR/DriverFiles/resources/shaders/d3d11/distort_ps_layered.hlsl).
- Derived file in this project: `shaders/distort_ps_layered.hlsl`.
- License: GNU GPL v2; upstream license text is reproduced in [licenses/CustomHeadsetOpenVR-GPL-2.0.txt](licenses/CustomHeadsetOpenVR-GPL-2.0.txt).

Modified on 2026-10-06 to add EASU scene sampling, per-channel distortion derivatives, per-eye sample bounds, and exclusion of overlays and the dashboard from EASU. `scripts/Build-CompositorShader.ps1` reproduces this adaptation from the pinned source.

The original shader's SHA-256 is `65CAAA283BE3F4FD9B8F62459E2E73D5D3B5136E6448A635C518217003E902CB`. The installer verifies the supported baseline before patching. CustomHeadsetOpenVR executables and driver DLLs are separate prerequisites and are not included in the PSVR2 Upscaler release ZIP.

## AMD FidelityFX Super Resolution 1 — EASU

- Project: <https://github.com/GPUOpen-Effects/FidelityFX-FSR>
- Source commit: `a21ffb8f6c13233ba336352bdff293894c706575`.
- Source: [`ffx-fsr/ffx_fsr1.h`](https://github.com/GPUOpen-Effects/FidelityFX-FSR/blob/a21ffb8f6c13233ba336352bdff293894c706575/ffx-fsr/ffx_fsr1.h).
- Adapted file in this project: `shaders/psvr2_easu.hlsl`.
- License: MIT; retained in the shader header and [licenses/FidelityFX-FSR-MIT.txt](licenses/FidelityFX-FSR-MIT.txt).

Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

The EASU equations are adapted for continuous distortion coordinates, explicit texture and eye bounds, safe exact reciprocals, a linear-input conversion, alpha preservation, and a local-minification bypass. This implementation contains EASU spatial reconstruction only; it does not include the separate RCAS pass. The MIT notice is preserved for the EASU component.

## Valve OpenVR

- Project: <https://github.com/ValveSoftware/openvr>
- Use: optional developer-side headset validation headers and runtime API.
- License: BSD 3-Clause; reproduced in [licenses/OpenVR-BSD-3-Clause.txt](licenses/OpenVR-BSD-3-Clause.txt).

Copyright (c) 2015, Valve Corporation. All rights reserved.

OpenVR headers are obtained through the pinned CustomHeadsetOpenVR source's OpenVR submodule when building the developer validation program. `scripts/Test-Psvr2Vr.ps1` uses the installed SteamVR runtime DLL for its local test build. The user release ZIP does not include OpenVR headers, runtime DLLs, or the compiled validation program.

## External software and names

Windows, SteamVR, PlayStation VR2 App, headset drivers, and VRChat are external prerequisites and are not redistributed by this release. References to their names, or to AMD FidelityFX, describe compatibility or source attribution and do not imply endorsement or official support.
