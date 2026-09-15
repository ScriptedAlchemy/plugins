#!/usr/bin/env bash
# Rank likely maintainers of a repo so the automate-maintainer skill can offer candidates.
#
# Usage: list-maintainers.sh [owner/name]    (default: the repo of the current directory)
#
# Prints a table: login, PRs merged by them, PRs they reviewed (not their own), PRs they authored,
# and whether they appear in CODEOWNERS. Ranked by merges then reviews. Bots are dropped.
# One GraphQL call for the last 200 merged PRs; CODEOWNERS is read from the local checkout when
# the current directory is that repo.
set -euo pipefail
for bin in gh jq; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

codeowners=""
if [ "$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" = "$repo" ]; then
	for f in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
		[ -f "$f" ] && codeowners+=" $(grep -v '^\s*#' "$f" | grep -o '@[A-Za-z0-9-]\+' | tr -d @ | sort -u | tr '\n' ' ')"
	done
fi

echo "repo: $repo  (last 200 merged PRs)"
gh pr list -R "$repo" --state merged --limit 200 --json author,mergedBy,reviews \
	| jq -r --arg co "$codeowners" '
		# ponytail: name heuristic for integrations that lack the [bot] suffix (codex connector, advanced security).
		def human: select(. != null and . != "" and (test("\\[bot\\]$|connector|copilot|dependabot|renovate|advanced-security"; "i") | not));
		[ .[] | . as $pr
		  | ( [$pr.mergedBy.login | human | {l:., k:"merged"}]
		    + [$pr.author.login   | human | {l:., k:"authored"}]
		    + [$pr.reviews[].author.login | human | select(. != $pr.author.login) | {l:., k:"reviewed"}] )
		  | unique[] ]
		| group_by(.l)
		| map({login:.[0].l,
		       merged:(map(select(.k=="merged"))|length),
		       reviewed:(map(select(.k=="reviewed"))|length),
		       authored:(map(select(.k=="authored"))|length)})
		| map(.login as $l | . + {codeowner:(($co | split(" ") | index($l)) != null)})
		| map(select(.merged > 0 or .reviewed > 0 or .codeowner))
		| sort_by(-.merged, -.reviewed)
		| .[:10]
		| (["login","merged","reviewed","authored","codeowner"] | @tsv),
		  (.[] | [.login, .merged, .reviewed, .authored, (if .codeowner then "yes" else "" end)] | @tsv)' \
	| column -t -s $'\t'
