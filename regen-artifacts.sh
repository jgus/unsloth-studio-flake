#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#gh nixpkgs#jq nixpkgs#prefetch-npm-deps nixpkgs#moreutils nixpkgs#python3 nixpkgs#coreutils --command bash

# flake-lib artifactHook for unsloth-studio. flake-lib's update-version invokes this
# after resolving the new rev, with: NEW_REV, NEW_VERSION, FLAKE_ROOT, GH_OWNER, GH_REPO.
# It regenerates the vendored frontend package.json/package-lock.json and the python
# upstream-deps.nix from upstream@NEW_REV, and prints `npmDepsHash=<hash>` on stdout
# (the only stdout line; flake-lib captures name=value lines into pin.nix). All other
# output goes to stderr.

set -euo pipefail

FRONTEND="${FLAKE_ROOT}/pkgs/unsloth-studio-frontend"

echo "Regenerating frontend package.json + package-lock.json..." >&2
WORK=$(mktemp -d)
DEPS_WORK=$(mktemp -d)
trap 'rm -rf "${WORK}" "${DEPS_WORK}"' EXIT
(
  cd "${WORK}"
  gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/studio/frontend/package.json?ref=${NEW_REV}" \
    --jq '.content' | base64 -d > package.json
  gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/studio/frontend/package-lock.json?ref=${NEW_REV}" \
    --jq '.content' | base64 -d > package-lock.json
  # `react-is` is recharts' peerDependency; rolldown/vite's strict resolver fails to find it via peers, so add it as a direct dep matching the range upstream uses for `react`.
  REACT_RANGE=$(jq -r '.dependencies.react' package.json)
  jq \
    --arg reactRange "${REACT_RANGE}" \
    '.dependencies["react-is"] = $reactRange' \
    package.json | sponge package.json
  jq \
    --arg reactRange "${REACT_RANGE}" \
    '.packages[""].dependencies["react-is"] = $reactRange' \
    package-lock.json | sponge package-lock.json
)
cp "${WORK}/package.json" "${FRONTEND}/package.json"
cp "${WORK}/package-lock.json" "${FRONTEND}/package-lock.json"

echo "Computing npm deps hash..." >&2
NPM_HASH=$(prefetch-npm-deps "${FRONTEND}/package-lock.json")

echo "Regenerating upstream-deps.nix..." >&2
mkdir -p "${DEPS_WORK}/studio/backend/requirements"
for UPSTREAM_PATH in \
  pyproject.toml \
  studio/backend/requirements/studio.txt \
  studio/backend/requirements/base.txt
do
  gh api "/repos/${GH_OWNER}/${GH_REPO}/contents/${UPSTREAM_PATH}?ref=${NEW_REV}" \
    --jq '.content' | base64 -d > "${DEPS_WORK}/${UPSTREAM_PATH}"
done
python3 "${FLAKE_ROOT}/gen-deps.py" "${DEPS_WORK}" "${FLAKE_ROOT}/pkgs/unsloth-studio/upstream-deps.nix" >&2

# Only stdout line: the extra hash flake-lib writes into pin.nix.
echo "npmDepsHash=${NPM_HASH}"
