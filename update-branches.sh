#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#git nixpkgs#gh nixpkgs#jq nixpkgs#gnused nixpkgs#coreutils --command bash

# Per-version branch orchestrator for unsloth-studio-flake. See bencoding-flake/update-branches.sh for the general design.
#
# Unsloth-specific bits:
# - list_upstream_versions queries GitHub releases (unslothai/unsloth).
# - placeholder pin.nix has 4 fields (version, sourceRev, sourceHash, npmDepsHash).
# - the diff check includes pkgs/unsloth-studio-frontend/* since update-version regenerates package.json/package-lock.json.
# - Some upstream releases ship a broken npm tree; failures on individual branches are surfaced (GH annotations + step summary) but don't abort the whole orchestrator. The workflow exits non-zero at the end if any branch failed.
#
# Structural note: each existing exact branch is `git merge`d with origin/main before its update-version runs, so orchestrator/workflow improvements that land on main propagate forward through every branch's tree. Branch-owned files (pin.nix, flake.lock, vendored frontend) stay as-is via the `ours` merge driver declared in .gitattributes.

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
# Define the `ours` merge driver so .gitattributes' `merge=ours` rules take effect: `true` exits 0 without touching the file, leaving the branch's version.
git config merge.ours.driver true

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

declare -a failed=()

for v in "${tracked[@]}"; do
  branch="v${v}"
  wt=$(mktemp -d)
  if git ls-remote --exit-code --heads origin "${branch}" >/dev/null 2>&1; then
    echo
    echo "=== Refreshing existing branch ${branch}"
    git fetch --quiet origin "${branch}:refs/remotes/origin/${branch}" || true
    git worktree add -B "${branch}" "${wt}" "origin/${branch}" >/dev/null
    # Merge any orchestrator/workflow improvements that have landed on main since this branch was last touched. Branch-owned files (pin.nix, flake.lock, pkgs/unsloth-studio-frontend/**) stay as-is per .gitattributes' `merge=ours` rules. A no-op merge is silent.
    (cd "${wt}" && git merge --no-edit origin/main)
  else
    echo
    echo "=== Creating new branch ${branch} from main"
    git worktree add -B "${branch}" "${wt}" "${main_sha}" >/dev/null
    (cd "${wt}" && write_placeholder_pin "${v}")
  fi
  pushd "${wt}" >/dev/null
  set +e
  nix flake update --option post-build-hook ""
  FLAKE_ROOT="${wt}" nix run --option post-build-hook "" .#update-version -- "${v}"
  uv_exit=$?
  set -e
  if (( uv_exit != 0 )); then
    failed+=("${v}")
    # GH Actions annotation — appears in the run UI and on commit/PR pages.
    echo "::warning title=Branch ${branch} skipped::update-version failed for ${v} (exit ${uv_exit}). Likely an upstream package.json / source defect at that release; see the orchestrator log above for the npm/source error."
    echo "  WARN: update-version failed for ${branch} (exit ${uv_exit}); skipping." >&2
    popd >/dev/null
    git worktree remove --force "${wt}" >/dev/null
    continue
  fi
  if ! git diff --quiet -- pin.nix flake.lock pkgs/unsloth-studio-frontend/ || [[ -n "$(git ls-files --others --exclude-standard -- flake.lock pkgs/unsloth-studio-frontend/)" ]]; then
    git add pin.nix flake.lock pkgs/unsloth-studio-frontend/
    git commit -q -m "auto: ${v} pin"
    git push --quiet origin "${branch}"
  else
    echo "  no change on ${branch}"
    # The merge from main may have advanced the branch without touching tracked files we diff for. Push if local HEAD is ahead of origin.
    if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${branch}")" ]]; then
      git push --quiet origin "${branch}"
    fi
  fi
  popd >/dev/null
  git worktree remove --force "${wt}" >/dev/null
done

git fetch --quiet origin
declare -A agg_target_version=()
record() { local key="$1" v="$2"; cur="${agg_target_version[$key]:-}"; if [[ -z "${cur}" ]] || version_lt "${cur}" "${v}"; then agg_target_version[$key]="${v}"; fi; }
for v in "${tracked[@]}"; do
  # Only consider exact branches that actually exist on origin (failed branches won't have a ref to advance aggregates to).
  if ! git ls-remote --exit-code --heads origin "v${v}" >/dev/null 2>&1; then
    continue
  fi
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
if (( ${#failed[@]} > 0 )); then
  echo "=== ${#failed[@]} branch(es) failed: ${failed[*]}"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "## :warning: ${#failed[@]} branch(es) failed to update"
      echo
      echo "These upstream versions couldn't be packaged (typically a broken upstream package.json or source). They were skipped; aggregate pointers reflect only the successful branches."
      echo
      for v in "${failed[@]}"; do
        echo "- \`v${v}\`"
      done
      echo
      echo "See the orchestrator log for the underlying error per version."
    } >> "${GITHUB_STEP_SUMMARY}"
  fi
  exit 1
fi

echo "Done."
