#Requires -Version 5.1
<#
.SYNOPSIS
Japanese Windows interface for the PSVR2 upscaling installer.
.DESCRIPTION
All host operations use Invoke-HostPsvr2Upscaling.ps1 without elevation.
SmokeTest creates the interface and closes it without invoking host operations.
ReadOnlySmokeTest exercises the real asynchronous Status path without changing settings.
.EXAMPLE
.\scripts\Show-Psvr2Upscaling.ps1
.EXAMPLE
powershell.exe -NoProfile -STA -File .\scripts\Show-Psvr2Upscaling.ps1 -SmokeTest -SmokeTestResultPath .\artifacts\ui-smoke.json
#>
[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [switch]$ReadOnlySmokeTest,
    [string]$SmokeTestResultPath,
    [Alias('PreviewPath')][string]$SmokeTestScreenshotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SmokeTest -and $ReadOnlySmokeTest) { throw 'Choose SmokeTest or ReadOnlySmokeTest, not both.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not ('Psvr2Upscaling.ManagementWindow' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
namespace Psvr2Upscaling {
    public class ManagementWindow : System.Windows.Forms.Form {
        public bool BackgroundPreview { get; set; }
        protected override bool ShowWithoutActivation { get { return BackgroundPreview; } }
        protected override System.Windows.Forms.CreateParams CreateParams {
            get {
                var p = base.CreateParams;
                if (BackgroundPreview) p.ExStyle |= 0x08000000 | 0x00000080;
                return p;
            }
        }
    }
}
'@
}
$wrapper = Join-Path $PSScriptRoot 'Invoke-HostPsvr2Upscaling.ps1'
$script:operation = $null
$script:lastStatus = $null
$script:qualityEdited = $false
$script:settingQuality = $false
$script:lastDetail = ''
$blue = [Drawing.Color]::FromArgb(30, 88, 190)
$ink = [Drawing.Color]::FromArgb(29, 39, 56)
$muted = [Drawing.Color]::FromArgb(85, 98, 116)
$background = [Drawing.Color]::FromArgb(246, 248, 251)

function Get-Field($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function New-Label([string]$Text, [single]$Size = 10, [bool]$Bold = $false) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.ForeColor = $ink
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $label.Font = New-Object Drawing.Font('Yu Gothic UI', $Size, $style)
    return $label
}

function New-Button([string]$Text, [int]$Width) {
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object Drawing.Size($Width, 40)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(205, 214, 227)
    $button.BackColor = [Drawing.Color]::White
    $button.Cursor = 'Hand'
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 0)
    return $button
}

$form = New-Object Psvr2Upscaling.ManagementWindow
$form.Text = 'PSVR2 アップスケーリング'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(744, 650)
$form.MinimumSize = New-Object Drawing.Size(760, 688)
$form.BackColor = $background
$form.ForeColor = $ink
$form.Font = New-Object Drawing.Font('Yu Gothic UI', 10)
$form.AutoScaleMode = 'Dpi'

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Padding = New-Object Windows.Forms.Padding(24, 18, 24, 18)
$layout.ColumnCount = 1
$layout.RowCount = 7
$null = $layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
foreach ($height in @(72, 114, 149, 76, 51, 27)) {
    $null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height)))
}
$null = $layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
$form.Controls.Add($layout)

$heading = New-Object Windows.Forms.Panel
$heading.Dock = 'Fill'
$title = New-Label 'PSVR2 アップスケーリング' 20 $true
$title.Location = New-Object Drawing.Point(0, 0)
$subtitle = New-Label 'VRChat の描画負荷と画質を調整します。' 10
$subtitle.ForeColor = $muted
$subtitle.Location = New-Object Drawing.Point(1, 42)
$heading.Controls.AddRange(@($title, $subtitle))
$layout.Controls.Add($heading, 0, 0)

$statusPanel = New-Object Windows.Forms.Panel
$statusPanel.Dock = 'Fill'
$statusPanel.BackColor = [Drawing.Color]::White
$statusPanel.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
$stateLabel = New-Label '状態を確認しています…' 14 $true
$stateLabel.Location = New-Object Drawing.Point(14, 11)
$stateLabel.MaximumSize = New-Object Drawing.Size(650, 30)
$statusSummary = New-Label '保存済みの設定を読み込みます。' 10
$statusSummary.Location = New-Object Drawing.Point(15, 45)
$statusSummary.MaximumSize = New-Object Drawing.Size(650, 25)
$runtimeLabel = New-Label '' 9
$runtimeLabel.ForeColor = $muted
$runtimeLabel.Location = New-Object Drawing.Point(15, 72)
$runtimeLabel.MaximumSize = New-Object Drawing.Size(650, 25)
$statusPanel.Controls.AddRange(@($stateLabel, $statusSummary, $runtimeLabel))
$layout.Controls.Add($statusPanel, 0, 1)

$qualityPanel = New-Object Windows.Forms.Panel
$qualityPanel.Dock = 'Fill'
$qualityHeading = New-Label '描画品質' 11 $true
$qualityHeading.Location = New-Object Drawing.Point(0, 0)
$presets = New-Object Windows.Forms.ComboBox
$presets.DropDownStyle = 'DropDownList'
$presets.Location = New-Object Drawing.Point(0, 31)
$presets.Size = New-Object Drawing.Size(300, 32)
$null = $presets.Items.AddRange(@('標準  —  67%', '軽量  —  50%', '高画質  —  100%', 'カスタム'))
$presets.SelectedIndex = 0
$scale = New-Object Windows.Forms.NumericUpDown
$scale.Minimum = 20
$scale.Maximum = 100
$scale.Value = 67
$scale.Location = New-Object Drawing.Point(319, 31)
$scale.Size = New-Object Drawing.Size(80, 32)
$scale.TextAlign = 'Right'
$percentLabel = New-Label '%' 11
$percentLabel.Location = New-Object Drawing.Point(405, 33)
$scaleExplanation = New-Label '' 9
$scaleExplanation.ForeColor = $muted
$scaleExplanation.Location = New-Object Drawing.Point(0, 75)
$scaleExplanation.MaximumSize = New-Object Drawing.Size(682, 52)
$qualityPanel.Controls.AddRange(@($qualityHeading, $presets, $scale, $percentLabel, $scaleExplanation))
$layout.Controls.Add($qualityPanel, 0, 2)

$actionPanel = New-Object Windows.Forms.Panel
$actionPanel.Dock = 'Fill'
$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.FlowDirection = 'LeftToRight'
$buttons.WrapContents = $false
$buttons.Size = New-Object Drawing.Size(686, 42)
$apply = New-Button '適用する' 190
$apply.BackColor = $blue
$apply.ForeColor = [Drawing.Color]::White
$apply.FlatAppearance.BorderColor = $blue
$restore = New-Button '元に戻す' 150
$refresh = New-Button '状態を更新' 140
$buttons.Controls.AddRange(@($apply, $restore, $refresh))
$preview = New-Object Windows.Forms.CheckBox
$preview.Text = '設定を変更せず、内容だけ確認する'
$preview.AutoSize = $true
$preview.Location = New-Object Drawing.Point(0, 49)
$actionPanel.Controls.AddRange(@($buttons, $preview))
$layout.Controls.Add($actionPanel, 0, 3)

$noticePanel = New-Object Windows.Forms.Panel
$noticePanel.Dock = 'Fill'
$operationLabel = New-Label '変更する場合は SteamVR と VRChat を終了してください。' 9
$operationLabel.ForeColor = $muted
$operationLabel.MaximumSize = New-Object Drawing.Size(680, 24)
$operationLabel.Location = New-Object Drawing.Point(0, 0)
$dependencyLink = New-Object Windows.Forms.LinkLabel
$dependencyLink.Text = '必要な CustomHeadsetOpenVR 1.3.0 を入手'
$dependencyLink.AutoSize = $true
$dependencyLink.Font = New-Object Drawing.Font('Yu Gothic UI', 9)
$dependencyLink.LinkColor = $blue
$dependencyLink.Location = New-Object Drawing.Point(0, 25)
$dependencyLink.Add_LinkClicked({ Start-Process 'https://github.com/sboys3/CustomHeadsetOpenVR/releases' })
$noticePanel.Controls.AddRange(@($operationLabel, $dependencyLink))
$layout.Controls.Add($noticePanel, 0, 4)

$showDetails = New-Object Windows.Forms.CheckBox
$showDetails.Text = '詳しい結果を表示'
$showDetails.AutoSize = $true
$showDetails.Margin = New-Object Windows.Forms.Padding(0)
$layout.Controls.Add($showDetails, 0, 5)
$details = New-Object Windows.Forms.TextBox
$details.Dock = 'Fill'
$details.Multiline = $true
$details.ReadOnly = $true
$details.WordWrap = $false
$details.ScrollBars = 'Both'
$details.Font = New-Object Drawing.Font('Consolas', 9)
$details.BackColor = [Drawing.Color]::White
$details.BorderStyle = 'FixedSingle'
$details.Visible = $false
$details.Margin = New-Object Windows.Forms.Padding(0)
$layout.Controls.Add($details, 0, 6)
$showDetails.Add_CheckedChanged({ $details.Visible = $showDetails.Checked })

function Get-ManagedState {
    return [string](Get-Field $script:lastStatus 'recordedState' 'Unknown')
}

function Test-RecordedShaders {
    $files = @(Get-Field $script:lastStatus 'shaders' @())
    return $files.Count -eq 2 -and @($files | Where-Object { -not (Get-Field $_ 'matchesRecordedPatch' $false) }).Count -eq 0
}

function Get-ApplyAction {
    if ((Get-ManagedState) -eq 'Installed' -and (Test-RecordedShaders)) { return 'Configure' }
    return 'Install'
}

function Update-Controls {
    $busy = $null -ne $script:operation
    $known = $null -ne $script:lastStatus
    $state = Get-ManagedState
    $running = @(Get-Field $script:lastStatus 'runningProcesses' @()).Count -gt 0
    $canChange = -not $busy -and $known -and (-not $running -or $preview.Checked)
    $validInstalled = $state -eq 'Installed' -and (Test-RecordedShaders)
    $canInstall = $state -in @('NotManaged', 'Uninstalled', 'Prepared')
    $apply.Enabled = $canChange -and ($validInstalled -or $canInstall)
    $restore.Enabled = $canChange -and $state -in @('Installed', 'Prepared') -and ((Test-RecordedShaders) -or $state -eq 'Prepared')
    $refresh.Enabled = -not $busy
    $presets.Enabled = -not $busy
    $scale.Enabled = -not $busy
    $preview.Enabled = -not $busy
    if ($preview.Checked) {
        $apply.Text = '適用内容を確認'
        $restore.Text = '復元内容を確認'
    }
    else {
        $apply.Text = if ($validInstalled) { '設定を適用' } else { '導入する' }
        $restore.Text = '元に戻す'
    }
    $form.UseWaitCursor = $busy
}

function Update-QualityText {
    $axis = [Math]::Sqrt([double]$scale.Value / 100.0) * 100.0
    $scaleExplanation.Text = ('描画ピクセル数 {0}%（縦横は約 {1:0}%）。数値を下げるほど負荷が軽くなります。' -f [int]$scale.Value, $axis) +
        [Environment]::NewLine + 'VRChat の個別設定だけを変更します。SteamVR 全体の解像度は変えません。'
}

function Set-Quality([int]$Value) {
    $script:settingQuality = $true
    try {
        $scale.Value = [Math]::Max(20, [Math]::Min(100, $Value))
        $presets.SelectedIndex = switch ([int]$scale.Value) { 67 { 0 }; 50 { 1 }; 100 { 2 }; default { 3 } }
    }
    finally { $script:settingQuality = $false }
    Update-QualityText
}

$presets.Add_SelectedIndexChanged({
    if (-not $script:settingQuality) {
        $script:qualityEdited = $true
        switch ($presets.SelectedIndex) { 0 { Set-Quality 67 }; 1 { Set-Quality 50 }; 2 { Set-Quality 100 } }
    }
})
$scale.Add_ValueChanged({
    if (-not $script:settingQuality) { $script:qualityEdited = $true; Set-Quality ([int]$scale.Value) }
})
$preview.Add_CheckedChanged({ Update-Controls })

function Show-Status($Status) {
    $script:lastStatus = $Status
    $state = Get-ManagedState
    $scaleNow = Get-Field $Status 'vrchatResolutionScale'
    $filter = Get-Field (Get-Field $Status 'customShader') 'samplingFilter' '未設定'
    if ($state -eq 'Installed' -and (Test-RecordedShaders) -and $filter -eq 'FSR_EASU') {
        $stateLabel.Text = '導入済み'
        $stateLabel.ForeColor = [Drawing.Color]::FromArgb(27, 116, 74)
    }
    elseif ($state -in @('NotManaged', 'Uninstalled')) {
        $stateLabel.Text = '未導入'
        $stateLabel.ForeColor = $ink
    }
    else {
        $stateLabel.Text = '設定の確認が必要です'
        $stateLabel.ForeColor = [Drawing.Color]::FromArgb(162, 92, 14)
    }
    $scaleText = if ($null -eq $scaleNow) { '個別指定なし' } else { "$scaleNow%" }
    $statusSummary.Text = "VRChat の描画解像度：$scaleText    フィルター：$filter"
    $running = @(Get-Field $Status 'runningProcesses' @())
    $runtimeLabel.Text = if ($running.Count -gt 0) {
        'SteamVR または VRChat が起動中です。変更には終了が必要です。'
    }
    else { 'SteamVR と VRChat は停止中です。設定を適用できます。' }
    if (-not $script:qualityEdited -and $null -ne $scaleNow) { Set-Quality ([int]$scaleNow) }
    Update-Controls
}

function Show-Error([string]$Message) {
    $stateLabel.Text = '操作を完了できませんでした'
    $stateLabel.ForeColor = [Drawing.Color]::FromArgb(174, 43, 45)
    $statusSummary.Text = '下の結果を確認して、状態の更新からやり直してください。'
    $runtimeLabel.Text = ''
    $operationLabel.Text = '設定の保存先や必要なソフトを確認してください。'
    if ($Message -match 'Close SteamVR|Running:') { $operationLabel.Text = 'SteamVR と VRChat を終了してから、もう一度お試しください。' }
    elseif ($Message -match 'resolution options|Uninstall.*before|Source shaders differ') {
        $operationLabel.Text = '更新版の導入は、いったん「元に戻す」を実行してから行ってください。'
    }
    $script:lastStatus = $null
    $script:lastDetail = $Message
    $details.Text = $Message
    $showDetails.Checked = $true
    Update-Controls
}

function Start-Operation([string]$Action, [bool]$IsPreview = $false, [bool]$KeepNotice = $false) {
    if ($null -ne $script:operation) { return }
    if ($SmokeTest) { throw 'SmokeTest must never invoke host operations.' }
    if ($ReadOnlySmokeTest -and $Action -ne 'Status') { throw 'ReadOnlySmokeTest only permits Status.' }
    try {
        if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw "Required file is missing: $wrapper" }
        $pipeline = [System.Management.Automation.PowerShell]::Create()
        $null = $pipeline.AddCommand($wrapper).AddParameter('Action', $Action).AddParameter('ResolutionScale', [int]$scale.Value)
        if ($IsPreview) { $null = $pipeline.AddParameter('DryRun', $true) }
        $script:operation = [pscustomobject]@{ pipeline = $pipeline; async = $null; action = $Action; preview = $IsPreview; keepNotice = $KeepNotice }
        if (-not $KeepNotice) {
            $operationLabel.Text = if ($Action -eq 'Status') { '状態を確認しています…' } elseif ($IsPreview) { '変更内容を確認しています…' } else { '設定を処理しています…' }
        }
        Update-Controls
        $script:operation.async = $pipeline.BeginInvoke()
    }
    catch {
        if ($null -ne $script:operation) { $script:operation.pipeline.Dispose(); $script:operation = $null }
        Show-Error $_.Exception.Message
    }
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    if ($null -eq $script:operation -or $null -eq $script:operation.async -or -not $script:operation.async.IsCompleted) { return }
    $completed = $script:operation
    $script:operation = $null
    try {
        $output = $completed.pipeline.EndInvoke($completed.async)
        if ($completed.pipeline.HadErrors) { throw (($completed.pipeline.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine) }
        $json = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        $result = $json | ConvertFrom-Json
        if ($completed.action -eq 'Status') {
            Show-Status $result
            if (-not $completed.keepNotice) { $operationLabel.Text = '保存済みの設定を確認しました。実際の画面はヘッドセットで確認できます。' }
            if (-not $completed.keepNotice) { $details.Text = $json; $script:lastDetail = $json }
        }
        elseif ($completed.preview) {
            $operationLabel.Text = '確認が完了しました。設定は変更していません。'
            $script:lastDetail = $json
            $details.Text = $json
            $showDetails.Checked = $true
        }
        else {
            $operationLabel.Text = if ($completed.action -eq 'Uninstall') { '変更前の設定へ戻しました。次回の SteamVR 起動から反映されます。' } else { '設定を保存しました。次回の SteamVR 起動から反映されます。' }
            $script:lastDetail = $json
            $details.Text = $json
            Start-Operation 'Status' $false $true
        }
    }
    catch { Show-Error $_.Exception.Message }
    finally { $completed.pipeline.Dispose(); Update-Controls }
})
$apply.Add_Click({ Start-Operation (Get-ApplyAction) $preview.Checked })
$restore.Add_Click({ Start-Operation 'Uninstall' $preview.Checked })
$refresh.Add_Click({ Start-Operation 'Status' })
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:operation) { $eventArgs.Cancel = $true; $operationLabel.Text = '処理が完了してから閉じてください。' }
})

Update-QualityText
Update-Controls
if ($SmokeTest) {
    try {
        # Render only our own form. Preview uses a transparent offscreen window
        # with WS_EX_NOACTIVATE; it cannot take focus or appear in the taskbar.
        # No host wrapper is called and no SteamVR settings are read or changed.
        $sampleStatus = [pscustomobject]@{
            recordedState = 'Installed'; vrchatResolutionScale = 67
            customShader = [pscustomobject]@{ samplingFilter = 'FSR_EASU' }
            shaders = @([pscustomobject]@{ matchesRecordedPatch = $true }, [pscustomobject]@{ matchesRecordedPatch = $true })
            runningProcesses = @()
        }
        Show-Status $sampleStatus
        if ((Get-ApplyAction) -ne 'Configure') { throw 'An installed patch must use Configure.' }
        Set-Quality 50
        if ($scale.Value -ne 50 -or $presets.SelectedIndex -ne 1) { throw 'Quality preset did not update.' }
        Set-Quality 67
        $sampleStatus.runningProcesses = @([pscustomobject]@{ ProcessName = 'vrserver'; Id = 1 })
        Show-Status $sampleStatus
        if ($apply.Enabled -or $restore.Enabled) { throw 'Live VR must disable changes.' }
        $preview.Checked = $true
        if (-not $apply.Enabled -or -not $restore.Enabled) { throw 'Live VR should allow read-only previews.' }
        $preview.Checked = $false
        $sampleStatus.runningProcesses = @()
        $sampleStatus.recordedState = 'NotManaged'
        Show-Status $sampleStatus
        if ((Get-ApplyAction) -ne 'Install' -or -not $apply.Enabled -or $restore.Enabled) { throw 'Unmanaged state has incorrect actions.' }
        Show-Error 'Smoke test: required dependency is missing.'
        if ($apply.Enabled -or -not $refresh.Enabled) { throw 'Errors must leave refresh available without allowing changes.' }
        $showDetails.Checked = $false
        $details.Clear()
        $sampleStatus.recordedState = 'Installed'
        Show-Status $sampleStatus
        $script:operation = [pscustomobject]@{ smoke = $true }
        Update-Controls
        if ($apply.Enabled -or $restore.Enabled -or $refresh.Enabled -or $scale.Enabled) { throw 'Busy state did not disable controls.' }
        $script:operation = $null
        Update-Controls
        $operationLabel.Text = '表示テスト：この画面の状態はサンプルです。設定は変更しません。'
        $form.ShowInTaskbar = $false
        $form.BackgroundPreview = $true
        $form.StartPosition = 'Manual'
        $form.Location = New-Object Drawing.Point(-32000, -32000)
        $form.Opacity = 0
        $null = $form.Handle
        $form.PerformLayout()
        if ($SmokeTestScreenshotPath) { $form.Show(); [Windows.Forms.Application]::DoEvents() }
        $result = [pscustomobject]@{
            result = 'PASS'; guiCreated = $form.IsHandleCreated; hostOperations = 0
            visibleWindowShown = $false; previewMode = 'Transparent offscreen, no activation'
            selectedPixelPercent = [int]$scale.Value; applyEnabled = $apply.Enabled
            restoreEnabled = $restore.Enabled; statusText = $stateLabel.Text
            checkedStates = @('Installed routing', 'Quality preset', 'VR running', 'Read-only preview', 'Not installed', 'Missing dependency', 'Busy controls')
            apartmentState = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
            clientWidth = $form.ClientSize.Width; clientHeight = $form.ClientSize.Height
        }
        if (-not $result.guiCreated -or -not $result.applyEnabled -or -not $result.restoreEnabled) { throw 'The smoke interface did not initialize correctly.' }
        if ($SmokeTestScreenshotPath) {
            $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
            try {
                $bounds = New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)
                $form.DrawToBitmap($bitmap, $bounds)
                $bitmap.Save([IO.Path]::GetFullPath($SmokeTestScreenshotPath), [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
        $json = $result | ConvertTo-Json -Depth 10
        if ($SmokeTestResultPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($SmokeTestResultPath), $json, (New-Object Text.UTF8Encoding($false))) }
        Write-Output $json
    }
    finally { $timer.Dispose(); $form.Dispose() }
    return
}
if ($ReadOnlySmokeTest) {
    try {
        $form.ShowInTaskbar = $false
        $form.BackgroundPreview = $true
        $form.StartPosition = 'Manual'
        $form.Location = New-Object Drawing.Point(-32000, -32000)
        $form.Opacity = 0
        $null = $form.Handle
        $form.PerformLayout()
        $timer.Start()
        Start-Operation 'Status'
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ($null -ne $script:operation) {
            [Windows.Forms.Application]::DoEvents()
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Read-only GUI status did not complete within 30 seconds.' }
            Start-Sleep -Milliseconds 40
        }
        if ($null -eq $script:lastStatus) { throw "Read-only GUI status failed: $($script:lastDetail)" }
        $running = @(Get-Field $script:lastStatus 'runningProcesses' @())
        if ($running.Count -gt 0 -and ($apply.Enabled -or $restore.Enabled)) { throw 'Live VR incorrectly permits changes in the real GUI status path.' }
        if (-not $refresh.Enabled -or $form.UseWaitCursor) { throw 'The completed asynchronous operation left the GUI busy.' }
        if ($SmokeTestScreenshotPath) {
            $form.Show()
            [Windows.Forms.Application]::DoEvents()
            $bitmap = New-Object Drawing.Bitmap($form.Width, $form.Height)
            try {
                $bounds = New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)
                $form.DrawToBitmap($bitmap, $bounds)
                $bitmap.Save([IO.Path]::GetFullPath($SmokeTestScreenshotPath), [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
        $result = [pscustomobject]@{
            result = 'PASS'; mode = 'Real asynchronous Status'; hostOperations = 1; mutationOperations = 0
            visibleWindowShown = $false; recordedState = (Get-ManagedState)
            shadersMatch = (Test-RecordedShaders); selectedPixelPercent = [int]$scale.Value
            storedPixelPercent = (Get-Field $script:lastStatus 'vrchatResolutionScale')
            runningProcesses = $running; applyEnabled = $apply.Enabled; restoreEnabled = $restore.Enabled
            refreshEnabled = $refresh.Enabled; statusText = $stateLabel.Text
        }
        $json = $result | ConvertTo-Json -Depth 10
        if ($SmokeTestResultPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($SmokeTestResultPath), $json, (New-Object Text.UTF8Encoding($false))) }
        Write-Output $json
    }
    finally {
        if ($null -ne $script:operation) { $script:operation.pipeline.Stop(); $script:operation.pipeline.Dispose(); $script:operation = $null }
        $timer.Stop(); $timer.Dispose(); $form.Dispose()
    }
    return
}
$form.Add_Shown({ Start-Operation 'Status' })
$timer.Start()
try { $null = $form.ShowDialog() }
finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }
