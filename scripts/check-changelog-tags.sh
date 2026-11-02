#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tags=$(git tag --list | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' || true)
if [[ -z "$tags" ]]; then
    echo 'No numeric release tags found; fetch tags before checking the changelog.' >&2
    exit 1
fi

missing=0
while IFS= read -r tag; do
    if ! awk -v heading="## [$tag]" 'index($0, heading) == 1 && (length($0) == length(heading) || substr($0, length(heading) + 1, 1) == " ") { found = 1 } END { exit !found }' CHANGELOG.md; then
        echo "Missing changelog entry for tag $tag" >&2
        missing=1
    fi
done <<< "$tags"
exit "$missing"
