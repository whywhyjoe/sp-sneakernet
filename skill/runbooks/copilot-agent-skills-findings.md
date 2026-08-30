# Findings: does Copilot read `.claude/skills`? (Phase 4 investigation)

**Yes — as a platform capability.** GitHub shipped Agent Skills support in
December 2025: skills defined as `SKILL.md` directories are an open standard,
and **Copilot picks up existing `.claude/skills` directories automatically** —
across Copilot coding agent, Copilot CLI, and VS Code agent mode (stable VS
Code since early January 2026).

**What this means for sp-env:** the thin per-repo `sp-project` skill
(`.claude/skills/sp-project/SKILL.md`) is likely readable by the prod-side
Copilot as-is. However:

- **Corporate reality is unverified.** Whether the WORK machine's VS Code /
  Copilot versions are new enough, and whether tenant policy leaves Agent
  Skills enabled, can only be proven on that machine. Check on first prod
  session: ask Copilot "what skills are available?" or make a request the
  sp-project skill should influence.
- **Decision: keep both.** `.github/copilot-instructions.md` (custom
  instructions — supported for years, guaranteed pickup) remains the
  authoritative prod instruction set; the thin skill duplicates the pointer
  so whichever mechanism works, the agent lands on the same guidance. The
  handoff's "generated file collapses into the thin skill" consolidation
  should only happen AFTER a live prod session proves skills pickup.

Sources: [GitHub Changelog — Copilot now supports Agent Skills](https://github.blog/changelog/2025-12-18-github-copilot-now-supports-agent-skills/),
[VS Code docs — Use Agent Skills](https://code.visualstudio.com/docs/agent-customization/agent-skills).
