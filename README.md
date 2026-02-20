# Universal One-Way Git Mirror Script

Continuously mirrors Git repositories from any source to any destination using SSH URLs.

> **WARNING — Destructive Mirror:** This script uses `git push --mirror`, which **force-pushes** the source state to the destination every cycle. Any commits, branches, or tags pushed directly to a destination repository **will be permanently overwritten**. Only use this when the destination is a read-only replica of the source.

## Features

- **Platform-agnostic** — works with any Git host (GitHub, GitLab, Bitbucket, self-hosted, etc.)
- **SSH-only** — all operations use SSH URLs
- **Continuous** — runs in an infinite loop with a configurable sleep interval
- **Retry mechanism** — network-dependent Git commands are retried up to 3 times with a 5-second delay
- **JSON config** — repositories defined in a simple JSON file, validated at startup
- **Safe directory handling** — all Git operations run in subshells to prevent working-directory corruption

## Prerequisites

- **Bash** (4.0+)
- **Git**
- **[jq](https://jqlang.github.io/jq/)** — for parsing the JSON config
- **SSH keys** configured for both source and destination hosts

## Quick Start

1. **Clone this repo:**
   ```bash
   git clone git@github.com:your-org/universal-Git-One-Way-Mirror-Script.git
   cd universal-Git-One-Way-Mirror-Script
   ```

2. **Copy the example config and edit it** with your source → destination mappings:
   ```bash
   cp repos.json.example repos.json
   ```
   Then edit `repos.json` (see [repos.json.example](repos.json.example) for the format):
   ```json
   {
     "repos": [
       {
         "source": "git@bitbucket.org:myorg/my-repo.git",
         "destination": "git@github.com:myorg/my-repo.git"
       }
     ]
   }
   ```
   > `repos.json` is gitignored so your real SSH URLs are never committed.

3. **Run the script:**
   ```bash
   chmod +x sync_repos.sh
   ./sync_repos.sh --config repos.json
   ```

## Configuration

All settings are passed as CLI flags:

| Flag | Required | Default | Description |
|---|---|---|---|
| `-c, --config <path>` | **Yes** | — | Path to the JSON config file |
| `-d, --sync-dir <path>` | No | `/tmp/git-mirrors` | Directory for bare mirror clones |
| `-i, --interval <secs>` | No | `300` (5 min) | Seconds between sync cycles |
| `-h, --help` | No | — | Show usage and exit |

Examples:
```bash
# Minimal — just the config file
./sync_repos.sh --config repos.json

# All options
./sync_repos.sh --config /path/to/repos.json --sync-dir /opt/mirrors --interval 60

# Short flags
./sync_repos.sh -c repos.json -d /opt/mirrors -i 60
```

## `repos.json` Format

```json
{
  "repos": [
    {
      "source": "git@source-host:org/repo.git",
      "destination": "git@dest-host:org/repo.git"
    }
  ]
}
```

Each object in the `repos` array must have:
- `source` — SSH URL of the upstream (authoritative) repository
- `destination` — SSH URL of the mirror (replica) repository

The config is loaded once at startup. To pick up changes, restart the script.

## How It Works

1. **Clone** — If a local bare mirror doesn't exist yet, `git clone --mirror <source>` creates one.
2. **Fetch** — `git fetch -p origin` pulls all updates and prunes deleted remote branches.
3. **Push** — `git push --mirror <destination>` force-pushes all refs to the destination, making it an exact 1:1 replica of the source.
4. **Sleep** — Waits `--interval` seconds, then repeats.

## License

MIT
