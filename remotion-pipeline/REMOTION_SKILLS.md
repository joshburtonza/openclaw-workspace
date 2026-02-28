# Remotion Skills Reference
> Distilled from video transcripts on Claude Code skills + Remotion motion graphics.
> Used by generate-broll-specs.sh and the B-roll render system.

---

## Motion Graphics Catalogue

### What works well (proven patterns from reference videos)

| Type | When to use | Key prop controls |
|---|---|---|
| `stat_card` | Metrics, numbers, results | label, value, delta, color |
| `iphone_telegram` | Telegram notifications, task completions, reminders | chat_name, messages[], show_notification_popup |
| `iphone_dashboard` | Dashboard pages, task counts, agent status | page, metric |
| `terminal` | Scripts running, LaunchAgents, automation output | title, lines[] |
| `chat_bubble` | AI conversation, showing AOS replies | messages[], sender, is_ai |
| `lower_third` | Introducing Josh, citing sources, labelling context | name, title, color |
| `tweet` | Social proof, reactions, testimonials | username, display_name, content, timestamp |
| `bar_chart` | Comparing data, before/after, growth over time | title, bars[{label,value}], color |

---

## Art Direction Defaults (for all B-roll)

- **Background**: transparent or dark `#0a0b14` — never white
- **Typography**: `-apple-system, 'SF Pro Display'` — system font stack
- **Primary accent**: `#4B9EFF` (blue), `#4ade80` (green for positive), `#f87171` (red for problems)
- **Active highlight**: `#FFE234` (yellow) — same as captions
- **Motion style**: spring-based entries (stiffness 180-240, damping 18-24), never linear
- **Fade**: 0.5s fade-in at clip start, 0.5s fade-out at end
- **Scale**: 0.55 of video width, right-aligned by default

---

## 9-Phase Build Pattern (for complex scenes)
When building a new B-roll component type:
1. Foundation — TypeScript interface, props, defaults
2. Art direction — color system, typography scale
3. Storyboard — frame-by-frame what appears when
4. Asset inventory — what visual elements exist
5. Generate assets — render static elements first
6. Motion primitives — define spring configs, fade functions
7. Layout — position elements
8. Scene assembly — combine with timing
9. Polish — edge cases, overflow, test at 30/60fps

---

## Motion Primitive Config Reference
```typescript
// Snappy entry
spring({ frame, fps, config: { stiffness: 240, damping: 24 } })

// Smooth elastic
spring({ frame, fps, config: { stiffness: 180, damping: 18 } })

// Slow reveal
spring({ frame, fps, config: { stiffness: 120, damping: 20 } })

// Standard fade (6 frames)
interpolate(frame, [0, 6], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' })

// Scale pop
interpolate(spring, [0, 1], [0.75, 1.0])

// 3D entry (rotateX)
interpolate(spring, [0, 1], [8, 0])  // degrees
```

---

## Props Best Practices
- Every visual property must be a prop (no hardcoded values)
- Colors, text, timing, sizes — all controllable
- Use sensible defaults so previews work without props
- Never hardcode position — use relative units (% of width)
- `phone_width` prop pattern scales everything proportionally

---

## Claude Code / Skills Integration Notes
- Skills = `skill.md` (SOP) + reference files (context, examples, assets)
- Progressive disclosure: only metadata in memory, skill.md loaded on trigger
- Self-improving: instruct skill to update its own rules when errors occur
- WAT framework: Workflows (instructions) + Agent (brain) + Tools (Python scripts)
- Plan mode first → bypass permissions to execute
- Context rot: clear conversation when context > 60%
- `CLAUDE.md` in project root = agent onboarding document

---

## B-roll Timing Rules (refined from testing)
- Minimum clip: 4s (120 frames at 30fps)
- Maximum clip: 8s — longer feels like a cutaway
- Leave 2s gap between clips
- Fade in: frames 0-15 (0.5s)
- Fade out: last 15 frames before end
- Stagger multiple elements: 12-18 frames apart
- Don't start B-roll in first 2s or last 5s of video
