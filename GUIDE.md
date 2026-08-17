# 🐝 Hiveflow CLI User Guide

A practical manual. If you're looking for the command reference, it's in the
[README](README.md); for the system design, see [HARNESS.md](HARNESS.md).

---

## Table of contents

1. [The map: what layers exist and when to use each](#the-map-what-layers-exist-and-when-to-use-each)
2. [First 5 minutes](#first-5-minutes)
3. [Daily usage: asking for code](#daily-usage-asking-for-code)
4. [The native agent](#the-native-agent)
5. [Embedding hiveflow in scripts and other apps](#embedding-hiveflow-in-scripts-and-other-apps)
6. [The bug agent, step by step](#the-bug-agent-step-by-step)
7. [Swarm and autonomous loops](#swarm-and-autonomous-loops)
8. [Is it working? Reading the metrics](#is-it-working-reading-the-metrics)
9. [Tuning the agent with data](#tuning-the-agent-with-data)
10. [Configuration](#configuration)
11. [Common problems](#common-problems)

---

## The map: what layers exist and when to use each

Hiveflow is **four layers on top of a single binary**. Knowing which one to use
at any given moment is 80% of this guide:

| Layer | What it is | When to use it |
|---|---|---|
| **CLI router** | Launches the best installed CLI (Claude Code, Gemini, Codex, Aider) based on the task type | Daily interactive work: you type what you need and that's it |
| **Native agent** | Its own agentic engine: tool-use loop against the API (reads, edits, executes, delegates) | When you don't want to depend on external CLIs, for embedding in scripts/CI, or when you want fine-grained control (permissions, hooks, sessions, MCP) |
| **Swarm + Ralph** | Agents distributed across devices, autonomous loops over PRDs | Large features that run on their own for hours/days, on one or several machines |
| **Tickets → PR** | Support pipeline: triage, fix in a worktree, PR, metrics | Bugs reported by users; the agent turns them into reviewable PRs |

Quick mental rules:

- **"I need this now"** → type the prompt directly (router) or `/agent <prompt>`.
- **"I want a script/pipeline to do it"** → `hiveflow agent --yes "..."` (embeddable).
- **"Let it work on its own while I sleep"** → `/ralph` (features) or `/tickets cron on` (bugs).
- **"I want to spread it across my machines"** → `/swarm wizard`.

The layers share state: the API chat (`/llm`) also feeds the native agent; the
swarm and the agent share `~/.config/coder-cli` (permissions, sessions, MCP);
the ticket metrics feed the routing.

---

## First 5 minutes

```bash
npm install -g hiveflow-cli     # or: git clone ... && ./install.sh
hiveflow
```

You get four equivalent names: **`hiveflow`**, **`hive`**, **`hf`** and
**`flow`**. Use whichever you prefer — `hf` is the shortest and matches the
code's prefix. If you ever install the HuggingFace CLI (also called `hf`),
use `hive` or `flow`.

On startup it welcomes you and asks to connect your account. Subscription
login works like Claude Code's: the CLI shows you a code (`XXXX-XXXX`), opens
the browser at `app.hiveflow.ai/cli-login`, you press **Authorize** and the
CLI connects on its own — the issued credential is an `hf_` API key that
shows up in your profile as "CLI: your-machine" and can be revoked whenever
you want. If you're on a server without a browser, it prints the URL and the
code so you can authorize from any other device. The alternative is to paste
an API key from your profile directly.

After that you're inside the REPL: anything starting with `/` is a command;
everything else is a code request.

**The first things worth doing:**

```
/tools          which CLIs do I have installed?
/install all    install the missing ones
/llm            claude/chatgpt/gemini API key → enables /ask and the native agent
/help           see everything there is
/help agent     detailed help on a specific topic
```

To exit: `/exit` (or Ctrl+D).

> **No CLI installed at all?** No problem: with just the `/llm` API key,
> the router automatically falls back to the native agent and everything
> works the same.

---

## Daily usage: asking for code

Type what you need, no command:

```
hiveflow (auto·auto) ❯ fix the login bug
  › Router: task 'quick-fix' → codex
```

The prompt always shows you the state: `(tool·mode)`.

- **`/use claude`** pins a specific CLI · **`/use native`** pins the own agent · **`/use auto`** lets the router choose
- **`/mode safe`** makes them ask for confirmation · **`/mode auto`** lets them act on their own
- **`/route <text>`** previews what the router would pick, without executing anything

How the router decides: it infers the task type from keywords (es/en) —
fix/bug → `aider/codex`, refactor → `claude`, docs/research → `gemini`,
security → `claude` — and walks the candidate chain until it finds one that's
installed. With enough history (`/routing`), it learns which CLI performs best
in each repo and adjusts itself.

---

## The native agent

The native agent is a **full agentic engine inside hiveflow**: it runs a
tool-use loop until the task is done. In `/llm` you choose who provides the
tokens:

- **hiveflow** — uses your account: calls go through the api.hiveflow.ai
  proxy, are billed against your plan's credits, and you don't need any
  provider API key. (Requires `/login`.)
- **claude / chatgpt / gemini** — straight to the provider with your own API key.

Its tools:

```
read_file · write_file · edit_file · bash_exec (with streaming) ·
web_fetch · grep_search · glob_files · subagent (+ MCP tools)
```

### Using it

```
/agent read package.json and tell me what scripts there are   ← one-shot
/agent                                                        ← interactive multi-turn mode
/plan migrate auth to JWT                                     ← plan mode: proposes WITHOUT executing
/cost                                                         ← tokens consumed in the session
/use native                                                   ← all free-form text goes to the agent
```

**The agent knows your project**: on startup it injects the `AGENTS.md` or
`CLAUDE.md` from the current directory (if it exists) + the repo structure as
system prompt. Write an `AGENTS.md` with your rules and every prompt will
respect it. Opt-out: `HIVEFLOW_NO_PROJECT_CONTEXT=1`.

**Plan mode** (`/plan`) registers only the read tools (`read_file`,
`grep_search`, `glob_files`, `web_fetch`): the agent explores whatever it
needs and produces a step-by-step plan, with a structural guarantee that it
touches nothing.

In interactive mode each turn keeps the history and **the session persists
itself**: if you close, `/sessions list` gives you the id and
`/sessions resume <id>` (or `hiveflow agent --session <id>` from outside)
resumes it where it was.

Inside interactive mode you also have slash commands that expand into prompts
with tools (`/analyze`, `/refactor <target>`, `/security`, `/test`, `/docs`,
`/fix <desc>`, `/focus <file>`, `/summary`...) — they come from the builtin
skills and you can add your own (below).

### Permissions: the handbrake

Read tools (`read_file`, `grep_search`, `glob_files`) always pass.
Mutating ones (`write_file`, `edit_file`, `bash_exec`, `subagent`...) depend
on the mode:

- **`/mode auto`** → they auto-approve (equivalent to `--yes`).
- **`/mode safe`** → each one asks for interactive confirmation, or consults
  the persistent allowlist you manage with `/permissions allow|deny|remove`.

There's also a **hard, non-disableable denylist** (`rm -rf /`, `mkfs`,
fork bombs, writes to `/dev/sd*`...) that always applies, even in `auto`.
And the `subagent` tool has an anti-recursion brake (max depth 3).

### Skills: your own slash commands

A skill is a markdown file with frontmatter (`description`) and a body that
becomes a prompt (with an optional `{{args}}` placeholder). Install them with
`/skills install ./my-skill.md` (they live in `~/.config/coder-cli/skills/`);
`/skills list` shows the available ones (yours + the package builtins)
and `/skills show <name>` displays their content.

### Hooks: intercepting every tool

`/hooks add tool_pre <tool> <command>` runs your command before every
invocation (and `tool_post` afterwards, with the result). Useful for logging,
automatic linters after every `edit_file`, or notifications.

### MCP: connecting more tools

```
/mcp add fs npx -y @modelcontextprotocol/server-filesystem /tmp
/mcp test fs        connects, lists its tools and disconnects (verification)
/mcp list           registered servers
/mcp remove fs      delete
```

No manual "connecting" required: servers with `enabled: true` in
`~/.config/coder-cli/mcp.json` **auto-connect when the agent starts** and
their tools register in the loop — the model sees them just like the native ones.

---

## Embedding hiveflow in scripts and other apps

The `agent` subcommand is designed to be **embeddable**: stdout is the model's
response (tool progress goes to stderr), the exit code is real, and it needs
neither a hiveflow account nor prior config — everything can come via env:

```bash
export HIVEFLOW_LLM_PROVIDER=claude          # hiveflow | claude | chatgpt | gemini
export HIVEFLOW_LLM_KEY=sk-ant-...           # with provider=hiveflow: an hf_ API key from your profile
export HIVEFLOW_LLM_MODEL=claude-sonnet-5    # optional

hiveflow agent --yes "fix the TODO in src/auth.js and run the tests"
echo $?                                      # 0 if it finished fine

# Structured output for pipelines:
hiveflow agent --json --yes "run npm test and summarize the result"
# → {"ok":true,"exit":0,"response":"...","tokens_in":1234,"tokens_out":567}

# Risk-free plan (read-only), ideal for reviewing before letting it loose:
hiveflow agent --plan "unify the API's error handling"
```

- `--yes` auto-approves mutating tools (essential without a TTY).
- Without `--yes`, in a pipeline without a terminal, mutating tools are
  rejected (fail-safe) unless they're in the `/permissions` allowlist.
- `HIVEFLOW_LLM_*` wins over what's stored in config — you can have your
  personal key in `/llm` and a different one in CI.
- For tool-less responses (text only), `hiveflow -p "..."` uses the
  router/CLIs, and `/ask` the pure API chat.

Other non-interactive passthroughs: `hiveflow tickets watch|list|fix|cron`,
`hiveflow swarm daemon start --foreground` (systemd), `hiveflow loop|deploy|
review|eval|intake|remote ...`.

---

## The bug agent, step by step

### Day 1 — configure

```
/tickets setup
```

It will ask for: the backend URL, Organization ID, and to pick the kanban
board and the support chat. Also the root of your repos (it discovers the git
repos inside it).

### Day 2 — try it risk-free

```
/tickets                    lists the board's tickets
/fix HF-xxxx --dry-run      rehearsal: shows what it would do, touching nothing
```

`--dry-run` is the safe way to see the whole pipeline: which repos it thinks
are involved, which branch it would create, which command it would launch.

### Day 3 — one real, supervised run

```
/fix HF-xxxx
```

You'll see the 7 steps. When it finishes there's a PR waiting for your review
and the ticket is in "Espera Aprobación" (Awaiting Approval).

### Day 4 — let it loose

```
/tickets cron on      every 5 min it works the tickets in "Por Hacer" (To Do)
/tickets cron status  check it's alive and see the latest passes
/tickets cron off     turn it off
```

**What it does on each pass:** takes up to 3 tickets (the highest priority
ones), works them one by one in isolated worktrees, opens PRs, and along the
way rebases the open PRs so they stay mergeable.

**What it NEVER does:** merge code without you. It can only auto-merge
documentation or dependency changes, and only if you enable it and there's
history to back it up.

### Feeding the queue from other sources

```
/intake alert alert.json     a Sentry/monitoring alert
/intake scan                 tech debt (FIXME/HACK) + npm audit
```

---

## Swarm and autonomous loops

For long-running work that runs on its own. Two pieces that combine:

- **`/prd`** generates a PRD (bootstrap of a new project, feature on an
  existing one, or merger) that serves as the contract for the loops.
- **`/ralph`** runs the autonomous loop over that PRD: implement → verify →
  iterate, with the brakes documented in [LOOPS.md](LOOPS.md).
- **`/swarm wizard`** distributes agents across your devices (via
  ssh/tmux/redis); `/agents` controls which CLI each agent uses and
  `/dashboard` shows it live.

The swarm requires `bash 4+` (on macOS: `brew install bash`). The rest of the
CLI — router, native agent, tickets — works with the stock bash 3.2.

---

## Is it working? Reading the metrics

```
/tickets stats        last 7 days
/tickets stats 30     last month
```

**The metric that decides everything is the acceptance rate** (what % of its
PRs you end up merging):

| Acceptance | What it means | What to do |
|---|---|---|
| **>70%** | It's saving you work | Raise `max_per_pass` |
| **40-70%** | Useful but improvable | Look at "Why they were rejected" |
| **<40%** | It's creating extra work | Review before continuing (below) |

The other sections tell you **where** to look:

- **"Why they were rejected"** — your own comments on the closed PRs.
  The most actionable thing there is: if you keep repeating "doesn't cover
  case X", that goes into the prompt.
- **"Acceptance per CLI"** — if one CLI performs worse, the routing will
  learn it on its own.
- **"Filtering reasons"** — many `diff_too_large` = your limit is too tight
  for these repos; many `needs_info` = the tickets arrive poorly written.
- **"Failures per repo"** — if one dominates, it's probably missing a
  CLAUDE.md or its test setup is fragile.

And for production:

```
/deploy check     are the endpoints healthy?
/deploy watch     does any degradation coincide with a recent merge by the bot?
```

---

## Tuning the agent with data

Don't change prompts blindly. Measure:

```
/eval add hiveflow-backend <sha-of-a-real-fix>    build the bench
/eval list                                        see the cases
/eval run                                         baseline
    ... you change something: /use another-cli, or a prompt ...
/eval run                                         second measurement
/eval compare                                     did it improve or get worse?
```

The bench is built from **your own fix commits**: it recreates the state just
before the fix and compares what the agent does with what you did.

```
/routing    which CLI works best in each repo (learned from history)
```

The routing adjusts itself only when there's evidence (≥4 decided PRs and
≥60% acceptance in that repo). Without enough data it uses the default table.

---

## Configuration

Two homes, depending on the layer:

**`~/.config/hiveflow/config.json`** (permissions 600) — hiveflow's own:

| Key | Default | What for |
|---|---|---|
| `tool` / `mode` | auto / auto | Active CLI and mode (set by `/use` and `/mode`) |
| `llm.provider/key/model` | — | API chat **and** native agent (set by `/llm`) |
| `tickets.max_per_pass` | 3 | Tickets per cron pass |
| `tickets.flood_threshold` | 8 | More pending = incident: pause and alert |
| `tickets.agent_timeout` | 1800 | Max seconds per agent |
| `tickets.max_diff_files` | 25 | Cap on files per PR |
| `tickets.require_test` | true | Require a reproduction test |
| `tickets.ci_gate` | true | Wait for CI before marking as ready |
| `tickets.ultracode` | false | Multi-agent workflows (more tokens) |
| `tickets.automerge.docs` | false | Auto-merge of docs-only changes |
| `tickets.automerge.deps` | false | Auto-merge of deps-only changes |
| `tickets.*_column` | — | Kanban column names |

**`~/.config/coder-cli/`** — the shared state of the engines (native agent +
swarm), inherited from asis-coder with no migration:

| File/dir | What it stores |
|---|---|
| `permissions.json` | Agent tool allowlist/denylist (`/permissions`) |
| `sessions/` | Agent multi-turn sessions (`/sessions`) |
| `hooks.json` | Pre/post tool hooks (`/hooks`) |
| `skills/` | Your custom skills (`/skills`) |
| `mcp.json` | Registered MCP servers (`/mcp`) |

Useful env vars: `HIVEFLOW_CONFIG_DIR`, `HIVEFLOW_ENGINE_DIR`,
`HIVEFLOW_LLM_PROVIDER/KEY/MODEL`, `HIVEFLOW_NO_PROJECT_CONTEXT=1` (don't
inject AGENTS.md/structure), `TOOL_LOOP_MAX_ITERATIONS` (loop iterations,
default 40), `CODER_CLAUDE_MODEL` / `CODER_OPENAI_MODEL` / `CODER_GEMINI_MODEL`
(models per provider; unset: `claude-sonnet-5` / `gpt-4o` /
`gemini-2.5-pro`).

Default columns for the ticket flow (Spanish names, configurable via
`tickets.*_column`):
`Por Hacer` (To Do) → `En Progreso` (In Progress) → `Espera Aprobación`
(Awaiting Approval) → `Hecho` (Done), plus `Necesita Humano` (Needs Human,
triage) and `Error Auto` (Auto Error, retries exhausted).

---

## Common problems

**The native agent says the provider/key is missing**
Configure it with `/llm` (or export `HIVEFLOW_LLM_PROVIDER` and
`HIVEFLOW_LLM_KEY`). The agent doesn't use your hiveflow account: it uses
your API key.

**The agent won't run `bash_exec`/`write_file` in a script**
You're in `safe` mode without a TTY: mutating tools are rejected by design.
Add `--yes` to the command, or pre-approve tools with `/permissions allow`.

**`/swarm` says it needs bash 4+**
The swarm engine uses `declare -A` and macOS's stock bash is 3.2:
`brew install bash`. The rest of the CLI (router, native agent, tickets)
works without that.

**The cron does nothing**
`/tickets cron status` shows the latest passes. Usual causes: no tickets in
the trigger column, or the column name doesn't match (check
`tickets.watch_column`). The full log is at
`~/.config/hiveflow/watch.log`.

**"No CLI installed"**
`/tools` to see the status, `/install all` to install them — or configure
`/llm` and let the router use the native agent. If the cron works by hand
but not automatically, it's usually the PATH: the crontab that
`/tickets cron on` generates already injects it, but if you installed a CLI
afterwards, regenerate with `/tickets cron off && /tickets cron on`.

**PRs aren't being created**
You need an authenticated `gh` (`gh auth status`). Without it, the pipeline
gets as far as the commit but doesn't open a PR.

**"no reproduction test"**
The agent didn't write a test and the gate stops it. That's intentional. If a
repo doesn't need it: `tickets.require_test = false`.

**Tickets stuck in "Error Auto"**
They exhausted the 2 attempts. Look at them by hand: they're usually poorly
described bugs or ones that require product decisions.

**A ticket got split into subtasks**
The triage considered it too big for a reviewable PR. The original stays in
"Necesita Humano" (Needs Human) and the parts enter the queue separately.

**The agent touched something it shouldn't have**
It shouldn't be able to: PRs touching `.env`, secrets, certificates or CI
workflows are blocked before being created, and the native agent has a hard
denylist (`rm -rf /`, `mkfs`, ...) even in auto mode. If you see something
like that, it's a bug — report it.
