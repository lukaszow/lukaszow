#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dotnet-updater scan.sh — Discovery script for .NET projects
# Scans the current directory, generates a report of .NET versions and issues.
# Usage: ./scan.sh [--json]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(pwd)"
OUTPUT_JSON=false

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT_JSON=true ;;
    -h|--help)
      echo "Usage: scan.sh [--json]"
      echo ""
      echo "Scans the current directory for .NET project files and generates a report."
      echo ""
      echo "Options:"
      echo "  --json    Output report in JSON format (default: markdown)"
      echo "  -h        Show this help"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      echo "Usage: scan.sh [--json]"
      exit 1
      ;;
  esac
done

# --- Helper: extract value from XML tag (no -P dependency) ---
xml_tag_value() {
  local file="$1"
  local tag="$2"
  sed -n "s/.*<${tag}>\([^<]*\)<\/${tag}>.*/\1/p" "$file" 2>/dev/null | head -1
}

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
    echo "unknown"
    return
  fi

  # Extract latest non-prerelease version tag
  local version
  version=$(echo "$api_response" | grep -B5 '"prerelease": false' | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/' | sed 's/-.*//')

  if [[ -n "$version" ]]; then
    # Extract major.minor (e.g., "10.0" from "10.0.200")
    echo "$version" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/'
  else
    echo "unknown"
  fi
}

# =============================================================================
# PHASE 1: Find all .csproj files
# =============================================================================
CSPROJ_FILES=()
while IFS= read -r -d '' file; do
  CSPROJ_FILES+=("$file")
done < <(find "$REPO_ROOT" -name "*.csproj" -not -path "*/bin/*" -not -path "*/obj/*" -not -path "*/.git/*" -print0 2>/dev/null)

if [[ ${#CSPROJ_FILES[@]} -eq 0 ]]; then
  echo "No .csproj files found in ${REPO_ROOT}"
  exit 0
fi

# =============================================================================
# PHASE 2: Scan each .csproj
# =============================================================================
declare -a PROJECT_NAMES=()
declare -a PROJECT_PATHS=()
declare -a PROJECT_TFMS=()
declare -a PROJECT_TFM_RAW=()
declare -a PROJECT_OUTPUT_TYPES=()
declare -a PROJECT_PACKAGES=()
declare -a PROJECT_ISSUES=()

for csproj in "${CSPROJ_FILES[@]}"; do
  project_name="$(basename "$csproj" .csproj)"
  rel_path="${csproj#$REPO_ROOT/}"

  tfm_raw=$(xml_tag_value "$csproj" "TargetFramework")
  tfm_multi=$(sed -n 's/.*<TargetFrameworks>\([^<]*\)<\/TargetFrameworks>.*/\1/p' "$csproj" 2>/dev/null | head -1)

  if [[ -n "$tfm_multi" ]]; then
    tfm_raw="$tfm_multi"
    tfm_display="$tfm_multi (multi)"
  else
    tfm_display="$tfm_raw"
  fi

  # Extract major.minor from TFM
  tfm_version=$(echo "$tfm_raw" | sed -n 's/.*net\([0-9]*\.[0-9]*\).*/\1/p' | head -1)

  output_type=$(xml_tag_value "$csproj" "OutputType")

  # Extract PackageReferences
  packages=$(sed -n 's/.*<PackageReference Include="\([^"]*\)" Version="\([^"]*\)".*/\1@\2/p' "$csproj" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

  PROJECT_NAMES+=("$project_name")
  PROJECT_PATHS+=("$rel_path")
  PROJECT_TFMS+=("$tfm_version")
  PROJECT_TFM_RAW+=("$tfm_display")
  PROJECT_OUTPUT_TYPES+=("${output_type:-Library}")
  PROJECT_PACKAGES+=("${packages:-none}")
  PROJECT_ISSUES+=("")
done

# =============================================================================
# PHASE 3: Check for consistency across projects
# =============================================================================
if [[ ${#PROJECT_TFMS[@]} -gt 1 ]]; then
  first_tfm="${PROJECT_TFMS[0]}"
  for i in "${!PROJECT_TFMS[@]}"; do
    if [[ "${PROJECT_TFMS[$i]}" != "$first_tfm" ]]; then
      for j in "${!PROJECT_ISSUES[@]}"; do
        PROJECT_ISSUES[$j]="inconsistent"
      done
      break
    fi
  done
fi

# =============================================================================
# PHASE 4: Check for global.json
# =============================================================================
GLOBAL_JSON_INFO="none"
if [[ -f "$REPO_ROOT/global.json" ]]; then
  sdk_version=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$REPO_ROOT/global.json" | head -1)
  roll_forward=$(sed -n 's/.*"rollForward" *: *"\([^"]*\)".*/\1/p' "$REPO_ROOT/global.json" | head -1)
  GLOBAL_JSON_INFO="SDK: ${sdk_version:-unknown}, rollForward: ${roll_forward:-default}"
fi

# =============================================================================
# PHASE 5: Find legacy files
# =============================================================================
LEGACY_FILES=()
while IFS= read -r -d '' file; do
  LEGACY_FILES+=("${file#$REPO_ROOT/}")
done < <(find "$REPO_ROOT" \( -name "packages.config" -o -name "*.nuspec" \) -not -path "*/.git/*" -print0 2>/dev/null)

# =============================================================================
# PHASE 6: Check IDE config files for hardcoded .NET paths
# =============================================================================
IDE_ISSUES=()

if [[ -f "$REPO_ROOT/.vscode/launch.json" ]]; then
  hardcoded_paths=$(grep -o 'net[0-9]*\.[0-9]*' "$REPO_ROOT/.vscode/launch.json" 2>/dev/null | sort -u)
  if [[ -n "$hardcoded_paths" ]]; then
    while IFS= read -r path_version; do
      path_tfm="${path_version#net}"
      found=false
      for tfm in "${PROJECT_TFMS[@]}"; do
        if [[ "$tfm" == "$path_tfm" ]]; then found=true; break; fi
      done
      if ! $found; then
        IDE_ISSUES+=(".vscode/launch.json references ${path_version} but projects use: $(IFS=', '; echo "${PROJECT_TFM_RAW[*]}")")
      fi
    done <<< "$hardcoded_paths"
  fi
fi

# =============================================================================
# PHASE 7: Check README for .NET version mentions
# =============================================================================
README_ISSUES=()
if [[ -f "$REPO_ROOT/README.md" ]]; then
  readme_versions=$(grep -o '\.NET [0-9]*\.[0-9]*' "$REPO_ROOT/README.md" 2>/dev/null | sort -u)
  if [[ -n "$readme_versions" ]]; then
    while IFS= read -r readme_ver; do
      readme_major_minor=$(echo "$readme_ver" | sed 's/\.NET //')
      found=false
      for tfm in "${PROJECT_TFMS[@]}"; do
        if [[ "$tfm" == "$readme_major_minor" ]]; then found=true; break; fi
      done
      if ! $found; then
        README_ISSUES+=("README.md mentions ${readme_ver} but projects use: $(IFS=', '; echo "${PROJECT_TFMS[*]}")")
      fi
    done <<< "$readme_versions"
  fi
fi

# =============================================================================
# PHASE 8: Get latest stable .NET version
# =============================================================================
LATEST_STABLE=$(get_latest_stable_dotnet)

# =============================================================================
# OUTPUT
# =============================================================================
if $OUTPUT_JSON; then
  echo "{"
  echo "  \"repo\": \"$REPO_ROOT\","
  echo "  \"latestStable\": \"$LATEST_STABLE\","
  echo "  \"globalJson\": \"$GLOBAL_JSON_INFO\","
  echo "  \"projects\": ["
  for i in "${!PROJECT_NAMES[@]}"; do
    echo "    {"
    echo "      \"name\": \"${PROJECT_NAMES[$i]}\","
    echo "      \"path\": \"${PROJECT_PATHS[$i]}\","
    echo "      \"tfm\": \"${PROJECT_TFMS[$i]}\","
    echo "      \"tfmRaw\": \"${PROJECT_TFM_RAW[$i]}\","
    echo "      \"outputType\": \"${PROJECT_OUTPUT_TYPES[$i]}\","
    echo "      \"packages\": \"${PROJECT_PACKAGES[$i]}\","
    echo "      \"needsUpdate\": $(if [[ "${PROJECT_TFMS[$i]}" != "$LATEST_STABLE" && "$LATEST_STABLE" != "unknown" ]]; then echo true; else echo false; fi)"
    echo "    }$([ $i -lt $((${#PROJECT_NAMES[@]} - 1)) ] && echo ",")"
  done
  echo "  ],"
  echo "  \"legacyFiles\": [$(printf '"%s",' "${LEGACY_FILES[@]}" 2>/dev/null | sed 's/,$//')],"
  echo "  \"ideIssues\": [$(printf '"%s",' "${IDE_ISSUES[@]}" 2>/dev/null | sed 's/,$//')],"
  echo "  \"readmeIssues\": [$(printf '"%s",' "${README_ISSUES[@]}" 2>/dev/null | sed 's/,$//')]"
  echo "}"
else
  # --- Markdown output ---
  echo "# .NET Project Scan Report"
  echo "**Repo**: ${REPO_ROOT}"
  echo "**Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%d)"
  echo "**Latest stable**: .NET ${LATEST_STABLE}"
  if [[ "$GLOBAL_JSON_INFO" != "none" ]]; then
    echo "**global.json**: ${GLOBAL_JSON_INFO}"
  fi
  echo ""

  # Projects table
  echo "## Projects"
  echo "| Project | TFM | Output | Status |"
  echo "|---------|-----|--------|--------|"
  for i in "${!PROJECT_NAMES[@]}"; do
    if [[ "${PROJECT_TFMS[$i]}" == "$LATEST_STABLE" ]]; then
      status="current"
    elif [[ "$LATEST_STABLE" == "unknown" ]]; then
      status="unknown"
    else
      status="${PROJECT_TFMS[$i]} -> ${LATEST_STABLE}"
    fi
    echo "| ${PROJECT_NAMES[$i]} | ${PROJECT_TFM_RAW[$i]} | ${PROJECT_OUTPUT_TYPES[$i]} | ${status} |"
  done
  echo ""

  # Dependencies
  has_packages=false
  for p in "${PROJECT_PACKAGES[@]}"; do
    if [[ "$p" != "none" ]]; then has_packages=true; break; fi
  done
  if $has_packages; then
    echo "## Dependencies"
    echo "| Project | Packages |"
    echo "|---------|----------|"
    for i in "${!PROJECT_NAMES[@]}"; do
      if [[ "${PROJECT_PACKAGES[$i]}" != "none" ]]; then
        echo "| ${PROJECT_NAMES[$i]} | ${PROJECT_PACKAGES[$i]} |"
      fi
    done
    echo ""
  fi

  # Consistency
  echo "## Consistency"
  has_inconsistent=false
  for issue in "${PROJECT_ISSUES[@]}"; do
    if [[ "$issue" == "inconsistent" ]]; then has_inconsistent=true; break; fi
  done
  if $has_inconsistent; then
    echo "- MIXED target frameworks detected: $(IFS=', '; echo "${PROJECT_TFM_RAW[*]}")"
    echo "  Recommendation: align all projects to .NET ${LATEST_STABLE}"
  else
    echo "- All projects use consistent target framework"
  fi
  if [[ "$GLOBAL_JSON_INFO" != "none" ]]; then
    echo "- global.json found: ${GLOBAL_JSON_INFO}"
  fi
  echo ""

  # Legacy files
  if [[ ${#LEGACY_FILES[@]} -gt 0 ]]; then
    echo "## Legacy Files"
    for f in "${LEGACY_FILES[@]}"; do
      echo "- ${f} (stale, likely .NET Framework artifact)"
    done
    echo ""
  fi

  # IDE issues
  if [[ ${#IDE_ISSUES[@]} -gt 0 ]]; then
    echo "## IDE Configuration Issues"
    for issue in "${IDE_ISSUES[@]}"; do
      echo "- ${issue}"
    done
    echo ""
  fi

  # README issues
  if [[ ${#README_ISSUES[@]} -gt 0 ]]; then
    echo "## Documentation Drift"
    for issue in "${README_ISSUES[@]}"; do
      echo "- ${issue}"
    done
    echo ""
  fi

  # Summary
  needs_update=0
  for i in "${!PROJECT_TFMS[@]}"; do
    if [[ "${PROJECT_TFMS[$i]}" != "$LATEST_STABLE" && "$LATEST_STABLE" != "unknown" ]]; then
      needs_update=$((needs_update + 1))
    fi
  done

  echo "## Summary"
  echo "- Projects found: ${#PROJECT_NAMES[@]}"
  echo "- Need update: ${needs_update}"
  echo "- Legacy files: ${#LEGACY_FILES[@]}"
  echo "- IDE issues: ${#IDE_ISSUES[@]}"
  echo "- Doc drift: ${#README_ISSUES[@]}"
  echo ""
  if [[ $needs_update -gt 0 ]]; then
    echo "Run: update.sh --target ${LATEST_STABLE}"
  else
    echo "All projects are up to date."
  fi
fi
