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

- **Bundled Signed Extension (`.xpi`):** Includes a pre-signed, permanent extension artifact ready for immediate installation in standard release Firefox.
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
- `zip`

Install dependencies on Debian / Ubuntu / KDE Neon:

```bash
sudo apt update && sudo apt install -y python3 dbus curl zip
```

---

## Quick Start (Using Included Signed XPI)

Because release Firefox requires signed add-ons for permanent installation, this repository provides a pre-signed artifact: `tabgroup-bridge.xpi`.

### 1. Install Native Host & Configuration
```bash
chmod +x ./tab-group-setup.sh
./tab-group-setup.sh --install
```

### 2. Install the Extension
Install the pre-signed add-on into Firefox:
- **Direct launch:**
  ```bash
  firefox ./tabgroup-bridge.xpi
  ```
- **Or Drag-and-Drop:** Open Firefox and drag `tabgroup-bridge.xpi` into any open window.
- Click **Add** when prompted. The extension is permanently installed and survives browser restarts.

---

## Alternative Installation Options

### Option A: System-Wide Enterprise Policy Deployment
To enforce installation across all user profiles on the machine without manual browser prompts:

```bash
sudo mkdir -p /etc/firefox/policies
sudo tee /etc/firefox/policies/policies.json << 'POLICY_EOF'
{
  "policies": {
    "ExtensionSettings": {
      "tabgroup-helper@local": {
        "installation_mode": "normal_installed",
        "install_url": "file:///path/to/tabgroup-bridge.xpi"
      }
    }
  }
}
POLICY_EOF
```

### Option B: Building and Re-Signing from Source
If you modify extension source code (`background.js`, `popup.js`, etc.), build and sign a new package:

1. Rebuild the `.xpi` package:
   ```bash
   cd ~/tabgroup-extension
   zip -r -FS ~/apps/tabgroup-extension/tabgroup-bridge.xpi manifest.json background.js popup.html popup.js icon.png
   ```

2. Sign via Mozilla Add-on Developer Hub (https://addons.mozilla.org/developers/):
   - Choose **On your own (Self-Distribution / Unlisted)**.
   - Upload `tabgroup-bridge.xpi`.
   - Download the signed `.xpi` once the automated check passes (2–5 minutes).

### Option C: Temporary Installation (Development Only)
1. Navigate to `about:debugging#/runtime/this-firefox`.
2. Click **Load Temporary Add-on...**.
3. Select `~/tabgroup-extension/manifest.json`.
*(Temporary add-ons unload when Firefox closes).* 

---

## Usage

1. Open the **Tab Group Workspace Bridge** popup from the Firefox toolbar.
2. The popup displays:
   - All tab groups located in the active window and their focus state (`Focused` vs `Background`).
   - All system virtual desktops detected over D-Bus.
3. Select a target desktop and click **Move**:
   - The window moves immediately to the target workspace.
   - Under KDE Plasma, an entry is written into `~/.config/kwinrulesrc` ensuring the window returns to this desktop upon reopening.

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
- Consistency of the `[General] rules` index inside `~/.config/kwinrulesrc`.

---

## Uninstallation

To purge the native helper, manifests, unpacked extension files, and strip all generated `tabgroup_*` rules from `~/.config/kwinrulesrc`:

```bash
./tab-group-setup.sh --uninstall
```

Then remove the extension from `about:addons` in Firefox.
