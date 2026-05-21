#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#nodejs nixpkgs#nix-prefetch-github nixpkgs#prefetch-npm-deps nixpkgs#moreutils --command bash

# Bumps pin.nix + the vendored frontend package.json/package-lock.json to the requested release of unslothai/unsloth. Run from the flake root:
#
#   nix run .#update-version              # latest GitHub release
#   nix run .#update-version -- <ref>     # specific tag, branch, or SHA (e.g. v2025.10.6 or 1.2.3)
#
# Always recomputes hashes and rewrites pin if anything changed; idempotent on no-change runs.
#
# Set SKIP_BUILD=1 to skip the final `nix build` verification step (used in CI where the heavy AI deps would blow the runner's resource budget). Hashes are still correct — they're derived from prefetch tools, not guessed.

set -euo pipefail

FLAKE_ROOT="${FLAKE_ROOT:-${PWD}}"
pin="${FLAKE_ROOT}/pin.nix"
frontend="${FLAKE_ROOT}/pkgs/unsloth-studio-frontend"

repo_owner=unslothai
repo_name=unsloth

if [[ ! -f "${pin}" ]]; then
  echo "error: no pin.nix in ${FLAKE_ROOT}" >&2
  exit 1
fi

if [[ $# -ge 1 && -n "${1}" ]]; then
  raw="${1}"
  echo "Resolving requested ref ${raw}..."
  new_tag=""
  for candidate in "${raw}" "v${raw#[Vv]}" "V${raw#[Vv]}"; do
    if gh api "/repos/${repo_owner}/${repo_name}/commits/${candidate}" >/dev/null 2>&1; then
      new_tag="${candidate}"
      break
    fi
  done
  if [[ -z "${new_tag}" ]]; then
    echo "error: could not resolve '${raw}' as a tag/branch/SHA on ${repo_owner}/${repo_name}." >&2
    exit 1
  fi
else
  echo "Querying GitHub for latest release..."
  release=$(gh api "/repos/${repo_owner}/${repo_name}/releases/latest")
  new_tag=$(jq -r '.tag_name' <<<"${release}")
fi
case "${new_tag}" in
  [Vv][0-9]*) new_version="${new_tag#[Vv]}" ;;
  *) new_version="${new_tag}" ;;
esac
new_rev=$(gh api "/repos/${repo_owner}/${repo_name}/commits/${new_tag}" --jq '.sha')

cur_version=$(nix eval --raw --file "${pin}" version 2>/dev/null || echo "")
cur_rev=$(nix eval --raw --file "${pin}" sourceRev 2>/dev/null || echo "")

echo "  current: ${cur_version} (${cur_rev:-<empty>})"
echo "  target:  ${new_version} (${new_rev})"

if [[ "${cur_version}" == "${new_version}" && "${cur_rev}" == "${new_rev}" ]]; then
  echo "Already up to date."
  exit 0
fi

echo "Computing source hash..."
new_source_hash=$(nix-prefetch-github --rev "${new_rev}" "${repo_owner}" "${repo_name}" --json | jq -r '.hash // .sha256')

echo "Regenerating frontend package.json + package-lock.json..."
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
(
  cd "${work}"
  gh api "/repos/${repo_owner}/${repo_name}/contents/studio/frontend/package.json?ref=${new_rev}" \
    --jq '.content' | base64 -d > package.json
  # `react-is` is recharts' peerDependency; rolldown/vite's strict resolver fails to find it via peers, so add it as a direct dep with the same range upstream uses for `react` itself (recharts accepts `^16 || ^17 || ^18 || ^19`, so matching React's major resolves cleanly).
  react_range=$(jq -r '.dependencies.react' package.json)
  jq --arg r "${react_range}" '.dependencies["react-is"] = $r' package.json | sponge package.json
  npm install --package-lock-only --no-audit --no-fund
)
cp "${work}/package.json" "${frontend}/package.json"
cp "${work}/package-lock.json" "${frontend}/package-lock.json"

echo "Computing npm deps hash..."
new_npm_hash=$(prefetch-npm-deps "${frontend}/package-lock.json")

echo "Writing pin.nix..."
cat > "${pin}" <<EOF
# Auto-managed by \`nix run .#update-version\`. Manual edits will be overwritten by the next bump.
{
  version = "${new_version}";
  sourceRev = "${new_rev}";
  sourceHash = "${new_source_hash}";
  npmDepsHash = "${new_npm_hash}";
}
EOF

if [[ "${SKIP_BUILD:-}" == "1" ]]; then
  echo "SKIP_BUILD=1; skipping nix build verification."
else
  echo "Verifying builds..."
  nix build --option post-build-hook "" "${FLAKE_ROOT}#unsloth-studio-frontend" --no-link
  nix build --option post-build-hook "" "${FLAKE_ROOT}#unsloth-studio" --no-link
fi

echo
echo "Updated to ${new_version} (${new_rev})"
echo "  Commit pin.nix and pkgs/unsloth-studio-frontend/* to capture."
