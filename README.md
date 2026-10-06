# PSVR2 Upscaler

[English](README.en.md) · [ダウンロード](https://github.com/ioridev/psvr2-upscaler/releases/tag/v0.1.0) · [不具合報告](https://github.com/ioridev/psvr2-upscaler/issues)

PSVR2 の PCVR 映像に、SteamVR 側で **AMD FSR 1 EASU の空間アップスケーリング**を適用するツールです。VRChat の描画解像度を下げた画像を、輪郭に適応するフィルターで拡大します。

[CustomHeadsetOpenVR](https://github.com/sboys3/CustomHeadsetOpenVR) の表示シェーダー置換を利用します。ゲームのファイルを変更せず、VRChat のプロセスに DLL を組み込むこともありません。処理は SteamVR の `vrcompositor.exe` 側で行います。

## 必要なもの

- Windows 64 bit と、PC 接続で動作する PSVR2。
- [SteamVR](https://store.steampowered.com/app/250820/SteamVR/) と [PlayStation VR2 App](https://store.steampowered.com/app/2580190/PlayStationVR2_App/)。まず通常の状態で PSVR2 が使えることを確認してください。
- **[CustomHeadsetOpenVR 1.3.0](https://github.com/sboys3/CustomHeadsetOpenVR/releases/tag/1.3.0)**。公式配布の ZIP 全体を展開し、`CustomHeadsetGUI/custom-headset-gui.exe` からドライバーを導入してください。更新時は GUI の About ページからドライバーを再インストールします。[公式の導入手順](https://github.com/sboys3/CustomHeadsetOpenVR#installing)
- Windows 標準の Windows PowerShell 5.1。通常の利用に Visual Studio や Python は不要です。

このリリースは CustomHeadsetOpenVR **1.3.0 の元シェーダー**に対応します。異なる版や、別の改造を加えたシェーダーへの上書きは停止します。SteamVR、CustomHeadsetOpenVR などの外部ソフトは同梱していません。

## はじめに

1. [Releases](https://github.com/ioridev/psvr2-upscaler/releases/tag/v0.1.0) の `PSVR2-Upscaling-v0.1.0.zip` をダウンロードし、フォルダー全体を展開します。
2. **SteamVR と VRChat を終了**します。
3. `Start-PSVR2-Upscaling.cmd` をダブルクリックします。
4. 初回は描画解像度 **67%** を選んで **「導入する」**を押します。導入後に解像度を変えるときは **「設定を適用」**を押します。
5. SteamVR と VRChat を起動し、ヘッドセットの表示を確認します。

「状態を更新」は保存済みのファイルと設定を確認します。表示が「導入済み」でも、現在の SteamVR 内でシェーダーが実行されていることまで証明するものではありません。変更は次回の SteamVR 起動から反映されます。

### 解像度と性能

**67% はピクセル数の割合**です。同じ基準の 100% に対し、縦横の解像度はそれぞれ約 **81.9%** になります。画質を優先するなら値を上げ、描画するピクセル数を減らしたい場合は下げて調整してください。

FPS への効果はワールド、アバター、GPU・CPU の負荷に依存します。SteamVR がリフレッシュレートの半分の FPS で動くかどうかも、負荷や再投影の設定によって変わります。これはフレーム生成ではなく、一定の FPS 向上や最大リフレッシュレートでの動作を保証するものではありません。

比較するときは、同じワールド・アバター・視点でフレーム時間を確認してください。条件を固定した FPS 向上率の測定は、まだ実施していません。

### 変更する範囲

- CustomHeadsetOpenVR のシェーダーと、カスタムフィルターの有効化設定。
- SteamVR の **VRChat 個別の描画解像度**。SteamVR 全体の解像度やリフレッシュレートは変更しません。

カスタムフィルターは CustomHeadsetOpenVR 共通の設定なので、他のゲームや対応 HMD にも適用され得ます。VRChat の個別解像度も HMD ごとの設定ではありません。SteamVR オーバーレイやダッシュボードには EASU を適用しません。

## 元に戻す・更新する

SteamVR と VRChat を終了し、ツールの **「元に戻す」**を押してください。元のシェーダーと、導入前の管理対象設定に戻します。後から変更した無関係な設定は保持します。

バックアップは `%LOCALAPPDATA%\PSVR2Upscaling` に保存します。復元が済むまで削除しないでください。管理対象のシェーダーや設定に別の変更が入った場合は、上書きせず競合を報告します。

**新しいバージョンへ更新するときは、今の版で「元に戻す」を実行してから、新しい版を導入**してください。SteamVR や CustomHeadsetOpenVR を更新した場合も、対応状況を確認してください。

## うまく動かないとき

| 状況 | 対処 |
| --- | --- |
| CustomHeadsetOpenVR が見つからない | ZIP の展開だけでなく、公式 GUI からドライバーを導入してください。 |
| バージョンや元シェーダーが一致しない | 対応する 1.3.0 の元ファイルか確認してください。別の改造に重ねて導入しないでください。 |
| 起動中のプロセスがあると言われる | SteamVR と VRChat を終了してから再実行してください。 |
| アクセスが拒否される | 表示された保存先の書き込み権限を確認してください。このツールは管理者へ自動昇格しません。 |
| 表示がおかしい | SteamVR と VRChat を終了し、「元に戻す」で通常の表示に戻して確認してください。 |
| 復元時に競合する | 詳しい結果に出た項目とバックアップを確認してください。バックアップを削除してやり直さないでください。 |

[Issue](https://github.com/ioridev/psvr2-upscaler/issues) には Windows、GPU、SteamVR、CustomHeadsetOpenVR のバージョンとエラーを添えてください。ログ中のユーザー名や個人用フォルダーは伏せてください。

## 仕組みと確認状況

処理は「低解像度の左右眼画像 → EASU による再サンプリングと SteamVR の歪み補正 → PSVR2」です。独立した高解像度の中間画像は作りません。RGB ごとの歪み座標を維持し、左右眼の境界でサンプルを制限します。局所的に縮小する領域では通常のサンプリングを使います。

実装は **FSR 1 の EASU 部分**です。RCAS の追加シャープニング、FSR 2/3/4、フレーム生成、視線追跡による可変解像度は含みません。

2026-10-06 時点で、以下を確認しています。

- AMD Radeon RX 9070 で GPU 読み戻し検証 36 項目が成功。黒・単色・左右眼境界・アルファ・縮小時の分岐・AMD オリジナル実装との比較を含みます。
- SteamVR の実際の宣言を使う 9 通りのシェーダーコンパイルが成功。
- PSVR2 実機でコンポジター内のシェーダー置換と、左右眼への描画を確認。
- 通常の Steam/EAC 経由で起動した VRChat でフレーム更新を確認。実機利用者から、表示は良好とのフィードバックを得ています。

長時間の安定性や、条件を固定した FPS 比較は未検証です。この動作確認は **EAC の公式認証や、将来の互換性の保証ではありません**。本プロジェクトは Sony、Valve、AMD、VRChat の公式製品ではありません。

## コマンドラインで使う

リポジトリーまたは展開したフォルダー内で実行します。

```powershell
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Status
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Install -ResolutionScale 67
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Configure -ResolutionScale 80
.\scripts\Invoke-HostPsvr2Upscaling.ps1 -Action Uninstall
```

`-DryRun` は変更予定だけを表示します。初回導入時に `-SkipResolutionScale` を指定すると、VRChat の個別解像度を変更しません。

このラッパーは WMI から非表示の Windows PowerShell を起動し、通常の SteamVR が読む設定を扱います。MSIX アプリからの実行時にも AppData の仮想化による保存先の違いを避けます。管理者への自動昇格や、実行ポリシーの永続的な変更は行いません。

## 開発

ソースの取得と派生シェーダーの再生成:

```powershell
git clone https://github.com/sboys3/CustomHeadsetOpenVR.git external/CustomHeadsetOpenVR
git -C external/CustomHeadsetOpenVR checkout 21185da63a9e4307ae876b3702a43a43044d451c
git -C external/CustomHeadsetOpenVR submodule update --init --depth 1 ThirdParty/openvr
.\scripts\Build-CompositorShader.ps1
```

- `Build-CompositorShader.ps1 -Compile`: Windows SDK の `fxc` と、CustomHeadsetOpenVR が取得した実際の SteamVR シェーダー宣言を使用します。
- `Test-Psvr2Gpu.ps1`: Visual Studio C++ ツールで D3D11 検証プログラムをビルドし、GPU の結果を読み戻します。
- `Test-Psvr2Vr.ps1`: ビルドとシェーダー検証。`-Probe` は実機状態の読み取り、明示的な `-Run` はテストシーンの表示です。

開発用スクリプトはリポジトリーのソース一式に含まれます。利用者向け ZIP は導入・設定・復元に必要なファイルのみを含みます。検証出力は `artifacts/` などに保存します。

## ライセンスと謝辞

プロジェクトは [GNU GPL v2](LICENSE) で配布します。AMD EASU 由来のファイルには MIT ライセンスの表示を保持しています。コンポーネントごとの出典・変更内容・ライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。

[CustomHeadsetOpenVR](https://github.com/sboys3/CustomHeadsetOpenVR)、[AMD FidelityFX-FSR](https://github.com/GPUOpen-Effects/FidelityFX-FSR)、[Valve OpenVR](https://github.com/ValveSoftware/openvr) に感謝します。
