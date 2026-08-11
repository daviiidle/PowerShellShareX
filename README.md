# PowerShell ShareX

Small Windows screenshot utility written in PowerShell and WPF.

## Run

```powershell
Set-Location C:\path\to\PowerShellShareX
powershell.exe -ExecutionPolicy Bypass -File .\ShareX.ps1
```

The command remains running by design. Look for the PowerShell ShareX icon in the Windows notification area, then use the hotkeys or right-click the icon. If the process returns immediately, copy the terminal error—the script requires Windows PowerShell/WPF and cannot run on Linux.

The app opens as a normal window. Default hotkeys:

- `PageUp`: select a region
- `PageDown`: capture the active window
- `Ctrl+Shift+6`: capture the virtual full screen
- `Ctrl+Shift+7`: open history

New screenshots appear in the main window's history list. Select multiple items with Ctrl-click or Shift-click, then edit one or create a vertical or horizontal collage. You can change all four hotkeys from the window. Closing the window unregisters the hotkeys and exits the script.
