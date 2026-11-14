#!/bin/bash
# usage-report.sh
# Guest House — accessible virtual machines
#
# How much Guest House is downloaded and visited, from GitHub's own numbers
# (2026-11-14). GitHub keeps visitor figures for 14 days only and download
# counts as running totals, so run this when you want a reading. The website
# writes the download totals down once a day and shows them, with the
# anonymous counts copies send, in its control panel under Visitors.
#
#   Tools/usage-report.sh            the ten newest releases, totals, visitors
#   Tools/usage-report.sh --all      every release
#
# Needs the gh command, signed in to the account that owns the repository
# (visitor figures are only shown to the owner).

set -euo pipefail
REPO_SLUG="${AVM_REPO:-amenathomas1997/guest-house}"
SHOW=10
[ "${1:-}" = "--all" ] && SHOW=1000
command -v gh >/dev/null || { echo "FAILED: the gh command isn't installed."; echo "Next: brew install gh, then gh auth login."; exit 1; }

echo "== Downloads of $REPO_SLUG, from GitHub"
gh api "repos/$REPO_SLUG/releases?per_page=100" --paginate \
    -q '.[] | [.tag_name, .published_at[:10], ([.assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0), ([.assets[] | select(.name | endswith(".zip")) | .download_count] | add // 0)] | @tsv' \
    | awk -F'\t' -v show="$SHOW" '
        { dmg += $3; zip += $4; n++; if (n <= show) rows[n] = sprintf("   %-9s %s   installer %4d   updates %4d", $1, $2, $3, $4) }
        END {
            printf "   %d releases. Installer (disk image) downloads: %d. Update downloads from inside the app: %d.\n", n, dmg, zip
            print "   An update download is one copy updating, so the newest releases show about how many copies are in use."
            for (i = 1; i <= n && i <= show; i++) print rows[i]
        }'

echo
echo "== Visitors to the repository in the last 14 days"
gh api "repos/$REPO_SLUG/traffic/views" -q '"   \(.uniques) people, \(.count) page views"' 2>/dev/null || echo "   Not shown: only the repository's owner can read these."
gh api "repos/$REPO_SLUG/traffic/popular/referrers" -q '.[] | "   from \(.referrer): \(.uniques) people"' 2>/dev/null || true
gh api "repos/$REPO_SLUG" -q '"   stars \(.stargazers_count), watchers \(.subscribers_count), forks \(.forks_count)"'
