# 🐝 Hiveflow CLI

[![npm version](https://img.shields.io/npm/v/@hiveflow/cli.svg)](https://www.npmjs.com/package/@hiveflow/cli)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub issues](https://img.shields.io/github/issues/hiveflowai/hiveflow-cli.svg)](https://github.com/hiveflowai/hiveflow-cli/issues)

A single entry point for **your entire AI coding stack**. Three powerful layers:

1. **CLI router** — orchestrates Claude Code, Gemini, Codex and Aider: infers the task type and launches the best installed CLI.
2. **Native agent** — its own agentic engine with a full tool-use loop (reads, edits, executes, searches, delegates to subagents) against the claude/chatgpt/gemini API. No dependency on any external CLI. With permissions, sessions, hooks, skills and MCP.
3. **Workers & automation** — local agents watching kanban boards: support tickets→PR pipeline, custom playbooks for sales/ops, parallel execution with human-in-the-loop gates. With metrics, evals and a CI gate.

```
$ hiveflow
  🐝 Welcome to Hiveflow 👋

hiveflow (auto·auto) ❯ fix the login bug
  › Router: task 'quick-fix' → codex

hiveflow (auto·auto) ❯ /agent refactor src/auth.js and run the tests
hiveflow (auto·auto) ❯ /worker list
hiveflow (auto·auto) ❯ /help
```

## Why Open Source?

**Transparency = Trust.** When you run `curl | bash` to install a development tool that touches your codebase, you deserve to audit every line. This CLI is MIT-licensed and fully auditable — inspect the code, report issues, contribute improvements.

The CLI is your on-ramp to the [Hiveflow platform](https://hiveflow.ai): visual workflow orchestration, remote control across devices, team collaboration, and workers that turn kanban boards into autonomous agents. Open-sourcing the CLI brings developers into the ecosystem while keeping our competitive advantage where it belongs: the platform itself.

## Documentation

| | |
|---|---|
| **[GUIDE.md](GUIDE.md)** | 📖 **Start here** — the map of the layers, first steps, daily usage, common problems |
| This README | Quick reference for every command |
| [SECURITY.md](SECURITY.md) | Security policy and vulnerability reporting |
| `/help` · `/help <command>` | Help inside the CLI itself |

## Installation

One line (no npm or git required):

```bash
curl -fsSL https://hiveflow.ai/install.sh | bash
hiveflow      # or the shortcuts: hive · hf · flow
```

With npm:

```bash
npm install -g @hiveflow/cli
```

Or from the repo (development):

```bash
git clone https://github.com/hiveflowai/hiveflow-cli.git
cd hiveflow-cli && ./install.sh
```

First run: welcome + Hiveflow account connection. **Subscription** login works like Claude Code's: it shows a code, opens the browser at `app.hiveflow.ai/cli-login`, you authorize and the CLI receives its credential on its own (no browser: it gives you the URL and the code so you can do it from any device). You can also paste an **API key** `hf_...` from your profile.

For the agent's LLM you have two paths (`/llm`): **your Hiveflow account** (tokens run against your plan's credits, no provider API key needed) or **your own API key** for claude/chatgpt/gemini.

## `/` Commands

### 🔧 AI CLIs (router layer)
| | |
|---|---|
| `/tools` | See the CLIs and their status |
| `/install <tool\|all>` | Install claude, gemini, codex, aider |
| `/use <tool\|native\|auto>` | Active CLI, `native` (own agent), or `auto` (routing per task) |
| `/mode <auto\|safe>` | `auto`: they act on their own · `safe`: they ask for confirmation |
| `/route <text>` | Preview the router's decision |
| `/health` | Verify they respond |

### 🤖 Native agent (own agentic engine, no external CLIs)

Full tool-use loop against the API of the provider you choose (claude/chatgpt/gemini):
**read_file · write_file · edit_file · bash_exec · web_fetch · grep_search · glob_files · subagent** (+ tools from connected MCP servers).

| | |
|---|---|
| `/agent <prompt>` | One-shot: the agent reads, edits, executes and responds |
| `/agent` | Interactive multi-turn (auto-persisted, resumable sessions) |
| `/plan <task>` | Plan mode: explores and proposes **without executing** (read-only tools) |
| `/cost` | Input/output tokens consumed in the session |
| `/use native` | Send all free-form REPL text to the native agent |
| `/permissions` | Persistent tool allowlist (`list · allow · deny · remove`) + hard denylist against `rm -rf /` |
| `/sessions` | Sessions: `list · show · resume <id> · remove · migrate` |
| `/skills` | Custom slash commands in markdown (`list · show · install · remove`) — ships builtins: `/analyze /refactor /security /test /docs ...` |
| `/hooks` | Pre/post hooks for every tool (`list · add · remove`) |
| `/mcp` | MCP servers: `list · add · remove · test` (`enabled` ones auto-connect when the agent starts) |

In `/mode safe` every mutating tool asks for confirmation; in `/mode auto` it acts on its own. The router treats `native` as a full-fledged candidate: with no CLIs installed, with just your API key, everything works.

**Project context**: on startup, the agent injects your `AGENTS.md`/`CLAUDE.md` from the current directory + the repo structure as system prompt (opt out with `HIVEFLOW_NO_PROJECT_CONTEXT=1`).

### 🎫 Support tickets → PR
| | |
|---|---|
| `/tickets setup` | Connect to the Hiveflow backend (API, org, kanban board, support chat) |
| `/tickets` | List the board's tickets |
| `/fix <ticket-id> [--dry-run]` | Full pipeline: **1)** reads the ticket and the user's chat → **2)** AI triage (fix / missing info / duplicate / not-a-bug) and which catalog repos it touches → **3)** isolated worktree with branch `fix/<ticketId>` from the repo's base → **4)** implements with agents → **5)** tests → **6)** security review + e2e → **7)** diff guard + PR → notifies the ticket's chat and moves it to **"Espera Aprobación"** (Awaiting Approval) |
| `/tickets watch` | One pass of the autonomous agent (priority queue, cap per pass, flood detection) |
| `/tickets sync` | Rebases the bot's open PRs onto their base; real conflicts → human alert |
| `/tickets cron on\|off\|status` | Autonomous agent every 5 min |
| `/tickets stats [days]` | 📊 Harness telemetry: PR acceptance rate, average time to PR, where it fails and why tickets get filtered |
| `/intake` | 📥 Other sources: prod alerts, tech debt (FIXME/HACK), npm audit |
| `/eval` | 🧪 Test bench from your real commits: does a change improve or worsen things? |
| `/review` | 👀 The agent reviews PRs opened by humans |
| `/deploy check` | 🚀 Did what got merged break production? |
| `/routing` | 🧭 Which CLI works best in each repo (learned from history) |
| `/loop trace <id>` | 🔁 Audit the loop: what it tried and what it verified |
| `/remote` | 🖥️ Run tickets on nodes (this PC or another machine) |

**CI gate:** after opening the PR, the pipeline waits for the repo's checks (`gh pr checks`). CI green → the ticket moves to "Espera Aprobación" (Awaiting Approval); CI red or pending → the PR stays open, the chat is notified and the ticket goes back to the queue. Disable with `.tickets.ci_gate = false`.

**Production protections:** ticket content treated as untrusted (anti prompt-injection) · PRs blocked if they touch `.env`/secrets/CI, if the diff is oversized or empty · `.env`+`node_modules` injected into the worktree with no commit risk · timeouts on agents and tests · 1 ticket = 1 PR (idempotent retries) · ticket flood = pause + alert (systemic incident) · GC of zombie worktrees.

### 💬 Direct API chat (no CLIs, no tools)
| | |
|---|---|
| `/llm` | Pick a provider: **hiveflow** (your plan's credits, no API key) or claude/chatgpt/gemini with your key — also configures the native agent |
| `/ask <question>` | One-off query to the configured provider |

### 👤 Account
`/status` · `/login` · `/logout` · `/help` · `/exit`

**Anything that doesn't start with `/` is a code request** — the router infers the task type (es/en) and launches the best installed CLI (or the native agent, if that's what's available or what you pinned).

## Architecture

```
hiveflow-cli/
├── hiveflow.sh          # entry: welcome, auth, REPL, subcommands
├── lib/core/            # UI, config, auth, tools, router, llm, agent, repl,
│                        # tickets, intake, eval, deploy, review, loop, remote
├── lib/agent/           # native agentic engine (vendored from asis-coder):
│   ├── tool_calling.sh  #   multi-provider ReAct loop (anthropic/openai/gemini)
│   ├── tools/           #   read/write/edit/bash/web_fetch/grep/glob/subagent
│   ├── permissions.sh   #   allowlist + hard denylist + confirmation
│   ├── sessions.sh      #   persistent multi-turn sessions
│   ├── hooks.sh         #   pre/post tool hooks
│   ├── skills.sh        #   custom slash commands (markdown)
│   └── mcp_client.sh    #   MCP client (stdio JSON-RPC)
└── lib/skills/builtin/  # bundled skills (/analyze /refactor /security ...)
```

The agent engine keeps its state under `~/.config/coder-cli` (permissions, sessions, hooks, mcp.json). Hiveflow's own config lives in `~/.config/hiveflow/config.json`.

## Non-interactive / embedded usage

```bash
# Router → external CLIs
hiveflow -p "write tests for src/auth.js"

# Native agent one-shot: stdout = model response, real exit code.
# Embeddable in scripts, CI or other apps with no prior config:
export HIVEFLOW_LLM_PROVIDER=claude HIVEFLOW_LLM_KEY=sk-... HIVEFLOW_LLM_MODEL=claude-sonnet-5
hiveflow agent --yes "fix the TODO in src/auth.js and run the tests"

# Multi-turn with a resumable session
hiveflow agent                      # interactive
hiveflow agent --session <id>      # resume

# Plan mode (read-only) and structured output for pipelines
hiveflow agent --plan "migrate auth to JWT"
hiveflow agent --json --yes "run npm test and summarize"   # → {ok, exit, response, tokens_in, tokens_out}

# Passthrough for systemd/cron/scripts
hiveflow tickets watch
```

`--yes` auto-approves mutating tools (equivalent to `/mode auto`). Without it, in `safe`, every `bash_exec`/`write_file` asks for confirmation or consults the `/permissions` allowlist.

## Tests

```bash
npm test        # 38 suites (full agentic engine + hiveflow shim, offline with mocks)
```

## Requirements

`bash`, `jq`, `curl` · The AI CLIs install from the REPL (`/install all`) · The native agent only needs an API key (`/llm`).
