# Plasma Firefox Sticky Desktops

[![GitHub](https://img.shields.io/badge/GitHub-rr4444%2Fplasma--firefox--sticky--desktops-blue?logo=github)](https://github.com/rr4444/plasma-firefox-sticky-desktops)

Bridge Firefox Tab Groups with desktop window managers (KDE Plasma and GNOME Shell) across Wayland and X11.

The bridge exposes internal Firefox tab group states to the display server by prefixing window titles, provides an interactive workspace switcher inside Firefox, and automatically registers persistent window-to-desktop rules in `~/.config/kwinrulesrc` without requiring manual configuration.

---

## Architectural Overview

On Wayland, security isolation prevents Firefox from obtaining native compositor window handles (`wl_surface`) or querying other windows. 

This project bridges that gap via a three-tier architecture:
1. **WebExtension Background Service:** Watches active tabs and tab groups via `browser.tabGroups`. Injects a structured `titlePreface` on each window:
   - Single group in focus: `[Work] `
   - Multiple groups in window: `[Work | Groups: Work, Dev, Research] `
   - Non-grouped tab active: `[Ungrouped | Groups: Dev, Research] `
2. **Native Messaging Host (`helper.py`):** Communicates with the browser over standard I/O and translates workspace queries/allocations into session D-Bus calls.
3. **Window Manager Integration:**
   - **KDE Plasma:** Matches window titles using regex and writes persistent rules directly to `~/.config/kwinrulesrc` before executing a live reload via `org.kde.KWin.reconfigure`.
   - **GNOME Shell:** Evaluates live workspace assignments dynamically via `org.gnome.Shell.Eval`.

---

## Features

- **Continuous Multi-Group Tracking:** Window rules match against all tab groups belonging to that window, ensuring placement rules remain active even when background or ungrouped tabs have focus.
- **Atomic KWin Configuration:** Custom rules are strictly scoped to `[tabgroup_<hash>]` sections. Backups (`kwinrulesrc.bak_tabgroup`) are taken automatically before writes, and non-tabgroup rules are preserved intact.
- **Zero Daemon Overhead:** No persistent daemon runs in the background. KWin evaluates rules natively, and `helper.py` executes only when invoked by the extension popup.
- **KDE Plasma 5 & 6 Ready:** Auto-detects virtual desktop interfaces across both Plasma 5 and Plasma 6 VirtualDesktopManager architectures.

---

## Prerequisites

- Firefox 102+
- Python 3
- `dbus-send` (package: `dbus` or `dbus-x11`)
- `curl` or `wget`

Install dependencies on Debian / Ubuntu / KDE Neon:

```bash
sudo apt update && sudo apt install -y python3 dbus curl
```

---

## Installation & Deployment

1. Make the setup script executable:
```bash
chmod +x ~/apps/tabgroup-extension/tab-group-setup.sh
```

2. Deploy the native messaging host and unpacked extension:
```bash
~/apps/tabgroup-extension/tab-group-setup.sh --install
```

3. Load the extension in Firefox:
   - Open Firefox and navigate to `about:debugging#/runtime/this-firefox`.
   - Click **Load Temporary Add-on...**.
   - Select `~/tabgroup-extension/manifest.json`.

> **Note on Add-on Persistence:** Temporary add-ons loaded through `about:debugging` unload when Firefox is fully closed. For permanent installation across reboots, run Firefox Developer Edition / Nightly (with `xpinstall.signatures.required` set to `false` in `about:config`) or package the extension using `web-ext` for local self-signing.

---

## Usage

1. Open the **Tab Group Workspace Bridge** popup from the Firefox toolbar.
2. The popup displays:
   - All tab groups located in the active window and their focus state.
   - All system virtual desktops detected over D-Bus.
3. Select a target desktop and click **Move**:
   - The window moves immediately to the target workspace.
   - Under KDE Plasma, an entry is written into `~/.config/kwinrulesrc` ensuring the window returns to this desktop upon reopening.

---

## Diagnostics & Verification

Run non-destructive integrity and D-Bus IPC checks at any time:

```bash
~/apps/tabgroup-extension/tab-group-setup.sh --test
```

The test suite validates:
- Desktop session variables (`XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`).
- File paths, permissions, and extension ID manifest pairing.
- Session bus communication with `org.kde.KWin` / `org.gnome.Shell`.
- Synthetic Native Messaging request/response loop with `helper.py`.
- Consistency of the `[General] rules` index inside `~/.config/kwinrulesrc`.

---

## Uninstallation

To purge the native helper, manifests, unpacked extension files, and strip all generated `tabgroup_*` rules from `~/.config/kwinrulesrc`:

```bash
~/apps/tabgroup-extension/tab-group-setup.sh --uninstall
```

After execution, remove the temporary add-on from `about:debugging` in Firefox.
