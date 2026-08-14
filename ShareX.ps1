#requires -Version 5.1
[CmdletBinding()]
param([switch]$NoTray)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath = Join-Path $Root 'sharex.log'

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    $line = "{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $line
}

Write-Log "Starting PowerShell ShareX. PowerShell $($PSVersionTable.PSVersion), OS $([Environment]::OSVersion.VersionString)"

try {
    Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Drawing, System.Windows.Forms
    Write-Log 'WPF, drawing, and WinForms assemblies loaded.'
} catch {
    Write-Log "Could not load Windows UI assemblies: $($_.Exception.Message)" 'ERROR'
    throw
}

if (-not ('ShareXWin32' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ShareXWin32 {
    [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);
    [DllImport("kernel32.dll")] public static extern uint GetLastError();
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
}

$ConfigPath = Join-Path $Root 'config.json'
$Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$script:HistoryHotkey = if ($Config.PSObject.Properties.Name -contains 'HistoryHotkey') { $Config.HistoryHotkey } else { 'Ctrl+Shift+7' }
$OutputDirectory = if ([string]::IsNullOrWhiteSpace($Config.OutputDirectory)) {
    Join-Path ([Environment]::GetFolderPath('MyPictures')) 'PowerShellShareX'
} else { [Environment]::ExpandEnvironmentVariables($Config.OutputDirectory) }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
Write-Log "Output directory: $OutputDirectory"

$script:HistoryWindow = $null
$script:HotkeyWindow = $null
$script:Hotkeys = @{}
$script:LastImage = $null
$script:HistoryList = $null

function New-ImageName {
    Join-Path $OutputDirectory ('{0:yyyy-MM-dd_HHmmss_fff}.png' -f (Get-Date))
}

function Save-Bitmap([System.Drawing.Bitmap]$Bitmap) {
    $path = New-ImageName
    $Bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    try { [System.Windows.Forms.Clipboard]::SetImage($Bitmap); Write-Log 'Screenshot copied to clipboard.' }
    catch { Write-Log "Could not copy screenshot to clipboard: $($_.Exception.Message)" 'WARN' }
    $Bitmap.Dispose()
    $script:LastImage = $path
    if ($script:HistoryList) { try { Refresh-HistoryList } catch { Write-Log "History refresh failed after saving ${path}: $($_.Exception.ToString())" 'ERROR' } }
    Write-Log "Saved screenshot: $path"
    return $path
}

function Get-VirtualScreen {
    [System.Windows.Forms.SystemInformation]::VirtualScreen
}

function Capture-Rectangle([int]$X, [int]$Y, [int]$Width, [int]$Height) {
    if ($Width -lt 1 -or $Height -lt 1) { Write-Log "Ignored empty capture rectangle ${Width}x${Height}." 'WARN'; return }
    Write-Log "Capturing rectangle X=$X Y=$Y W=$Width H=$Height"
    $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($X, $Y, 0, 0, $bitmap.Size)
    $graphics.Dispose()
    Save-Bitmap $bitmap | Out-Null
}

function Capture-FullScreen {
    $screen = Get-VirtualScreen
    Write-Log 'Full-screen capture requested.'
    Capture-Rectangle $screen.X $screen.Y $screen.Width $screen.Height | Out-Null
}

function Capture-ActiveWindow {
    $handle = [ShareXWin32]::GetForegroundWindow()
    Write-Log "Active-window capture requested. Foreground handle: $handle"
    $rect = New-Object ShareXWin32+RECT
    if ($handle -ne [IntPtr]::Zero -and [ShareXWin32]::GetWindowRect($handle, [ref]$rect)) {
        Capture-Rectangle $rect.Left $rect.Top ($rect.Right - $rect.Left) ($rect.Bottom - $rect.Top) | Out-Null
    } else { Write-Log 'Could not read the active window bounds.' 'WARN' }
}

function Select-Region {
    Write-Log 'Region capture overlay requested.'
    $screen = Get-VirtualScreen
    $frozen = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
    $frozenGraphics = [System.Drawing.Graphics]::FromImage($frozen)
    $frozenGraphics.CopyFromScreen($screen.X, $screen.Y, 0, 0, $frozen.Size)
    $frozenGraphics.Dispose()
    $frozenStream = New-Object IO.MemoryStream
    $frozen.Save($frozenStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $frozen.Dispose(); $frozenStream.Position = 0
    $frozenSource = New-Object Windows.Media.Imaging.BitmapImage
    $frozenSource.BeginInit(); $frozenSource.CacheOption = 'OnLoad'; $frozenSource.StreamSource = $frozenStream; $frozenSource.EndInit(); $frozenSource.Freeze(); $frozenStream.Dispose()
    $window = New-Object Windows.Window
    $window.WindowStyle = 'None'
    $window.ResizeMode = 'NoResize'
    $window.WindowState = 'Normal'
    $window.Left = $screen.X; $window.Top = $screen.Y
    $window.Width = $screen.Width; $window.Height = $screen.Height
    $window.Topmost = $true
    $window.ShowInTaskbar = $false
    $window.AllowsTransparency = $true
    $window.Background = New-Object Windows.Media.ImageBrush $frozenSource
    $window.Background.Stretch = 'None'; $window.Background.AlignmentX = 'Left'; $window.Background.AlignmentY = 'Top'

    $canvas = New-Object Windows.Controls.Canvas
    # Transparent backgrounds still participate in WPF hit testing; a null Canvas background does not.
    $canvas.Background = [Windows.Media.Brushes]::Transparent
    $canvas.IsHitTestVisible = $true
    $window.Content = $canvas
    $dim = New-Object Windows.Shapes.Rectangle
    $dim.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(70, 0, 0, 0)); $dim.Width = $screen.Width; $dim.Height = $screen.Height; $dim.IsHitTestVisible = $false
    $canvas.Children.Add($dim) | Out-Null
    $selection = New-Object Windows.Shapes.Rectangle
    $selection.Stroke = [Windows.Media.Brushes]::DodgerBlue
    $selection.StrokeThickness = 2
    $selection.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(45, 30, 144, 255))
    $canvas.Children.Add($selection) | Out-Null
    $state = @{ Start = $null; Result = $null }

    $canvas.Add_MouseLeftButtonDown({
        $state.Start = $args[1].GetPosition($canvas)
        Write-Log "Region mouse-down at X=$($state.Start.X) Y=$($state.Start.Y)"
        $canvas.CaptureMouse() | Out-Null
    })
    $canvas.Add_MouseMove({
        if ($null -eq $state.Start -or -not $canvas.IsMouseCaptured) { return }
        $point = $args[1].GetPosition($canvas)
        $left = [Math]::Min($state.Start.X, $point.X); $top = [Math]::Min($state.Start.Y, $point.Y)
        $selection.Width = [Math]::Abs($point.X - $state.Start.X); $selection.Height = [Math]::Abs($point.Y - $state.Start.Y)
        [Windows.Controls.Canvas]::SetLeft($selection, $left); [Windows.Controls.Canvas]::SetTop($selection, $top)
    })
    $canvas.Add_MouseLeftButtonUp({
        if ($null -eq $state.Start) { return }
        $point = $args[1].GetPosition($canvas)
        $canvas.ReleaseMouseCapture()
        $x = [Math]::Min($state.Start.X, $point.X); $y = [Math]::Min($state.Start.Y, $point.Y)
        $state.Result = [pscustomobject]@{ X = [int]($screen.X + $x); Y = [int]($screen.Y + $y); Width = [int][Math]::Abs($point.X - $state.Start.X); Height = [int][Math]::Abs($point.Y - $state.Start.Y) }
        Write-Log "Region mouse-up at X=$($point.X) Y=$($point.Y)"
        $window.Close()
    })
    $window.Add_KeyDown({ if ($args[1].Key -eq 'Escape') { $window.Close() } })
    $window.ShowDialog() | Out-Null
    if ($state.Result) { Write-Log "Region selected: $($state.Result.Width)x$($state.Result.Height)"; Capture-Rectangle $state.Result.X $state.Result.Y $state.Result.Width $state.Result.Height } else { Write-Log 'Region capture cancelled.' }
}

function New-ImageSource([string]$Path) {
    $source = New-Object Windows.Media.Imaging.BitmapImage
    $source.BeginInit(); $source.CacheOption = 'OnLoad'; $source.UriSource = [Uri]$Path; $source.EndInit(); $source.Freeze()
    $source
}

function Get-HistoryFiles {
    Get-ChildItem $OutputDirectory -Filter '*.png' -File | Sort-Object LastWriteTime -Descending | Select-Object -First ([int]$Config.HistoryLimit)
}

function Enable-FileDrag($Item) {
    $state = @{ Start = $null }
    $Item.Add_PreviewMouseLeftButtonDown(({
        $state.Start = $args[1].GetPosition($Item)
        if ($Item.IsSelected) { $args[1].Handled = $true }
    }).GetNewClosure())
    $Item.Add_PreviewMouseMove(({
        if ($null -eq $state.Start -or $args[1].LeftButton -ne [Windows.Input.MouseButtonState]::Pressed) { return }
        $point = $args[1].GetPosition($Item); if ([Math]::Abs($point.X - $state.Start.X) -lt 6 -and [Math]::Abs($point.Y - $state.Start.Y) -lt 6) { return }
        $fileList = New-Object System.Collections.Specialized.StringCollection; $fileList.Add([string]$Item.Tag) | Out-Null
        $data = New-Object Windows.DataObject; $data.SetFileDropList($fileList)
        [Windows.DragDrop]::DoDragDrop($Item, $data, ([Windows.DragDropEffects]::Copy -bor [Windows.DragDropEffects]::Link)) | Out-Null; $state.Start = $null
    }).GetNewClosure())
}

function Open-Screenshot([string]$Path) {
    if ($Path) { Start-Process -FilePath $Path }
}

function Open-ScreenshotLocation([string]$Path) {
    if (-not $Path) { return }
    Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
}

function Refresh-HistoryList {
    if (-not $script:HistoryList) { return }
    $selected = @($script:HistoryList.SelectedItems | ForEach-Object { $_.Tag })
    $script:HistoryList.Items.Clear()
    foreach ($file in (Get-HistoryFiles)) {
        $item = New-Object Windows.Controls.ListBoxItem; $item.Tag = $file.FullName; $item.Width = 172; $item.Height = 126; $item.Padding = '4'; $item.HorizontalContentAlignment = 'Center'
        $card = New-Object Windows.Controls.StackPanel
        $thumbnail = New-Object Windows.Controls.Image; $thumbnail.Source = New-ImageSource $file.FullName; $thumbnail.Width = 158; $thumbnail.Height = 92; $thumbnail.Stretch = 'Uniform'
        $name = New-Object Windows.Controls.TextBlock; $name.Text = $file.Name; $name.Width = 158; $name.TextAlignment = 'Center'; $name.TextTrimming = 'CharacterEllipsis'
        $card.Children.Add($thumbnail) | Out-Null; $card.Children.Add($name) | Out-Null; $item.Content = $card; Enable-FileDrag $item; $script:HistoryList.Items.Add($item) | Out-Null
        if ($selected -contains $file.FullName) { $item.IsSelected = $true }
    }
}

function Show-Prompt([string]$Title, [string]$Default = '', [Windows.Window]$Owner = $null) {
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title; $dialog.Width = 360; $dialog.Height = 130; $dialog.ResizeMode = 'NoResize'
    if ($Owner) { $dialog.Owner = $Owner; $dialog.WindowStartupLocation = 'Manual'; $dialog.Left = $Owner.Left + 20; $dialog.Top = $Owner.Top + 60 } else { $dialog.WindowStartupLocation = 'CenterScreen' }
    $panel = New-Object Windows.Controls.StackPanel; $panel.Margin = '12'
    $input = New-Object Windows.Controls.TextBox; $input.Text = $Default; $input.Margin = '0,0,0,10'
    $ok = New-Object Windows.Controls.Button; $ok.Content = 'OK'; $ok.Width = 70; $ok.HorizontalAlignment = 'Right'; $ok.IsDefault = $true
    $ok.Add_Click({ $dialog.DialogResult = $true; $dialog.Close() })
    $panel.Children.Add($input) | Out-Null; $panel.Children.Add($ok) | Out-Null; $dialog.Content = $panel
    if ($dialog.ShowDialog()) { return $input.Text }
}

function Save-EditedImage($Grid, $ImageWidth, $ImageHeight) {
    $hiddenHandles = @()
    foreach ($child in $Grid.Children) { if ($child -is [Windows.Controls.Canvas]) { foreach ($overlayChild in $child.Children) { if ($overlayChild -is [Windows.Controls.Primitives.Thumb]) { $overlayChild.Visibility = 'Hidden'; $hiddenHandles += $overlayChild } } } }
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap $ImageWidth, $ImageHeight, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
    $Grid.Measure((New-Object Windows.Size $ImageWidth, $ImageHeight)); $Grid.Arrange((New-Object Windows.Rect 0, 0, $ImageWidth, $ImageHeight)); $bitmap.Render($Grid)
    foreach ($handle in $hiddenHandles) { $handle.Visibility = 'Visible' }
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder; $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path = New-ImageName; $stream = [IO.File]::OpenWrite($path); $encoder.Save($stream); $stream.Dispose(); $script:LastImage = $path; $path
}

function Update-ResizeHandle($Element, $Handle) {
    $left = [Windows.Controls.Canvas]::GetLeft($Element); $top = [Windows.Controls.Canvas]::GetTop($Element)
    if ([double]::IsNaN($left)) { $left = 0 }; if ([double]::IsNaN($top)) { $top = 0 }
    $width = if ($Element -is [Windows.Shapes.Rectangle]) { $Element.Width } else { $Element.ActualWidth }
    $height = if ($Element -is [Windows.Shapes.Rectangle]) { $Element.Height } else { $Element.ActualHeight }
    if ($width -le 0) { $width = $Element.DesiredSize.Width }; if ($height -le 0) { $height = $Element.DesiredSize.Height }
    [Windows.Controls.Canvas]::SetLeft($Handle, $left + $width - 8); [Windows.Controls.Canvas]::SetTop($Handle, $top + $height - 8)
}
Set-Item Function:\global:Update-ResizeHandle -Value ${function:Update-ResizeHandle}

function Enable-OverlayResize($Element, $Canvas) {
    $handle = New-Object Windows.Controls.Primitives.Thumb; $handle.Width = 10; $handle.Height = 10; $handle.Background = [Windows.Media.Brushes]::DodgerBlue; $handle.Cursor = [Windows.Input.Cursors]::SizeNWSE; $Canvas.Children.Add($handle) | Out-Null
    $Element.Tag = $handle
    $resize = @{ Active = $false; StartX = 0; StartY = 0; Width = 0; Height = 0; FontSize = 0 }
    $handle.Add_DragStarted(({
        $Canvas.Tag.Selected = $Element; $resize.Active = $true; $resize.Width = $Element.Width; $resize.Height = $Element.Height; $resize.FontSize = $Element.FontSize
    }).GetNewClosure())
    $handle.Add_DragDelta(({
        if (-not $resize.Active) { return }; $dx = $args[1].HorizontalChange; $dy = $args[1].VerticalChange
        if ($Element -is [Windows.Shapes.Rectangle]) { $Element.Width = [Math]::Max(10, $Element.Width + $dx); $Element.Height = [Math]::Max(10, $Element.Height + $dy) } else { $Element.FontSize = [Math]::Max(8, $resize.FontSize + (($args[1].CumulativeHorizontalChange + $args[1].CumulativeVerticalChange) / 4)) }
        Update-ResizeHandle $Element $handle
    }).GetNewClosure())
    $handle.Add_DragCompleted(({
        if ($resize.Active) { $resize.Active = $false }
    }).GetNewClosure())
    Update-ResizeHandle $Element $handle
}

function Enable-OverlayDrag($Element, $Canvas) {
    $drag = @{ Active = $false; OffsetX = 0; OffsetY = 0 }
    $Element.Add_MouseLeftButtonDown(({
        $point = $args[1].GetPosition($Canvas)
        $Canvas.Tag.Selected = $Element
        $left = [Windows.Controls.Canvas]::GetLeft($Element); $top = [Windows.Controls.Canvas]::GetTop($Element)
        if ([double]::IsNaN($left)) { $left = 0 }; if ([double]::IsNaN($top)) { $top = 0 }
        $drag.OffsetX = $point.X - $left; $drag.OffsetY = $point.Y - $top; $drag.Active = $true
        $Element.CaptureMouse() | Out-Null; $args[1].Handled = $true
    }).GetNewClosure())
    $Element.Add_MouseMove(({
        if (-not $drag.Active) { return }
        $point = $args[1].GetPosition($Canvas); [Windows.Controls.Canvas]::SetLeft($Element, $point.X - $drag.OffsetX); [Windows.Controls.Canvas]::SetTop($Element, $point.Y - $drag.OffsetY); if ($Element.Tag) { Update-ResizeHandle $Element $Element.Tag }
    }).GetNewClosure())
    $Element.Add_MouseLeftButtonUp(({
        if ($drag.Active) { $Element.ReleaseMouseCapture(); $drag.Active = $false; $args[1].Handled = $true }
    }).GetNewClosure())
}

function Edit-Image([string]$Path) {
    $source = New-ImageSource $Path
    $window = New-Object Windows.Window; $window.Title = "Edit - $(Split-Path $Path -Leaf)"; $window.WindowStartupLocation = 'CenterScreen'; $window.Width = 1000; $window.Height = 800
    $outer = New-Object Windows.Controls.DockPanel
    $toolbar = New-Object Windows.Controls.StackPanel; $toolbar.Orientation = 'Horizontal'; $toolbar.Margin = '6'; [Windows.Controls.DockPanel]::SetDock($toolbar, 'Top')
    $highlight = New-Object Windows.Controls.Button; $highlight.Content = 'Highlight'; $highlight.Margin = '2'
    $text = New-Object Windows.Controls.Button; $text.Content = 'Text'; $text.Margin = '2'
    $undo = New-Object Windows.Controls.Button; $undo.Content = 'Undo'; $undo.Margin = '2'
    $save = New-Object Windows.Controls.Button; $save.Content = 'Save copy'; $save.Margin = '2'
    $done = New-Object Windows.Controls.Button; $done.Content = 'Done'; $done.Margin = '2'
    @($highlight, $text, $undo, $save, $done) | ForEach-Object { $toolbar.Children.Add($_) | Out-Null }
    $outer.Children.Add($toolbar) | Out-Null
    $grid = New-Object Windows.Controls.Grid; $grid.Width = $source.PixelWidth; $grid.Height = $source.PixelHeight; $image = New-Object Windows.Controls.Image; $image.Source = $source; $image.Stretch = 'None'; $grid.Children.Add($image) | Out-Null
    $overlay = New-Object Windows.Controls.Canvas; $overlay.Background = [Windows.Media.Brushes]::Transparent; $overlay.IsHitTestVisible = $true; $grid.Children.Add($overlay) | Out-Null
    $viewer = New-Object Windows.Controls.ScrollViewer; $viewer.HorizontalScrollBarVisibility = 'Auto'; $viewer.VerticalScrollBarVisibility = 'Auto'; $viewer.PanningMode = 'None'; $viewer.Content = $grid; $outer.Children.Add($viewer) | Out-Null; $window.Content = $outer
    $state = @{ Mode = 'highlight'; DragStart = $null; Draft = $null; PanStart = $null; PanX = 0; PanY = 0; Selected = $null }; $overlay.Tag = $state
    $highlight.Add_Click({ $state.Mode = 'highlight'; Write-Log 'Editor tool selected: highlight' }); $text.Add_Click({ $state.Mode = 'text'; Write-Log 'Editor tool selected: text' })
    $undo.Add_Click({ if ($overlay.Children.Count -gt 0) { $last = $overlay.Children[$overlay.Children.Count - 1]; if ($last -is [Windows.Controls.Primitives.Thumb]) { $overlay.Children.RemoveAt($overlay.Children.Count - 1) }; if ($overlay.Children.Count -gt 0) { $overlay.Children.RemoveAt($overlay.Children.Count - 1) } } })
    $save.Add_Click({ $path = Save-EditedImage $grid $source.PixelWidth $source.PixelHeight; [Windows.MessageBox]::Show("Saved: $path", 'PowerShell ShareX') | Out-Null })
    $done.Add_Click({ $path = Save-EditedImage $grid $source.PixelWidth $source.PixelHeight; Refresh-HistoryList; Write-Log "Editor done; saved edited copy: $path"; $window.Close() })
    $window.Add_PreviewKeyDown({ if ($args[1].Key -eq 'Delete' -and $state.Selected) { $selected = $state.Selected; if ($selected.Tag -is [Windows.Controls.Primitives.Thumb]) { $overlay.Children.Remove($selected.Tag) | Out-Null }; $overlay.Children.Remove($selected) | Out-Null; $state.Selected = $null; $args[1].Handled = $true; Write-Log 'Editor annotation deleted.' } })
    $overlay.Add_MouseDown({ if ($args[1].ChangedButton -eq 'Middle') { $state.PanStart = $args[1].GetPosition($viewer); $state.PanX = $viewer.HorizontalOffset; $state.PanY = $viewer.VerticalOffset; $overlay.CaptureMouse() | Out-Null; $args[1].Handled = $true; Write-Log 'Editor pan started.' } })
    $overlay.Add_MouseMove({ if ($null -ne $state.PanStart) { $point = $args[1].GetPosition($viewer); $viewer.ScrollToHorizontalOffset($state.PanX - ($point.X - $state.PanStart.X)); $viewer.ScrollToVerticalOffset($state.PanY - ($point.Y - $state.PanStart.Y)); $args[1].Handled = $true } })
    $overlay.Add_MouseUp({ if ($args[1].ChangedButton -eq 'Middle' -and $null -ne $state.PanStart) { $overlay.ReleaseMouseCapture(); $state.PanStart = $null; $args[1].Handled = $true; Write-Log 'Editor pan finished.' } })
    $overlay.Add_MouseLeftButtonDown({
        $point = $args[1].GetPosition($overlay)
        Write-Log "Editor click at X=$($point.X) Y=$($point.Y), mode=$($state.Mode)"
        if ($state.Mode -eq 'text') { $value = Show-Prompt 'Text' '' $window; if ($value) { $label = New-Object Windows.Controls.TextBlock; $label.Text = $value; $label.FontSize = 24; $label.FontWeight = 'Bold'; $label.Foreground = [Windows.Media.Brushes]::Red; $label.Background = [Windows.Media.Brushes]::Transparent; [Windows.Controls.Canvas]::SetLeft($label, $point.X); [Windows.Controls.Canvas]::SetTop($label, $point.Y); $overlay.Children.Add($label) | Out-Null; Enable-OverlayDrag $label $overlay; Enable-OverlayResize $label $overlay; Write-Log 'Editor text added.' }; return }
        $state.DragStart = $point; $state.Draft = New-Object Windows.Shapes.Rectangle; $state.Draft.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb(90, 255, 235, 0)); $overlay.Children.Add($state.Draft) | Out-Null; Enable-OverlayDrag $state.Draft $overlay; Enable-OverlayResize $state.Draft $overlay; $overlay.CaptureMouse() | Out-Null
    })
    $overlay.Add_MouseMove({ if ($null -eq $state.DragStart) { return }; $point = $args[1].GetPosition($overlay); [Windows.Controls.Canvas]::SetLeft($state.Draft, [Math]::Min($state.DragStart.X, $point.X)); [Windows.Controls.Canvas]::SetTop($state.Draft, [Math]::Min($state.DragStart.Y, $point.Y)); $state.Draft.Width = [Math]::Abs($point.X - $state.DragStart.X); $state.Draft.Height = [Math]::Abs($point.Y - $state.DragStart.Y); if ($state.Draft.Tag) { Update-ResizeHandle $state.Draft $state.Draft.Tag } })
    $overlay.Add_MouseLeftButtonUp({ if ($state.DragStart) { $overlay.ReleaseMouseCapture(); $state.DragStart = $null; $state.Draft = $null } })
    $window.ShowDialog() | Out-Null
}

function Build-Collage([string[]]$Paths, [bool]$Vertical) {
    $selected = @($Paths | ForEach-Object { [System.Drawing.Image]::FromFile($_) })
    if ($selected.Count -lt 2) { return }
    $gap = 8
    $widthRaw = if ($Vertical) { ($selected | Measure-Object Width -Maximum).Maximum } else { ($selected | Measure-Object Width -Sum).Sum + ($gap * ($selected.Count - 1)) }
    $heightRaw = if ($Vertical) { ($selected | Measure-Object Height -Sum).Sum + ($gap * ($selected.Count - 1)) } else { ($selected | Measure-Object Height -Maximum).Maximum }
    $width = [int][Math]::Ceiling([double]$widthRaw); $height = [int][Math]::Ceiling([double]$heightRaw)
    Write-Log "Building collage: $($selected.Count) images, ${width}x${height}, vertical=$Vertical"
    if ($width -lt 1 -or $height -lt 1) { $selected | ForEach-Object { $_.Dispose() }; throw "Invalid collage dimensions: ${width}x${height}" }
    $out = New-Object -TypeName System.Drawing.Bitmap -ArgumentList @($width, $height); $g = [Drawing.Graphics]::FromImage($out); $g.Clear([Drawing.Color]::White); $offset = 0
    foreach ($img in $selected) { $x = if ($Vertical) { ($width - $img.Width) / 2 } else { $offset }; $y = if ($Vertical) { $offset } else { ($height - $img.Height) / 2 }; $g.DrawImage($img, $x, $y); $offset += if ($Vertical) { $img.Height + $gap } else { $img.Width + $gap }; $img.Dispose() }
    $g.Dispose(); $path = Save-Bitmap $out; [Windows.MessageBox]::Show("Saved: $path", 'PowerShell ShareX') | Out-Null
}

function New-Collage {
    $files = @(Get-HistoryFiles)
    if ($files.Count -lt 2) { [Windows.MessageBox]::Show('Take at least two screenshots first.') | Out-Null; return }
    $dialog = New-Object Windows.Window; $dialog.Title = 'Create collage'; $dialog.Width = 420; $dialog.Height = 500; $dialog.WindowStartupLocation = 'CenterScreen'
    $panel = New-Object Windows.Controls.DockPanel; $list = New-Object Windows.Controls.ListBox; $list.SelectionMode = 'Extended'
    foreach ($file in $files) { $item = New-Object Windows.Controls.ListBoxItem; $item.Content = $file.Name; $item.Tag = $file.FullName; $list.Items.Add($item) | Out-Null }
    $buttons = New-Object Windows.Controls.StackPanel; $buttons.Orientation = 'Horizontal'; $buttons.Margin = '6'; [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')
    $vertical = New-Object Windows.Controls.Button; $vertical.Content = 'Vertical'; $vertical.Margin = '2'; $horizontal = New-Object Windows.Controls.Button; $horizontal.Content = 'Horizontal'; $horizontal.Margin = '2'
    $buttons.Children.Add($vertical) | Out-Null; $buttons.Children.Add($horizontal) | Out-Null; $panel.Children.Add($buttons) | Out-Null; $panel.Children.Add($list) | Out-Null; $dialog.Content = $panel
    $build = { param($verticalLayout); $paths = @($list.SelectedItems | ForEach-Object { $_.Tag }); if ($paths.Count -lt 2) { return }; $dialog.Close(); Build-Collage $paths $verticalLayout }
    $vertical.Add_Click({ & $build $true }); $horizontal.Add_Click({ & $build $false }); $dialog.ShowDialog() | Out-Null
}

function Show-History {
    if ($script:HistoryWindow -and $script:HistoryWindow.IsVisible) { $script:HistoryWindow.Activate(); return }
    $window = New-Object Windows.Window; $window.Title = 'PowerShell ShareX - History'; $window.Width = 760; $window.Height = 560; $window.WindowStartupLocation = 'CenterScreen'
    $dock = New-Object Windows.Controls.DockPanel; $buttons = New-Object Windows.Controls.StackPanel; $buttons.Orientation = 'Horizontal'; $buttons.Margin = '6'; [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')
    $edit = New-Object Windows.Controls.Button; $edit.Content = 'Edit selected'; $edit.Margin = '2'; $collage = New-Object Windows.Controls.Button; $collage.Content = 'Collage'; $collage.Margin = '2'; $refresh = New-Object Windows.Controls.Button; $refresh.Content = 'Refresh'; $refresh.Margin = '2'; @($edit,$collage,$refresh) | ForEach-Object { $buttons.Children.Add($_) | Out-Null }
    $list = New-Object Windows.Controls.ListBox; $list.SelectionMode = 'Single'; [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom'); $dock.Children.Add($buttons) | Out-Null; $dock.Children.Add($list) | Out-Null; $window.Content = $dock
    $load = { $list.Items.Clear(); foreach ($file in (Get-HistoryFiles)) { $item = New-Object Windows.Controls.ListBoxItem; $item.Content = $file.Name; $item.Tag = $file.FullName; $list.Items.Add($item) | Out-Null } }; & $load
    $refresh.Add_Click({ & $load }); $edit.Add_Click({ if ($list.SelectedItem) { Edit-Image $list.SelectedItem.Tag } }); $collage.Add_Click({ New-Collage }); $list.Add_MouseDoubleClick({ if ($list.SelectedItem) { Open-Screenshot $list.SelectedItem.Tag } }); $window.Add_Closed({ $script:HistoryWindow = $null }); $script:HistoryWindow = $window; $window.Show()
}

function Parse-Hotkey([string]$Value) {
    $mod = 0; $key = $null
    foreach ($part in $Value -split '\+') { $name = $part.Trim().ToUpperInvariant(); switch -Regex ($name) { 'CTRL|CONTROL' { $mod = $mod -bor 2 }; 'ALT' { $mod = $mod -bor 1 }; 'SHIFT' { $mod = $mod -bor 4 }; 'WIN|WINDOWS' { $mod = $mod -bor 8 }; default { if ($name -match '^\d$') { $name = "D$name" }; $key = [byte][System.Windows.Forms.Keys]::$name } } }
    if ($null -eq $key) { throw "Invalid hotkey: $Value" }; @($mod, $key)
}

function Start-Hotkeys {
    $window = New-Object Windows.Window; $window.Width = 1; $window.Height = 1; $window.ShowInTaskbar = $false; $window.WindowStyle = 'None'; $window.Opacity = 0
    $window.Add_SourceInitialized({
        $source = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        $hook = [Windows.Interop.HwndSource]::FromHwnd($source)
        Write-Log "Hotkey message window created: $source"
        $hook.AddHook({ param($hwnd,$msg,$wParam,$lParam,[ref]$handled); if ($msg -ne 0x0312) { return [IntPtr]::Zero }; try { Write-Log "Hotkey received: $([int]$wParam)"; switch ([int]$wParam) { 1 { Select-Region | Out-Null }; 2 { Capture-ActiveWindow | Out-Null }; 3 { Capture-FullScreen | Out-Null }; 4 { Show-History | Out-Null } }; $null = ($handled.Value = $true) } catch { Write-Log "Hotkey action failed: $($_.Exception.ToString())" 'ERROR'; [Windows.MessageBox]::Show($_.Exception.ToString(), 'PowerShell ShareX error') | Out-Null }; return [IntPtr]::Zero })
        $definitions = @(@(1,$Config.CaptureRegionHotkey), @(2,$Config.CaptureWindowHotkey), @(3,$Config.CaptureScreenHotkey), @(4,$script:HistoryHotkey))
        foreach ($definition in $definitions) { $parsed = Parse-Hotkey $definition[1]; $registered = [ShareXWin32]::RegisterHotKey($source, $definition[0], $parsed[0] -bor 0x4000, $parsed[1]); if (-not $registered) { Write-Log "Could not register hotkey $($definition[1]); Win32 error $([ShareXWin32]::GetLastError()). Another ShareX instance or application may own it." 'WARN' } else { $script:Hotkeys[$definition[0]] = $source; Write-Log "Registered hotkey $($definition[1]) as ID $($definition[0])" } }
    })
    $window.Add_Closed({ foreach ($id in $script:Hotkeys.Keys) { [ShareXWin32]::UnregisterHotKey($script:Hotkeys[$id], $id) | Out-Null } })
    $window.Show(); $script:HotkeyWindow = $window
}

function Stop-Hotkeys {
    if ($script:HotkeyWindow) {
        $script:HotkeyWindow.Close()
        $script:HotkeyWindow = $null
        $script:Hotkeys.Clear()
        Write-Log 'Global hotkeys unregistered.'
    }
}
function Show-MainWindow {
    $window = New-Object Windows.Window
    $window.Title = 'PowerShell ShareX'; $window.Width = 760; $window.Height = 700; $window.MinWidth = 620; $window.MinHeight = 520
    $window.WindowStartupLocation = 'CenterScreen'
    $root = New-Object Windows.Controls.StackPanel; $root.Margin = '18'
    $title = New-Object Windows.Controls.TextBlock; $title.Text = 'PowerShell ShareX'; $title.FontSize = 26; $title.FontWeight = 'Bold'; $title.Margin = '0,0,0,4'
    $subtitle = New-Object Windows.Controls.TextBlock; $subtitle.Text = 'Capture, annotate, and combine screenshots'; $subtitle.Foreground = [Windows.Media.Brushes]::Gray; $subtitle.Margin = '0,0,0,18'
    $root.Children.Add($title) | Out-Null; $root.Children.Add($subtitle) | Out-Null

    $captureGrid = New-Object Windows.Controls.Grid
    3..5 | ForEach-Object { $captureGrid.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)) }
    $captureButtons = @(
        @('Capture region', { Select-Region }),
        @('Active window', { Capture-ActiveWindow }),
        @('Full screen', { Capture-FullScreen })
    )
    for ($i = 0; $i -lt $captureButtons.Count; $i++) { $button = New-Object Windows.Controls.Button; $button.Content = $captureButtons[$i][0]; $button.Margin = '3'; [Windows.Controls.Grid]::SetColumn($button, $i); $button.Add_Click($captureButtons[$i][1]); $captureGrid.Children.Add($button) | Out-Null }
    $root.Children.Add($captureGrid) | Out-Null

    $actions = New-Object Windows.Controls.StackPanel; $actions.Orientation = 'Horizontal'; $actions.Margin = '0,12,0,6'
    foreach ($entry in @(@('Open history', { Show-History }), @('Edit selected', { if ($historyList.SelectedItem) { Edit-Image $historyList.SelectedItem.Tag } }), @('Collage vertical', { $paths = @($historyList.SelectedItems | ForEach-Object { $_.Tag }); if ($paths.Count -ge 2) { Build-Collage $paths $true } else { [Windows.MessageBox]::Show('Select at least two screenshots.') | Out-Null } }), @('Collage horizontal', { $paths = @($historyList.SelectedItems | ForEach-Object { $_.Tag }); if ($paths.Count -ge 2) { Build-Collage $paths $false } else { [Windows.MessageBox]::Show('Select at least two screenshots.') | Out-Null } }), @('Open location', { if ($historyList.SelectedItem) { Open-ScreenshotLocation $historyList.SelectedItem.Tag } else { [Windows.MessageBox]::Show('Select a screenshot first.') | Out-Null } }))) { $button = New-Object Windows.Controls.Button; $button.Content = $entry[0]; $button.Margin = '3'; $button.Add_Click($entry[1]); $actions.Children.Add($button) | Out-Null }
    $root.Children.Add($actions) | Out-Null

    $historyTitle = New-Object Windows.Controls.TextBlock; $historyTitle.Text = 'Screenshot history'; $historyTitle.FontSize = 16; $historyTitle.FontWeight = 'Bold'; $historyTitle.Margin = '0,6,0,6'; $root.Children.Add($historyTitle) | Out-Null
    $historyList = New-Object Windows.Controls.ListBox; $historyList.Height = 320; $historyList.SelectionMode = 'Extended'; [Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($historyList, [Windows.Controls.ScrollBarVisibility]::Disabled); $itemsPanel = New-Object Windows.Controls.ItemsPanelTemplate; $wrapFactory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel]); $wrapFactory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal); $itemsPanel.VisualTree = $wrapFactory; $historyList.ItemsPanel = $itemsPanel; $historyList.Add_MouseDoubleClick({ if ($historyList.SelectedItem) { Open-Screenshot $historyList.SelectedItem.Tag } }); $script:HistoryList = $historyList; Refresh-HistoryList; $root.Children.Add($historyList) | Out-Null

    $settingsTitle = New-Object Windows.Controls.TextBlock; $settingsTitle.Text = 'Global hotkeys'; $settingsTitle.FontSize = 16; $settingsTitle.FontWeight = 'Bold'; $settingsTitle.Margin = '0,4,0,6'; $root.Children.Add($settingsTitle) | Out-Null
    $settings = New-Object Windows.Controls.Grid
    0..2 | ForEach-Object { $settings.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition)) }
    0..3 | ForEach-Object { $settings.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition)) }
    $labels = @('Region', 'Active window', 'Full screen', 'History')
    $values = @($Config.CaptureRegionHotkey, $Config.CaptureWindowHotkey, $Config.CaptureScreenHotkey, $script:HistoryHotkey)
    $inputs = @()
    for ($i = 0; $i -lt $labels.Count; $i++) { $label = New-Object Windows.Controls.TextBlock; $label.Text = "$($labels[$i]):"; $label.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetRow($label, $i); $settings.Children.Add($label) | Out-Null; $input = New-Object Windows.Controls.TextBox; $input.Text = $values[$i]; $input.Margin = '3'; [Windows.Controls.Grid]::SetRow($input, $i); [Windows.Controls.Grid]::SetColumn($input, 1); $settings.Children.Add($input) | Out-Null; $inputs += $input }
    $apply = New-Object Windows.Controls.Button; $apply.Content = 'Apply hotkeys'; $apply.Margin = '3'; $apply.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetRow($apply, 3); [Windows.Controls.Grid]::SetColumn($apply, 2); $settings.Children.Add($apply) | Out-Null
    $apply.Add_Click({ try { $Config.CaptureRegionHotkey = $inputs[0].Text; $Config.CaptureWindowHotkey = $inputs[1].Text; $Config.CaptureScreenHotkey = $inputs[2].Text; $script:HistoryHotkey = $inputs[3].Text; $configObject = [ordered]@{ CaptureRegionHotkey = $Config.CaptureRegionHotkey; CaptureWindowHotkey = $Config.CaptureWindowHotkey; CaptureScreenHotkey = $Config.CaptureScreenHotkey; HistoryHotkey = $script:HistoryHotkey; OutputDirectory = $Config.OutputDirectory; HistoryLimit = $Config.HistoryLimit }; $configObject | ConvertTo-Json | Set-Content $ConfigPath; Stop-Hotkeys; Start-Hotkeys; [Windows.MessageBox]::Show('Hotkeys applied.', 'PowerShell ShareX') | Out-Null } catch { Write-Log "Could not apply hotkeys: $($_.Exception.Message)" 'ERROR'; [Windows.MessageBox]::Show($_.Exception.Message, 'PowerShell ShareX error') | Out-Null } })
    $root.Children.Add($settings) | Out-Null
    $close = New-Object Windows.Controls.Button; $close.Content = 'Exit'; $close.Width = 80; $close.HorizontalAlignment = 'Right'; $close.Margin = '3,18,3,0'; $close.Add_Click({ $window.Close() }); $root.Children.Add($close) | Out-Null
    $window.Content = $root
    $window.Add_Closed({ Stop-Hotkeys; Write-Log 'Main window closed. Exiting.' })
    $window.ShowDialog() | Out-Null
}

Start-Hotkeys
Write-Log 'Main window starting.'
Show-MainWindow
