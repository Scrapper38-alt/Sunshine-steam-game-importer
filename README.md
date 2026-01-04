# Sunshine-steam-game-importer
A tool/service to import Steam games into Sunshines application system

# import_steam_to_sunshine 🕹️➡️☀️

A small utility to import installed Steam games into a Sunshine `apps.json` file and keep it up to date. This repository contains an installer script that can set up a systemd service + timer to run the importer periodically. Only testet on linux.

## Features ✅
- Scans Steam libraries and `appmanifest_*.acf` files for installed games
- Creates Sunshine app entries using `steam://rungameid/<appid>` (detached)
- Supports `--dry-run`, `--backup` and `--logs` options
- Optional installer script to install a systemd service and timer that runs every 60s

## Quick start 🔧
Clone this repository (or copy the files) and run the importer in dry-run to see what would change:

```bash
python3 "import_steam_to_sunshine.py" --dry-run
```

To write changes to your Sunshine file (creates a `.bak` if `--backup` is specified):

```bash
python3 "import_steam_to_sunshine.py" --backup --logs
```

### Install (system-wide or per-user)
The installer supports two modes:

- **System-wide** (requires root): writes files under `/usr/local/bin` and `/etc/systemd/system`. Run with sudo and use `--system-mode` (or run as root without `--user-mode`).

  ```bash
  cd "/path/to/repo"
  sudo ./install_importer_service.sh --system-mode --user <your-username>
  ```

- **Per-user** (no root required): writes to `~/.local/bin` and `~/.config/systemd/user/`. When run without sudo, the installer defaults to per-user mode; you can also pass `--user-mode` to be explicit.

  ```bash
  # install for the current user (no sudo)
  ./install_importer_service.sh
  # or be explicit
  ./install_importer_service.sh --user-mode
  ```

Notes:
- The installer accepts `--user <username>` (defaults to the invoking user for per-user installs or the sudo user when running as root), and `--sunshine-file` to target a non-default Sunshine file.
- On per-user installs, the script will attempt to enable the timer via `systemctl --user`; this can fail if the user has no active systemd user instance. If that happens, enable it manually as the target user:

```bash
systemctl --user daemon-reload && systemctl --user enable --now import_steam_to_sunshine.timer
```

## CLI flags ⚙️
- `--sunshine-file`, `-s`: Path to the Sunshine `apps.json` (default `~/.config/sunshine/apps.json`)  
- `--steam-root`: Optional Steam root directory (overrides autodetect)  
- `--dry-run`: Show what would be added (no writes)  
- `--backup`: When writing, create a `.bak` backup of the previous file  
- `--logs`: Append a simple timestamped message to `~/.config/sunshine/import_steam_to_sunshine.log`  
- `--user-mode`: Force a per-user install (writes to `~/.local/bin` and `~/.config/systemd/user/`)  
- `--system-mode`: Force a system-wide install (requires root)
(As of right now a few of this flags are only supported when running the .py manually)

## Logging
If `--logs` is used, the script appends timestamped messages to `~/.config/sunshine/import_steam_to_sunshine.log` (ISO 8601, UTC). It also writes messages during dry-run and when there are no new apps found.


## Contributing 💡
Contributions welcome. Please open issues or PRs with small, focused changes. Be sure not to include secrets or personal data in commits.

## License
This project is available under the MIT License — see `LICENSE`
