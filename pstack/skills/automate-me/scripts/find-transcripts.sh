#!/usr/bin/env bash
# List agent transcripts for one project across every tool that stores them locally.
#
# Usage: find-transcripts.sh [project-path] [--since YYYY-MM-DD]
#   project-path defaults to the current directory. Linked worktrees of the project are included.
#
# Prints TSV: tool, last-modified (ISO), path. Only files for this project are listed; other
# projects' chats are never touched. opencode keeps messages in sqlite, so its matching sessions
# are exported to $TMPDIR/automate-me/opencode/<session>.jsonl and those paths are listed.
#
# Tools: cursor, claude (Claude Code), codex, opencode, kimi (Kimi Code). Add a tool by adding a
# function that prints "tool<TAB>path" lines and calling it at the bottom.
set -euo pipefail

project_arg=.
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then project_arg="$1"; shift; fi
project="$(cd "$project_arg" 2>/dev/null && pwd -P)" || { echo "bad path: $project_arg" >&2; exit 1; }
since=""
while [ $# -gt 0 ]; do
	case "$1" in
		--since) since="$2"; shift 2 ;;
		*) sed -n '2,12p' "$0" >&2; exit 1 ;;
	esac
done

base="$(basename "$project")"
dashed="${project//\//-}"                # /fast/projects/x -> -fast-projects-x  (Claude Code)
slug="${dashed#-}"                       # fast-projects-x                     (Cursor)

cursor() {
	for d in ~/.cursor/projects/"$slug" ~/.cursor/projects/"$slug"-worktrees-*; do
		if [ -d "$d/agent-transcripts" ]; then find "$d/agent-transcripts" -name '*.jsonl' -size +1k | sed 's/^/cursor\t/'; fi
	done
}
claude() {
	for d in ~/.claude/projects/"$dashed" ~/.claude/projects/"$dashed"--*; do
		if [ -d "$d" ]; then find "$d" -maxdepth 1 -name '*.jsonl' -size +1k | sed 's/^/claude\t/'; fi
	done
}
codex() {
	[ -d ~/.codex/sessions ] || return 0
	find ~/.codex/sessions -name 'rollout-*.jsonl' -size +1k | while read -r f; do
		if head -n 1 "$f" | grep -q "\"cwd\":\"$project[\"/]"; then printf 'codex\t%s\n' "$f"; fi
	done
}
opencode() {
	local db=~/.local/share/opencode/opencode.db
	{ [ -f "$db" ] && command -v sqlite3 >/dev/null; } || return 0
	local out="${TMPDIR:-/tmp}/automate-me/opencode"; mkdir -p "$out"
	sqlite3 -readonly -separator $'\t' "$db" \
		"select id, time_updated/1000 from session where directory = '$project' or directory like '$project/%'" \
		| while IFS=$'\t' read -r sid updated; do
			sqlite3 -readonly "$db" "select data from message where session_id = '$sid' order by time_created" > "$out/$sid.jsonl"
			touch -d "@$updated" "$out/$sid.jsonl" 2>/dev/null || touch -t "$(date -u -r "$updated" +%Y%m%d%H%M.%S)" "$out/$sid.jsonl"
			if [ -s "$out/$sid.jsonl" ]; then printf 'opencode\t%s\n' "$out/$sid.jsonl"; fi
		done
}
kimi() {
	# ponytail: Kimi keys sessions by workspace id "wd_<basename>_<hash>", so this matches on basename only.
	[ -d ~/.kimi-code/server/events ] || return 0
	grep -l "\"workspace_id\":\"wd_${base}_" ~/.kimi-code/server/events/session_*.jsonl 2>/dev/null | sed 's/^/kimi\t/' || true
}

{ cursor; claude; codex; opencode; kimi; } | while IFS=$'\t' read -r tool path; do
	mtime="$(date -u -r "$path" +%Y-%m-%dT%H:%M:%SZ)"
	[ -z "$since" ] || [ "${mtime%%T*}" \> "$since" ] || [ "${mtime%%T*}" = "$since" ] || continue
	printf '%s\t%s\t%s\n' "$tool" "$mtime" "$path"
done | sort -k2
