#!/usr/bin/env bash
set -euo pipefail

# 1. Map required commands to their corresponding Nix package names
declare -A BIN_PKG_MAP=(
  [curl]="curl"
  [jq]="jq"
  [python3]="python3"
  [nix-prefetch-git]="nix-prefetch-git"
  [nix-hash]="nix"
)

REQUIRED_BINS=("${!BIN_PKG_MAP[@]}")
MISSING_PKGS=()

for bin in "${REQUIRED_BINS[@]}"; do
  if ! command -v "$bin" &>/dev/null; then
    pkg="${BIN_PKG_MAP[$bin]}"
    # Avoid adding duplicate packages
    if [[ ! " ${MISSING_PKGS[*]:-} " =~ [[:space:]]${pkg}[[:space:]] ]]; then
      MISSING_PKGS+=("$pkg")
    fi
  fi
done

# 2. Re-enter via nix-shell if dependencies are missing
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
  if [ "${IN_NIX_SHELL_UPDATER:-}" = "1" ]; then
    echo "Error: Still missing dependencies inside nix-shell: ${MISSING_PKGS[*]}" >&2
    exit 1
  fi

  echo "==> Missing dependencies: ${MISSING_PKGS[*]}"
  echo "==> Entering temporary nix-shell environment..."
  exec env IN_NIX_SHELL_UPDATER=1 nix-shell -p "${MISSING_PKGS[@]}" --run "$(printf '%q ' "$0" "$@")"
fi

NIX_FILE="${1:-flake.nix}"
VERSION_FILE="version.txt"
REPO_OWNER="diegopvlk"
REPO_NAME="Cine"

if [ ! -f "$NIX_FILE" ]; then
  echo "Error: Nix file not found: $NIX_FILE" >&2
  exit 1
fi

echo "==> 1. Fetching latest release from GitHub API..."
# If GITHUB_TOKEN is present in the environment, use it to avoid rate limits
AUTH_HEADER=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

RELEASE_JSON=$(curl -sSL "${AUTH_HEADER[@]}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest")

TAG_NAME=$(echo "$RELEASE_JSON" | jq -r '.tag_name // empty')

# Fallback: If no releases exist or the call failed, check git tags
if [ -z "$TAG_NAME" ] || [ "$TAG_NAME" = "null" ]; then
  echo "No official release found, falling back to latest git tag..."
  TAGS_JSON=$(curl -sSL "${AUTH_HEADER[@]}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/tags")
  TAG_NAME=$(echo "$TAGS_JSON" | jq -r '.[0].name // empty')
fi

if [ -z "$TAG_NAME" ] || [ "$TAG_NAME" = "null" ]; then
  echo "Error: Failed to fetch latest tag/release from GitHub." >&2
  exit 1
fi

# Strip leading 'v' to get the clean semver string (e.g. "v1.8.6" -> "1.8.6")
PKGVER="${TAG_NAME#v}"

echo "Latest Tag    : $TAG_NAME"
echo "Parsed Version: $PKGVER"

echo "==> 2. Updating latest.txt..."
date -u -Iseconds > latest.txt

# Check if already up to date
if [ -f "$VERSION_FILE" ] && [ "$(cat "$VERSION_FILE")" = "$PKGVER" ]; then
  echo "==> Package is already up to date ($PKGVER). Exiting."
  exit 0
fi

echo "==> 3. Updating version.txt..."
echo "$PKGVER" > "$VERSION_FILE"

echo "==> 4. Prefetching git source with submodules to compute SRI hash..."
GIT_REPO="https://github.com/$REPO_OWNER/$REPO_NAME"

PREFETCH_OUTPUT=$(nix-prefetch-git \
  --url "$GIT_REPO" \
  --rev "$TAG_NAME" \
  --fetch-submodules \
  --quiet)

SRI_HASH=$(echo "$PREFETCH_OUTPUT" | jq -r '.hash // empty')

if [ -z "$SRI_HASH" ]; then
  RAW_SHA256=$(echo "$PREFETCH_OUTPUT" | jq -r '.sha256')
  SRI_HASH=$(nix-hash --type sha256 --to-sri "$RAW_SHA256")
fi

echo "SRI Hash: $SRI_HASH"

echo "==> 5. Updating $NIX_FILE..."
python3 -c "
import re

with open('$NIX_FILE', 'r') as f:
    content = f.read()

# Update version field associated with cine
content = re.sub(
    r'(pname\s*=\s*\"cine\";\s*version\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$PKGVER\2',
    content
)

# Update fetchFromGitHub hash field
content = re.sub(
    r'(src\s*=\s*(?:pkgs\.)?fetchFromGitHub\s*\{[\s\S]*?hash\s*=\s*\")[^\"]+(\";)',
    r'\g<1>$SRI_HASH\2',
    content
)

with open('$NIX_FILE', 'w') as f:
    f.write(content)
"

echo "==> Successfully updated $NIX_FILE to version $PKGVER!"
