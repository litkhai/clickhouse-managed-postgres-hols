# AGENTS.md

Instructions for coding agents working in this repository.

This repository was split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols). Its
[AGENTS.md](https://github.com/litkhai/clickhouse-hols/blob/main/AGENTS.md) still applies here —
bilingual READMEs (English first, `## English` / `## 한국어`), no links to labs
that do not exist yet, and the **Verification claims** rule: only write
*"Verified on …"* when the scripts actually ran end to end against that version.

Differences from the core repository:

- No Pages site and no `site` CI job (decision D7). The root README tables are
  documentation only, not a site index.
- Enable the guard once per clone: `git config core.hooksPath .githooks`.

## Rules for this repository

- ClickHouse Managed Postgres hostnames (`*.pg.clickhouse.cloud`) are caught by the
  `clickhouse-managed-postgres-host` gitleaks rule. Use `<service>.<id>.c0.<region>.aws.pg.clickhouse.cloud`
  style placeholders in docs.
- Directory depth matches the original repository (`managed-postgres/<lab>`, `extensions/<lab>`),
  so `../../LICENSE` links keep working. Keep new labs at depth 2.
- Verification lines name both the Postgres/extension version and the ClickHouse version.

## Where things came from

Paths were renamed by `git filter-repo`, so `git log --follow` works across the
split. The original locations:

| In clickhouse-hols | Here |
|---|---|
| `managed-postgres/` | `managed-postgres/` |
| `local/pg-clickhouse-lab/` | `extensions/pg-clickhouse-lab/` |

## Tracking work

Planned work, re-verification and follow-ups are **GitHub issues**; every change
lands through a **pull request** that references its issue (`Closes #N`).
`STATUS.md` is a snapshot of the current state and links to the open issues
instead of keeping its own to-do list. When you find something to do that you
are not doing now, open an issue rather than writing it into a README or
`STATUS.md`. Labels: `re-verify` (changed but not re-run), `enhancement`,
`docs`, `ops`, `security`.

한국어: 해야 할 일은 GitHub 이슈로, 변경은 이슈를 참조하는 PR로 관리합니다. `STATUS.md`는 열린 이슈를 링크합니다.

## Model roles

Work in this repository is split across Claude models:

| Role | Model | Does |
|------|-------|------|
| Lead | **Opus** | Plans and designs the work, writes and updates documentation (READMEs, `AGENTS.md`, `STATUS.md`, issues, PR descriptions), splits the work into tasks and reviews what comes back |
| Implementer | **Sonnet** | Writes the code, scripts and SQL for a task the lead hands over, runs the checks, opens the PR |
| Status checker | **Haiku** | Read-only checks: CI and `smoke` results, open issues and PRs, link and syntax checks, what changed since the last look |

The lead gives the implementer one issue at a time with the design and the files
to touch; the implementer does not change the design or the docs' claims on its
own. Verification claims still follow the rule above: only a real end-to-end run
updates them, whichever model ran it.

한국어: Opus는 리드(설계·문서·리뷰), Sonnet은 구현(코드·PR), Haiku는 현황 체크(읽기 전용)를 맡습니다.
