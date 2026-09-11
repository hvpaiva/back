#!/usr/bin/env bash
# Points the lab at your forks: replaces github.com/hvpaiva/ in platform/ with your account,
# and commits (just use-fork <your-github-user>).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh

owner=${1:?usage: just use-fork <your-github-user>}
files=()
while IFS= read -r file; do files+=("$file"); done < <(git grep -l 'github.com/hvpaiva/' -- platform || true)
if ((${#files[@]} == 0)); then
  ok "platform/ doesn't reference github.com/hvpaiva/ anymore; nothing to do"
  exit 0
fi
# perl rather than sed -i, which differs between GNU and BSD.
perl -pi -e "s#github\.com/hvpaiva/#github.com/$owner/#g" "${files[@]}"
git commit --quiet -m "chore: point the lab at github.com/$owner" -- "${files[@]}"
ok "committed; next: git push, then just argocd, so Argo CD reads your fork"
