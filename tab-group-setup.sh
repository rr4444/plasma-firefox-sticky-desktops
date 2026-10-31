#!/usr/bin/env bash
# Part of rr4444/plasma-firefox-sticky-desktops
# GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops
# Setup, test harness, and uninstaller for Firefox tab group desktop synchronization

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/tabgroup-helper"
HOST_DIR="$HOME/.mozilla/native-messaging-hosts"
EXT_DIR="$HOME/tabgroup-extension"
ADDON_ID="tabgroup-helper@local"
KWINRC="$HOME/.config/kwinrulesrc"
ICON_URL="https://kde.org/stuff/clipart/logo/plasma-logo-colorful-128x128.png"

show_help() {
  cat << EOF
Firefox Tab Group Window Manager Bridge (rr4444/plasma-firefox-sticky-desktops)

Usage: $(basename "$0") [OPTION]

Options:
  -i, --install, -u, --update   Install or update helper, extension, icon, and manifests
  -t, --test, --diag            Run non-destructive diagnostic checks and IPC test
  -r, --uninstall, --remove     Safely remove tabgroup rules from kwinrulesrc and delete files
  -h, --help                    Display this help message and exit

Default:
  If run without arguments, this help message is shown and no changes are made.
EOF
}

do_install() {
  echo "==> Deploying Firefox Tab Group Integration (rr4444/plasma-firefox-sticky-desktops)..."

  mkdir -p "$INSTALL_DIR" "$HOST_DIR" "$EXT_DIR"

  # 1. Download Extension Icon
  echo "==> Fetching extension icon..."
  if command -v curl &>/dev/null; then
    curl -fsSL "$ICON_URL" -o "$EXT_DIR/icon.png" || true
  elif command -v wget &>/dev/null; then
    wget -qO "$EXT_DIR/icon.png" "$ICON_URL" || true
  fi

  # 2. Native Messaging Helper (Python + KWin / GNOME D-Bus Bridge)
  cat > "$INSTALL_DIR/helper.py" << 'PYEOF'
#!/usr/bin/env python3
# Part of rr4444/plasma-firefox-sticky-desktops
# GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops
# Native messaging helper bridging Firefox WebExtension events to KWin / GNOME D-Bus

import sys
import json
import struct
import subprocess
import os
import time
import re
import hashlib
import shutil
import configparser

DESKTOP = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
SESSION = os.environ.get('DESKTOP_SESSION', '').lower()

IS_KDE = any(k in DESKTOP or k in SESSION for k in ('kde', 'plasma'))
IS_GNOME = 'gnome' in DESKTOP or 'gnome' in SESSION
KWINRC_PATH = os.path.expanduser('~/.config/kwinrulesrc')

def log(msg):
    print(f"[tabgroup-helper] {msg}", file=sys.stderr, flush=True)

def send_message(payload):
    encoded = json.dumps(payload).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('I', len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.flush()

def read_message():
    try:
        raw_size = sys.stdin.buffer.read(4)
        if not raw_size:
            return None
        size = struct.unpack('I', raw_size)[0]
        return json.loads(sys.stdin.buffer.read(size).decode('utf-8'))
    except Exception as e:
        log(f"Read error: {e}")
        return None

def dbus_call(dest, path, interface, method, *args):
    cmd = ['dbus-send', '--print-reply', '--session', f'--dest={dest}', path, f'{interface}.{method}']
    for arg in args:
        if isinstance(arg, int):
            cmd.append(f'int32:{arg}')
        elif isinstance(arg, bool):
            cmd.append(f'boolean:{"true" if arg else "false"}')
        else:
            cmd.append(f'string:{arg}')
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return proc.returncode == 0, proc.stdout + proc.stderr
    except Exception as e:
        return False, str(e)

def get_kde_desktops():
    ok, out = dbus_call('org.kde.KWin', '/VirtualDesktopManager', 'org.freedesktop.DBus.Properties', 'Get', 'org.kde.KWin.VirtualDesktopManager', 'count')
    if ok:
        for line in out.splitlines():
            if 'uint32' in line or 'int32' in line:
                count = int(line.split()[-1])
                return [i + 1 for i in range(count)]
    ok, out = dbus_call('org.kde.KWin', '/KWin', 'org.kde.KWin', 'desktops')
    if ok:
        desktops = [line.strip().replace('"', '') for line in out.splitlines() if 'string' in line]
        if desktops:
            return desktops
    return [1]

def persist_kde_rule(groups, target_title, desktop_num):
    try:
        config = configparser.ConfigParser(interpolation=None, strict=False)
        config.optionxform = str

        if os.path.exists(KWINRC_PATH):
            shutil.copy2(KWINRC_PATH, KWINRC_PATH + '.bak_tabgroup')
            config.read(KWINRC_PATH, encoding='utf-8')

        if not config.has_section('General'):
            config.add_section('General')

        existing_rules = []
        if config.has_option('General', 'rules'):
            existing_rules = [r.strip() for r in config.get('General', 'rules').split(',') if r.strip()]

        if groups and len(groups) > 0:
            clean_groups = sorted(list(set(g.strip() for g in groups if g.strip())))
            group_hash = hashlib.md5("_".join(clean_groups).encode('utf-8')).hexdigest()[:8]
            rule_id = f"tabgroup_{group_hash}"
            desc = f"Firefox Tab Groups: {', '.join(clean_groups)}"
            escaped = [re.escape(g) for g in clean_groups]
            title_regex = r'.*\[.*(' + '|'.join(escaped) + r').*\].*'
        else:
            clean_title = (target_title or "").strip()
            title_hash = hashlib.md5(clean_title.encode('utf-8')).hexdigest()[:8]
            rule_id = f"tabgroup_win_{title_hash}"
            desc = f"Firefox Window: {clean_title[:30]}"
            title_regex = r'.*' + re.escape(clean_title) + r'.*'

        if rule_id not in existing_rules:
            existing_rules.append(rule_id)
            config.set('General', 'rules', ','.join(existing_rules))
            config.set('General', 'count', str(len(existing_rules)))

        if not config.has_section(rule_id):
            config.add_section(rule_id)

        config.set(rule_id, 'Description', desc)
        config.set(rule_id, 'wmclass', 'firefox')
        config.set(rule_id, 'wmclassmatch', '1')
        config.set(rule_id, 'title', title_regex)
        config.set(rule_id, 'titlematch', '3')
        config.set(rule_id, 'desktops', str(desktop_num))
        config.set(rule_id, 'desktopsrule', '2')

        temp_rc = f"{KWINRC_PATH}.tmp"
        with open(temp_rc, 'w', encoding='utf-8') as f:
            config.write(f, space_around_delimiters=False)
        os.replace(temp_rc, KWINRC_PATH)

        dbus_call('org.kde.KWin', '/KWin', 'org.kde.KWin', 'reconfigure')
        return True
    except Exception as e:
        log(f"Failed to persist KWin rule: {e}")
        return False

def move_window_kde(target_title, desktop_num, follow=True):
    js_code = f"""
    var targetTitle = {json.dumps(target_title or "")};
    var targetDesktop = {int(desktop_num)};
    var follow = {"true" if follow else "false"};

    var windows = (typeof workspace.windowList === "function") 
        ? workspace.windowList() 
        : workspace.clientList();

    var target = null;
    if (targetTitle) {{
        for (var i = 0; i < windows.length; i++) {{
            var w = windows[i];
            if (w.caption && (w.caption === targetTitle || w.caption.indexOf(targetTitle) !== -1 || targetTitle.indexOf(w.caption) !== -1)) {{
                target = w;
                break;
            }}
        }}
    }}
    if (!target) {{
        target = (typeof workspace.activeWindow !== "undefined") ? workspace.activeWindow : workspace.activeClient;
    }}

    if (target) {{
        if (typeof workspace.desktops !== "undefined" && workspace.desktops.length > 0) {{
            var idx = targetDesktop - 1;
            if (idx >= 0 && idx < workspace.desktops.length) {{
                target.desktops = [workspace.desktops[idx]];
                if (follow) {{
                    workspace.currentDesktop = workspace.desktops[idx];
                }}
            }}
        }} else {{
            target.desktop = targetDesktop;
            if (follow && typeof workspace.setCurrentDesktop === "function") {{
                workspace.setCurrentDesktop(targetDesktop);
            }}
        }}
    }}
    """
    script_name = f"tabgroup_move_{os.getpid()}_{int(time.time() * 1000)}"
    temp_path = f"/tmp/{script_name}.js"
    try:
        with open(temp_path, "w", encoding="utf-8") as f:
            f.write(js_code)

        ok, out = dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'loadScript', temp_path, script_name)
        if not ok or 'int32' not in out:
            ok, out = dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'loadScript', temp_path)

        script_id = None
        for line in out.splitlines():
            if 'int32' in line:
                script_id = line.strip().split()[-1]
                break

        if script_id is not None:
            script_path = f"/Scripting/Script{script_id}"
            dbus_call('org.kde.KWin', script_path, 'org.kde.kwin.Script', 'run')
            dbus_call('org.kde.KWin', script_path, 'org.kde.kwin.Script', 'stop')
            dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'unloadScript', script_name)
            return True
        return False
    except Exception as e:
        log(f"KDE window move error: {e}")
        return False
    finally:
        if os.path.exists(temp_path):
            try:
                os.remove(temp_path)
            except OSError:
                pass

def get_gnome_workspaces():
    ok, out = dbus_call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell', 'Eval', 'global.workspace_manager.n_workspaces')
    if ok:
        for line in out.splitlines():
            if 'string' in line:
                val = line.split('"')[1]
                if val.isdigit():
                    return [i + 1 for i in range(int(val))]
    return [1]

def move_window_gnome(target_title, desktop_num, follow=True):
    idx = max(0, int(desktop_num) - 1)
    escaped_title = json.dumps(target_title or "")
    follow_js = "true" if follow else "false"
    js_code = f"""
    (function() {{
        let targetTitle = {escaped_title};
        let targetIdx = {idx};
        let follow = {follow_js};
        let ws = global.workspace_manager.get_workspace_by_index(targetIdx);
        if (!ws) return false;

        let windows = global.display.get_tab_list(0, null);
        let target = null;
        if (targetTitle) {{
            for (let i = 0; i < windows.length; i++) {{
                let w = windows[i];
                if (w.get_title() && (w.get_title() === targetTitle || w.get_title().indexOf(targetTitle) !== -1 || targetTitle.indexOf(w.get_title()) !== -1)) {{
                    target = w;
                    break;
                }}
            }}
        }}
        if (!target) {{
            target = global.display.focus_window;
        }}
        if (target) {{
            target.change_workspace(ws);
            if (follow) {{
                ws.activate(global.get_current_time());
            }}
            return true;
        }}
        return false;
    }})()
    """
    ok, _ = dbus_call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell', 'Eval', js_code)
    return ok

while True:
    msg = read_message()
    if msg is None:
        break

    action = msg.get("action")
    if action == "get_desktops":
        desktops = get_kde_desktops() if IS_KDE else (get_gnome_workspaces() if IS_GNOME else [1])
        send_message({
            "action": "desktops_response",
            "success": True,
            "desktops": desktops,
            "de": "kde" if IS_KDE else ("gnome" if IS_GNOME else "other")
        })
    elif action == "move_window":
        target = int(msg.get("desktop", 1))
        title = msg.get("windowTitle", "")
        groups = msg.get("groups", [])
        follow = bool(msg.get("follow", True))

        move_ok = False
        persisted = False

        if IS_KDE:
            move_ok = move_window_kde(title, target, follow)
            persisted = persist_kde_rule(groups, title, target)
        elif IS_GNOME:
            move_ok = move_window_gnome(title, target, follow)
            persisted = True

        send_message({
            "action": "move_response",
            "success": move_ok,
            "persisted": persisted
        })
    else:
        send_message({"action": "error", "message": f"Unsupported action: {action}"})
PYEOF
  chmod +x "$INSTALL_DIR/helper.py"

  # 3. Native Messaging Host Manifest
  cat > "$HOST_DIR/tabgroup_helper.json" << EOF
{
  "homepage_url": "https://github.com/rr4444/plasma-firefox-sticky-desktops",
  "name": "tabgroup_helper",
  "description": "Bridge Firefox tab groups with desktop window managers",
  "path": "$INSTALL_DIR/helper.py",
  "type": "stdio",
  "allowed_extensions": ["$ADDON_ID"]
}
EOF

  # 4. Firefox Extension Manifest
  cat > "$EXT_DIR/manifest.json" << EOF
{
  "homepage_url": "https://github.com/rr4444/plasma-firefox-sticky-desktops",
  "manifest_version": 3,
  "name": "Tab Group Window Rules Bridge",
  "version": "1.4",
  "description": "Prefixes window titles with tab groups and synchronizes persistent desktop rules.",
  "permissions": [
    "tabGroups",
    "tabs",
    "nativeMessaging"
  ],
  "browser_specific_settings": {
    "gecko": {
      "id": "$ADDON_ID",
      "strict_min_version": "102.0"
    }
  },
  "icons": {
    "128": "icon.png"
  },
  "background": {
    "scripts": ["background.js"]
  },
  "action": {
    "default_icon": "icon.png",
    "default_popup": "popup.html",
    "default_title": "Tab Group Workspace Switcher"
  }
}
EOF

  # 5. Background Script
  cat > "$EXT_DIR/background.js" << 'JSEOF'
// Part of rr4444/plasma-firefox-sticky-desktops
// GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops
// Continuously updates Firefox window title prefixes based on active & background tab groups

async function refreshWindowTitle(windowId) {
  if (!windowId || windowId < 0) return;

  try {
    const [allGroups, activeTabs] = await Promise.all([
      browser.tabGroups.query({ windowId }),
      browser.tabs.query({ windowId, active: true })
    ]);

    const activeTab = activeTabs[0];
    let activeGroupName = null;

    if (activeTab && activeTab.groupId !== undefined && activeTab.groupId !== -1) {
      const currentGroup = allGroups.find(g => g.id === activeTab.groupId);
      if (currentGroup && currentGroup.title) {
        activeGroupName = currentGroup.title.trim();
      }
    }

    const groupNames = allGroups
      .map(g => (g.title ? g.title.trim() : `Group ${g.id}`))
      .filter(Boolean);

    let prefix = "";

    if (activeGroupName) {
      const otherGroups = groupNames.filter(name => name !== activeGroupName);
      if (otherGroups.length > 0) {
        prefix = `[${activeGroupName} | Groups: ${groupNames.join(', ')}] `;
      } else {
        prefix = `[${activeGroupName}] `;
      }
    } else if (groupNames.length > 0) {
      prefix = `[Ungrouped | Groups: ${groupNames.join(', ')}] `;
    }

    await browser.windows.update(windowId, { titlePreface: prefix });
  } catch (err) {
    console.error(`[Background] Failed to update titlePreface for window ${windowId}:`, err);
  }
}

browser.tabs.onActivated.addListener(info => refreshWindowTitle(info.windowId));
browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.groupId !== undefined || changeInfo.status === 'complete') {
    refreshWindowTitle(tab.windowId);
  }
});
browser.tabGroups.onCreated.addListener(g => refreshWindowTitle(g.windowId));
browser.tabGroups.onUpdated.addListener(g => refreshWindowTitle(g.windowId));
browser.tabGroups.onRemoved.addListener(g => refreshWindowTitle(g.windowId));
browser.tabGroups.onMoved.addListener(g => refreshWindowTitle(g.windowId));

browser.windows.getAll().then(windows => {
  for (const win of windows) {
    refreshWindowTitle(win.id);
  }
});
JSEOF

  # 6. Extension Popup HTML
  cat > "$EXT_DIR/popup.html" << 'EOF'
<!DOCTYPE html>
<!--
  Part of rr4444/plasma-firefox-sticky-desktops
  GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops
-->
<html>
<head>
  <meta charset="utf-8">
  <style>
    body {
      font-family: system-ui, -apple-system, sans-serif;
      padding: 12px;
      width: 360px;
      margin: 0;
      background: #f8f9fa;
      color: #212529;
    }
    .header {
      display: flex;
      align-items: center;
      gap: 8px;
      margin-bottom: 12px;
    }
    .header img {
      width: 24px;
      height: 24px;
    }
    .header h3 {
      margin: 0;
      font-size: 14px;
      font-weight: 600;
    }
    .panel {
      background: #ffffff;
      border-radius: 6px;
      padding: 12px;
      margin-bottom: 10px;
      border: 1px solid #dee2e6;
    }
    h4 { margin: 0 0 8px 0; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; color: #6c757d; }
    .group-item {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 6px 0;
      border-bottom: 1px solid #f1f3f5;
      font-size: 13px;
    }
    .group-item:last-child { border-bottom: none; }
    .badge {
      font-size: 10px;
      padding: 2px 6px;
      border-radius: 4px;
      background: #e9ecef;
      color: #495057;
    }
    .badge.active { background: #d3f9d8; color: #2b8a3e; font-weight: bold; }
    .row { display: flex; gap: 8px; margin-top: 8px; }
    select, button {
      padding: 6px 10px;
      border: 1px solid #ced4da;
      border-radius: 4px;
      font-size: 12px;
    }
    select { flex: 1; }
    button {
      background: #228be6;
      color: #fff;
      border: none;
      cursor: pointer;
      font-weight: 500;
    }
    button:hover { background: #1c7ed6; }
    button:disabled { background: #adb5bd; cursor: not-allowed; }
    .option-row {
      display: flex;
      align-items: center;
      gap: 6px;
      margin-top: 8px;
      font-size: 12px;
      color: #495057;
    }
    .status { font-size: 11px; color: #868e96; margin-top: 6px; }
  </style>
</head>
<body>
  <div class="header">
    <img src="icon.png" alt="Plasma Logo">
    <h3>Tab Group Workspace Bridge</h3>
  </div>

  <div class="panel">
    <h4>Tab Groups in This Window</h4>
    <div id="groupsList">Scanning...</div>
  </div>

  <div class="panel">
    <h4>Allocate & Move Desktop</h4>
    <div class="row">
      <select id="desktopSelect"><option>Detecting...</option></select>
      <button id="moveBtn">Move</button>
    </div>
    <div class="option-row">
      <input type="checkbox" id="followCheck" checked>
      <label for="followCheck">Switch active view to desktop</label>
    </div>
    <div class="status" id="deStatus">Connecting to system D-Bus...</div>
  </div>

  <script src="popup.js"></script>
</body>
</html>
EOF

  # 7. Extension Popup JS
  cat > "$EXT_DIR/popup.js" << 'JSEOF'
// Part of rr4444/plasma-firefox-sticky-desktops
// GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops
// Interactive popup UI logic for querying groups and dispatching desktop moves

let port = null;
let currentWindow = null;
let windowGroups = [];

document.addEventListener("DOMContentLoaded", async () => {
  currentWindow = await browser.windows.getCurrent({ populate: true });
  await loadGroups(currentWindow.id);
  initNativeBridge();
});

async function loadGroups(windowId) {
  const list = document.getElementById("groupsList");
  const [groups, activeTabs] = await Promise.all([
    browser.tabGroups.query({ windowId }),
    browser.tabs.query({ windowId, active: true })
  ]);

  windowGroups = groups.map(g => (g.title ? g.title.trim() : `Group ${g.id}`)).filter(Boolean);

  if (!groups || groups.length === 0) {
    list.innerHTML = '<span style="color:#adb5bd; font-size:12px;">No tab groups in this window</span>';
    return;
  }

  const activeGroupId = activeTabs[0]?.groupId;
  list.innerHTML = groups.map(g => {
    const isActive = g.id === activeGroupId;
    const name = g.title ? g.title : `Group ${g.id}`;
    return `
      <div class="group-item">
        <span>${name}</span>
        <span class="badge ${isActive ? 'active' : ''}">${isActive ? 'Focused' : 'Background'}</span>
      </div>
    `;
  }).join('');
}

function initNativeBridge() {
  const select = document.getElementById("desktopSelect");
  const btn = document.getElementById("moveBtn");
  const status = document.getElementById("deStatus");
  const followCheck = document.getElementById("followCheck");

  try {
    port = browser.runtime.connectNative("tabgroup_helper");
    port.onMessage.addListener(msg => {
      if (msg.action === "desktops_response") {
        select.innerHTML = msg.desktops.map(d => `<option value="${d}">Desktop ${d}</option>`).join('');
        status.textContent = `Environment: ${msg.de.toUpperCase()} (D-Bus ready)`;
      } else if (msg.action === "move_response") {
        btn.disabled = false;
        if (msg.success) {
          status.textContent = msg.persisted ? "Window moved & rule committed to kwinrulesrc." : "Window moved in memory.";
        } else {
          status.textContent = "Failed to move window.";
        }
      }
    });

    port.onDisconnect.addListener(() => {
      status.textContent = "Native bridge disconnected.";
      select.disabled = true;
      btn.disabled = true;
    });

    port.postMessage({ action: "get_desktops" });
  } catch (err) {
    status.textContent = "Native messaging connection error.";
  }

  btn.addEventListener("click", async () => {
    btn.disabled = true;
    status.textContent = "Persisting placement rule...";

    const win = await browser.windows.getCurrent();

    port.postMessage({
      action: "move_window",
      desktop: parseInt(select.value, 10),
      windowTitle: win.title || "",
      groups: windowGroups,
      follow: followCheck.checked
    });
  });
}
JSEOF

  echo "==> Installation complete."
  echo "Load or reload in Firefox: about:debugging#/runtime/this-firefox -> '$EXT_DIR/manifest.json'"
}

do_test() {
  echo "================================================================="
  echo "  Firefox Tab Group Bridge - Diagnostic & Test Suite"
  echo "  Repo: rr4444/plasma-firefox-sticky-desktops"
  echo "================================================================="

  echo -e "\n[1/5] Checking Desktop & Session Environment..."
  echo "  XDG_CURRENT_DESKTOP : ${XDG_CURRENT_DESKTOP:-<unset>}"
  echo "  DESKTOP_SESSION     : ${DESKTOP_SESSION:-<unset>}"
  echo "  XDG_SESSION_TYPE    : ${XDG_SESSION_TYPE:-<unset>}"

  if command -v dbus-send &>/dev/null; then
    echo "  dbus-send           : Available ($(command -v dbus-send))"
  else
    echo "  dbus-send           : MISSING (Install: sudo apt install dbus)"
  fi

  echo -e "\n[2/5] Checking Files, Manifests, and Integrity..."
  HELPER_BIN="$INSTALL_DIR/helper.py"
  HOST_MANIFEST="$HOST_DIR/tabgroup_helper.json"
  EXT_MANIFEST="$EXT_DIR/manifest.json"

  for f in "$HELPER_BIN" "$HOST_MANIFEST" "$EXT_MANIFEST"; do
    if [ -f "$f" ]; then
      echo "  [FOUND] $f"
    else
      echo "  [MISSING] $f"
    fi
  done

  if [ -x "$HELPER_BIN" ]; then
    echo "  [OK] Helper script is executable."
  else
    echo "  [ERROR] Helper script lacks execute permissions."
  fi

  python3 - << 'PYEOF'
import json, os, sys

host_path = os.path.expanduser('~/.mozilla/native-messaging-hosts/tabgroup_helper.json')
ext_path = os.path.expanduser('~/tabgroup-extension/manifest.json')

def load_json(p):
    try:
        with open(p) as f:
            return json.load(f)
    except Exception as e:
        print(f"  [ERROR] Failed to read {p}: {e}")
        return None

host = load_json(host_path)
ext = load_json(ext_path)

if host and ext:
    target = host.get("path", "")
    ext_id = ext.get("browser_specific_settings", {}).get("gecko", {}).get("id", "")
    allowed = host.get("allowed_extensions", [])

    if os.path.exists(target):
        print(f"  [OK] Host manifest binary target exists: {target}")
    else:
        print(f"  [ERROR] Host manifest path does not exist: {target}")

    if ext_id in allowed:
        print(f"  [OK] Extension ID match: '{ext_id}'")
    else:
        print(f"  [ERROR] Extension ID '{ext_id}' not in allowed_extensions: {allowed}")
PYEOF

  echo -e "\n[3/5] Testing Compositor D-Bus API..."
  if dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.kde.KWin &>/dev/null; then
    echo "  [OK] org.kde.KWin service active on session bus."

    VD_QUERY=$(dbus-send --session --dest=org.kde.KWin --type=method_call --print-reply /VirtualDesktopManager org.freedesktop.DBus.Properties.Get string:org.kde.KWin.VirtualDesktopManager string:count 2>/dev/null || true)
    if echo "$VD_QUERY" | grep -q "variant"; then
      COUNT=$(echo "$VD_QUERY" | awk '/variant/ {print $NF}')
      echo "  [OK] Plasma Virtual Desktops detected (count: $COUNT)"
    fi

    SCRIPTING_TEST=$(dbus-send --session --dest=org.kde.KWin --type=method_call --print-reply /Scripting org.freedesktop.DBus.Introspectable.Introspect 2>/dev/null || true)
    if echo "$SCRIPTING_TEST" | grep -q "loadScript"; then
      echo "  [OK] KWin Scripting API (/Scripting -> loadScript) available."
    else
      echo "  [WARN] KWin Scripting interface did not return loadScript."
    fi
  elif dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.gnome.Shell &>/dev/null; then
    echo "  [OK] org.gnome.Shell service active on session bus."
  else
    echo "  [WARN] Neither KWin nor GNOME Shell responded on the session D-Bus."
  fi

  echo -e "\n[4/5] Testing Native Helper IPC (Query Only)..."
  python3 - << 'PYEOF'
import struct, json, subprocess, os, sys

helper_path = os.path.expanduser("~/.local/share/tabgroup-helper/helper.py")
if not os.path.exists(helper_path):
    print("  [SKIP] helper.py does not exist.")
    sys.exit(0)

raw = json.dumps({"action": "get_desktops"}).encode('utf-8')
packet = struct.pack('I', len(raw)) + raw

proc = subprocess.Popen([helper_path], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
stdout, stderr = proc.communicate(packet, timeout=5)

if proc.returncode != 0:
    print(f"  [ERROR] Process exited with status {proc.returncode}: {stderr.decode()}")
    sys.exit(0)

if len(stdout) < 4:
    print(f"  [ERROR] Malformed response from helper: {stdout}")
    sys.exit(0)

size = struct.unpack('I', stdout[:4])[0]
response = json.loads(stdout[4:4+size].decode('utf-8'))
print(f"  [OK] Helper response: {response}")
PYEOF

  echo -e "\n[5/5] Auditing ~/.config/kwinrulesrc..."
  if [ -f "$KWINRC" ]; then
    python3 - << 'PYEOF'
import configparser, os

path = os.path.expanduser('~/.config/kwinrulesrc')
config = configparser.ConfigParser(interpolation=None, strict=False)
config.optionxform = str
config.read(path, encoding='utf-8')

rules_list = []
if config.has_section("General") and config.has_option("General", "rules"):
    rules_list = [r.strip() for r in config.get("General", "rules").split(",") if r.strip()]

tg_sections = [s for s in config.sections() if s.startswith("tabgroup_")]
print(f"  Total rules registered in [General] : {len(rules_list)}")
print(f"  TabGroup-managed rules in file      : {len(tg_sections)}")

for s in tg_sections[-3:]:
    desc = config.get(s, "Description", fallback="<none>")
    desk = config.get(s, "desktops", fallback="<all>")
    regex = config.get(s, "title", fallback="<all>")
    print(f"    * [{s}] '{desc}' -> Desktop {desk} (Regex: {regex})")
PYEOF
  else
    echo "  [INFO] ~/.config/kwinrulesrc does not exist yet."
  fi

  echo -e "\n================================================================="
  echo "  Diagnostic Complete."
  echo "================================================================="
}

do_uninstall() {
  echo "==> Safely removing Tab Group Integration (rr4444/plasma-firefox-sticky-desktops)..."

  if [ -f "$KWINRC" ]; then
    echo "==> Cleaning tabgroup-specific rules from kwinrulesrc..."
    python3 - << 'PYEOF'
import configparser
import os
import subprocess

path = os.path.expanduser('~/.config/kwinrulesrc')
if os.path.exists(path):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.optionxform = str
    config.read(path, encoding='utf-8')

    sections_to_remove = [
        s for s in config.sections()
        if s.startswith('tabgroup_') or s == 'TabGroup-Work-Rule'
    ]

    if sections_to_remove:
        for s in sections_to_remove:
            config.remove_section(s)

        if config.has_section('General') and config.has_option('General', 'rules'):
            rules = [r.strip() for r in config.get('General', 'rules').split(',') if r.strip()]
            rules = [r for r in rules if r not in sections_to_remove]
            config.set('General', 'rules', ','.join(rules))
            config.set('General', 'count', str(len(rules)))

        temp_file = f"{path}.tmp"
        with open(temp_file, 'w', encoding='utf-8') as f:
            config.write(f, space_around_delimiters=False)
        os.replace(temp_file, path)

        subprocess.run(['dbus-send', '--session', '--dest=org.kde.KWin', '/KWin', 'org.kde.KWin.reconfigure'],
                       capture_output=True)
PYEOF
  fi

  rm -rf "$INSTALL_DIR"
  rm -f "$HOST_DIR/tabgroup_helper.json"
  rm -rf "$EXT_DIR"
  rm -f /tmp/tabgroup_move_*.js

  echo "==> Uninstall complete. Remove the temporary add-on from about:debugging in Firefox."
}

if [ $# -eq 0 ]; then
  show_help
  exit 0
fi

case "$1" in
  -i|--install|-u|--update)
    do_install
    ;;
  -t|--test|--diag)
    do_test
    ;;
  -r|--uninstall|--remove)
    do_uninstall
    ;;
  -h|--help)
    show_help
    exit 0
    ;;
  *)
    echo "Error: Unknown option '$1'" >&2
    echo "" >&2
    show_help >&2
    exit 1
    ;;
esac
