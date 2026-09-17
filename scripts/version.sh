#!/usr/bin/env bash
# The version a service's next build gets, read from its own commits since the last one. The rule is the
# one its commit messages already follow: a breaking change raises the major, a feature the minor, anything
# else the patch. Prints it; the delivery workflow tags the commit with it.
set -Eeuo pipefail

# A commit has one version, so running this twice over it answers the same.
current=$(git tag --points-at HEAD --list 'v[0-9]*.[0-9]*.[0-9]*' | head -1)
if [[ -n $current ]]; then
  echo "${current#v}"
  exit 0
fi

last=$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-version:refname | head -1)
if [[ -z $last ]]; then
  echo 1.0.0
  exit 0
fi

IFS=. read -r major minor patch <<<"${last#v}"
bump='patch'

while IFS= read -r subject; do
  if [[ $subject =~ ^[a-z]+(\([^\)]*\))?!: ]]; then
    bump=major
    break
  fi
  if [[ $subject =~ ^feat(\([^\)]*\))?: ]]; then
    bump=minor
  fi
done < <(git log --format=%s "$last..HEAD")

# The footer says it too, and it outranks every subject.
if git log --format=%b "$last..HEAD" | grep -q '^BREAKING CHANGE'; then
  bump=major
fi

case $bump in
  major) echo "$((major + 1)).0.0" ;;
  minor) echo "$major.$((minor + 1)).0" ;;
  patch) echo "$major.$minor.$((patch + 1))" ;;
esac
