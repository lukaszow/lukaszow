# dotnet-updater

Reusable agent and scripts for updating .NET target frameworks across projects.

## What it does

1. **Scans** your repo — finds all `.csproj` files, checks TFMs, detects inconsistencies
2. **Updates** — changes `TargetFramework` in `.csproj`, fixes hardcoded paths in IDE config, updates docs
3. **Verifies** — runs `dotnet restore` and `dotnet build` after changes
4. **Protects** — creates a git stash before any change (instant revert)

## Files

| File | Purpose |
|------|---------|
| `AGENT.md` | Instructions for AI agents (opencode, Copilot, etc.) — load as context |
| `scan.sh` | Read-only discovery script — generates a report |
| `update.sh` | Update script — applies changes to files |
| `README.md` | This file |

## Quick start

### Scan your project

```bash
cd /path/to/your/dotnet/project
/path/to/dotnet-updater/scan.sh
```

Or if using a symlink:

```bash
./.agents/scan.sh
```

### Update to latest stable

```bash
./.agents/update.sh
```

### Update to specific version

```bash
./.agents/update.sh --target 10.0
```

### Preview changes (dry run)

```bash
./.agents/update.sh --target 10.0 --dry-run
```

### Revert changes

```bash
git stash pop
```

## Setup: symlink in your project

Create a symlink so scripts are accessible from any project:

```bash
cd /path/to/your/project
ln -s /path/to/dotnet-updater .agents
```

Then use:
- `./.agents/scan.sh`
- `./.agents/update.sh`
- `@.agents/AGENT.md` (for AI agent context)

## Using with an AI agent

1. Open your project in opencode (or similar)
2. Reference the agent instructions: `@/path/to/dotnet-updater/AGENT.md`
3. Say: "Scan this project and update to latest .NET"

The agent will follow the workflow in `AGENT.md`.

## Script options

### scan.sh

| Option | Description |
|--------|-------------|
| `--json` | Output in JSON format instead of markdown |
| `-h` | Show help |

### update.sh

| Option | Description |
|--------|-------------|
| `--target <version>` | Target .NET version (e.g., `10.0`). Auto-detected if omitted. |
| `--dry-run` | Show what would change without modifying files |
| `--force` | Continue even if working tree is not clean |
| `--no-stash` | Skip creating a git stash |
| `-h` | Show help |

## Requirements

- bash (macOS/Linux/WSL/Git Bash on Windows)
- git
- curl or `gh` CLI (for fetching latest .NET version)
- dotnet SDK (for restore/build verification)

## What it updates

| File type | What changes |
|-----------|-------------|
| `*.csproj` | `<TargetFramework>` value |
| `.vscode/launch.json` | Hardcoded `netX.Y` paths |
| `README.md` | Mentions of `.NET X.Y` and `SDK X.Y` |

## What it does NOT do

- Delete files (legacy `packages.config` are flagged, not removed)
- Commit or push changes
- Update multi-target projects (flagged for manual update)
- Update to preview/prerelease versions without explicit confirmation
- Modify `global.json` (flagged if present)
