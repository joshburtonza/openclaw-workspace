# Vanta Studios — Client Context

## Overview
Vanta Studios is a South African photography/visual studio business. Amalfi AI manages their
outbound pipeline: B2B lead gen targeting other photographers and studios in SA, personalized
email outreach, and Instagram engagement (comments + DMs).

## Business Focus
- **Primary goal**: Generate qualified B2B leads — studios reaching out to photographers for
  collaboration, equipment rental, studio hire, or training.
- **Key constraint**: Quality over quantity. Every lead must be verified before outreach.
  "1,000 emails, zero responses" is failure. We aim for 50 perfect leads over 1,000 cold ones.
- **Target audience**: SA-based photographers (portrait, wedding, commercial, lifestyle, product),
  photography studios, photo agencies, content creators with commercial work.

## Contact
- Client: Vanta Studios
- Telegram contact: TBC
- Instagram: TBC (needs configuring — set VANTA_INSTAGRAM_USERNAME + VANTA_INSTAGRAM_PASSWORD in .env.scheduler)

## Lead Quality Criteria
Quality score 0-100. Only outreach to leads with score >= 50.

| Factor | Points |
|--------|--------|
| Email found and verified (MX check passes) | +30 |
| Active Instagram (post in last 30 days) | +20 |
| Professional email (not gmail/hotmail/yahoo) | +15 |
| Has a website | +10 |
| SA location confirmed | +10 |
| Follower count 500-50,000 (sweet spot) | +10 |
| Engagement rate > 3% | +5 |

Minimum score to email: 50
Minimum score for premium personalized: 70

## Outreach Voice
- Sender: sophia@amalfiai.com (on behalf of Vanta Studios)
- Tone: warm, professional, peer-to-peer — one creative professional to another
- Subject lines: specific, relevant to their niche (wedding vs commercial vs portrait)
- Never: bulk template feel, aggressive CTA, "click here" links

## Scripts (deployed on Vanta Mac Mini, NOT Josh's machine)
All scripts live in `clients/vanta-studios/scripts/` on Josh's machine for reference.
On the Vanta Mac Mini they run from `~/.amalfiai/workspace/scripts/`.
- `vanta-lead-discovery.sh` — discovers SA photographer leads
- `vanta-lead-verify.sh` — verifies and scores each lead
- `vanta-outreach.sh` — queues personalized Sophia emails
- `vanta-instagram-engage.sh` — Instagram commenting + DM automation

## LaunchAgents (on Vanta Mac Mini)
Plist templates in `clients/vanta-studios/launchagents/` — copy + path-rewrite on Monday.
- `com.amalfiai.vanta-lead-discovery` — 09:00 SAST
- `com.amalfiai.vanta-lead-verify` — 10:00 SAST
- `com.amalfiai.vanta-outreach` — 11:00 SAST
- Instagram engagement: manual trigger or Telegram `/vanta ig-engage`

## Supabase (Josh's shared instance)
- Table: `vanta_leads` (migration 005_vanta_leads.sql — run once in Supabase dashboard)
- Outreach tracked via `outreach_status`
- Mission Control `/vanta` page on Josh's dashboard reads from this table

## Instagram Setup Requirements
Add to .env.scheduler:
```
VANTA_INSTAGRAM_USERNAME=your_instagram_handle
VANTA_INSTAGRAM_PASSWORD=your_instagram_password
VANTA_IG_TARGET_HASHTAGS=#southafricanphotographer,#capetownphotographer,#johannesburgphotographer,#safotography,#weddingphotographersa,#portraitphotographersa
VANTA_IG_TARGET_LOCATIONS=Cape Town,Johannesburg,Durban,Pretoria
```

## Google Maps / Search Requirements
Add to .env.scheduler:
```
GOOGLE_MAPS_API_KEY=your_google_maps_api_key  (optional, improves business verification)
```
