# STATUS.md

**As of 2026-09-27** — split out of [litkhai/clickhouse-hols](https://github.com/litkhai/clickhouse-hols/tree/pre-split-2026-10) with history.

## CI

`checks`: `links`, `syntax`, `shellcheck` (advisory), `secrets` (gitleaks), `hygiene` — green.
GitHub secret scanning and push protection are on.

## Inventory

5 labs in the README tables; 0 single-language.

## Re-verification notes

Not re-run; update a README's verification line only after a real end-to-end run.

| What | Note |
|------|------|
| All labs | Moved from clickhouse-hols without code changes; verification claims in each README date from before the move. |
