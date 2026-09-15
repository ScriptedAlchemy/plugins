#!/usr/bin/env bash
# Dump one GitHub login's maintainer footprint to JSONL for the automate-maintainer skill.
#
# Usage: mine-github-user.sh <login> [--repo owner/name]... [--owner org-or-user]...
#                            [--since YYYY-MM-DD] [--limit N] [--holdout N] [--out DIR]
#
# Writes to DIR (default $TMPDIR/automate-maintainer/<login>):
#   prs-authored.jsonl   PRs the login opened
#   prs-reviewed.jsonl   PRs the login reviewed, excluding their own
#   issues.jsonl         issues the login authored, was assigned, commented on, or was mentioned in
#   comments.jsonl       every comment, review verdict, and inline review comment by the login on the above
#   holdout.jsonl        the same, for the N newest reviewed PRs only (default 3), kept out of comments.jsonl
#                        so the drafted skill can be tested on reviews it never saw
#   discussions.jsonl    discussions the login opened or commented in, with their comments only
#   summary.txt          counts, repo visibility, review verdicts, most-reviewed paths
#
# Needs gh (authenticated) and jq. Only repos the gh token can read are visible.
set -euo pipefail

usage() { sed -n '2,17p' "$0" >&2; exit 1; }
[ "$#" -ge 1 ] || usage
for bin in gh jq; do command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }; done

login="$1"; shift
limit=200
holdout=3
since=""
out=""
search_scope=()
gql_scope=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--repo)  search_scope+=(--repo "$2");  gql_scope+=" repo:$2"; shift 2 ;;
		--owner) search_scope+=(--owner "$2"); gql_scope+=" user:$2"; shift 2 ;;
		--since) since="$2"; shift 2 ;;
		--limit) limit="$2"; shift 2 ;;
		--holdout) holdout="$2"; shift 2 ;;
		--out)   out="$2"; shift 2 ;;
		*) usage ;;
	esac
done
if [ -z "$since" ]; then
	since="$(date -u -d '-12 months' +%F 2>/dev/null || date -u -v-12m +%F)"
fi
out="${out:-${TMPDIR:-/tmp}/automate-maintainer/$login}"
mkdir -p "$out/parts"
rm -f "$out"/*.jsonl "$out"/parts/*

fields=number,title,body,url,createdAt,updatedAt,closedAt,state,labels,repository,commentsCount,author,isPullRequest

echo "mining $login since $since (limit $limit per source) -> $out" >&2
gh search prs --author="$login" --created=">=$since" --limit "$limit" "${search_scope[@]}" --json "$fields" \
	| jq -c '.[]' > "$out/prs-authored.jsonl"
gh search prs --reviewed-by="$login" --updated=">=$since" --limit "$limit" "${search_scope[@]}" --json "$fields" -- "-author:$login" \
	| jq -c '.[]' > "$out/prs-reviewed.jsonl"
gh search issues --involves="$login" --updated=">=$since" --limit "$limit" "${search_scope[@]}" --json "$fields" \
	| jq -c '.[]' > "$out/issues.jsonl"

# One fetch per unique item: issue comments for everything, plus review verdicts and inline
# comments for PRs. Each worker writes its own part file so long bodies never interleave.
api_rows() { # <path> <jq filter> <part file>. gh prints HTTP error bodies to stdout, so buffer first.
	local rows
	if rows="$(gh api --paginate "$1" --jq "$2" 2>/dev/null)" && [ -n "$rows" ]; then printf '%s\n' "$rows" >> "$3"; fi
}
fetch_item() {
	local login="$1" out="$2" repo="$3" number="$4" is_pr="$5"
	local part="$out/parts/${repo//\//_}-$number.jsonl"
	local sel=".[] | select(.user.login==\"$login\")"
	api_rows "repos/$repo/issues/$number/comments?per_page=100" \
		"$sel | {kind:\"comment\", repo:\"$repo\", number:$number, url:.html_url, created_at, body}" "$part"
	if [ "$is_pr" = "true" ]; then
		api_rows "repos/$repo/pulls/$number/reviews?per_page=100" \
			"$sel | {kind:\"review\", repo:\"$repo\", number:$number, url:.html_url, created_at:.submitted_at, state, body}" "$part"
		api_rows "repos/$repo/pulls/$number/comments?per_page=100" \
			"$sel | {kind:\"review_comment\", repo:\"$repo\", number:$number, url:.html_url, created_at, path, line, diff_hunk, body}" "$part"
	fi
}
export -f api_rows fetch_item

cat "$out"/prs-authored.jsonl "$out"/prs-reviewed.jsonl "$out"/issues.jsonl \
	| jq -r '[.repository.nameWithOwner, .number, .isPullRequest] | @tsv' \
	| sort -u \
	| xargs -r -P 4 -L 1 bash -c 'fetch_item "$0" "$1" "$2" "$3" "$4"' "$login" "$out"
cat "$out"/parts/*.jsonl 2>/dev/null | jq -c . > "$out/all-comments.jsonl" || : > "$out/all-comments.jsonl"
rm -rf "$out/parts"

# Hold out the login's activity on the N newest reviewed PRs so the drafted skill can be tested
# on reviews it never saw. comments.jsonl is the training set, holdout.jsonl the test set.
held="$(jq -nc --argjson n "$holdout" '[inputs] | sort_by(.updatedAt) | reverse | .[:$n] | map(.repository.nameWithOwner + "#" + (.number|tostring))' "$out/prs-reviewed.jsonl")"
jq -c --argjson held "$held" '(.repo + "#" + (.number|tostring)) as $k | select(($held | index($k)) == null)' "$out/all-comments.jsonl" > "$out/comments.jsonl"
jq -c --argjson held "$held" '(.repo + "#" + (.number|tostring)) as $k | select(($held | index($k)) != null)' "$out/all-comments.jsonl" > "$out/holdout.jsonl"
rm -f "$out/all-comments.jsonl"

# Discussions only exist behind GraphQL search. Its issueCount is unreliable, so count nodes.
# ponytail: nested comments(first:50) and replies(first:20) are not paginated; a huge thread loses its tail.
query='query($q:String!, $after:String){ search(query:$q, type:DISCUSSION, first:50, after:$after){
  pageInfo{hasNextPage endCursor}
  nodes{ ... on Discussion { number title url createdAt body isAnswered
    repository{nameWithOwner} author{login} answer{author{login}}
    comments(first:50){ nodes{ author{login} body createdAt url replies(first:20){nodes{author{login} body createdAt url}} } } } } } }'
q="involves:$login created:>=$since$gql_scope"
after=""
: > "$out/discussions.jsonl"
while :; do
	page="$(gh api graphql -f query="$query" -f q="$q" ${after:+-f after="$after"})"
	printf '%s' "$page" | jq -c --arg l "$login" '.data.search.nodes[] | {
		repo:.repository.nameWithOwner, number, title, url, createdAt, isAnswered,
		authored:(.author.login==$l), answered:(.answer.author.login==$l),
		body:(if .author.login==$l then .body else null end),
		my_comments:[(.comments.nodes[], .comments.nodes[].replies.nodes[]) | select(.author.login==$l) | {body, createdAt, url}]
	}' >> "$out/discussions.jsonl"
	[ "$(wc -l < "$out/discussions.jsonl")" -lt "$limit" ] || break
	[ "$(printf '%s' "$page" | jq -r '.data.search.pageInfo.hasNextPage')" = "true" ] || break
	after="$(printf '%s' "$page" | jq -r '.data.search.pageInfo.endCursor')"
done

{
	echo "login: $login  since: $since  scope:${gql_scope:- global}"
	for f in prs-authored prs-reviewed issues comments holdout discussions; do
		printf '%-14s %s\n' "$f" "$(wc -l < "$out/$f.jsonl")"
	done
	echo; echo "repos (count, visibility). Private quotes must not land in a public skill:"
	cat "$out"/prs-authored.jsonl "$out"/prs-reviewed.jsonl "$out"/issues.jsonl "$out"/discussions.jsonl \
		| jq -r '.repository.nameWithOwner // .repo' | sort | uniq -c | sort -rn | head -15 \
		| while read -r n r; do printf '%7s %s %s\n' "$n" "$r" "$(gh api "repos/$r" --jq 'if .private then "PRIVATE" else "public" end' 2>/dev/null || echo unknown)"; done
	echo; echo "review verdicts:"
	jq -r 'select(.kind=="review") | .state' "$out/comments.jsonl" | sort | uniq -c | sort -rn
	echo; echo "most-reviewed paths (dir):"
	jq -r 'select(.kind=="review_comment") | .path | split("/")[:-1] | join("/")' "$out/comments.jsonl" | sort | uniq -c | sort -rn | head -15
	echo; echo "labels on authored PRs:"
	jq -r '.labels[]?.name' "$out/prs-authored.jsonl" | sort | uniq -c | sort -rn | head -10
} > "$out/summary.txt"
cat "$out/summary.txt"
