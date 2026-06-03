#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#nodejs nixpkgs#prefetch-npm-deps nixpkgs#moreutils nixpkgs#python3 nixpkgs#coreutils --command bash

# flake-lib artifactHook for unsloth-studio. flake-lib's update-version invokes this
# after resolving the new rev, with: NEW_REV, NEW_VERSION, FLAKE_ROOT, GH_OWNER, GH_REPO.
# It regenerates the vendored frontend package.json/package-lock.json and the python
# upstream-deps.nix from upstream@NEW_REV, and prints `npmDepsHash=<hash>` on stdout
# (the only stdout line; flake-lib captures name=value lines into pin.nix). All other
# output goes to stderr.

set -euo pipefail

frontend="${FLAKE_ROOT}/pkgs/unsloth-studio-frontend"

echo "Regenerating frontend package.json + package-lock.json..." >&2
work=$(mktemp -d)
deps_work=$(mktemp -d)
trap 'rm -rf "${work}" "${deps_work}"' EXIT
(
  cd "${work}"
  gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/studio/frontend/package.json?ref=${NEW_REV}" \
    --jq '.content' | base64 -d > package.json
  # `react-is` is recharts' peerDependency; rolldown/vite's strict resolver fails to find it via peers, so add it as a direct dep matching the range upstream uses for `react`.
  react_range=$(jq -r '.dependencies.react' package.json)
  jq --arg r "${react_range}" '.dependencies["react-is"] = $r' package.json | sponge package.json
  # --legacy-peer-deps: upstream occasionally pins a dep that doesn't satisfy a transitive peer; npm 7+ strict enforcement would ERESOLVE-fail. The vite build tolerates peer-mismatch warnings.
  npm install --package-lock-only --no-audit --no-fund --legacy-peer-deps >&2
)
cp "${work}/package.json" "${frontend}/package.json"
cp "${work}/package-lock.json" "${frontend}/package-lock.json"

echo "Computing npm deps hash..." >&2
npm_hash=$(prefetch-npm-deps "${frontend}/package-lock.json")

echo "Regenerating upstream-deps.nix..." >&2
mkdir -p "${deps_work}/studio/backend/requirements"
for path in \
  pyproject.toml \
  studio/backend/requirements/studio.txt \
  studio/backend/requirements/base.txt
do
  gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/${path}?ref=${NEW_REV}" \
    --jq '.content' | base64 -d > "${deps_work}/${path}"
done
python3 "${FLAKE_ROOT}/gen-deps.py" "${deps_work}" "${FLAKE_ROOT}/pkgs/unsloth-studio/upstream-deps.nix" >&2

# Only stdout line: the extra hash flake-lib writes into pin.nix.
echo "npmDepsHash=${npm_hash}"
