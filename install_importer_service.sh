#!/usr/bin/env bash
set -euo pipefail

# Installer script for import_steam_to_sunshine.py and systemd service+timer
# Installs the Python script to /usr/local/bin/import_steam_to_sunshine.py
# Installs systemd units to /etc/systemd/system/
# Usage: sudo ./install_importer_service.sh

TARGET_PY="/usr/local/bin/import_steam_to_sunshine.py"
SERVICE_NAME="import_steam_to_sunshine.service"
TIMER_NAME="import_steam_to_sunshine.timer"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"

# Detect whether we're running as root or not. If not root, default to user-mode install.
IS_ROOT=false
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  IS_ROOT=true
fi

if [ "${IS_ROOT}" = false ]; then
  echo "Running as non-root: defaulting to per-user install mode (no system-wide changes)."
  echo "Use --system-mode when running as root to install system-wide units."
fi

# Optional: allow specifying the target user for the installed service
INSTALL_USER="${SUDO_USER:-}"
USER_MODE=0
SYSTEM_MODE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      shift
      INSTALL_USER="$1"
      shift
      ;;
    --sunshine-file)
      shift
      INSTALL_SUNSHINE_FILE="$1"
      shift
      ;;
    --user-mode)
      USER_MODE=1
      shift
      ;;
    --system-mode)
      SYSTEM_MODE=1
      shift
      ;;
    --help|-h)
      echo "Usage: ./install_importer_service.sh [--user <username>] [--sunshine-file <path>] [--user-mode|--system-mode]"
      echo "If run as non-root, the installer defaults to user-mode."
      echo "If --sunshine-file is relative or uses ~/, it will be converted to use systemd %h (home dir) in the unit."
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# Determine install mode: system vs user
if [ "${IS_ROOT}" = true ] ; then
  # running as root: default to system install unless user-mode forced
  if [ "${USER_MODE}" -eq 1 ]; then
    MODE="user"
  else
    MODE="system"
  fi
else
  # non-root cannot perform system install
  if [ "${SYSTEM_MODE}" -eq 1 ]; then
    echo "Error: --system-mode requires root. Re-run the installer with sudo for system-wide install."
    exit 1
  fi
  MODE="user"
fi

# If no explicit --user provided, pick a sensible default
if [ -z "${INSTALL_USER:-}" ]; then
  if [ "${MODE}" = "system" ]; then
    # when installing system-wide, default to the sudo user that invoked the script
    INSTALL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
  else
    # user-mode: default to the current user running the script
    INSTALL_USER="$(logname 2>/dev/null || echo $(id -un))"
  fi
fi

# Validate that the target user exists and discover their home directory
if ! getent passwd "${INSTALL_USER}" >/dev/null 2>&1; then
  echo "Error: user '${INSTALL_USER}' does not exist."
  exit 1
fi

INSTALL_USER_HOME=$(getent passwd "${INSTALL_USER}" | cut -d: -f6)
if [ -z "${INSTALL_USER_HOME}" ] || [ ! -d "${INSTALL_USER_HOME}" ]; then
  echo "Error: cannot determine home directory for user '${INSTALL_USER}' or home is inaccessible."
  exit 1
fi

# Adjust paths for user-mode vs system-mode
if [ "${MODE}" = "system" ]; then
  TARGET_PY="/usr/local/bin/import_steam_to_sunshine.py"
  SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
  TIMER_PATH="/etc/systemd/system/${TIMER_NAME}"
else
  TARGET_PY="${INSTALL_USER_HOME}/.local/bin/import_steam_to_sunshine.py"
  SERVICE_PATH="${INSTALL_USER_HOME}/.config/systemd/user/${SERVICE_NAME}"
  TIMER_PATH="${INSTALL_USER_HOME}/.config/systemd/user/${TIMER_NAME}"
fi

# Determine sunshine-file used by the generated unit. If user supplied a path, normalize:
# - paths starting with ~/  -> replace leading ~/ with %h/
# - paths starting with /   -> keep absolute
# - paths containing %h     -> keep as-is
# - other relative paths    -> prefix with %h/
INSTALL_SUNSHINE_FILE_UNIT="%h/.config/sunshine/apps.json"
if [ -n "${INSTALL_SUNSHINE_FILE:-}" ]; then
  if [[ "${INSTALL_SUNSHINE_FILE}" == ~/* ]]; then
    INSTALL_SUNSHINE_FILE_UNIT="%h/${INSTALL_SUNSHINE_FILE#~/}"
  elif [[ "${INSTALL_SUNSHINE_FILE}" == /* ]]; then
    INSTALL_SUNSHINE_FILE_UNIT="${INSTALL_SUNSHINE_FILE}"
  elif [[ "${INSTALL_SUNSHINE_FILE}" == *"%h"* ]]; then
    INSTALL_SUNSHINE_FILE_UNIT="${INSTALL_SUNSHINE_FILE}"
  else
    INSTALL_SUNSHINE_FILE_UNIT="%h/${INSTALL_SUNSHINE_FILE}"
  fi
fi


# Write the Python script
cat > "${TARGET_PY}" <<'PY'
#!/usr/bin/env python3
"""Import installed Steam games into a Sunshine apps JSON file.

Usage examples:
  python3 import_steam_to_sunshine.py --sunshine-file ~/.config/sunshine/apps.json
  python3 import_steam_to_sunshine.py --dry-run

Default Sunshine file: ~/.config/sunshine/apps.json
This script creates entries using `steam -applaunch <appid>` so Steam launches the game (works for native and Proton games).
"""

import argparse
import json
import os
import re
import shutil
import urllib.request
from pathlib import Path
from datetime import datetime, timezone


def find_steam_roots():
    candidates = [
        Path(os.path.expanduser('~')) / '.local' / 'share' / 'Steam',
        Path(os.path.expanduser('~')) / '.steam' / 'steam',
        Path(os.path.expanduser('~')) / '.steam' / 'root',
        Path(os.path.expanduser('~')) / '.var' / 'app' / 'com.valvesoftware.Steam' / 'data' / 'Steam',
    ]
    found = []
    for p in candidates:
        if p.exists():
            found.append(p)
    return found


def parse_libraryfolders(vdf_path):
    text = vdf_path.read_text(errors='ignore')
    paths = []
    # common style: "path" "C:\\..." entries
    paths += re.findall(r'"path"\s+"([^"]+)"', text)
    # fallback: lines like "1" "/path/to/library"
    paths += re.findall(r'"\d+"\s+"([^"]+)"', text)
    # normalize and deduplicate
    norm = []
    for p in paths:
        p2 = os.path.expandvars(os.path.expanduser(p))
        if p2 and p2 not in norm:
            norm.append(p2)
    return norm


def parse_appmanifest(manifest_path):
    text = manifest_path.read_text(errors='ignore')
    appid_m = re.search(r'"appid"\s+"(\d+)"', text)
    name_m = re.search(r'"name"\s+"([^"]+)"', text)
    installdir_m = re.search(r'"installdir"\s+"([^"]+)"', text)
    if not appid_m:
        return None
    appid = int(appid_m.group(1))
    name = name_m.group(1) if name_m else f"steam-{appid}"
    installdir = installdir_m.group(1) if installdir_m else None
    return {'appid': appid, 'name': name, 'installdir': installdir}


def load_existing_apps(sunshine_file):
    # Return a dict matching Sunshine file shape, e.g. { "apps": [ ... ], "env": { ... } }
    if not sunshine_file.exists():
        return {'apps': []}
    try:
        data = json.loads(sunshine_file.read_text())
        if isinstance(data, dict):
            if 'apps' in data and isinstance(data['apps'], list):
                return data
            # if it's a dict but missing apps, create one
            return {'apps': [], **{k: v for k, v in data.items() if k != 'apps'}}
        if isinstance(data, list):
            return {'apps': data}
    except Exception:
        pass
    return {'apps': []}


def write_apps(sunshine_file, data):
    sunshine_file.parent.mkdir(parents=True, exist_ok=True)
    # write as a Sunshine JSON object with an "apps" array
    sunshine_file.write_text(json.dumps(data, indent=2, ensure_ascii=False))


def build_entry(game, steamapps_path):
    # use steam -applaunch to ensure Steam launches the game (works with Proton)
    appid = game['appid']
    entry = {
        'name': game['name'],
        'cmd': [],
        'detached': [f'setsid steam steam://rungameid/{appid}'],
        'auto-detach': True,
        'elevated': False,
        'exclude-global-prep-cmd': False,
        'exit-timeout': 5,
        'image-path': '',
        'output': '',
        'wait-all': True,
        'category': 'Game',
        'steam_app_id': appid,
        'tags': ['steam'],
    }
    if game.get('installdir'):
        common = Path(steamapps_path) / 'common' / game['installdir']
        if common.exists():
            entry['working_dir'] = str(common)
    return entry


def main():
    p = argparse.ArgumentParser(description='Import installed Steam games into a Sunshine apps JSON.')
    p.add_argument('--sunshine-file', '-s', default=str(Path.home() / '.config' / 'sunshine' / 'apps.json'))
    p.add_argument('--steam-root', help='Optional Steam root directory (overrides autodetect)')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--backup', action='store_true', help='Backup existing Sunshine file to .bak')
    p.add_argument('--logs', action='store_true', help='Append a simple log of actions to ~/.config/sunshine/import_steam_to_sunshine.log')
    args = p.parse_args()

    sunshine_file = Path(os.path.expanduser(args.sunshine_file))

    steam_roots = []
    if args.steam_root:
        steam_roots = [Path(os.path.expanduser(args.steam_root))]
    else:
        steam_roots = find_steam_roots()

    if not steam_roots:
        print('No Steam root found. Try passing --steam-root')
        return

    library_paths = []
    for root in steam_roots:
        lf = root / 'steamapps' / 'libraryfolders.vdf'
        if lf.exists():
            library_paths += parse_libraryfolders(lf)
        # always include the primary steamapps
        library_paths.append(str(root / 'steamapps'))

    # deduplicate and normalize
    library_paths = [os.path.normpath(os.path.expanduser(p)) for p in dict.fromkeys(library_paths) if p]

    found_games = {}
    for lib in library_paths:
        steamapps = Path(lib)
        if not steamapps.exists():
            continue
        for mf in steamapps.glob('appmanifest_*.acf'):
            info = parse_appmanifest(mf)
            if not info:
                continue
            found_games[info['appid']] = {'info': info, 'steamapps': str(steamapps)}

    if not found_games:
        print('No installed Steam games found in detected libraries.')
        return

    existing_data = load_existing_apps(sunshine_file)
    existing_apps = existing_data.get('apps', [])
    existing_by_appid = {a.get('steam_app_id'): a for a in existing_apps if a.get('steam_app_id')}

    new_entries = []
    for appid, data in found_games.items():
        if appid in existing_by_appid:
            continue
        entry = build_entry(data['info'], data['steamapps'])
        new_entries.append(entry)

    # merged_apps should exist even when no new entries are found so icon refresh can run
    merged_apps = existing_apps + new_entries

    if not new_entries:
        msg = 'No new Steam games to add — all detected apps are already present in the Sunshine file.'
        print(msg)
        if args.logs:
            try:
                log_path = sunshine_file.parent / 'import_steam_to_sunshine.log'
                with open(log_path, 'a') as lf:
                    ts = datetime.now(timezone.utc).isoformat()
                    lf.write(f"{ts} - {msg}\n")
            except Exception:
                pass
        return

    if args.dry_run:
        print(f'Would add {len(new_entries)} entries to {sunshine_file}:')
        for e in new_entries:
            print(f"- {e['name']} (appid={e['steam_app_id']})")
        if args.logs:
            try:
                log_path = sunshine_file.parent / 'import_steam_to_sunshine.log'
                with open(log_path, 'a') as lf:
                    ts = datetime.now(timezone.utc).isoformat()
                    lf.write(f"{ts} - DRY-RUN - Would add {len(new_entries)} entries to {sunshine_file}:\n")
                    for e in new_entries:
                        lf.write(f"  - {e['name']} (appid={e['steam_app_id']})\n")
            except Exception:
                pass
        return

    # Ensure every app has an "image-path" key (leave empty by default so Sunshine can auto-download covers)
    for a in merged_apps:
        if 'image-path' not in a:
            a['image-path'] = ''

    # Merge into existing data structure
    merged_apps = existing_apps + new_entries
    merged_data = dict(existing_data)
    merged_data['apps'] = merged_apps

    # Always write a single apps.json (per-app-dir removed)
    if sunshine_file.exists() and args.backup:
        bak = sunshine_file.with_suffix(sunshine_file.suffix + '.bak')
        bak.write_text(sunshine_file.read_text())
    write_apps(sunshine_file, merged_data)

    # Optional simple logging
    if args.logs:
        log_path = sunshine_file.parent / 'import_steam_to_sunshine.log'
        try:
            with open(log_path, 'a') as lf:
                ts = datetime.now(timezone.utc).isoformat()
                lf.write(f"{ts} - Added {len(new_entries)} Steam games to {sunshine_file}\n")
        except Exception:
            pass

    print(f'Added {len(new_entries)} Steam games to {sunshine_file}')


if __name__ == '__main__':
    main()
PY

chmod 755 "${TARGET_PY}"

# Create systemd service and timer units (mode-aware)
mkdir -p "$(dirname "${SERVICE_PATH}")"
cat > "${SERVICE_PATH}" <<SERVICE
[Unit]
Description=Import Steam games into Sunshine apps.json
After=network.target

[Service]
Type=oneshot
# When installing system-wide we run the unit as the target user; for user-mode, the unit is a per-user unit and must NOT contain a User= line
$( [ "${MODE}" = "system" ] && echo "User=${INSTALL_USER}" || true )
WorkingDirectory=%h
ExecStart=${TARGET_PY} --backup --logs --sunshine-file ${INSTALL_SUNSHINE_FILE_UNIT}

SERVICE

# Create timer unit
mkdir -p "$(dirname "${TIMER_PATH}")"
cat > "${TIMER_PATH}" <<TIMER
[Unit]
Description=Run import_steam_to_sunshine every 60s

[Timer]
OnUnitActiveSec=60
Unit=${SERVICE_NAME}
Persistent=true

[Install]
WantedBy=timers.target

TIMER

# Reload and enable the units
if [ "${MODE}" = "system" ]; then
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" || true
  systemctl enable --now "${TIMER_NAME}"
  echo "Installed ${TARGET_PY}"
  echo "Installed systemd unit: ${SERVICE_PATH} and timer: ${TIMER_PATH} (system-wide)"
  echo "Service will run as user: ${INSTALL_USER} (uses %h to refer to home directory in the unit)."
  echo "Timer started and enabled; it will run every 60 seconds."
else
  # user mode: try to reload and enable via the target user's systemd --user; may fail if the user has no active systemd user instance
  if su - "${INSTALL_USER}" -c "systemctl --user daemon-reload" >/dev/null 2>&1; then
    su - "${INSTALL_USER}" -c "systemctl --user enable --now ${TIMER_NAME}" || true
    echo "Installed ${TARGET_PY}"
    echo "Installed per-user systemd unit: ${SERVICE_PATH} and timer: ${TIMER_PATH} (user-mode)"
    echo "Attempted to enable and start the timer via systemctl --user for ${INSTALL_USER}; if you see failures, run 'systemctl --user enable --now ${TIMER_NAME}' as ${INSTALL_USER} or ensure the user has a running user systemd session."
  else
    echo "Installed ${TARGET_PY}"
    echo "Installed per-user systemd unit: ${SERVICE_PATH} and timer: ${TIMER_PATH} (user-mode)"
    echo "Note: could not contact ${INSTALL_USER}'s systemd user instance to enable the timer. To enable it, run as that user: 'systemctl --user daemon-reload && systemctl --user enable --now ${TIMER_NAME}'."
  fi
fi

echo "Installation complete."

