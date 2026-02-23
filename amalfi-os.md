# Amalfi OS — Framework Document

**Version:** 1.0 — February 2026
**Author:** Josh Burton, Amalfi AI

---

## What Is It

Amalfi OS is an AI-native operating system for founder-led businesses. It replaces the patchwork of tools, assistants, and manual workflows with a unified system where one AI brain runs end-to-end operations — research, communication, client delivery, and visibility.

It is not a chatbot. It is not a plugin. It is an operating layer that sits underneath the business.

The difference: most AI tools answer questions. Amalfi OS replaces workflows.

---

## The Four Layers

### 1. Intelligence

The system reads everything relevant to the business — market research, competitor moves, meeting notes, articles, transcripts — and distills it into actionable intel. Every morning, the founder gets a brief covering what matters.

- **Research Digest** — Drop URLs, transcripts, or articles. AI extracts strategic insights, identifies gaps, creates tasks to close them.
- **Morning Brief** — Daily Telegram message at 7am: repo activity, email queue depth, strategic intel from overnight processing.
- **Meeting Intelligence** — Google Meet notes auto-captured and routed into the research pipeline. No manual copy-paste.

**The result:** You start every day knowing what matters, without reading anything.

---

### 2. Communication

Client communication runs on a rules-based AI layer that drafts, queues, and (with approval) sends emails on behalf of the founder. Nothing goes out without a human checkpoint.

- **Sophia CSM** — AI email agent that drafts responses for every inbound email, queued for one-tap approval.
- **Telegram Gateway** — Direct line from founder to AI brain. One message creates tasks, books calendar events, approves emails, queries system state.
- **Approval Queue** — Every outbound email visible in Mission Control. Swipe or tap: approve, hold, or reject.

**The result:** Email response time drops from hours to minutes. You never draft from scratch.

---

### 3. Operations

Client work gets done autonomously. The founder queues a task via Telegram; the system pulls the latest code, reads client context, implements the change, commits, and pushes — without manual intervention.

- **Autonomous Task Worker** — Picks up tasks every 10 minutes, routes to the correct client repo, implements, commits, pushes, and notifies.
- **Client Context Files** — Per-client priming documents (key contacts, tech stack, current focus, business priorities). AI reads before touching anything.
- **Repo Routing** — Tag any task with a client name. It finds the right codebase automatically.

**The result:** Development tasks ship overnight. You wake up to committed code, not a to-do list.

---

### 4. Visibility

One dashboard shows the full system state. Not a BI tool — an operations surface. What's pending, what's running, what needs a decision.

- **Mission Control** — Real-time dashboard: email queue, agent health, pending approvals, kill switch.
- **Current State** — System snapshot regenerated nightly. Queue depth, agent status, repo activity, OOO mode.
- **Error Monitor** — Every script monitored. Failures Telegram-alerted within 10 minutes.

**The result:** You always know what the system is doing and why. Full control without full attention.

---

## How the Layers Connect

```
World
  └── Research Pipeline → Intelligence → Morning Brief → Founder
                                                           │
                                              Telegram Message (task / event / query)
                                                           │
                              ┌────────────────────────────┼──────────────────────────┐
                              ▼                            ▼                          ▼
                     Task Worker                     Sophia CSM                  Calendar Sync
                     → Client Repo                  → Approval Queue            → Google Calendar
                     → Committed & Pushed           → Sent on approval          → Synced in 30 min
                              │                            │                          │
                              └────────────────────────────┼──────────────────────────┘
                                                           ▼
                                                  Mission Control
                                             (visibility across all layers)
```

A single Telegram message from the founder triggers work across all four layers. The system coordinates. The founder reviews outcomes, not processes.

---

## The Proof

Amalfi AI runs on Amalfi OS.

Every client email goes through Sophia. Every repo task runs through the autonomous worker. The morning brief lands at 7am. This document was produced by Claude Code running inside the system.

We are the first client. We know it works because we live in it.

---

## What Clients Get

When Amalfi AI builds Amalfi OS for a client:

1. **Audit** — We map where time is lost, where decisions stack up, where manual work can be replaced.
2. **Build** — We configure Amalfi OS to the client's business: their email tone, their repos, their team structure, their tools. 1–2 weeks.
3. **Hand-off** — We deploy Mission Control on their domain, configure their Telegram gateway, and hand them the keys.
4. **Infrastructure** — We stay on as the AI infrastructure team. The system evolves as the business does.

Clients do not get software to learn. They get a running system.

---

## What Amalfi OS Is Not

- Not a general AI assistant (it knows your business specifically)
- Not a SaaS subscription (it's built and configured for you)
- Not ChatGPT with a wrapper (it takes actions, not just answers)
- Not a black box (Mission Control shows everything, kill switch always accessible)

---

*Amalfi AI — Building AI operating systems for founder-led businesses.*
*josh@amalfiai.com — amalfiai.com*
