# Vanta OS — Complete Setup Guide
## Mac Mini Onboarding (Monday)

---

## What Vanta OS Does

Vanta OS is a fully automated outbound engine for Vanta Studios. It:

1. **Discovers** SA photographer leads daily via Instagram hashtags
2. **Verifies** each lead — email deliverability, Instagram activity, SA location, engagement
3. **Scores** every lead 0 to 100 — only leads scoring 50+ get outreached
4. **Generates** personalized emails via Claude Haiku (bespoke intro per photographer)
5. **Queues** for approval — Josh reviews in Mission Control before any email sends
6. **Sends** approved emails via Sophia (sophia@amalfiai.com)
7. **Engages** on Instagram — personalized comments on target accounts' posts
8. **Tracks** all leads, responses, and conversions in Supabase

---

## Architecture Overview

```
Instagram Hashtags → [Discovery] → vanta_leads (status=new)
                                          ↓
                                    [Verify + Score]
                                          ↓
                            score < 50 → rejected
                            score ≥ 50 → queued
                                          ↓
                                    [Email Gen (Claude)]
                                          ↓
                                  email_queue (awaiting_approval)
                                          ↓
                              [Mission Control approval by Josh]
                                          ↓
                               [Sophia sends the email]
                                          ↓
                              [Instagram Engage (Playwright)]
                                          ↓
                            [Vanta Dashboard — track everything]
```

---

## Mac Mini Setup (Step by Step)

### 1. Machine Requirements

- macOS Ventura or later
- Homebrew installed
- Python 3 (`brew install python3`)
- Node.js (`brew install node`)
- Git (`brew install git`)

### 2. Copy Vanta scripts to the Mac Mini

All Vanta scripts and LaunchAgent plists live on Josh's machine at:
```
~/.openclaw/workspace-anthropic/clients/vanta-studios/scripts/
~/.openclaw/workspace-anthropic/clients/vanta-studios/launchagents/
```

Copy them to the Vanta Mac Mini via SCP (run from Josh's machine):
```bash
VANTA_IP=<vanta-mac-ip>          # or Tailscale IP once VPN is set up
VANTA_USER=<mac-username>         # e.g. vantastudios

# Create workspace on Vanta Mac Mini
ssh ${VANTA_USER}@${VANTA_IP} 'mkdir -p ~/.amalfiai/workspace/scripts ~/.amalfiai/workspace/out ~/.amalfiai/workspace/tmp ~/.amalfiai/workspace/data'

# Copy scripts
scp ~/.openclaw/workspace-anthropic/clients/vanta-studios/scripts/*.sh \
    ${VANTA_USER}@${VANTA_IP}:~/.amalfiai/workspace/scripts/

# Copy LaunchAgent plists
scp ~/.openclaw/workspace-anthropic/clients/vanta-studios/launchagents/*.plist \
    ${VANTA_USER}@${VANTA_IP}:~/.amalfiai/workspace/launchagents/

# Copy shared Supabase migration
scp ~/.openclaw/workspace-anthropic/supabase/migrations/005_vanta_leads.sql \
    ${VANTA_USER}@${VANTA_IP}:~/.amalfiai/workspace/

chmod +x ~/.amalfiai/workspace/scripts/*.sh
```

### 3. Create .env.scheduler

```bash
nano ~/.amalfiai/workspace/.env.scheduler
```

Paste and fill in:

```bash
# Supabase (master — Josh's instance, shared across all clients)
AOS_SUPABASE_URL=https://afmpbtynucpbglwtbfuz.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<from Josh>
SUPABASE_ANON_KEY=<from Josh>

# Telegram (Vanta's own bot or shared bot)
TELEGRAM_BOT_TOKEN=<Vanta bot token OR Josh's shared bot token>
AOS_TELEGRAM_OWNER_CHAT_ID=<Vanta owner's Telegram chat_id>

# Anthropic API (shared)
ANTHROPIC_API_KEY=<from Josh>

# Instagram credentials for Vanta Studios account
VANTA_INSTAGRAM_USERNAME=<vanta_studios_ig_handle>
VANTA_INSTAGRAM_PASSWORD=<vanta_studios_ig_password>

# Target hashtags (comma-separated, no # prefix needed)
VANTA_IG_TARGET_HASHTAGS=#southafricanphotographer,#capetownphotographer,#johannesburgphotographer,#safotography,#weddingphotographersa,#portraitphotographersa,#photographersa,#durbanphotographer,#pretoriaphotographer

# Daily limits (quality control)
VANTA_DAILY_OUTREACH_CAP=10
VANTA_VERIFY_BATCH=50
VANTA_IG_DAILY_COMMENTS=15
VANTA_IG_DAILY_DMS=5

# Client OS kill switch (for retainer enforcement)
AOS_CLIENT_SLUG=vanta_studios
AOS_MASTER_SUPABASE_URL=https://afmpbtynucpbglwtbfuz.supabase.co
AOS_MASTER_SERVICE_KEY=<from Josh>
```

### 4. Install Dependencies

```bash
# Python dependencies
pip3 install dnspython requests

# Node dependencies for Instagram Playwright automation
cd ~/.amalfiai/workspace
npm init -y
npm install @playwright/test
npx playwright install chromium
```

### 5. Run Database Migrations

In Supabase dashboard at https://supabase.com/dashboard/project/afmpbtynucpbglwtbfuz/editor:

```sql
-- Run each in order:
-- 004_whatsapp_messages.sql  (if not already done)
-- 005_vanta_leads.sql
```

Or paste contents of each file from:
`workspace/supabase/migrations/005_vanta_leads.sql`

### 6. Deploy LaunchAgents

The plists reference `/Users/henryburton/.openclaw/workspace-anthropic` (Josh's paths). Before loading,
update them to match the Vanta Mac Mini's username and workspace path:

```bash
WORKSPACE="$HOME/.amalfiai/workspace"
PLIST_DIR="$HOME/Library/LaunchAgents"

for PLIST in \
  com.amalfiai.vanta-lead-discovery \
  com.amalfiai.vanta-lead-verify \
  com.amalfiai.vanta-outreach
do
  # Rewrite Josh's paths to Vanta Mac Mini paths
  sed "s|/Users/henryburton/.openclaw/workspace-anthropic|$WORKSPACE|g; s|/Users/henryburton|$HOME|g" \
    "$WORKSPACE/launchagents/$PLIST.plist" > "$PLIST_DIR/$PLIST.plist"

  launchctl load "$PLIST_DIR/$PLIST.plist"
  echo "Loaded: $PLIST"
done

# Verify all three are loaded
launchctl list | grep vanta
```

### 7. First Instagram Login (one-time, on the Vanta Mac Mini)

Run the Instagram engagement script manually first to authenticate and save the session:

```bash
bash ~/.amalfiai/workspace/scripts/vanta-instagram-engage.sh
```

This will launch a headless browser and log in. Session is saved to `tmp/vanta-ig-session.json` — subsequent runs restore it without re-logging in.

**If Instagram asks for 2FA**: the headless browser can't handle it. You may need to:
1. Log in manually from the Mac Mini's browser first
2. Export cookies (or use `--headed` mode in Playwright to see the browser)

### 8. Test Run (on the Vanta Mac Mini)

Trigger discovery manually to confirm everything is wired up:
```bash
bash ~/.amalfiai/workspace/scripts/vanta-lead-discovery.sh
```

Then verify:
```bash
bash ~/.amalfiai/workspace/scripts/vanta-lead-verify.sh
```

Check Supabase for leads (Josh's dashboard — shared Supabase):
```
https://supabase.com/dashboard/project/afmpbtynucpbglwtbfuz/editor
SELECT instagram_handle, quality_score, email, outreach_status
FROM vanta_leads
ORDER BY quality_score DESC
LIMIT 20;
```

Check Mission Control Vanta dashboard (Josh's side) to confirm leads appear.

---

## Daily Schedule

| Time (SAST) | Script | What it does |
|-------------|--------|--------------|
| 09:00 | vanta-lead-discovery | Scans Instagram hashtags, finds new SA photographer accounts |
| 10:00 | vanta-lead-verify | Email MX check, SMTP probe, Instagram activity, quality score |
| 11:00 | vanta-outreach | Generates + queues personalized emails (awaiting approval) |
| Manual | vanta-instagram-engage | Comments on leads' posts (triggered by Josh or /vanta ig-engage) |

---

## Lead Quality System

Every lead gets a quality score 0 to 100 before any outreach happens.

| Check | Points |
|-------|--------|
| Email found + MX record valid | +30 |
| Instagram active (post in last 30 days) | +20 |
| Business email (not gmail/yahoo) | +15 |
| SA location confirmed in bio | +10 |
| Website is live | +10 |
| Follower count in sweet spot (500 to 50k) | +10 |
| Engagement rate above 3% | +5 |
| SMTP probe confirms mailbox valid | +5 |
| SMTP probe says mailbox invalid | minus 20 |
| Email domain MX fails | minus 5 |

**Threshold**: Only leads with score >= 50 proceed to outreach.

This means a lead MUST have at minimum:
- A verified email (30 points)
- Active Instagram (20 points)
...plus anything else to get over 50.

No email? No outreach, full stop.

---

## Approval Workflow

Outreach emails are NOT sent automatically. They go into `email_queue` with status `awaiting_approval`.

1. Vanta OS discovers + verifies leads and generates emails
2. Josh gets a Telegram notification: "10 Vanta emails ready for approval"
3. Josh reviews in Mission Control → Email Queue (or via Telegram)
4. Josh approves → Sophia sends
5. Lead status updates to `emailed`

This means bad emails NEVER go out without a human check.

---

## Vanta Dashboard (Mission Control)

A dedicated dashboard page for Vanta owners to track their pipeline.

**URL**: `[Mission Control URL]/vanta`

**Shows**:
- Pipeline summary: total leads | qualified | emailed | responded | converted
- Lead list with quality scores, outreach status, Instagram link
- Email queue (drafts awaiting approval)
- Instagram engagement log
- Response tracking

**Dashboard build**: see `mission-control-hub/src/pages/VantaPage.tsx`
(to be built on Monday when Mac Mini arrives)

---

## What's NOT Automatic (Manual Steps)

1. **Instagram DMs**: Only to warm leads (who engaged with your comment or replied to email).
   Never cold DMs — Instagram bans accounts for this.
2. **Response handling**: When a photographer replies to an email, it goes to sophia@amalfiai.com.
   Sophia (AI) drafts a follow-up, Josh approves before sending.
3. **Lead list expansion**: If you want to target new niches or cities, update
   `VANTA_IG_TARGET_HASHTAGS` in `.env.scheduler`.

---

## Metrics to Track

- **Discovery rate**: Leads found per day
- **Qualification rate**: % of discovered leads that score >= 50 (target > 20%)
- **Email delivery rate**: Should be > 95% for verified leads
- **Open rate**: Tracked if using an ESP; Sophia sends raw SMTP so no open tracking unless added
- **Reply rate**: Target > 10% (quality-first approach should achieve this)
- **Conversion rate**: Leads that book a studio session or collaboration

---

## Troubleshooting

**Discovery finds 0 leads**: Instagram may be rate-limiting. Check `out/vanta-lead-discovery.err.log`.
Solution: wait a few hours, or change target hashtags.

**Verification fails with dnspython error**:
```bash
pip3 install dnspython
```

**Instagram login fails**: Run manually with headed browser (edit script to set `headless: false`).
May need to handle 2FA the first time.

**Emails not sending after approval**: Check Sophia email bridge is running.
```bash
launchctl list | grep sophia
```

**Low quality scores**: Leads from niche hashtags may not have emails in bio.
Consider adding website-scraping to extract emails from photographers' websites.
