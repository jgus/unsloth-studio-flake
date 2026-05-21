#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#coreutils --command bash

# Per-version branch orchestrator for unsloth-studio-flake. See bencoding-flake/update-branches.sh for the general design.
#
# Unsloth-specific bits:
# - list_upstream_versions queries GitHub releases (unslothai/unsloth).
# - placeholder pin.nix has 4 fields (version, sourceRev, sourceHash, npmDepsHash).
# - the diff check includes pkgs/unsloth-studio-frontend/* since update-version regenerates package.json/package-lock.json.
# - SKIP_BUILD=1 is passed through to update-version (heavy AI deps don't fit on GH runners).

set -euo pipefail
: "${MINIMUM_TRACKING_VERSION:?required env var}"

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
cd "${FLAKE_ROOT}"

list_upstream_versions() {
  gh api --paginate "/repos/unslothai/unsloth/releases" --jq '.[].tag_name'
}

write_placeholder_pin() {
  local v="$1"
  cat > pin.nix <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${v}";
  sourceRev = "";
  sourceHash = "";
  npmDepsHash = "";
}
EOF
}

version_lt() { [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

echo "Querying upstream..."
mapfile -t raw_versions < <(list_upstream_versions)
if (( ${#raw_versions[@]} == 0 )); then
  echo "error: list_upstream_versions returned no rows (auth issue?)" >&2
  exit 1
fi
declare -a all_versions=()
for v in "${raw_versions[@]}"; do
  v="${v#[Vv]}"
  if [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+a-zA-Z0-9.]+)?$ ]]; then
    all_versions+=("${v}")
  fi
done

declare -a tracked=()
for v in "${all_versions[@]}"; do
  if ! version_lt "${v}" "${MINIMUM_TRACKING_VERSION}"; then
    tracked+=("${v}")
  fi
done
if (( ${#tracked[@]} == 0 )); then
  echo "No upstream versions >= ${MINIMUM_TRACKING_VERSION}; nothing to do."
  exit 0
fi
mapfile -t tracked < <(printf '%s\n' "${tracked[@]}" | sort -V)
echo "Tracking ${#tracked[@]} upstream versions: ${tracked[*]}"

git fetch --quiet origin
main_sha=$(git rev-parse --verify origin/main)

for v in "${tracked[@]}"; do
  branch="v${v}"
  wt=$(mktemp -d)
  if git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
    echo
    echo "=== Refreshing existing branch ${branch}"
    git fetch --quiet origin "${branch}:refs/remotes/origin/${branch}" || true
    git worktree add -B "${branch}" "${wt}" "origin/${branch}" >/dev/null
  else
    echo
    echo "=== Creating new branch ${branch} from main"
    git worktree add -B "${branch}" "${wt}" "${main_sha}" >/dev/null
    (cd "${wt}" && write_placeholder_pin "${v}")
  fi
  pushd "${wt}" >/dev/null
  nix flake update --option post-build-hook ""
  SKIP_BUILD=1 FLAKE_ROOT="${wt}" nix run --option post-build-hook "" .#update-version -- "${v}"
  if ! git diff --quiet -- pin.nix flake.lock pkgs/unsloth-studio-frontend/ || [[ -n "$(git ls-files --others --exclude-standard -- flake.lock pkgs/unsloth-studio-frontend/)" ]]; then
    git add pin.nix flake.lock pkgs/unsloth-studio-frontend/
    git commit -q -m "auto: ${v} pin"
    git push --quiet origin "${branch}"
  else
    echo "  no change on ${branch}"
  fi
  popd >/dev/null
  git worktree remove --force "${wt}" >/dev/null
done

git fetch --quiet origin
declare -A agg_target_version=()
record() { local key="$1" v="$2"; cur="${agg_target_version[$key]:-}"; if [[ -z "${cur}" ]] || version_lt "${cur}" "${v}"; then agg_target_version[$key]="${v}"; fi; }
for v in "${tracked[@]}"; do
  IFS='.' read -r M m _ <<<"${v}"
  record "main" "${v}"
  record "v${M}" "${v}"
  record "v${M}.${m}" "${v}"
done

echo
echo "=== Updating aggregate pointers"
for agg in "${!agg_target_version[@]}"; do
  target_v="${agg_target_version[$agg]}"
  target_branch="v${target_v}"
  target_sha=$(git rev-parse --verify "origin/${target_branch}")
  cur_sha=$(git rev-parse --verify "origin/${agg}" 2>/dev/null || echo "")
  if [[ "${cur_sha}" == "${target_sha}" ]]; then
    echo "  ${agg} already at ${target_branch}"
    continue
  fi
  echo "  ${agg} -> ${target_branch} (${target_sha:0:8})"
  git push --force --quiet origin "${target_sha}:refs/heads/${agg}"
done

echo
echo "Done."
