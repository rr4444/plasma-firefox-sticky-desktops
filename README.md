# Firefox Tab Group Window Manager Bridge

Synchronize Firefox Tab Groups with Linux desktop environments (KDE Plasma and GNOME Shell) across Wayland and X11.

The bridge updates window titles dynamically with active and member tab group names, provides an interactive workspace switcher inside Firefox, and persists window-to-desktop allocations into `~/.config/kwinrulesrc` without manual configuration.

## Features

- **Continuous Title Synchronization:** Automatically prefixes Firefox window titles via `browser.windows.update({ titlePreface })`:
  - Focused group: `[Work] `
  - Multiple groups in window: `[Work | Groups: Work, Research, Dev] `
  - Ungrouped tab focused: `[Ungrouped | Groups: Research, Dev] `
- **Persistent Workspace Rules:** Moving a window from the extension relocates the live window and registers a matching rule in `~/.config/kwinrulesrc` with a live D-Bus reload.
- **Multi-Group Safety:** Generated window rules match all tab groups present in that window. Placement rules persist whether a tab group is in the foreground or background.
- **Atomic Configuration Isolation:** Only creates and updates rules scoped with `tabgroup_<hash>`. Backs up `kwinrulesrc` prior to modification and preserves existing custom window rules.
- **Display Server & DE Support:** Compatible with KDE Plasma (Plasma 5 and Plasma 6 on Wayland/X11) and GNOME Shell.

## Prerequisites

- Firefox 102+
- Python 3
- dbus-send (package: `dbus` or `dbus-x11`)
- curl or wget (for fetching the extension icon)

Install dependencies on Debian/Ubuntu/KDE Neon:

```bash
sudo apt update && sudo apt install -y python3 dbus curl
```

## Installation & Setup

1. Ensure the setup script is executable:
```bash
chmod +x ~/apps/tabgroup-extension/tab-group-setup.sh
```

2. Run the deployment:
```bash
~/apps/tabgroup-extension/tab-group-setup.sh --install
```

3. Load the extension in Firefox:
   - Navigate to `about:debugging#/runtime/this-firefox` in the address bar.
   - Click **Load Temporary Add-on...**.
   - Select `~/tabgroup-extension/manifest.json`.

## Usage

1. Click the **Tab Group Workspace Bridge** icon in the Firefox toolbar.
2. The popup lists:
   - All tab groups present in the current window.
   - Their active status (`Focused` vs `Background`).
   - All available system virtual desktops/workspaces detected via D-Bus.
3. Select a target desktop and click **Move**:
   - The active window relocates to the designated desktop.
   - The allocation is written to `~/.config/kwinrulesrc` so that window placement survives reboots.

## Diagnostics

To run non-destructive integrity tests without killing processes or modifying configuration:

```bash
~/apps/tabgroup-extension/tab-group-setup.sh --test
```

The diagnostic suite audits:
- Session environment variables (`XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`).
- File paths, executable permissions, and manifest identity matching.
- Live compositor D-Bus communication (`org.kde.KWin` or `org.gnome.Shell`).
- End-to-end standard I/O IPC between the native messaging host and Python bridge.
- Current rule count and state inside `~/.config/kwinrulesrc`.

## Uninstallation

To cleanly purge all extension files, remove the native messaging host, and erase all generated rules from `~/.config/kwinrulesrc`:

```bash
~/apps/tabgroup-extension/tab-group-setup.sh --uninstall
```

After uninstalling, remove the temporary extension entry from `about:debugging` in Firefox.
