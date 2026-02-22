# QMD Configuration

## How Alex Uses QMD Automatically

**You don't have to say "qmd search"** — I'm configured to automatically query QMD whenever you ask questions about:

- Your workspace, memory, or notes
- OpenClaw skills or documentation
- Downloaded references or knowledge bases
- Customer context or project details

## Collections Available

1. **workspace-memory** — Personal notes & daily logs
2. **workspace-root** — Full workspace (SOUL.md, USER.md, MEMORY.md, etc.)
3. **openclaw-skills** — All OpenClaw skill documentation
4. **downloads** — Reference docs, knowledge bases, Josh's KBs

## What This Saves

- **95%+ token reduction** — Only relevant chunks sent to Claude
- **Faster answers** — Search completes in <1s
- **Better context** — Hybrid semantic + keyword search
- **Offline** — All models run locally on M1

## How I Use It

When you ask "How should Sophia respond to X?" → I search QMD for customer context automatically
When you ask "What's the Callaway framework?" → I search workspace-root automatically
When you ask "What skills do we have?" → I search openclaw-skills automatically

## CLI (if you ever want to manually search)

```bash
# Fast keyword search
qmd search "your query"

# Semantic search
qmd vsearch "natural language question"

# Best quality (hybrid + rerank)
qmd query "complex question"

# See all collections
qmd status
```

## Keep It Updated

```bash
# Add new files to a collection (auto-detects)
qmd embed

# Run anytime you add new docs
```

---

**TL;DR:** I'll handle QMD automatically. Just ask questions naturally, and I'll pull the right context without you having to remember the tool exists.
