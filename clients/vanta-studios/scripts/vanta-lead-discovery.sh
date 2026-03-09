#!/usr/bin/env bash
# Kill switch check — bail early if Vanta OS is paused
_KS=$(curl -s \
  "https://afmpbtynucpbglwtbfuz.supabase.co/rest/v1/kill_switch?id=eq.d2a6eb7c-014c-43e6-9a5e-e0d5876c21cc&select=status" \
  -H "apikey: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['status'] if d else 'running')" 2>/dev/null)
if [[ "$_KS" == "stopped" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Vanta OS kill switch active — skipping run"
  exit 0
fi

# vanta-lead-discovery.sh
# Discovers SA photographer/studio leads from Instagram hashtags + Google Maps.
# Writes raw candidate data to Supabase vanta_leads (status='new').
# Deduplicates by instagram_handle — won't re-insert existing handles.
# Runs daily at 09:00 SAST via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$ROOT/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
LOG="$ROOT/out/vanta-lead-discovery.log"

# Instagram credentials (needed for IG scraping)
IG_USERNAME="${VANTA_INSTAGRAM_USERNAME:-}"
IG_PASSWORD="${VANTA_INSTAGRAM_PASSWORD:-}"

# Target hashtags for SA photographers
HASHTAGS="${VANTA_IG_TARGET_HASHTAGS:-#southafricanphotographer,#capetownphotographer,#johannesburgphotographer,#safotography,#weddingphotographersa,#portraitphotographersa,#photographersa,#durbanphotographer,#pretoriaphotographer,#southafricanweddingphotographer}"

mkdir -p "$ROOT/out" "$ROOT/tmp"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === vanta-lead-discovery starting ===" | tee -a "$LOG"

export SUPABASE_URL SERVICE_KEY BOT_TOKEN CHAT_ID IG_USERNAME IG_PASSWORD HASHTAGS

python3 - <<'PY'
import os, json, sys, re, time, datetime, urllib.request, urllib.parse, random

SUPABASE_URL = os.environ['SUPABASE_URL']
SERVICE_KEY  = os.environ['SERVICE_KEY']
BOT_TOKEN    = os.environ['BOT_TOKEN']
CHAT_ID      = os.environ['CHAT_ID']
IG_USERNAME  = os.environ['IG_USERNAME']
IG_PASSWORD  = os.environ['IG_PASSWORD']
HASHTAGS     = [h.strip().lstrip('#') for h in os.environ['HASHTAGS'].split(',') if h.strip()]

# ── Supabase helpers ──────────────────────────────────────────────────────────

def supa_post(rows):
    """Insert rows into leads table (client_id already set on each row)."""
    url = f"{SUPABASE_URL}/rest/v1/leads"
    data = json.dumps(rows).encode()
    req = urllib.request.Request(url, data=data, method='POST', headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status in (200, 201, 204)
    except Exception as e:
        print(f'[discovery] DB insert error: {e}', file=sys.stderr)
        return False

def supa_get_handles():
    """Get existing IG handles (stored in twitter_url) to avoid re-processing."""
    url = f"{SUPABASE_URL}/rest/v1/leads?client_id=eq.{VANTA_CLIENT_ID}&select=twitter_url"
    req = urllib.request.Request(url, headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Accept': 'application/json',
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            rows = json.loads(r.read())
        # twitter_url stored as https://www.instagram.com/{handle}/
        return set(r['twitter_url'].rstrip('/').split('/')[-1] for r in rows if r.get('twitter_url'))
    except Exception:
        return set()

def tg_send(text):
    data = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        data=data, headers={'Content-Type': 'application/json'}
    )
    try:
        with urllib.request.urlopen(req, timeout=10):
            pass
    except Exception:
        pass

# ── Instagram hashtag discovery via unofficial web API ───────────────────────
# Uses Instagram's public JSON endpoint (no auth required for hashtag search).
# Returns top recent posts for each hashtag, extracts account info from post metadata.

def ig_fetch_hashtag(tag, max_posts=20):
    """
    Fetch recent posts for a hashtag via Instagram's web API.
    Returns list of {username, full_name, biography, external_url, follower_count,
                     is_business_account, post_count, last_post_ts}
    """
    leads = []
    seen_users = set()

    # Instagram web API for hashtag
    url = f"https://www.instagram.com/explore/tags/{urllib.parse.quote(tag)}/?__a=1&__d=dis"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Accept': 'application/json',
        'X-IG-App-ID': '936619743392459',
    }

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read().decode('utf-8', errors='replace')
        data = json.loads(raw)
    except Exception as e:
        print(f'[discovery] IG hashtag {tag} fetch failed: {e}', file=sys.stderr)
        return leads

    # Navigate to posts
    try:
        hashtag_data = data.get('data', {}).get('hashtag', {})
        edge = hashtag_data.get('edge_hashtag_to_media', {})
        edges = edge.get('edges', [])
    except Exception:
        return leads

    for post_edge in edges[:max_posts]:
        node = post_edge.get('node', {})
        owner = node.get('owner', {})
        username = owner.get('username', '')
        if not username or username in seen_users:
            continue
        seen_users.add(username)

        # Extract what's available from post metadata
        # Map to leads table schema: twitter_url = IG profile URL (used as unique key)
        lead = {
            'twitter_url': f'https://www.instagram.com/{username}/',
            'first_name': (owner.get('full_name') or '').split()[0] if owner.get('full_name') else username,
            'last_name': ' '.join((owner.get('full_name') or '').split()[1:]) or None,
            'company': username,  # IG handle as company identifier
            'follower_count_raw': owner.get('edge_followed_by', {}).get('count') if isinstance(owner.get('edge_followed_by'), dict) else None,
            'is_business_account': owner.get('is_business_account', False),
            'source': 'instagram',
            'source_hashtag': tag,
            'client_id': VANTA_CLIENT_ID,
            'status': 'new',
        }
        leads.append(lead)
        time.sleep(random.uniform(0.3, 0.8))

    return leads

def ig_fetch_profile(username):
    """
    Fetch full profile data for a single Instagram user.
    Returns enriched dict with bio, website, email hints.
    """
    url = f"https://www.instagram.com/{username}/?__a=1&__d=dis"
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Accept': 'application/json',
        'X-IG-App-ID': '936619743392459',
    }
    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read().decode('utf-8', errors='replace'))
        user = data.get('graphql', {}).get('user', {}) or data.get('data', {}).get('user', {})
        if not user:
            return {}

        bio = user.get('biography') or ''
        website = user.get('external_url') or ''

        # Extract email from bio
        email_match = re.search(r'[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}', bio)
        email = email_match.group(0).lower() if email_match else None

        # Extract phone from bio
        phone_match = re.search(r'(\+27|0)[0-9\s\-]{8,12}', bio)
        phone = re.sub(r'\s', '', phone_match.group(0)) if phone_match else None

        # Detect SA location from bio
        sa_cities = ['cape town', 'johannesburg', 'durban', 'pretoria', 'tshwane',
                     'bloemfontein', 'port elizabeth', 'nelson mandela bay', 'east london',
                     'south africa', 'sa', 'joburg', 'jozi', 'capetown', 'ctphotographer']
        bio_lower = bio.lower()
        in_sa = any(city in bio_lower for city in sa_cities)

        location_city = None
        city_map = {
            'cape town': 'Cape Town', 'capetown': 'Cape Town', 'cpt': 'Cape Town',
            'johannesburg': 'Johannesburg', 'joburg': 'Johannesburg', 'jozi': 'Johannesburg',
            'durban': 'Durban', 'pretoria': 'Pretoria', 'tshwane': 'Pretoria',
            'bloemfontein': 'Bloemfontein', 'port elizabeth': 'Gqeberha',
        }
        for key, city in city_map.items():
            if key in bio_lower:
                location_city = city
                break

        # Specialty detection
        specialty_keywords = {
            'wedding': 'wedding',
            'portrait': 'portrait',
            'commercial': 'commercial',
            'product': 'product',
            'lifestyle': 'lifestyle',
            'fashion': 'fashion',
            'corporate': 'corporate',
            'event': 'event',
            'boudoir': 'boudoir',
            'newborn': 'newborn',
            'architecture': 'architecture',
        }
        specialties = [v for k, v in specialty_keywords.items() if k in bio_lower]

        edges_followed = user.get('edge_followed_by', {})
        follower_count = edges_followed.get('count') if isinstance(edges_followed, dict) else None

        edges_media = user.get('edge_owner_to_timeline_media', {})
        post_count = edges_media.get('count') if isinstance(edges_media, dict) else None

        # Engagement from last posts
        recent_edges = edges_media.get('edges', [])[:12] if isinstance(edges_media, dict) else []
        if recent_edges:
            likes = []
            comments = []
            for e in recent_edges:
                n = e.get('node', {})
                l = n.get('edge_liked_by', {}).get('count', 0)
                c = n.get('edge_media_to_comment', {}).get('count', 0)
                likes.append(l)
                comments.append(c)
            avg_likes = sum(likes) / len(likes) if likes else 0
            avg_comments = sum(comments) / len(comments) if comments else 0
            engagement_rate = ((avg_likes + avg_comments) / follower_count * 100) if follower_count and follower_count > 0 else None
        else:
            avg_likes = avg_comments = engagement_rate = None

        # Map to leads table schema
        follower_str = str(follower_count) if follower_count else ''
        engagement_str = f'{round(engagement_rate,2)}%' if engagement_rate else ''
        notes_meta = json.dumps({
            'follower_count': follower_count,
            'post_count': post_count,
            'avg_likes': round(avg_likes, 1) if avg_likes is not None else None,
            'avg_comments': round(avg_comments, 1) if avg_comments is not None else None,
            'engagement_rate': round(engagement_rate, 2) if engagement_rate is not None else None,
            'in_south_africa': in_sa,
            'is_business_account': user.get('is_business_account', False),
        })
        return {
            'email': email,
            'website': website,
            'headline': bio[:500] if bio else None,
            'location_city': location_city,
            'location_country': 'ZA' if in_sa else None,
            'industry': ', '.join(specialties) if specialties else 'photography',
            'company_description': f'IG followers: {follower_str} | engagement: {engagement_str}',
            'notes': notes_meta,
            'tags': specialties + ['photographer', 'instagram'],
        }
    except Exception as e:
        print(f'[discovery] Profile fetch failed for {username}: {e}', file=sys.stderr)
        return {}

# ── Main discovery run ────────────────────────────────────────────────────────

existing_handles = supa_get_handles()
print(f'[discovery] {len(existing_handles)} existing handles in DB')

new_leads_count = 0
all_new = []

for tag in HASHTAGS:
    print(f'[discovery] Scanning #{tag}...')
    raw_leads = ig_fetch_hashtag(tag, max_posts=30)
    print(f'[discovery]   Found {len(raw_leads)} accounts from #{tag}')

    for lead in raw_leads:
        handle = lead.get('instagram_handle', '')
        if not handle or handle in existing_handles:
            continue

        # Enrich with full profile data
        time.sleep(random.uniform(1.5, 3.0))  # Be polite
        profile_data = ig_fetch_profile(handle)
        if profile_data:
            lead.update(profile_data)

        # Only include SA leads (or uncertain — verifier will filter)
        # Keep if bio says SA, OR if we're uncertain (don't discard too early)
        lead['discovered_at'] = datetime.datetime.utcnow().isoformat() + 'Z'
        all_new.append(lead)
        existing_handles.add(handle)
        new_leads_count += 1
        print(f'[discovery]   + {handle} ({"SA" if lead.get("in_south_africa") else "?location"}, {lead.get("follower_count","?")} followers, email={lead.get("email","none")})')

    # Batch insert every 20 leads
    if len(all_new) >= 20:
        batch = all_new[:20]
        all_new = all_new[20:]
        # Strip internal-only keys before insert
        clean = [{k:v for k,v in r.items() if k not in ('follower_count_raw','is_business_account','source_hashtag')} for r in batch]
        supa_post(clean)

    time.sleep(random.uniform(3, 6))  # Respect rate limits between hashtags

# Final batch
if all_new:
    clean = [{k:v for k,v in r.items() if k not in ('follower_count_raw','is_business_account','source_hashtag')} for r in all_new]
    supa_post(clean)

print(f'[discovery] Done. {new_leads_count} new leads discovered.')

if BOT_TOKEN and CHAT_ID:
    tg_send(
        f'🔍 <b>Vanta Lead Discovery</b>\n'
        f'Found <b>{new_leads_count}</b> new photographer leads.\n'
        f'Verification runs next at 10:00 SAST.'
    )
PY

echo "[$(date '+%Y-%m-%d %H:%M:%S')] vanta-lead-discovery complete" | tee -a "$LOG"
