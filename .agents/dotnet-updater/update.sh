#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dotnet-updater update.sh — Update .NET target frameworks
# Updates .csproj files, IDE config, and docs to a target .NET version.
# Usage: ./update.sh [--target <version>] [--dry-run] [--force] [--no-stash]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"

# --- Defaults ---
TARGET_VERSION=""
DRY_RUN=false
FORCE=false
NO_STASH=false

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --no-stash)
      NO_STASH=true
      shift
      ;;
    -h|--help)
      echo "Usage: update.sh [--target <version>] [--dry-run] [--force] [--no-stash]"
      echo ""
      echo "Options:"
      echo "  --target <version>   Target .NET version (e.g., '10.0'). Auto-detected if omitted."
      echo "  --dry-run            Show what would change without modifying files."
      echo "  --force              Continue even if working tree is not clean."
      echo "  --no-stash           Skip creating a git stash (revert point)."
      echo "  -h                   Show this help."
      echo ""
      echo "Revert: git stash pop"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: update.sh [--target <version>] [--dry-run] [--force] [--no-stash]"
      exit 1
      ;;
  esac
done

# --- Helper: get latest stable .NET version from GitHub API ---
get_latest_stable_dotnet() {
  local api_response=""
  if command -v gh &> /dev/null; then
    api_response="$(gh api repos/dotnet/sdk/releases?per_page=20 2>/dev/null)" || true
  fi
  if [[ -z "$api_response" ]]; then
    api_response="$(curl -s -f 'https://api.github.com/repos/dotnet/sdk/releases?per_page=20' 2>/dev/null)" || true
  fi
  if [[ -z "$api_response" ]]; then
    echo ""
    return
  fi
  local version
  version=$(echo "$api_response" | grep -B5 '"prerelease": false' | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/' | sed 's/-.*//')
  if [[ -n "$version" ]]; then
    echo "$version" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/'
  else
    echo ""
  fi
}

# --- Helper: extract XML tag value ---
xml_tag_value() {
  local file="$1"
  local tag="$2"
  sed -n "s/.*<${tag}>\([^<]*\)<\/${tag}>.*/\1/p" "$file" 2>/dev/null | head -1
}

# =============================================================================
# PHASE 1: Resolve target version
# =============================================================================
if [[ -z "$TARGET_VERSION" ]]; then
  echo "Auto-detecting latest stable .NET version..."
  TARGET_VERSION=$(get_latest_stable_dotnet)
  if [[ -z "$TARGET_VERSION" ]]; then
    echo "ERROR: Could not determine latest stable .NET version."
    echo "Specify manually: update.sh --target <version>"
    exit 1
  fi
  echo "Latest stable: .NET ${TARGET_VERSION}"
fi

# Validate version format (major.minor)
if ! echo "$TARGET_VERSION" | grep -q '^[0-9]*\.[0-9]*$'; then
  echo "ERROR: Invalid version format '${TARGET_VERSION}'. Expected: major.minor (e.g., '10.0')"
  exit 1
fi

TARGET_TFM="net${TARGET_VERSION}"

echo ""
echo "Target: .NET ${TARGET_VERSION} (${TARGET_TFM})"
if $DRY_RUN; then
  echo "Mode: DRY RUN (no files will be modified)"
else
  echo "Mode: LIVE (files will be modified)"
fi
echo ""

# =============================================================================
# PHASE 2: Check working tree cleanliness
# =============================================================================
if ! $FORCE && ! $DRY_RUN; then
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "ERROR: Working tree is not clean. Commit or stash your changes first."
    echo "  Or use --force to override."
    echo ""
    echo "Uncommitted changes:"
    git status --short
    exit 1
  fi
fi

# =============================================================================
# PHASE 3: Find all .csproj files
# =============================================================================
CSPROJ_FILES=()
while IFS= read -r -d '' file; do
  CSPROJ_FILES+=("$file")
done < <(find "$REPO_ROOT" -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*" -not -path "*/.git/*" -print0 2>/dev/null)

if [[ ${#CSPROJ_FILES[@]} -eq 0 ]]; then
  echo "No .csproj files found in ${REPO_ROOT}"
  exit 0
fi

echo "Found ${#CSPROJ_FILES[@]} project(s)"
echo ""

# =============================================================================
# PHASE 4: Create stash (revert point)
# =============================================================================
STASH_NAME="pre-dotnet-updater-$(date +%Y%m%d-%H%M%S)"

if ! $DRY_RUN && ! $NO_STASH; then
  if command -v git &> /dev/null && git rev-parse --git-dir &> /dev/null 2>&1; then
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
      echo "Creating git stash: '${STASH_NAME}'"
      git stash push -m "$STASH_NAME" --include-untracked 2>/dev/null || true
      echo "  Revert with: git stash pop"
      echo ""
    else
      echo "Working tree clean, no stash needed."
      echo ""
    fi
  fi
fi

# =============================================================================
# PHASE 5: Update .csproj files
# =============================================================================
CHANGES=()

for csproj in "${CSPROJ_FILES[@]}"; do
  rel_path="${csproj#$REPO_ROOT/}"

  # Get current TFM
  current_tfm=$(xml_tag_value "$csproj" "TargetFramework")
  current_tfm_multi=$(sed -n 's/.*<TargetFrameworks>\([^<]*\)<\/TargetFrameworks>.*/\1/p' "$csproj" 2>/dev/null | head -1)

  if [[ -n "$current_tfm_multi" ]]; then
    echo "SKIP ${rel_path}: multi-target project (${current_tfm_multi}) -- manual update required"
    continue
  fi

  if [[ -z "$current_tfm" ]]; then
    echo "SKIP ${rel_path}: no <TargetFramework> found"
    continue
  fi

  if [[ "$current_tfm" == "$TARGET_TFM" ]]; then
    echo "OK   ${rel_path}: already at ${TARGET_TFM}"
    continue
  fi

  # Perform replacement
  if $DRY_RUN; then
    echo "WILL ${rel_path}: ${current_tfm} -> ${TARGET_TFM}"
  else
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "s|<TargetFramework>${current_tfm}</TargetFramework>|<TargetFramework>${TARGET_TFM}</TargetFramework>|" "$csproj"
    else
      sed -i "s|<TargetFramework>${current_tfm}</TargetFramework>|<TargetFramework>${TARGET_TFM}</TargetFramework>|" "$csproj"
    fi
    echo "DONE ${rel_path}: ${current_tfm} -> ${TARGET_TFM}"
  fi
  CHANGES+=("${rel_path}|${current_tfm}|${TARGET_TFM}")
done

echo ""

# =============================================================================
# PHASE 6: Update .vscode/launch.json
# =============================================================================
LAUNCH_JSON="$REPO_ROOT/.vscode/launch.json"
if [[ -f "$LAUNCH_JSON" ]]; then
  hardcoded_versions=$(grep -o 'net[0-9]*\.[0-9]*' "$LAUNCH_JSON" 2>/dev/null | sort -u)
  if [[ -n "$hardcoded_versions" ]]; then
    while IFS= read -r old_version; do
      if [[ "$old_version" != "$TARGET_TFM" ]]; then
        if $DRY_RUN; then
          echo "WILL .vscode/launch.json: ${old_version} -> ${TARGET_TFM}"
        else
          if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|${old_version}|${TARGET_TFM}|g" "$LAUNCH_JSON"
          else
            sed -i "s|${old_version}|${TARGET_TFM}|g" "$LAUNCH_JSON"
          fi
          echo "DONE .vscode/launch.json: ${old_version} -> ${TARGET_TFM}"
        fi
        CHANGES+=(".vscode/launch.json|${old_version}|${TARGET_TFM}")
      fi
    done <<< "$hardcoded_versions"
  fi
fi

# =============================================================================
# PHASE 7: Update README.md
# =============================================================================
README_FILE="$REPO_ROOT/README.md"
if [[ -f "$README_FILE" ]]; then
  readme_versions=$(grep -o '\.NET [0-9]*\.[0-9]*' "$README_FILE" 2>/dev/null | sort -u)
  if [[ -n "$readme_versions" ]]; then
    while IFS= read -r readme_ver; do
      readme_major_minor=$(echo "$readme_ver" | sed 's/\.NET //')
      if [[ "$readme_major_minor" != "$TARGET_VERSION" ]]; then
        old_dotnet_ver=".NET ${readme_major_minor}"
        new_dotnet_ver=".NET ${TARGET_VERSION}"
        if $DRY_RUN; then
          echo "WILL README.md: ${old_dotnet_ver} -> ${new_dotnet_ver}"
        else
          if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|\.NET ${readme_major_minor}|\.NET ${TARGET_VERSION}|g" "$README_FILE"
          else
            sed -i "s|\.NET ${readme_major_minor}|\.NET ${TARGET_VERSION}|g" "$README_FILE"
          fi
          echo "DONE README.md: ${old_dotnet_ver} -> ${new_dotnet_ver}"
        fi
        CHANGES+=("README.md|${old_dotnet_ver}|${new_dotnet_ver}")
      fi
    done <<< "$readme_versions"
  fi

  # Update SDK version mentions (case-insensitive)
  sdk_versions=$(grep -oi 'SDK [0-9]*\.[0-9]*' "$README_FILE" 2>/dev/null | sort -u)
  if [[ -n "$sdk_versions" ]]; then
    while IFS= read -r sdk_ver; do
      sdk_major_minor=$(echo "$sdk_ver" | sed 's/[Ss][Dd][Kk] //')
      if [[ "$sdk_major_minor" != "$TARGET_VERSION" ]]; then
        if $DRY_RUN; then
          echo "WILL README.md: SDK ${sdk_major_minor} -> SDK ${TARGET_VERSION}"
        else
          if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|[Ss][Dd][Kk] ${sdk_major_minor}|SDK ${TARGET_VERSION}|g" "$README_FILE"
          else
            sed -i "s|[Ss][Dd][Kk] ${sdk_major_minor}|SDK ${TARGET_VERSION}|g" "$README_FILE"
          fi
          echo "DONE README.md: SDK ${sdk_major_minor} -> SDK ${TARGET_VERSION}"
        fi
        CHANGES+=("README.md|SDK ${sdk_major_minor}|SDK ${TARGET_VERSION}")
      fi
    done <<< "$sdk_versions"
  fi
fi

# =============================================================================
# PHASE 8: Warn about legacy files (do not delete)
# =============================================================================
LEGACY_FILES=()
while IFS= read -r -d '' file; do
  LEGACY_FILES+=("${file#$REPO_ROOT/}")
done < <(find "$REPO_ROOT" \( -name "packages.config" -o -name "*.nuspec" \) -not -path "*/.git/*" -print0 2>/dev/null)

if [[ ${#LEGACY_FILES[@]} -gt 0 ]]; then
  echo ""
  echo "WARNING: Legacy files found (not deleted):"
  for f in "${LEGACY_FILES[@]}"; do
    echo "  - ${f}"
  done
fi

# =============================================================================
# PHASE 9: Restore and verify
# =============================================================================
if ! $DRY_RUN && [[ ${#CHANGES[@]} -gt 0 ]]; then
  echo ""
  echo "Running dotnet restore..."
  if dotnet restore --verbosity quiet > /dev/null 2>&1; then
    echo "Restore: OK"
  else
    echo "Restore: FAILED -- review changes with: git diff"
    exit 1
  fi

  echo "Running dotnet build..."
  build_output=$(dotnet build --verbosity quiet --no-restore 2>&1) || true
  if echo "$build_output" | grep -q "Build succeeded"; then
    echo "Build:   OK"
  else
    echo "Build:   FAILED -- review changes with: git diff"
    echo "$build_output" | tail -10
    exit 1
  fi
fi

# =============================================================================
# PHASE 10: Summary
# =============================================================================
echo ""
echo "=============================================="
echo "  .NET Update Summary"
echo "=============================================="
echo "  Target:  .NET ${TARGET_VERSION} (${TARGET_TFM})"
echo "  Mode:    $(if $DRY_RUN; then echo "DRY RUN"; else echo "LIVE"; fi)"
echo "  Changes: ${#CHANGES[@]}"
echo "=============================================="

if [[ ${#CHANGES[@]} -gt 0 ]]; then
  echo ""
  echo "| File | Old | New |"
  echo "|------|-----|-----|"
  for change in "${CHANGES[@]}"; do
    IFS='|' read -r file old new <<< "$change"
    echo "| ${file} | ${old} | ${new} |"
  done
fi

if ! $DRY_RUN && [[ ${#CHANGES[@]} -gt 0 ]]; then
  echo ""
  echo "Next steps:"
  echo "  1. Review:   git diff"
  echo "  2. Test:     dotnet test"
  echo "  3. Commit:   git add -A && git commit -m 'chore: update .NET to ${TARGET_VERSION}'"
  echo ""
  echo "Revert: git stash pop"
fi
