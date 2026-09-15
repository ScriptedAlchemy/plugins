---
name: automate-maintainer
description: "Use for \"automate maintainer\", \"recreate <github user> as a skill\", \"review like <maintainer> would\", \"capture how <login> maintains this repo\", or wanting agents to review, triage, and answer the way a specific GitHub user does. Mines that user's PRs, code reviews, issues, and discussions on GitHub (one repo, an org, or globally) and drafts a <login>-maintainer skill via create-skill + unslop."
disable-model-invocation: true
---

# Automate maintainer

The **automate-me** skill turns your own Cursor history into a `-mode` skill. This one does the same for someone else, from their public record on GitHub. The output is one `<login>-maintainer` skill (e.g. `sokra-maintainer`) that lets an agent review a PR, triage an issue, or answer a discussion the way that person does in that codebase.

It orchestrates three things: the mining script in this skill's `scripts/`, Cursor's built-in `create-skill` (authoring), and the **unslop** skill (prose discipline). It sequences them. It doesn't replace them.

## Inputs

You need a GitHub login and a scope. Ask with `AskQuestion` if the user gave only one:

- **Login.** The GitHub handle to recreate.
- **Scope.** One repo (`--repo owner/name`), an owner (`--owner org`), or global (no flag). Repeat flags to widen. A maintainer's behavior is repo-specific, so prefer the narrowest scope that still yields a few hundred comments.
- **Window.** Default is the last 12 months (`--since YYYY-MM-DD` to change). Older behavior is weak evidence for how they act now.

`gh` must be authenticated. The token sees whatever repos the operator can read, so a private-org scope mines private review threads. Only mine repos the user is entitled to read, and never write private-repo content into a skill that lands in a public repo.

## Flow

### 0. Check for an existing skill

Look recursively for `.cursor/skills/**/<login>-maintainer/SKILL.md` and `~/.cursor/skills/<login>-maintainer/SKILL.md`. If one exists, confirm intent with `AskQuestion` (unless they already said "update"):

- Update the existing skill (default for repeat runs)
- Start fresh (rare, ask why before doing it)

Update mode changes the rest of the flow. Step 1 mines only since the skill was last edited (`git log -1 --format=%cI <path>`, passed as `--since`). Step 2 asks what's changed or missing. Step 4 edits the file in place, keeping sections the evidence hasn't contradicted.

### 1. Mine their GitHub record

Run the script. It writes JSONL files plus a `summary.txt` and prints the summary:

```bash
<this skill dir>/scripts/mine-github-user.sh <login> --repo owner/name --limit 200
```

Read `summary.txt` first. If `comments` is under ~50, widen the scope or window before mining further. The summary's review-verdict split (APPROVED vs CHANGES_REQUESTED vs COMMENTED) and most-reviewed paths are the first two facts about the maintainer and go straight into the notes. Its repo list marks each repo `public` or `PRIVATE`. Note the private ones now, because the guardrails below treat their content differently.

The script also sets aside `holdout.jsonl`, the maintainer's activity on their 3 newest reviewed PRs. Nobody reads it until the Evaluation step. It is the test set.

Then fan out one subagent per source file, in parallel, each reading only its file from the output dir and returning a short structured list of patterns with URL evidence for each. Read the **guard-the-context-window** principle skill first, because `comments.jsonl` can be large. Signals per source:

- `comments.jsonl` (kind `review` and `review_comment`): what they block on vs nit, recurring asks (tests, naming, API shape, perf, docs, changelog), whether they cite a reason or a rule, tone, how they phrase requests, what they approve without comment, what paths they show up on.
- `comments.jsonl` (kind `comment`) plus `prs-authored.jsonl`: how they respond to review of their own work, PR description shape, PR size, commit message style, how they prove a change works.
- `issues.jsonl` plus `comments.jsonl` on issues: what they demand before engaging (repro, version, minimal case), how they close (duplicate, wontfix, needs-info), labels they lean on, how quickly they push back on scope.
- `discussions.jsonl`: how they explain, what they refuse to support, how they redirect to docs or issues.

Cross-check across sources before elevating a signal. A rule seen in 2+ sources, or 3+ times in one, is high-confidence. Lone signals get dropped. Distinguish what they enforce on others from what they do themselves. Both matter, but they go in different sections.

### 2. Ask the user directly

The user is not the subject here, so don't ask about the subject's style. Ask what the persona is for. `AskQuestion`, one or two rounds, 4-6 options each, `allow_multiple: true`:

- Which jobs it should do (review PRs, triage issues, answer discussions, write in their voice for PR descriptions, judge what to merge).
- Which areas of the repo to weight, if the summary's path list shows the maintainer owns some corners more than others.
- Anything to leave out (a period they weren't active, an area they've handed off, one-off disputes).

One free-form question at the end catches what the options missed.

### 3. Cluster findings

Group into sections. Use only what the evidence supports:

- **Review bar.** What blocks a merge, what's a nit, what gets waved through.
- **Recurring asks.** The 5-10 things they ask for most, each with one linked example.
- **Triage.** What they need before engaging, how they close, labels they use.
- **Voice.** Length, tone, how they phrase a request vs a refusal. One or two short quotes with links.
- **Their own work.** PR shape, commit style, how they prove changes.
- **Ownership.** Paths and subsystems where their review carries the most weight.
- **Refusals.** What they consistently decline to support or merge, and how they say so.

The **poteto-mode** skill shows the granularity. Don't copy its content.

### 4. Draft the skill

Use Cursor's built-in `create-skill` skill to author it. Placement and frontmatter:

- Path: `.cursor/skills/<login>-maintainer/SKILL.md` in the repo the persona is for. For an org-wide or global persona, `~/.cursor/skills/<login>-maintainer/` if the user prefers it personal.
- `description`: trigger on the login, `/<login>-maintainer`, and phrases like "review this the way <login> would". Not on generic verbs like "review PR".
- One YAML scalar for `description`, quoted, per `create-skill`'s rules.
- `disable-model-invocation: true`.

Write rules in the imperative for the agent ("Block on missing tests for runtime changes"), not as biography ("<login> usually asks for tests"). Every non-obvious rule carries one evidence link.

### 5. Iterate on prose

Apply the **unslop** skill and `create-skill`'s writing guidelines to every line. Show the draft to the user. Cut anything that reads like a profile rather than an instruction.

### 6. Land it

Work in a worktree off main. Commit and open a PR. Don't push to main directly.

## Evaluation

This skill's output is testable, unlike a self `-mode` skill. `holdout.jsonl` holds the maintainer's real reviews on their 3 newest reviewed PRs, and nothing in the draft was derived from them. For each PR, give a fresh subagent the drafted skill and the PR diff (`gh pr diff <url>`), with no access to the mined files, and ask for a review. Compare its verdict and asks against `holdout.jsonl`. Same verdict and 2+ overlapping asks on 2 of 3 PRs is a pass. A miss points at a rule that's missing or too vague. Fix the rule, not the test. Three PRs is a smoke test, not a benchmark. Pass `--holdout 10` to the script when the maintainer has enough volume to afford it.

## Guardrails

- **Don't impersonate.** The skill encodes standards and voice for an agent working in that codebase. It never posts as the person, signs as them, or claims their approval. Say so in the drafted skill's first paragraph.
- **Evidence or cut.** A rule with no supporting URL in the mined data doesn't ship. A rule seen once is an anecdote. Write the URL into the skill unless the next guardrail forbids it.
- **Respect visibility.** `summary.txt` marks each repo `public` or `PRIVATE`. If the drafted skill lands in a public repo, rules supported only by private-repo evidence are dropped, not paraphrased. Private links, quotes, file paths, and issue titles never appear in it. A skill that itself lives in the private repo may cite that repo freely.
- **Recency wins.** A rule they enforced two years ago and stopped enforcing is not a rule.
- **Bots and noise.** Dependabot approvals, "LGTM" on trivial PRs, and emoji-only replies tell you the merge bar for trivia, nothing else. Don't build rules from them.
- **Reference, don't inline.** Contributing guides, CODEOWNERS, and style docs they point people at appear as path references in the skill, not pasted excerpts.
- **Name conventions generic.** "The maintainer" or "the reviewer" in imperatives, not the login, except in the description and title.

## When not to use

- The subject is you and the evidence is your Cursor history: **automate-me**.
- You want a contributing guide or CODEOWNERS routing, not a persona: a regular skill or the repo's docs.
- You want one narrow convention (how they write changelogs): a regular skill, no mining required.
