# PSVR2 compositor EASU

CustomHeadsetOpenVR 1.3.0 の SteamVR 表示シェーダーに、AMD FSR 1 の EASU（輪郭に適応する空間アップスケーリング）を追加するローカル実装です。ゲーム側の DLL やプロセスへの組み込みは行わず、既存 CustomHeadsetOpenVR の `vrcompositor.exe` 用シェーダー置換を利用します。

処理は「低解像度の左右眼画像 → EASU による再サンプリングと SteamVR の歪み補正 → PSVR2」です。独立した高解像度の中間画像を作る方式ではありません。RGB ごとの歪み座標を維持し、左右眼の境界でサンプルを制限します。局所的に縮小する領域は通常のサンプリングに戻し、SteamVR オーバーレイには EASU を適用しません。

これは **FSR 1 の EASU 部分**です。RCAS の追加シャープニング、FSR 2/3/4、フレーム生成、視線追跡による可変解像度は含みません。EAC の公式認証や将来の互換性を意味しません。

## インストールと復元

SteamVR と VRChat を終了して実行します。

```powershell
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Install -ResolutionScale 67
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Status
```

VRChat の SteamVR 個別解像度を 67% にします。これはピクセル数の割合で、縦横はそれぞれ約 81.9% です。SteamVR 全体の解像度とリフレッシュレートは変更しません。ゲームの負荷やボトルネックによって性能への効果は変わります。

カスタムフィルター設定そのものは CustomHeadsetOpenVR 共通の設定です。他の対応 HMD を使う場合にも適用され得ます。VRChat の個別解像度も HMD ごとの設定ではありません。

元のフィルターと変更前の VRChat 個別設定へ戻すには次を実行します。

```powershell
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Uninstall
```

元のシェーダーと変更した設定項目は `%LOCALAPPDATA%\PSVR2Upscaling` に保存されます。以後の無関係な設定変更は保持します。管理対象のシェーダーや設定に別の変更が入った場合は、勝手に上書きせず競合を報告します。`-DryRun` は変更予定だけを表示します。

`Invoke-HostPsvr2Upscaling.ps1` は WMI から非表示の通常 PowerShell を起動します。Codex の MSIX 環境では AppData の読み書きが専用 `LocalCache` に転送され、SteamVR が読む実ファイルと異なりました。このラッパーで導入・確認・復元を同じ実ファイルに対して行います。管理者権限への昇格は行いません。低レベルの `Manage-Psvr2Upscaling.ps1` を Codex 内から直接実行すると、この仮想化されたコピーを参照するため使用しないでください。

SteamVR 起動後に実際のシェーダーコンパイル・置換ログと PSVR2 の表示を確認して初めて実行経路を検証できます。`Status` の設定表示だけでは有効化の証拠になりません。

## 実装と検証

- `shaders/psvr2_easu.hlsl`: AMD EASU の連続 UV 座標対応版。
- `shaders/distort_ps_layered.hlsl`: 導入する CustomHeadsetOpenVR 派生シェーダー。
- `scripts/Build-CompositorShader.ps1`: 元ソースから派生版を再生成。`-Compile` で実際の SteamVR バイトコードから取得された宣言を使い、3 種類 × 3 フィルターをコンパイル。
- `scripts/Test-Psvr2Gpu.ps1`: D3D11 ハードウェア GPU で計算し、結果を読み戻して検証。
- `scripts/Test-Psvr2Vr.ps1`: ビルド、および明示的な `-Run` / `-Probe` による OpenVR 実機検証。
- `scripts/capture_vr_shader_debug.py`: SteamVR の公開デバッグ出力を収集。

検証結果は `artifacts/` に保存します。GPU 単体の計測と、実機のコンポジター計測、VRChat の動作確認は別々の証拠として扱います。

2026-10-06 の実行結果:

- AMD Radeon RX 9070 で GPU 読み戻し検証 36 項目成功。黒・単色・左右眼境界・アルファ・縮小時の分岐・AMD オリジナル実装との比較を含みます。
- SteamVR の実際の宣言を用いた 9 通りのシェーダーコンパイル成功。
- 実際の `vrcompositor.exe` 内でコンパイル／キャッシュ利用の成功ログ 27 件、置換 15 件、コンパイルエラー 0 件。
- PSVR2 実機、119.879791 Hz、片眼 2783×2839 のテスト画像で両眼 Submit 2,390 フレーム成功。実ドライバーは `playstation_vr2`。一般シーンアプリにはモデル名を Oculus Quest2 と報告する互換動作があるため、実ドライバー名と区別しました。
- VRChat を通常の Steam/EAC 経由で起動。OpenVR 接続ログと、VRChat がシーンを担当したまま 457 件のフレーム時刻更新を取得しました。長時間の安定性、画質の主観評価、比較条件を固定した FPS 向上率までは未検証です。

## 参照した OSS

- [CustomHeadsetOpenVR](https://github.com/sboys3/CustomHeadsetOpenVR)、`21185da63a9e4307ae876b3702a43a43044d451c`。GPL-2.0。元シェーダー SHA256: `65CAAA283BE3F4FD9B8F62459E2E73D5D3B5136E6448A635C518217003E902CB`。
- [AMD FidelityFX-FSR](https://github.com/GPUOpen-Effects/FidelityFX-FSR)、`a21ffb8f6c13233ba336352bdff293894c706575`。EASU は MIT。著作権表示をシェーダー内に保持。
- [Valve OpenVR](https://github.com/ValveSoftware/openvr)。実機検証プログラムの API。

[vrperfkit](https://github.com/fholger/vrperfkit) と [NVIDIA NIS](https://github.com/NVIDIAGameWorks/NVIDIAImageScaling) も調査しました。今回の実装は既存の SteamVR 表示シェーダーに組み込める EASU を採用しています。

ソースを再取得する場合:

```powershell
git clone https://github.com/sboys3/CustomHeadsetOpenVR.git external/CustomHeadsetOpenVR
git -C external/CustomHeadsetOpenVR checkout 21185da63a9e4307ae876b3702a43a43044d451c
git -C external/CustomHeadsetOpenVR submodule update --init --depth 1 ThirdParty/openvr
.\scripts\Build-CompositorShader.ps1 -Compile
```
