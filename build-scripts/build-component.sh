#!/bin/bash
# Clone a pinned upstream component and build it.
#
# Mirrors canonical/k8s-snap's build-scripts/build-component.sh, with one
# addition: k8s-snap pins every component to a tag and uses a shallow
# `git clone -b <tag>`. Cilium is pinned here to a bare commit SHA (the tree
# this work was scoped against is 1.21.0-dev, which has no release tag), and
# `-b` does not accept a SHA -- so fall back to fetch+checkout in that case.

set -uex

DIR=$(realpath "$(dirname "${0}")")

BUILD_DIRECTORY="${CRAFT_PART_BUILD:-${SNAPCRAFT_PART_BUILD:-${DIR}/.build}}"
INSTALL_DIRECTORY="${CRAFT_PART_INSTALL:-${SNAPCRAFT_PART_INSTALL:-${DIR}/.install}}"

mkdir -p "${BUILD_DIRECTORY}" "${INSTALL_DIRECTORY}"

COMPONENT_NAME="${1}"
COMPONENT_DIRECTORY="${DIR}/components/${COMPONENT_NAME}"

GIT_REPOSITORY="$(cat "${COMPONENT_DIRECTORY}/repository")"
GIT_VERSION="$(cat "${COMPONENT_DIRECTORY}/version")"

COMPONENT_BUILD_DIRECTORY="${BUILD_DIRECTORY}/${COMPONENT_NAME}"

# Drop a stale checkout that cannot be reset to the requested version.
if [ -d "${COMPONENT_BUILD_DIRECTORY}/.git" ]; then
  cd "${COMPONENT_BUILD_DIRECTORY}"
  if ! git reset --hard "${GIT_VERSION}"; then
    cd "${BUILD_DIRECTORY}"
    rm -rf "${COMPONENT_BUILD_DIRECTORY}"
  fi
fi

# Git cannot resolve an abbreviated SHA on the remote: `git fetch` needs a
# full 40-character object name. Fail loudly rather than after a confusing
# "couldn't find remote ref".
if printf '%s' "${GIT_VERSION}" | grep -qE '^[0-9a-f]{7,39}$'; then
  echo "ERROR: ${COMPONENT_NAME} is pinned to abbreviated SHA '${GIT_VERSION}'." >&2
  echo "       Use the full 40-character SHA, a tag, or a branch." >&2
  exit 1
fi

if [ ! -d "${COMPONENT_BUILD_DIRECTORY}/.git" ]; then
  if git clone "${GIT_REPOSITORY}" --depth 1 -b "${GIT_VERSION}" "${COMPONENT_BUILD_DIRECTORY}"; then
    : # tag or branch
  else
    # Bare commit SHA: shallow-fetch just that object.
    rm -rf "${COMPONENT_BUILD_DIRECTORY}"
    git init "${COMPONENT_BUILD_DIRECTORY}"
    cd "${COMPONENT_BUILD_DIRECTORY}"
    git remote add origin "${GIT_REPOSITORY}"
    git fetch --depth 1 origin "${GIT_VERSION}"
    git checkout FETCH_HEAD
  fi
fi

cd "${COMPONENT_BUILD_DIRECTORY}"
echo "Building ${COMPONENT_NAME} at commit $(git rev-parse HEAD)"

bash -xe "${COMPONENT_DIRECTORY}/build.sh" "${INSTALL_DIRECTORY}" "${GIT_VERSION}"
