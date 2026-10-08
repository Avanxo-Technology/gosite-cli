# Token baseline (before)

Measured 2026-10-08 on gosite 0.56.0, before any change from this proposal.

## Method

- Script: `bench/run.sh <label> <site-dir>` copies the site to a scratch
  directory and runs each task in each tool, headless and read-only. Totals:
  `bench/sum.py <label-dir>`.
- Tools and models:
  - Claude Code: `claude -p --model haiku --permission-mode plan`. The runs
    report `claude-sonnet-5-5` in `modelUsage`: plan mode used Sonnet. The
    "after" run must use the same flags.
  - OpenCode 1.18.34: `opencode run --agent plan -m opencode-go/deepseek-v4.1-flash`
    (the default model's key returns 401).
  - omp 18.5.0: `omp -p --mode json`, default model `opencode-go/deepseek-v4.1-flash`.
- Tokens = input + output + cache read + cache write, summed over all model
  calls. Compare a tool only with itself; models and prompts differ per tool.
- One run per cell. Single runs vary a lot (see omp A vs B); read the "after"
  numbers as a direction, not a precise saving.

## Tasks

- **A:** explain how a Forms submission reaches Cockpit and how it gets
  e-mailed; name files and settings; under 300 words; no edits.
- **B:** explain how to add a field to a Medusa product and show it on the
  shop page; name files, APIs and commands; under 300 words; no edits.

## Idle cost (prompt "Reply with the word ok only.", empty directory)

| tool | tokens |
|---|---:|
| omp | 9,180 |
| OpenCode | 23,004 |

OpenCode loads 50 global skills (`~/.agents/skills`, `~/.claude/skills`)
into every session; that is user-level, outside this change.

## Results

| run | tokens | model calls | cost USD |
|---|---:|---:|---:|
| analytics-draft-claude-A | 160,937 | 5 | 0.1529 |
| analytics-draft-claude-B | 88,153 | 3 | 0.1077 |
| analytics-draft-omp-A | 321,183 | 12 | 0.0090 |
| analytics-draft-omp-B | 42,150 | 4 | 0.0013 |
| analytics-draft-opencode-A | 487,017 | 14 | 0.0091 |
| analytics-draft-opencode-B | 87,437 | 3 | 0.0043 |
| analytics-draft-v2-claude-A | 182,717 | 1 | 0.2185 |
| analytics-draft-v2-claude-B | 29,848 | 1 | 0.0939 |
| analytics-draft-v2-omp-A | 277,482 | 13 | 0.0079 |
| analytics-draft-v2-omp-B | 118,659 | 8 | 0.0032 |
| analytics-draft-v2-opencode-A | 50,288 | 2 | 0.0040 |
| analytics-draft-v2-opencode-B | 101,463 | 4 | 0.0044 |

# After (first attempt) — 2026-10-08

The sandboxes were migrated with the 0.57.0 MIGRATIONS entry (analytics-draft:
AGENTS.md 60 lines, rest appended to ARCHITECTURE.md; analytics-draft-v2:
AGENTS.md 43 lines). `gosite docs` came from the repository through a PATH
shim (`BENCH_PATH`), every other `gosite` command from the installed 0.56.0.
"before 2" re-ran the original files restored from backup.

| run | before 1 | before 2 | after 1 | after 2 | change of means |
|---|---:|---:|---:|---:|---:|
| analytics-draft-claude-A | 160,937 | 162,633 | 130,588 | 129,054 | -20% |
| analytics-draft-claude-B | 88,153 | 91,185 | 132,655 | 136,421 | +50% |
| analytics-draft-omp-A | 321,183 | 148,420 | 544,487 | 340,166 | +88% |
| analytics-draft-omp-B | 42,150 | 48,857 | 79,932 | 130,781 | +132% |
| analytics-draft-opencode-A | 487,017 | 383,019 | 201,718 | 234,964 | -50% |
| analytics-draft-opencode-B | 87,437 | 84,252 | 170,480 | 200,872 | +116% |
| analytics-draft-v2-claude-A | 182,717 | 124,780 | 164,385 | 163,112 | +7% |
| analytics-draft-v2-claude-B | 29,848 | 59,524 | 129,320 | 128,347 | +188% |
| analytics-draft-v2-omp-A | 277,482 | 262,723 | 366,553 | 192,890 | +4% |
| analytics-draft-v2-omp-B | 118,659 | 40,975 | 183,692 | 209,535 | +146% |
| analytics-draft-v2-opencode-A | 50,288 | 50,017 | 204,652 | 178,784 | +282% |
| analytics-draft-v2-opencode-B | 101,463 | 49,882 | 466,687 | 170,350 | +321% |

Totals per tool (sum of cell means): Claude +24%, OpenCode +41%, omp +62%.

## Why tokens went up

- **The answers changed, not only the cost.** Before, task B mostly ended
  after a few greps with "this project has no Medusa" (OpenCode) or a generic
  Medusa v2 + Next.js answer that does not match gosite (Claude). After, the
  answers are gosite-specific and use facts only the notes hold (Admin API
  Basic auth with an empty password, updates are POST, `shop.<domain>`).
  Token count alone does not measure this; a quality grade per answer is
  needed next to it.
- **The notes stop short, so agents keep digging.** After reading the skill and
  `gosite docs`, agents still opened the core module in the Go module cache
  (`CORE_API.md`, `internal/addons/commerce/*.go`, `pages/commerce-*.html`) to
  learn how a site enables Commerce and renders a product, and how Forms
  works. Neither is in `src/knowledge/`: that knowledge lives in
  `src/addons/*/README.md` and `core/CORE_API.md`, which `gosite docs` does not
  serve. The thin AGENTS.md also names "`CORE_API.md` in that module", which
  sends agents into the module cache.
- One run (after 1, v2 OpenCode B, 467k tokens) ended with no answer: OpenCode
  auto-rejected reading the module cache in headless mode.
- Two samples per cell; spread inside a cell is up to 2.7× (v2 OpenCode B),
  so single-cell changes are noise-level. The direction across all three
  tools is the same.

# After trimming (design.md D9) — 2026-10-08

Knowledge index and skills removed from the always-loaded context; `gosite docs`
kept. Runs `after3` and `after4`; "before" and "with index+skills" are the
means of the two runs above.

| run | before (mean) | with index+skills (mean) | trimmed 1 | trimmed 2 | trimmed vs before |
|---|---:|---:|---:|---:|---:|
| analytics-draft-claude-A | 161,785 | 129,821 | 129,900 | 127,879 | -20% |
| analytics-draft-claude-B | 89,669 | 134,538 | 61,790 | 62,217 | -31% |
| analytics-draft-omp-A | 234,802 | 442,326 | 100,735 | 114,584 | -54% |
| analytics-draft-omp-B | 45,504 | 105,356 | 21,152 | 24,506 | -50% |
| analytics-draft-opencode-A | 435,018 | 218,341 | 259,144 | 250,592 | -41% |
| analytics-draft-opencode-B | 85,844 | 185,676 | 100,158 | 82,220 | +6% |
| analytics-draft-v2-claude-A | 153,748 | 163,748 | 197,513 | 275,625 | +54% |
| analytics-draft-v2-claude-B | 44,686 | 128,834 | 61,036 | 61,027 | +37% |
| analytics-draft-v2-omp-A | 270,102 | 279,722 | 454,285 | 348,434 | +49% |
| analytics-draft-v2-omp-B | 79,817 | 196,614 | 32,408 | 42,456 | -53% |
| analytics-draft-v2-opencode-A | 50,152 | 191,718 | 132,987 | 102,728 | +135% |
| analytics-draft-v2-opencode-B | 75,672 | 318,518 | 77,530 | 107,089 | +22% |

| tool | before | with index+skills | trimmed |
|---|---:|---:|---:|
| claude | 449,888 | 556,941 (+24%) | 488,494 (+9%) |
| omp | 630,224 | 1,024,018 (+62%) | 569,280 (-10%) |
| opencode | 646,688 | 914,254 (+41%) | 556,224 (-14%) |

## Reading

- **Legacy site (analytics-draft): lower in 5 of 6 cells** (-20% to -54%;
  OpenCode B +6%). The 60-line AGENTS.md gives the layout and rules up front,
  so agents read fewer files.
- **Thin site (analytics-draft-v2): higher in 5 of 6 cells** (+22% to +135%;
  omp B -53%). The thin AGENTS.md is now loaded on every turn, and its line
  "Its contract is `CORE_API.md` in that module" sends agents into the Go
  module cache to find and read core (seen in OpenCode A: `go env GOMODCACHE`,
  `find … CORE_API.md`, then core source). Before, the same line sat in a
  `MEMORY.md` that no tool loaded, and agents stayed in the site.

# Thin site without the CORE_API pointer — 2026-10-08

Runs `after5` and `after6`, thin site only (task 10.8).

| run | before (mean) | trimmed (mean) | no CORE_API 1 | no CORE_API 2 | vs before |
|---|---:|---:|---:|---:|---:|
| analytics-draft-v2-claude-A | 153,748 | 236,569 | 315,203 | 269,542 | +90% |
| analytics-draft-v2-claude-B | 44,686 | 61,032 | 35,726 | 35,738 | -20% |
| analytics-draft-v2-omp-A | 270,102 | 401,360 | 276,099 | 87,026 | -33% |
| analytics-draft-v2-omp-B | 79,817 | 37,432 | 21,198 | 43,664 | -59% |
| analytics-draft-v2-opencode-A | 50,152 | 117,858 | 133,730 | 49,276 | +82% |
| analytics-draft-v2-opencode-B | 75,672 | 92,310 | 76,775 | 49,456 | -17% |

| tool (thin site) | before | trimmed | no CORE_API |
|---|---:|---:|---:|
| claude | 198,434 | 297,600 (+50%) | 328,104 (+65%) |
| omp | 349,920 | 438,792 (+25%) | 213,994 (-39%) |
| opencode | 125,825 | 210,167 (+67%) | 154,618 (+23%) |

## Final state, both sites

Legacy cells from `after3`/`after4` (unchanged by 10.8), thin cells from
`after5`/`after6`; means of two runs per cell.

| tool | before tokens | final tokens | change |
|---|---:|---:|---:|
| Claude Code | 449,888 | 518,998 | +15% |
| OpenCode | 646,688 | 500,676 | -23% |
| omp | 630,224 | 344,482 | -45% |

- OpenCode and omp are lower. Claude is higher, almost all of it from one
  cell: thin site, task A (Forms), +90%. Forms lives in the core module and in
  the CMS image, not in the site, so any answer that is more than a guess has
  to read core; no `src/knowledge/` note covers Forms.
- Spread inside one cell is still up to 3× (omp thin A: 276k vs 87k; OpenCode
  thin A: 134k vs 49k). Per-cell changes are noise-level; the per-tool totals
  are the most reliable reading.
