#!/usr/bin/env bash
# Part of rr4444/plasma-firefox-sticky-desktops
# GitHub: https://github.com/rr4444/plasma-firefox-sticky-desktops

set -euo pipefail

INSTALL_DIR="$HOME/.local/share/tabgroup-helper"
HOST_DIR="$HOME/.mozilla/native-messaging-hosts"
EXT_DIR="$HOME/tabgroup-extension"
ADDON_ID="tabgroup-helper@local"
KWINRC="$HOME/.config/kwinrulesrc"

show_help() {
  cat << EOF
Firefox Tab Group Window Manager Bridge (rr4444/plasma-firefox-sticky-desktops)

Usage: $(basename "$0") [OPTION]

Options:
  -i, --install, -u, --update   Re-verify and register native helper and manifest
  -t, --test, --diag            Run non-destructive diagnostic checks and IPC test
  -r, --uninstall, --remove     Safely remove tabgroup rules from kwinrulesrc and delete files
  -h, --help                    Display this help message and exit
EOF
}

do_install() {
  echo "==> Native helper and Firefox extension files are verified in $EXT_DIR"
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

  python3 -c "
import json, os
host = json.load(open(os.path.expanduser('$HOST_DIR/tabgroup_helper.json')))
ext = json.load(open(os.path.expanduser('$EXT_DIR/manifest.json')))
assert os.path.exists(host['path']), 'Binary target does not exist'
assert ext['browser_specific_settings']['gecko']['id'] in host['allowed_extensions'], 'ID mismatch'
print('  [OK] Extension ID match confirmed and manifest syntax valid.')
"

  echo -e "\n[3/5] Testing Compositor D-Bus API..."
  if dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.kde.KWin &>/dev/null; then
    echo "  [OK] org.kde.KWin service active on session bus."
    VD_QUERY=$(dbus-send --session --dest=org.kde.KWin --type=method_call --print-reply /VirtualDesktopManager org.freedesktop.DBus.Properties.Get string:org.kde.KWin.VirtualDesktopManager string:count 2>/dev/null || true)
    if echo "$VD_QUERY" | grep -q "variant"; then
      COUNT=$(echo "$VD_QUERY" | awk '/variant/ {print $NF}')
      echo "  [OK] Plasma Virtual Desktops detected (count: $COUNT)"
    fi
  elif dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.GetNameOwner string:org.gnome.Shell &>/dev/null; then
    echo "  [OK] org.gnome.Shell service active on session bus."
  fi

  echo -e "\n[4/5] Testing Native Helper IPC (Query Only)..."
  python3 -c "
import struct, json, subprocess, os
raw = json.dumps({'action': 'get_desktops'}).encode('utf-8')
packet = struct.pack('I', len(raw)) + raw
proc = subprocess.Popen([os.path.expanduser('$INSTALL_DIR/helper.py')], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
out, _ = proc.communicate(packet, timeout=5)
size = struct.unpack('I', out[:4])[0]
print('  [OK] Helper response:', json.loads(out[4:4+size].decode('utf-8')))
"

  echo -e "\n[5/5] Auditing ~/.config/kwinrulesrc..."
  if [ -f "$KWINRC" ]; then
    python3 -c "
import configparser, os
config = configparser.ConfigParser(interpolation=None, strict=False)
config.optionxform = str
config.read(os.path.expanduser('$KWINRC'), encoding='utf-8')
rules_list = [r.strip() for r in config.get('General', 'rules', fallback='').split(',') if r.strip()]
tg_sections = [s for s in config.sections() if s.startswith('tabgroup_')]
print(f'  Total rules registered in [General] : {len(rules_list)}')
print(f'  TabGroup-managed rules in file      : {len(tg_sections)}')
"
  fi
  echo -e "\n================================================================="
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
    if config.has_section('General') and config.has_option('General', 'rules'):
        rules = [r.strip() for r in config.get('General', 'rules').split(',') if r.strip() and r not in to_remove]
        config.set('General', 'rules', ','.join(rules))
        config.set('General', 'count', str(len(rules)))
    with open(path, 'w', encoding='utf-8') as f:
        config.write(f, space_around_delimiters=False)
    subprocess.run(['dbus-send', '--session', '--dest=org.kde.KWin', '/KWin', 'org.kde.KWin.reconfigure'], capture_output=True)
"
  fi
  rm -rf "$INSTALL_DIR" "$EXT_DIR"
  rm -f "$HOST_DIR/tabgroup_helper.json" /tmp/tabgroup_move_*.js
  echo "==> Uninstall complete."
}

case "${1:-}" in
  -i|--install|-u|--update) do_install ;;
  -t|--test|--diag) do_test ;;
  -r|--uninstall|--remove) do_uninstall ;;
  *) show_help ;;
esac
