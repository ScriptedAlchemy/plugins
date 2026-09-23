---
name: automate-maintainer
description: "Use for \"automate maintainer\", \"create/update a <login>-mode maintainer persona\", \"review like <maintainer> would\", \"capture how <login> maintains this repo\", or wanting agents to review, triage, and answer the way a specific GitHub user does. Mines that user's PRs, reviews, issues, and discussions on GitHub and drafts a <login>-mode skill via create-skill + unslop."
disable-model-invocation: true
---

# Automate maintainer

The **automate-me** skill turns your own history into a `-mode` skill. This one does the same for someone else, from their public record on GitHub. The output is one `<login>-mode` skill (e.g. `sokra-mode`) that lets an agent review a PR, triage an issue, or answer a discussion the way that person does in that codebase. Same concept as a personal operator mode, different evidence source.

It orchestrates three things: an inline mining pass over GitHub (see step 1), Cursor's built-in `create-skill` (authoring), and the **unslop** skill (prose discipline). It sequences them. It doesn't replace them.

## Naming

The drafted skill is always `<login>-mode`, never `<login>-maintainer`. If `<login>-mode` already exists as an AutomateMe personal mode for the same login string, use `<login>-maintainer-mode` instead and say so in the skill body. On update, look for a legacy `<login>-maintainer` dir and migrate/rename it to `<login>-mode`.

## Inputs

You need a GitHub login and a scope. When the user gives neither, default the scope to the repo of the current directory and discover the login by ranking the people behind recent merged PRs (`gh pr list --state merged --limit 200`, then per-PR reviewers via `gh api`). Present the top candidates with `AskQuestion` (`allow_multiple: true`, 4-6 options, each labelled `login (merged N, reviewed N)`), asking which maintainer or maintainers to automate. Drop obvious bots. One selected login runs the flow below once. Several run the mining for all of them in parallel and then the rest of the flow per login, producing one `<login>-mode` skill each.

Ask with `AskQuestion` if the user gave only one of the two:

- **Login.** The GitHub handle to draft a mode for.
- **Scope.** One repo, one owner/org, or global. A maintainer's behavior is repo-specific, so prefer the narrowest scope that still yields a few dozen review comments.
- **Window.** Default is the last 12 months. Older behavior is weak evidence for how they act now.

`gh` must be authenticated. The token sees whatever repos the operator can read, so a private-org scope mines private review threads. Only mine repos the user is entitled to read, and never write private-repo content into a skill that lands in a public repo.

## Flow

### 0. Check for an existing skill

Look recursively for `.cursor/skills/**/*<login>-mode/SKILL.md` and `~/.cursor/skills/*<login>-mode/SKILL.md`, plus a legacy `<login>-maintainer` dir to migrate. If one exists, confirm intent with `AskQuestion` (unless they already said "update"):

- Update the existing skill (default for repeat runs)
- Start fresh (rare, ask why before doing it)

Update mode changes the rest of the flow. Step 1 mines only since the skill was last edited. Step 2 asks what's changed or missing. Step 4 edits the file in place, keeping sections the evidence hasn't contradicted. Apply the collision rule above when the name is taken.

### 1. Mine their GitHub record

Collect with `gh` (`gh search prs --reviewed-by <login>`, `--author <login>`, `gh search issues --involves <login>`, `gh api` for review and comment bodies). Set aside their activity on the 3 newest reviewed PRs before reading anything else. Nobody reads it until the Evaluation step. It is the test set.

If review comments total under ~50, widen the scope or window before mining further. Note each repo's `public`/`PRIVATE` visibility now, because the guardrails below treat their content differently.

Then fan out one subagent per source, in parallel, each returning a short structured list of patterns with URL evidence for each. Signals per source:

- Reviews and inline comments: what they block on vs nit, recurring asks (tests, naming, API shape, perf, docs, changelog), whether they cite a reason or a rule, tone, how they phrase requests, what they approve without comment, what paths they show up on.
- Authored PRs and review replies: PR description shape, PR size, commit message style, how they prove a change works, how they respond to review of their own work.
- Issues and issue comments: what they demand before engaging (repro, version, minimal case), how they close (duplicate, wontfix, needs-info), labels they lean on, how quickly they push back on scope.
- Discussions: how they explain, what they refuse to support, how they redirect to docs or issues.

Cross-check across sources before elevating a signal. A rule seen in 2+ sources, or 3+ times in one, is high-confidence. Lone signals get dropped. Distinguish what they enforce on others from what they do themselves. Both matter, but they go in different sections.

### 2. Ask what the persona is for

The user is not the subject here, so don't ask about the subject's style. Ask what the persona is for. `AskQuestion`, one or two rounds, 4-6 options each, `allow_multiple: true`:

- Which jobs it should do (review PRs, triage issues, answer discussions, judge what to merge).
- Which areas of the repo to weight, if the evidence shows the maintainer owns some corners more than others.
- Anything to leave out (a period they weren't active, an area they've handed off, one-off disputes).

One free-form question at the end catches what the options missed.

### 3. Cluster findings into lean mode sections

Group the combined signals into a short mode skill in the shape of **zack-mode**: lean imperative sections, ~60 lines total, not a review encyclopedia. Use only what the evidence supports:

- **Verification.** What "mergeable" means here: merge bar, repro posture, what proof a change needs.
- **Discipline.** The few hard bars and recurring asks, as rules. Cut verdict-model walls.
- **Delegation and ownership.** When to decide vs ask; paths and subsystems where this mode applies.
- **Replies.** Voice: lead with the outcome, how they phrase a request vs a refusal. One or two short quotes with links.
- **Process.** PR shape, commits, triage habits, and what they consistently decline.

Short frontmatter, `# <Login> mode` heading, then sections only. Subtract before add.

### 4. Draft the skill

Use Cursor's built-in `create-skill` skill to author it. Placement and frontmatter:

- Path: preserve an existing mode skill's category. For a new mode, `.cursor/skills/<login>-mode/SKILL.md` in the repo the persona is for (or `~/.cursor/skills/<login>-mode/` if the user prefers it personal). Migrate any legacy `<login>-maintainer` dir on update.
- Title: `# <login> mode`, not `# <login> maintainer`.
- Opening: one short paragraph. This is a conventions skill the agent follows when invoked. Don't impersonate, don't sign as them, don't claim their approval. Name the evidence window. Not a biography.
- Frontmatter `name`: `<login>-mode` (`<login>-maintainer-mode` only under the collision rule).
- Frontmatter `description`: trigger on the login + `/<login>-mode` + "work in their style / review like them". Not on generic verbs like "review PR".
- Frontmatter formatting: follow `create-skill`'s YAML rules. Keep `description` as one YAML scalar. Quote it or use `description: >-` with indented continuation lines when punctuation or wrapping requires it.
- Frontmatter `disable-model-invocation: true` by default.

Write rules in the imperative for the agent ("Block on missing tests for runtime changes"), not as biography ("<login> usually asks for tests"). Every non-obvious rule carries one evidence link. Target ~60 lines for the whole skill. Cut anything that reads like a profile rather than an instruction.

### 5. Iterate on prose

Apply the **unslop** skill and `create-skill`'s writing guidelines to every line.

Show the draft to the user and take feedback. Expect multiple iterations. Cut ruthlessly. A mode skill is not a manual.

### 6. Land it

Work in a worktree off main. Commit and open a PR. Don't push to main directly.

## Evaluation

This skill's output is testable, unlike a self `-mode` skill. The held-out activity on the 3 newest reviewed PRs was never mined. For each PR, give a fresh subagent the drafted skill and the PR diff (`gh pr diff <url>`), with no access to the mined material, and ask for a review. Compare its verdict and asks against what the maintainer actually did. Same verdict and 2+ overlapping asks on 2 of 3 PRs is a pass. A miss points at a rule that's missing or too vague. Fix the rule, not the test. Three PRs is a smoke test, not a benchmark.

## Guardrails

- **Don't impersonate.** The skill encodes standards and voice for an agent working in that codebase. It never posts as the person, signs as them, or claims their approval. Say so in the drafted skill's first paragraph.
- **Evidence or cut.** A rule with no supporting URL in the mined data doesn't ship. A rule seen once is an anecdote. Write the URL into the skill unless the next guardrail forbids it.
- **Respect visibility.** If the drafted skill lands in a public repo, rules supported only by private-repo evidence are dropped, not paraphrased. Private links, quotes, file paths, and issue titles never appear in it. A skill that itself lives in the private repo may cite that repo freely.
- **Recency wins.** A rule they enforced two years ago and stopped enforcing is not a rule.
- **Bots and noise.** Dependabot approvals, "LGTM" on trivial PRs, and emoji-only replies tell you the merge bar for trivia, nothing else. Don't build rules from them.
- **Reference, don't inline.** Contributing guides, CODEOWNERS, and style docs they point people at appear as path references in the skill, not pasted excerpts.
- **Keep sections minimal.** Only add a section if the evidence supports a specific, non-default rule there.
- **Name conventions generic.** "The maintainer" or "the reviewer" in imperatives, not the login, except in the description and title.

## When not to use

- The subject is you and the evidence is your own history: **automate-me**.
- You want a contributing guide or CODEOWNERS routing, not a persona: a regular skill or the repo's docs.
- You want one narrow convention (how they write changelogs): a regular skill, no mining required.
