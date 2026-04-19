#!/usr/bin/env bash
set -euo pipefail

TARGET_REPO="${TARGET_REPO:-}"
SOURCE_PREFIX="${SOURCE_PREFIX:-php/package}"
TARGET_BRANCH="${TARGET_BRANCH:-main}"
RELEASE_TAG="${RELEASE_TAG:-}"

if [[ -z "${TARGET_REPO}" ]]; then
  echo "TARGET_REPO is required, e.g. https://x-access-token:<token>@github.com/guweigang/vphp-package.git" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Must run inside a git repository" >&2
  exit 1
fi

split_branch="split/vphp-package-$(date +%Y%m%d-%H%M%S)"

echo "[publish] split prefix: ${SOURCE_PREFIX}"
git subtree split --prefix="${SOURCE_PREFIX}" -b "${split_branch}"

echo "[publish] push branch -> ${TARGET_BRANCH}"
git push "${TARGET_REPO}" "${split_branch}:${TARGET_BRANCH}" --force

if [[ -n "${RELEASE_TAG}" ]]; then
  split_sha="$(git rev-parse "${split_branch}")"
  echo "[publish] push tag ${RELEASE_TAG} -> ${split_sha}"
  git push "${TARGET_REPO}" "${split_sha}:refs/tags/${RELEASE_TAG}" --force
fi

git branch -D "${split_branch}" >/dev/null
echo "[publish] done"
