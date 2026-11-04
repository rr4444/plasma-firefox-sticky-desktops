#!/usr/bin/env bash
# Part of rr4444/plasma-firefox-sticky-desktops
# GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops
set -euo pipefail

INSTALL_DIR="$HOME/.local/share/tabgroup-helper"
HOST_DIR="$HOME/.mozilla/native-messaging-hosts"
EXT_DIR="$HOME/tabgroup-extension"
APPS_DIR="$HOME/apps/tabgroup-extension"
XPI_UNSIGNED="$APPS_DIR/tabgroup-bridge-unsigned-for-amo-signing.xpi"
ADDON_ID="tabgroup-helper@local"
KWINRC="$HOME/.config/kwinrulesrc"
ICON_URL="https://kde.org/stuff/clipart/logo/plasma-logo-colorful-128x128.png"

show_help() {
  cat << 'EOHELP'
Firefox Tab Group Window Manager Bridge (rr4444/plasma-firefox-sticky-desktops)

Usage: tab-group-setup.sh [OPTION]

Options:
  -i, --install, -u, --update   Deploy helper, extension, icon, and manifests
  -b, --build, --package        Package unsigned .xpi ready for Mozilla AMO signing
  -t, --test, --diag            Run non-destructive diagnostics and IPC checks
  -r, --uninstall, --remove     Remove tabgroup rules from kwinrulesrc and delete files
  -h, --help                    Display this help message
EOHELP
}

do_install() {
  echo "==> Deploying Firefox Tab Group Integration..."
  mkdir -p "$INSTALL_DIR" "$HOST_DIR" "$EXT_DIR" "$APPS_DIR"

  if [ -f "$KWINRC" ]; then
    echo "==> Checking for legacy integer rules in kwinrulesrc..."
    python3 -c "
import configparser, os, subprocess
path = os.path.expanduser('$KWINRC')
if os.path.exists(path):
    cfg = configparser.ConfigParser(interpolation=None, strict=False)
    cfg.optionxform = str
    cfg.read(path, encoding='utf-8')
    to_remove = [s for s in cfg.sections() if (s.startswith('tabgroup_') or s == 'TabGroup-Work-Rule') and cfg.get(s, 'desktops', fallback='').isdigit()]
    if to_remove:
        for s in to_remove: cfg.remove_section(s)
        if cfg.has_section('General'):
            if cfg.has_option('General', 'Order'):
                order = [x.strip() for x in cfg.get('General', 'Order').split(',') if x.strip() and x not in to_remove]
                cfg.set('General', 'Order', ','.join(order))
            if cfg.has_option('General', 'rules'):
                r = [x.strip() for x in cfg.get('General', 'rules').split(',') if x.strip() and x not in to_remove]
                cfg.set('General', 'rules', ','.join(r))
                cfg.set('General', 'count', str(len(r)))
        with open(f'{path}.tmp', 'w', encoding='utf-8') as f: cfg.write(f, space_around_delimiters=False)
        os.replace(f'{path}.tmp', path)
        subprocess.run(['dbus-send', '--session', '--dest=org.kde.KWin', '/KWin', 'org.kde.KWin.reconfigure'], capture_output=True)
        print(f'  [Purged] {len(to_remove)} legacy integer rule(s) from kwinrulesrc.')
" || true
  fi

  if [ ! -f "$EXT_DIR/icon.png" ]; then
    echo "==> Fetching extension icon..."
    if command -v curl &>/dev/null; then
      curl -fsSL "$ICON_URL" -o "$EXT_DIR/icon.png" || true
    elif command -v wget &>/dev/null; then
      wget -qO "$EXT_DIR/icon.png" "$ICON_URL" || true
    fi
  fi

  cat > "$INSTALL_DIR/helper.py" << 'PYEOF'
#!/usr/bin/env python3
# Part of rr4444/plasma-firefox-sticky-desktops
import sys, json, struct, subprocess, os, time, re, hashlib, shutil, configparser

DESKTOP = os.environ.get('XDG_CURRENT_DESKTOP', '').lower()
SESSION = os.environ.get('DESKTOP_SESSION', '').lower()
IS_KDE_ENV = any(k in DESKTOP or k in SESSION for k in ('kde', 'plasma'))
IS_GNOME_ENV = 'gnome' in DESKTOP or 'gnome' in SESSION
KWINRC_PATH = os.path.expanduser('~/.config/kwinrulesrc')
KWIN_CONFIG_PATH = os.path.expanduser('~/.config/kwinrc')

def log(msg):
    print(f"[tabgroup-helper] {msg}", file=sys.stderr, flush=True)

def send_message(payload):
    encoded = json.dumps(payload).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('I', len(encoded)) + encoded)
    sys.stdout.flush()

def read_message():
    try:
        raw_size = sys.stdin.buffer.read(4)
        if not raw_size: return None
        size = struct.unpack('I', raw_size)[0]
        return json.loads(sys.stdin.buffer.read(size).decode('utf-8'))
    except Exception as e:
        log(f"Read error: {e}")
        return None

def dbus_call(dest, path, interface, method, *args):
    cmd = ['dbus-send', '--print-reply', '--session', f'--dest={dest}', path, f'{interface}.{method}']
    for arg in args:
        if isinstance(arg, int): cmd.append(f'int32:{arg}')
        elif isinstance(arg, bool): cmd.append(f'boolean:{"true" if arg else "false"}')
        else: cmd.append(f'string:{arg}')
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        return proc.returncode == 0, proc.stdout + proc.stderr
    except Exception as e:
        return False, str(e)

def is_kde():
    if IS_KDE_ENV: return True
    ok, _ = dbus_call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetNameOwner', 'org.kde.KWin')
    return ok

def is_gnome():
    if IS_GNOME_ENV: return True
    ok, _ = dbus_call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'GetNameOwner', 'org.gnome.Shell')
    return ok

def get_kde_desktops():
    desktops = []
    # 1. Try D-Bus VirtualDesktopManager desktops property
    ok, out = dbus_call('org.kde.KWin', '/VirtualDesktopManager', 'org.freedesktop.DBus.Properties', 'Get', 'org.kde.KWin.VirtualDesktopManager', 'desktops')
    if ok:
        lines = out.splitlines()
        curr = {}
        in_struct = False
        for line in lines:
            line = line.strip()
            if line.startswith('struct {'):
                curr = {}
                in_struct = True
            elif line == '}':
                if in_struct and 'id' in curr:
                    desktops.append(curr)
                in_struct = False
            elif in_struct:
                if line.startswith('uint32'):
                    curr['index'] = int(line.split()[-1])
                elif line.startswith('string'):
                    val = line.split('\"')[1]
                    if 'id' not in curr:
                        curr['id'] = val
                    else:
                        curr['name'] = val

    # 2. If D-Bus was incomplete or failed, fall back to ~/.config/kwinrc [Desktops]
    if not desktops and os.path.exists(KWIN_CONFIG_PATH):
        try:
            cfg = configparser.ConfigParser(interpolation=None, strict=False)
            cfg.read(KWIN_CONFIG_PATH, encoding='utf-8')
            if cfg.has_section('Desktops'):
                count = int(cfg.get('Desktops', 'Number', fallback=cfg.get('Desktops', 'number', fallback='1')))
                for i in range(1, count + 1):
                    uid = cfg.get('Desktops', f'Id_{i}', fallback=cfg.get('Desktops', f'id_{i}', fallback=''))
                    name = cfg.get('Desktops', f'Name_{i}', fallback=cfg.get('Desktops', f'name_{i}', fallback=''))
                    desktops.append({'index': i - 1, 'id': uid.strip(), 'name': name.strip()})
        except Exception as e:
            log(f"kwinrc parse error: {e}")

    # 3. Fall back to count property if needed
    if not desktops:
        ok, out = dbus_call('org.kde.KWin', '/VirtualDesktopManager', 'org.freedesktop.DBus.Properties', 'Get', 'org.kde.KWin.VirtualDesktopManager', 'count')
        if ok:
            for line in out.splitlines():
                if 'uint32' in line or 'int32' in line:
                    c = int(line.split()[-1])
                    for i in range(1, c + 1):
                        desktops.append({'index': i - 1, 'id': '', 'name': f'Desktop {i}'})
                    break

    if not desktops:
        desktops = [{'index': 0, 'id': '', 'name': 'Desktop 1'}]

    # Format each desktop: assigned cosmetic name followed by desktop number '[i]'
    res = []
    for i, d in enumerate(desktops, start=1):
        name = d.get('name', '').strip()
        uid = d.get('id', '').strip()
        display_name = f"{name} [{i}]" if name else f"Desktop {i} [{i}]"
        res.append({
            'id': i,
            'name': display_name,
            'cosmetic_name': name,
            'uuid': uid
        })
    return res

def get_current_desktop_kde(desktop_list):
    # 1. Check VirtualDesktopManager current (UUID)
    ok, out = dbus_call('org.kde.KWin', '/VirtualDesktopManager', 'org.freedesktop.DBus.Properties', 'Get', 'org.kde.KWin.VirtualDesktopManager', 'current')
    if ok:
        for line in out.splitlines():
            if 'string "' in line:
                cur_uuid = line.split('"')[1]
                for d in desktop_list:
                    if d.get('uuid') and d['uuid'] == cur_uuid:
                        return d['id']
    # 2. Check /KWin currentDesktop (1-based int)
    ok, out = dbus_call('org.kde.KWin', '/KWin', 'org.kde.KWin', 'currentDesktop')
    if ok:
        for line in out.splitlines():
            if 'int32' in line or 'uint32' in line:
                val = line.split()[-1]
                if val.isdigit(): return int(val)
    return 1

def get_gnome_workspaces():
    ok, out = dbus_call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell', 'Eval', 'global.workspace_manager.n_workspaces')
    n = 1
    if ok:
        for line in out.splitlines():
            if 'string' in line:
                v = line.split('"')[1]
                if v.isdigit():
                    n = int(v)
                    break
    res = []
    for i in range(1, n + 1):
        res.append({
            'id': i,
            'name': f"Workspace [{i}]",
            'cosmetic_name': f"Workspace {i}",
            'uuid': ''
        })
    return res

def get_current_workspace_gnome():
    ok, out = dbus_call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell', 'Eval', 'global.workspace_manager.get_active_workspace_index()')
    if ok:
        for line in out.splitlines():
            if 'string' in line:
                v = line.split('"')[1]
                if v.isdigit(): return int(v) + 1
    return 1

def persist_kde_rule(groups, target_title, desktop_num, desktop_uuid=None):
    try:
        config = configparser.ConfigParser(interpolation=None, strict=False)
        config.optionxform = str
        if os.path.exists(KWINRC_PATH):
            shutil.copy2(KWINRC_PATH, KWINRC_PATH + '.bak_tabgroup')
            config.read(KWINRC_PATH, encoding='utf-8')
        if not config.has_section('General'): config.add_section('General')

        existing_rules = []
        if config.has_option('General', 'Order'):
            existing_rules = [r.strip() for r in config.get('General', 'Order').split(',') if r.strip()]
        elif config.has_option('General', 'rules'):
            existing_rules = [r.strip() for r in config.get('General', 'rules').split(',') if r.strip()]

        # Resolve desktop UUID or fallback to integer
        target_desktop_val = desktop_uuid
        if not target_desktop_val:
            desktops = get_kde_desktops()
            if 1 <= desktop_num <= len(desktops) and desktops[desktop_num - 1].get('uuid'):
                target_desktop_val = desktops[desktop_num - 1]['uuid']
            else:
                target_desktop_val = str(desktop_num)

        # Remove legacy integer rules for tabgroups if UUIDs are in use
        if target_desktop_val != str(desktop_num):
            legacy = [s for s in config.sections() if (s.startswith('tabgroup_') or s == 'TabGroup-Work-Rule') and config.get(s, 'desktops', fallback='').isdigit()]
            for s in legacy:
                config.remove_section(s)
            existing_rules = [r for r in existing_rules if r not in legacy]

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

        rule_str = ','.join(existing_rules)
        config.set('General', 'Order', rule_str)
        config.set('General', 'rules', rule_str)
        config.set('General', 'count', str(len(existing_rules)))

        if not config.has_section(rule_id): config.add_section(rule_id)

        config.set(rule_id, 'Description', desc)
        config.set(rule_id, 'wmclass', 'firefox')
        config.set(rule_id, 'wmclassmatch', '1')
        config.set(rule_id, 'title', title_regex)
        config.set(rule_id, 'titlematch', '3')
        config.set(rule_id, 'desktops', str(target_desktop_val))
        config.set(rule_id, 'desktopsrule', '2')

        temp_rc = f"{KWINRC_PATH}.tmp"
        with open(temp_rc, 'w', encoding='utf-8') as f: config.write(f, space_around_delimiters=False)
        os.replace(temp_rc, KWINRC_PATH)
        dbus_call('org.kde.KWin', '/KWin', 'org.kde.KWin', 'reconfigure')
        return True
    except Exception as e:
        log(f"Rule persist error: {e}")
        return False

def move_window_kde(target_title, desktop_num, follow=True):
    js_code = f"""
    var targetTitle = {json.dumps(target_title or "")};
    var targetDesktop = {int(desktop_num)};
    var follow = {"true" if follow else "false"};
    var windows = (typeof workspace.windowList === "function") ? workspace.windowList() : workspace.clientList();
    var target = null;
    if (targetTitle) {{
        for (var i = 0; i < windows.length; i++) {{
            var w = windows[i];
            if (w.caption && (w.caption === targetTitle || w.caption.indexOf(targetTitle) !== -1 || targetTitle.indexOf(w.caption) !== -1)) {{
                target = w; break;
            }}
        }}
    }}
    if (!target) {{
        for (var i = 0; i < windows.length; i++) {{
            var w = windows[i];
            if (w.resourceClass === "firefox" || (w.caption && w.caption.indexOf("Firefox") !== -1)) {{
                target = w; break;
            }}
        }}
    }}
    if (!target) target = (typeof workspace.activeWindow !== "undefined") ? workspace.activeWindow : workspace.activeClient;
    if (target) {{
        target.onAllDesktops = false;
        if (typeof workspace.desktops !== "undefined" && workspace.desktops.length > 0) {{
            var idx = targetDesktop - 1;
            if (idx >= 0 && idx < workspace.desktops.length) {{
                target.desktops = [workspace.desktops[idx]];
                if (follow) workspace.currentDesktop = workspace.desktops[idx];
            }}
        }} else {{
            target.desktop = targetDesktop;
            if (follow && typeof workspace.setCurrentDesktop === "function") workspace.setCurrentDesktop(targetDesktop);
        }}
    }}
    """
    script_name = f"tabgroup_move_{os.getpid()}_{int(time.time() * 1000)}"
    temp_path = f"/tmp/{script_name}.js"
    try:
        with open(temp_path, "w", encoding="utf-8") as f: f.write(js_code)
        ok, out = dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'loadScript', temp_path, script_name)
        if not ok or 'int32' not in out:
            ok, out = dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'loadScript', temp_path)
        script_id = None
        for line in out.splitlines():
            if 'int32' in line:
                script_id = line.strip().split()[-1]
                break
        if script_id is not None:
            sp = f"/Scripting/Script{script_id}"
            dbus_call('org.kde.KWin', sp, 'org.kde.kwin.Script', 'run')
            dbus_call('org.kde.KWin', sp, 'org.kde.kwin.Script', 'stop')
            dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'unloadScript', f"Script{script_id}")
            dbus_call('org.kde.KWin', '/Scripting', 'org.kde.kwin.Scripting', 'unloadScript', script_name)
            return True
        return False
    except Exception as e:
        log(f"Move error: {e}")
        return False
    finally:
        if os.path.exists(temp_path):
            try: os.remove(temp_path)
            except OSError: pass

def move_window_gnome(target_title, desktop_num, follow=True):
    idx = max(0, int(desktop_num) - 1)
    escaped_title = json.dumps(target_title or "")
    follow_js = "true" if follow else "false"
    js_code = f"""
    (function() {{
        let targetTitle = {escaped_title};
        let ws = global.workspace_manager.get_workspace_by_index({idx});
        if (!ws) return false;
        let windows = global.display.get_tab_list(0, null);
        let target = null;
        if (targetTitle) {{
            for (let i = 0; i < windows.length; i++) {{
                let w = windows[i];
                if (w.get_title() && (w.get_title() === targetTitle || w.get_title().indexOf(targetTitle) !== -1 || targetTitle.indexOf(w.get_title()) !== -1)) {{
                    target = w; break;
                }}
            }}
        }}
        if (!target) target = global.display.focus_window;
        if (target) {{
            target.change_workspace(ws);
            if ({follow_js}) ws.activate(global.get_current_time());
            return true;
        }}
        return false;
    }})()
    """
    ok, _ = dbus_call('org.gnome.Shell', '/org/gnome/Shell', 'org.gnome.Shell', 'Eval', js_code)
    return ok

while True:
    msg = read_message()
    if msg is None: break
    action = msg.get("action")
    if action == "get_desktops":
        kde = is_kde()
        gnome = is_gnome()
        if kde:
            desktops = get_kde_desktops()
            cur_desk = get_current_desktop_kde(desktops)
            de_name = "kde"
        elif gnome:
            desktops = get_gnome_workspaces()
            cur_desk = get_current_workspace_gnome()
            de_name = "gnome"
        else:
            desktops = [{'id': 1, 'name': 'Desktop [1]', 'cosmetic_name': 'Desktop', 'uuid': ''}]
            cur_desk = 1
            de_name = "other"
        send_message({
            "action": "desktops_response", "success": True,
            "desktops": desktops, "current_desktop": cur_desk,
            "de": de_name
        })
    elif action == "move_window":
        target = int(msg.get("desktop", 1))
        target_uuid = msg.get("desktopUuid", "")
        title = msg.get("windowTitle", "")
        groups = msg.get("groups", [])
        follow = bool(msg.get("follow", True))
        kde = is_kde()
        gnome = is_gnome()
        if kde:
            move_ok = move_window_kde(title, target, follow)
            persisted = persist_kde_rule(groups, title, target, target_uuid)
        elif gnome:
            move_ok = move_window_gnome(title, target, follow)
            persisted = True
        else:
            move_ok, persisted = False, False
        send_message({"action": "move_response", "success": move_ok, "persisted": persisted})
    else:
        send_message({"action": "error", "message": f"Unsupported action: {action}"})
PYEOF
  chmod +x "$INSTALL_DIR/helper.py"

  cat > "$HOST_DIR/tabgroup_helper.json" << EOF
{
  "name": "tabgroup_helper",
  "description": "Bridge Firefox tab groups with desktop window managers",
  "path": "$INSTALL_DIR/helper.py",
  "type": "stdio",
  "allowed_extensions": ["$ADDON_ID"]
}
EOF

  python3 -c "
import json
m = {
  'manifest_version': 3,
  'name': 'Tab Group Window Rules Bridge',
  'version': '1.6',
  'homepage_url': 'https://github.com/rr4444/plasma-firefox-sticky-desktops',
  'description': 'Prefixes window titles with tab groups and synchronizes persistent desktop rules.',
  'permissions': ['tabGroups', 'tabs', 'nativeMessaging'],
  'browser_specific_settings': {
    'gecko': {
      'id': '$ADDON_ID',
      'strict_min_version': '102.0',
      'data_collection_permissions': {
        'required': ['none']
      }
    }
  },
  'icons': {'128': 'icon.png'},
  'background': {'scripts': ['background.js']},
  'action': {
    'default_icon': 'icon.png',
    'default_popup': 'popup.html',
    'default_title': 'Tab Group Workspace Switcher'
  }
}
with open('$EXT_DIR/manifest.json', 'w') as f: json.dump(m, f, indent=2)
"

  cat > "$EXT_DIR/background.js" << 'JSEOF'
// Part of rr4444/plasma-firefox-sticky-desktops
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
      if (currentGroup && currentGroup.title) activeGroupName = currentGroup.title.trim();
    }
    const groupNames = allGroups.map(g => (g.title ? g.title.trim() : `Group ${g.id}`)).filter(Boolean);
    let prefix = "";
    if (activeGroupName) {
      const others = groupNames.filter(name => name !== activeGroupName);
      prefix = others.length > 0 ? `[${activeGroupName} | Groups: ${groupNames.join(', ')}] ` : `[${activeGroupName}] `;
    } else if (groupNames.length > 0) {
      prefix = `[Ungrouped | Groups: ${groupNames.join(', ')}] `;
    }
    await browser.windows.update(windowId, { titlePreface: prefix });
  } catch (err) {
    console.error(`[Background] Update titlePreface failed for window ${windowId}:`, err);
  }
}

browser.windows.onCreated.addListener(win => refreshWindowTitle(win.id));
browser.tabs.onActivated.addListener(info => refreshWindowTitle(info.windowId));
browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.groupId !== undefined || changeInfo.status === 'complete') refreshWindowTitle(tab.windowId);
});
browser.tabGroups.onCreated.addListener(g => refreshWindowTitle(g.windowId));
browser.tabGroups.onUpdated.addListener(g => refreshWindowTitle(g.windowId));
browser.tabGroups.onRemoved.addListener(g => refreshWindowTitle(g.windowId));
browser.tabGroups.onMoved.addListener(g => refreshWindowTitle(g.windowId));

browser.windows.getAll().then(windows => {
  for (const win of windows) refreshWindowTitle(win.id);
});
JSEOF

  cat > "$EXT_DIR/popup.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: system-ui, -apple-system, sans-serif; padding: 12px; width: 360px; margin: 0; background: #f8f9fa; color: #212529; }
    .header { display: flex; align-items: center; gap: 8px; margin-bottom: 12px; }
    .header img { width: 24px; height: 24px; }
    .header h3 { margin: 0; font-size: 14px; font-weight: 600; }
    .panel { background: #ffffff; border-radius: 6px; padding: 12px; margin-bottom: 10px; border: 1px solid #dee2e6; }
    h4 { margin: 0 0 8px 0; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; color: #6c757d; }
    .group-item { display: flex; align-items: center; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #f1f3f5; font-size: 13px; }
    .group-item:last-child { border-bottom: none; }
    .badge { font-size: 10px; padding: 2px 6px; border-radius: 4px; background: #e9ecef; color: #495057; }
    .badge.active { background: #d3f9d8; color: #2b8a3e; font-weight: bold; }
    .row { display: flex; gap: 8px; margin-top: 8px; }
    select, button { padding: 6px 10px; border: 1px solid #ced4da; border-radius: 4px; font-size: 12px; }
    select { flex: 1; }
    button { background: #228be6; color: #fff; border: none; cursor: pointer; font-weight: 500; }
    button:hover { background: #1c7ed6; }
    button:disabled { background: #adb5bd; cursor: not-allowed; }
    .option-row { display: flex; align-items: center; gap: 6px; margin-top: 8px; font-size: 12px; color: #495057; }
    .status { font-size: 11px; color: #868e96; margin-top: 6px; }
  </style>
</head>
<body>
  <div class="header">
    <img src="icon.png" alt="Logo">
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

  cat > "$EXT_DIR/popup.js" << 'JSEOF'
// Part of rr4444/plasma-firefox-sticky-desktops
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
    return `<div class="group-item"><span>${name}</span><span class="badge ${isActive ? 'active' : ''}">${isActive ? 'Focused' : 'Background'}</span></div>`;
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
        select.innerHTML = msg.desktops.map(d => {
          const val = (typeof d === "object" && d !== null) ? d.id : d;
          const label = (typeof d === "object" && d !== null) ? (d.name || `Desktop ${d.id}`) : `Desktop ${d}`;
          const uuid = (typeof d === "object" && d !== null && d.uuid) ? d.uuid : "";
          return `<option value="${val}" data-uuid="${uuid}">${label}</option>`;
        }).join('');
        if (msg.current_desktop) select.value = String(msg.current_desktop);
        const curDesk = msg.desktops.find(d => ((typeof d === "object" && d !== null) ? d.id : d) == msg.current_desktop);
        const curName = (typeof curDesk === "object" && curDesk !== null) ? curDesk.name : `Desktop ${msg.current_desktop || '?'}`;
        status.textContent = `Environment: ${msg.de.toUpperCase()} (${curName})`;
      } else if (msg.action === "move_response") {
        btn.disabled = false;
        status.textContent = msg.success ? (msg.persisted ? "Window moved & rule saved to kwinrulesrc." : "Window moved in memory.") : "Failed to move window.";
      }
    });

    port.onDisconnect.addListener(() => {
      status.textContent = "Native bridge disconnected.";
      select.disabled = true;
      btn.disabled = true;
    });

    port.postMessage({ action: "get_desktops", windowTitle: currentWindow.title || "" });
  } catch (err) {
    status.textContent = "Native messaging connection error.";
  }

  btn.addEventListener("click", async () => {
    btn.disabled = true;
    status.textContent = "Persisting placement rule...";
    const win = await browser.windows.getCurrent();
    const selectedOpt = select.selectedOptions[0];
    port.postMessage({
      action: "move_window",
      desktop: parseInt(select.value, 10),
      desktopUuid: selectedOpt?.dataset?.uuid || "",
      windowTitle: win.title || "",
      groups: windowGroups,
      follow: followCheck.checked
    });
  });
}
JSEOF

  echo "==> Deployed to $EXT_DIR and $INSTALL_DIR"
}

do_build() {
  if [ ! -f "$EXT_DIR/manifest.json" ]; then
    do_install
  fi
  echo "==> Building unsigned XPI archive..."
  python3 -c "
import os, zipfile
ext_dir = os.path.expanduser('$EXT_DIR')
out_file = os.path.expanduser('$XPI_UNSIGNED')
files = ['manifest.json', 'background.js', 'popup.html', 'popup.js', 'icon.png']
with zipfile.ZipFile(out_file, 'w', zipfile.ZIP_DEFLATED) as zf:
    for f in files:
        p = os.path.join(ext_dir, f)
        if os.path.exists(p): zf.write(p, f)
print(f'  [OK] Successfully packaged: {out_file}')
"
}

do_test() {
  echo "================================================================="
  echo "  Firefox Tab Group Bridge - Diagnostic & Test Suite"
  echo "================================================================="
  echo -e "
[1/5] Checking Desktop & Session Environment..."
  echo "  XDG_CURRENT_DESKTOP : ${XDG_CURRENT_DESKTOP:-<unset>}"
  echo "  DESKTOP_SESSION     : ${DESKTOP_SESSION:-<unset>}"
  echo "  XDG_SESSION_TYPE    : ${XDG_SESSION_TYPE:-<unset>}"

  echo -e "
[2/5] Checking Files and Manifest Integrity..."
  for f in "$INSTALL_DIR/helper.py" "$HOST_DIR/tabgroup_helper.json" "$EXT_DIR/manifest.json"; do
    [ -f "$f" ] && echo "  [FOUND] $f" || echo "  [MISSING] $f"
  done
  python3 -c "
import json, os
h = json.load(open(os.path.expanduser('$HOST_DIR/tabgroup_helper.json')))
m = json.load(open(os.path.expanduser('$EXT_DIR/manifest.json')))
assert os.path.exists(h['path']), 'Binary target does not exist'
assert m['browser_specific_settings']['gecko']['id'] in h['allowed_extensions'], 'ID mismatch'
print('  [OK] Valid extension manifest v' + str(m.get('version', '?')))
"

  echo -e "
[3/5] Testing Compositor D-Bus Interface..."
  if dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.kde.KWin &>/dev/null; then
    echo "  [OK] org.kde.KWin service active on session bus."
    VD=$(dbus-send --session --dest=org.kde.KWin --type=method_call --print-reply /VirtualDesktopManager org.freedesktop.DBus.Properties.Get string:org.kde.KWin.VirtualDesktopManager string:count 2>/dev/null || true)
    if echo "$VD" | grep -q "variant"; then
      echo "  [OK] Plasma Virtual Desktops count: $(echo "$VD" | awk '/variant/ {print $NF}')"
    fi
  elif dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.gnome.Shell &>/dev/null; then
    echo "  [OK] org.gnome.Shell service active on session bus."
  fi

  echo -e "
[4/5] Testing Native Helper IPC (Query Only)..."
  python3 -c "
import struct, json, subprocess, os
raw = json.dumps({'action': 'get_desktops', 'windowTitle': ''}).encode('utf-8')
proc = subprocess.Popen([os.path.expanduser('$INSTALL_DIR/helper.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
out, _ = proc.communicate(struct.pack('I', len(raw)) + raw, timeout=5)
size = struct.unpack('I', out[:4])[0]
print('  [OK] Helper response:', json.loads(out[4:4+size].decode('utf-8')))
"

  echo -e "
[5/5] Auditing ~/.config/kwinrulesrc..."
  if [ -f "$KWINRC" ]; then
    python3 -c "
import configparser, os
config = configparser.ConfigParser(interpolation=None, strict=False)
config.optionxform = str
config.read(os.path.expanduser('$KWINRC'), encoding='utf-8')
order = [r.strip() for r in config.get('General', 'Order', fallback='').split(',') if r.strip()]
rules = [r.strip() for r in config.get('General', 'rules', fallback='').split(',') if r.strip()]
all_rules = list(dict.fromkeys(order + rules))
tg = [s for s in config.sections() if s.startswith('tabgroup_')]
print(f'  Total rules in [General] : {len(all_rules)}')
print(f'  TabGroup-managed rules   : {len(tg)}')
"
  fi
  echo -e "
================================================================="
  echo "  Diagnostic Complete."
  echo "================================================================="
}

do_uninstall() {
  echo "==> Safely removing Tab Group Integration..."
  if [ -f "$KWINRC" ]; then
    python3 -c "
import configparser, os, subprocess
path = os.path.expanduser('~/.config/kwinrulesrc')
if os.path.exists(path):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.optionxform = str
    config.read(path, encoding='utf-8')
    to_remove = [s for s in config.sections() if s.startswith('tabgroup_') or s == 'TabGroup-Work-Rule']
    for s in to_remove: config.remove_section(s)
    if config.has_section('General'):
        if config.has_option('General', 'Order'):
            order = [r.strip() for r in config.get('General', 'Order').split(',') if r.strip() and r not in to_remove]
            config.set('General', 'Order', ','.join(order))
        if config.has_option('General', 'rules'):
            rules = [r.strip() for r in config.get('General', 'rules').split(',') if r.strip() and r not in to_remove]
            config.set('General', 'rules', ','.join(rules))
            config.set('General', 'count', str(len(rules)))
    with open(path, 'w', encoding='utf-8') as f: config.write(f, space_around_delimiters=False)
    subprocess.run(['dbus-send', '--session', '--dest=org.kde.KWin', '/KWin', 'org.kde.KWin.reconfigure'], capture_output=True)
"
  fi
  rm -rf "$INSTALL_DIR" "$EXT_DIR"
  rm -f "$HOST_DIR/tabgroup_helper.json" "$XPI_UNSIGNED" /tmp/tabgroup_move_*.js /tmp/tabgroup_getdesk_*.js /tmp/tg_*.js
  echo "==> Uninstall complete. Remove the add-on from Firefox."
}

case "${1:-}" in
  -i|--install|-u|--update) do_install ;;
  -b|--build|--package) do_build ;;
  -t|--test|--diag) do_test ;;
  -r|--uninstall|--remove) do_uninstall ;;
  *) show_help ;;
esac
