# Plasma Firefox Sticky Desktops

[![GitHub](https://img.shields.io/badge/GitHub-rr4444%2Fplasma--firefox--sticky--desktops-blue?logo=github)](https://github.com/rr4444/plasma-firefox-sticky-desktops)

Bridge Firefox Tab Groups with desktop window managers (KDE Plasma and GNOME Shell) across Wayland and X11.

The bridge exposes internal Firefox tab group states to the display server by prefixing window titles, provides an interactive workspace switcher inside Firefox, and automatically registers persistent window-to-desktop rules in `~/.config/kwinrulesrc` without requiring manual configuration.

---

## Architectural Overview

On Wayland, security isolation prevents Firefox from obtaining native compositor window handles (`wl_surface`) or querying other windows.

This project bridges that gap via a three-tier architecture:
1. **WebExtension Background Service:** Watches active tabs, tab groups, and window creation events via `browser.tabGroups` and `browser.windows.onCreated`. Injects a structured `titlePreface` on each window:
   - Single group in focus: `[Work] `
   - Multiple groups in window: `[Work | Groups: Work, Dev, Research] `
   - Non-grouped tab active: `[Ungrouped | Groups: Dev, Research] `
2. **Native Messaging Host (`helper.py`):** Communicates with the browser over standard I/O and translates workspace queries and allocations into session D-Bus calls.
3. **Window Manager Integration:**
   - **KDE Plasma:** Matches window titles using regex and writes persistent rules directly to `~/.config/kwinrulesrc` before executing a live reload via `org.kde.KWin.reconfigure`.
   - **GNOME Shell:** Evaluates live workspace assignments dynamically via `org.gnome.Shell.Eval`.

---

## Features

- **Full Lifecycle & State Tracking:** Tracks window creation (`browser.windows.onCreated`), tab updates, and active tab group changes so titles update immediately upon session restore or new window launch.
- **Cosmetic Desktop Naming:** Detects and displays virtual desktops using their assigned cosmetic names followed by the desktop number (e.g. `Daily [1]`, `Work [2]`), falling back cleanly if unnamed.
- **Live Desktop Detection:** Pre-selects whichever virtual desktop the active window currently occupies when opening the extension popup.
- **Continuous Multi-Group Tracking:** Window rules match against all tab groups belonging to that window, ensuring placement rules remain active even when background or ungrouped tabs have focus.
- **Atomic KWin Configuration:** Custom rules are strictly scoped to `[tabgroup_<hash>]` sections. Backups (`kwinrulesrc.bak_tabgroup`) are taken automatically before writes, and non-tabgroup rules are preserved intact.
- **Zero Daemon Overhead:** No persistent daemon runs in the background. KWin evaluates rules natively, and `helper.py` executes only when invoked by the extension popup.
- **KDE Plasma 5 & 6 Ready:** Auto-detects virtual desktop interfaces across both Plasma 5 and Plasma 6 VirtualDesktopManager architectures. Writes desktop UUIDs to `kwinrulesrc` on modern Plasma, maintains `[General] Order` and `rules` compatibility, and safely unpins sticky windows on relocation.

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

## Quick Start

### 1. Install Native Host & Extension Assets
Deploy the native messaging host and config files:
```bash
./tab-group-setup.sh --install
```

### 2. Install the Pre-Signed Extension into Firefox
A pre-signed version of the extension is included directly in this repository. To install permanently in Firefox:
```bash
firefox 8a4c8a1517cb411a83a2-1.6.xpi
```
*(Alternatively, drag and drop `8a4c8a1517cb411a83a2-1.6.xpi` into any open Firefox window).*

Click **Add** when prompted. The extension is permanently installed and survives browser restarts.

### 3. Verify System IPC
Run the non-destructive diagnostic check:
```bash
./tab-group-setup.sh --test
```

---

## Development & Custom Builds

If you modify `background.js`, `popup.js`, or the native helper, follow these steps to test or sign custom builds:

### Instant Live Testing (No Signing Needed)
1. Open Firefox and navigate to:
   ```text
   about:debugging#/runtime/this-firefox
   ```
2. Click **Load Temporary Add-on...**
3. Select `~/tabgroup-extension/manifest.json`.
4. Changes in `~/tabgroup-extension` can be reloaded instantly with the **Reload** button.

### Packaging & Signing for Permanent Release
Release builds of Firefox require add-ons to be digitally signed by Mozilla to install permanently:

1. **Package the unsigned archive:**
   ```bash
   ./tab-group-setup.sh --build
   ```
   This generates `tabgroup-bridge-unsigned-for-amo-signing.xpi` in your current working directory.

2. **Submit to Mozilla AMO:**
   - Go to the [Mozilla Add-on Developer Hub](https://addons.mozilla.org/developers/).
   - Click **Submit a New Add-on** (or **New Version** if updating).
   - Select **On your own (Self-Distribution / Unlisted)**.
   - Upload `tabgroup-bridge-unsigned-for-amo-signing.xpi`.
   - When automated review completes (typically 2–3 minutes), go to **Manage Status & Versions**, click the version, and download your signed `.xpi`.

3. **Install the new signed file:**
   ```bash
   firefox /path/to/downloaded-signed-addon.xpi
   ```

---

## Usage

1. Open the **Tab Group Workspace Bridge** popup from the Firefox toolbar.
2. The popup displays:
   - All tab groups located in the active window and their focus state (`Focused` vs `Background`).
   - All system virtual desktops with their assigned cosmetic names and numbers (e.g. `Daily [1]`, `Work [2]`), with the active window's current desktop automatically pre-selected.
3. Select a target desktop and click **Move**:
   - The window moves immediately to the target workspace (and unpins from other desktops if sticky).
   - Under KDE Plasma, an entry is written into `~/.config/kwinrulesrc` using the desktop's native UUID ensuring the window returns to this desktop upon reopening.

---

## Diagnostics & Verification

Run non-destructive integrity and D-Bus IPC checks at any time:

```bash
./tab-group-setup.sh --test
```

The test suite validates:
- Desktop session variables (`XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`).
- File paths, permissions, and extension ID manifest pairing.
- Session bus communication with `org.kde.KWin` / `org.gnome.Shell`.
- Synthetic Native Messaging request/response loop with `helper.py`.
- Consistency of the `[General] Order` and `rules` index inside `~/.config/kwinrulesrc`.

---

## Uninstallation

To purge the native helper, manifests, unpacked extension files, and strip all generated `tabgroup_*` rules from `~/.config/kwinrulesrc`:

```bash
./tab-group-setup.sh --uninstall
```

Then remove the extension from `about:addons` in Firefox.
