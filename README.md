# Micro Startup

`Micro Startup` is a repo-embedded crew runtime for small startup teams.

It installs into a product repo and gives that repo one command:

```bash
./micro-startup <command>
```

The default crew is still:
- `product`
- `design`
- `engineer`

But the runtime is no longer fixed to those three roles.

You can add or remove roles, choose archetypes, and let multiple writers work in isolated git worktrees.

## Quick Start

From your product repo:

```bash
/path/to/Micro_Startup/install.sh
./micro-startup start
```

Optional overrides:

```bash
cp .micro-startup/config.env.example .micro-startup/config.env
```

## What Gets Installed

After installation, your product repo contains:

```text
your-repo/
  micro-startup
  .micro-startup/
    .gitignore
    config.env.example
    crew.env
    roles/
      product.env
      design.env
      engineer.env
      ...
    prompts/
      product.md
      design.md
      engineer.md
      ...
    docs/
      backlog.md
      product.md
      design.md
      engineer.md
      ...
    scripts/
      common.sh
      role_once.sh
      triad_ctl.sh
    templates/
      prompts/
      repo-docs/
      role-prompts/
      role-docs/
    logs/
    runtime/
    worktrees/
```

Tracked by git:
- `crew.env`
- `roles/`
- `prompts/`
- `docs/`

Ignored locally by `.micro-startup/.gitignore`:
- `logs/`
- `runtime/`
- `worktrees/`
- `config.env`

## Public Commands

Main commands:

```bash
./micro-startup init
./micro-startup doctor
./micro-startup start
./micro-startup stop
./micro-startup restart
./micro-startup status
./micro-startup logs
./micro-startup attach
```

Role management:

```bash
./micro-startup role list
./micro-startup role add qa --archetype advisor
./micro-startup role add reviewer --archetype writer
./micro-startup role remove qa
```

You can also DIY roles manually by creating:
- `.micro-startup/roles/<id>.env`
- `.micro-startup/prompts/<id>.md`
- `.micro-startup/docs/<id>.md`

`doctor` and `start` auto-discover those manual roles.

## Crew Model

Supported archetypes:
- `writer`: isolated git worktree, may edit product code, test, commit, and enter auto-merge
- `planner`: runs in the main repo, may edit its own doc and `docs/backlog.md`
- `advisor`: runs in the main repo, may edit only its own doc
- `reviewer`: template-level reviewer, runtime behavior is the same as `advisor`

Default runtime model:
- multiple writers are allowed
- each writer gets its own branch and worktree
- writer branches use `codex/micro-startup/<role-id>` by default
- main-branch integration is local-only and uses automatic `cherry-pick`
- runtime state lives in `.micro-startup/runtime/*.state`

## Backlog Format

`docs/backlog.md` is the tracked task source.

One task per line:

```text
- TASK-001 | target=any-writer | priority=P1 | title=Implement onboarding CTA
```

Supported `target=` values:
- `any-writer`
- `role:<role-id>`
- `label:<label>`

Writers do not auto-edit `backlog.md`.
Claim, running, verified, merged, conflict, and repair state live in `.micro-startup/runtime/`.

## Runtime Rules

When the runtime is running:
- each active role gets one tmux window
- planners are serialized behind a backlog lock
- writers claim tasks from `backlog.md`
- writers work only inside their own git worktrees
- writers auto-merge back to `BASE_BRANCH` only after a local clean commit
- merge conflicts abort immediately and turn into runtime repair tasks

## Dependencies

Current assumptions:
- macOS
- `tmux`
- `caffeinate`
- Claude Code CLI installed and authenticated

`./micro-startup doctor` checks these dependencies plus role schema, backlog format, base branch, and worktree readiness.

## Migration

If an older three-role install is present, `init` and `doctor` migrate it automatically:
- `product_lead.md -> product.md`
- `design_lead.md -> design.md`
- `working_log.md -> engineer.md`

The runtime keeps old content and writes the new crew structure around it.

## Source Repo Layout

This source repo ships:
- `scripts/` for the installed runtime
- `prompts/` for default role prompts
- `templates/repo-docs/` for default tracked docs
- `templates/role-prompts/` and `templates/role-docs/` for `role add`
- `config/project.env.example` for optional overrides

See [examples/openbrowse/README.md](examples/openbrowse/README.md) for an OpenBrowse install example.
