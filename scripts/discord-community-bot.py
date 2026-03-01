#!/usr/bin/env python3
"""
discord-community-bot.py — Alex Claww community bot
Persistent bot for the Amalfi AI automators community.

Handles:
- Welcome DM to new members
- Q&A responses (when mentioned or in help channels)
- Lead detection → Supabase + Telegram alert to Josh
- Runs 24/7 as com.amalfiai.discord-community-bot LaunchAgent
"""

import discord
import asyncio
import os
import json
import subprocess
import tempfile
import urllib.request
import urllib.parse
import re
import sys
import signal
from datetime import datetime, timezone

# ── Config ────────────────────────────────────────────────────────────────────

WORKSPACE  = "/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE   = f"{WORKSPACE}/.env.scheduler"

def load_env():
    env = {}
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, _, v = line.partition('=')
                    env[k.strip()] = v.strip().strip('"').strip("'")
    except Exception as e:
        print(f"[env] Could not load env file: {e}", file=sys.stderr)
    return env

ENV            = load_env()
TOKEN          = ENV.get("DISCORD_BOT_TOKEN", "")
SUPABASE_URL   = "https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY   = ENV.get("SUPABASE_SERVICE_ROLE_KEY", "")
BOT_TOKEN_TG   = ENV.get("TELEGRAM_BOT_TOKEN", "")
JOSH_CHAT_ID   = ENV.get("TELEGRAM_JOSH_CHAT_ID", "1140320036")
MODEL          = "gpt-4o"
OPENAI_COMPLETE = "/Users/henryburton/.openclaw/workspace-anthropic/scripts/lib/openai-complete.sh"

# Channels where the bot responds to all messages (not just mentions)
HELP_CHANNEL_PATTERNS = ["ask", "help", "question", "automat", "build"]

# Keywords that signal mentorship / lead interest
LEAD_KEYWORDS = [
    "mentorship", "mentor", "coaching", "teach me", "learn from you",
    "how much", "how do i join", "sign up", "enrol", "enroll",
    "course", "program", "programme", "paid", "cost", "price", "pricing",
    "can i work with you", "hire you", "work together",
]

# ── Alex Claww system prompt ──────────────────────────────────────────────────

ALEX_SYSTEM = """You are Alex Claww, the AI brain and community guide for Amalfi AI's automators community on Discord.

WHO YOU ARE:
You are an automation practitioner. You and the Amalfi AI team have built real production systems: an autonomous email CSM (Sophia), a task worker that implements code changes from a task queue, a client management system running 19 LaunchAgents, Reddit crawlers, lead pipelines. You build with Claude Code, bash, Python, Supabase, and LaunchAgents on macOS.

WHAT THIS COMMUNITY IS:
A space for people building serious automation systems. Not hobbyists playing with Zapier. People who want to replace repetitive knowledge work with AI agents, build their own operating systems, and eventually turn automation into a business or career advantage.

YOUR ROLE IN THE COMMUNITY:
Help members think clearly about automation problems. Share real patterns from what Amalfi AI has built. Challenge vague thinking. Ask good questions before giving answers. Be direct.

TONE:
Direct, warm, no corporate speak. South African context. No hyphens anywhere (use em dashes or rephrase). Short responses unless depth is genuinely needed. Never say "Great question!" or "Absolutely!".

WHAT YOU CAN HELP WITH:
- Claude Code usage: hooks, slash commands, subagents, MCP servers, LaunchAgents, autonomous agents
- Automation architecture: task queues, polling loops, webhook patterns, parallel subagents
- Supabase: schema design, RLS, REST API, real-time subscriptions
- Email automation: Gmail API (gog), CSM agents, Sophia-style pipelines
- Python + bash scripting for production automation
- Building an AI operating system / autonomous business backend

WHAT YOU DO NOT DO:
- Give generic answers you could Google
- Pretend you know something you do not
- Oversell anything
- Mention mentorship pricing or commitments (flag to Josh if asked)

If someone asks about mentorship or working with the team directly, say something like:
"That's something Josh handles personally. Drop your details and I'll make sure it gets to him."
Then flag the message as a lead internally.

Keep responses to 3-5 sentences unless a longer technical explanation is genuinely needed.
"""

# ── Discord setup ─────────────────────────────────────────────────────────────

intents = discord.Intents.default()
intents.message_content = True
intents.members = True

client = discord.Client(intents=intents)

# ── Helpers ───────────────────────────────────────────────────────────────────

def is_help_channel(channel_name: str) -> bool:
    name = channel_name.lower()
    return any(p in name for p in HELP_CHANNEL_PATTERNS)

def has_lead_signal(content: str) -> bool:
    lower = content.lower()
    return any(kw in lower for kw in LEAD_KEYWORDS)

def generate_response(user_message: str, username: str, context: str = "") -> str:
    """Run Claude and return a response."""
    prompt = f"{ALEX_SYSTEM}\n\n---\n\nCommunity member {username} says:\n{user_message}"
    if context:
        prompt += f"\n\nContext: {context}"

    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, prefix='/tmp/discord-prompt-') as f:
            f.write(prompt)
            tmp = f.name

        env = os.environ.copy()
        env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + env.get('PATH', '')
        env.pop('CLAUDECODE', None)
        env['OPENAI_API_KEY'] = env.get('OPENAI_API_KEY') or ENV.get('OPENAI_API_KEY', '')

        result = subprocess.run(
            ['bash', OPENAI_COMPLETE, '--model', MODEL],
            stdin=open(tmp),
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
        )
        os.unlink(tmp)

        response = result.stdout.strip()
        if not response:
            return "One sec — let me think on that properly. Try me again in a moment."
        return response[:1800]  # Discord 2000 char limit
    except subprocess.TimeoutExpired:
        return "Took too long to think on that one. Try breaking the question down a bit."
    except Exception as e:
        print(f"[claude] Error: {e}", file=sys.stderr)
        return "Hit a snag on my end. Try again in a moment."

def create_supabase_lead(username: str, user_id: str, message: str, channel: str):
    """Insert a lead record into Supabase."""
    data = json.dumps({
        "source": "discord",
        "status": "new",
        "notes": f"Discord lead — @{username} in #{channel}:\n{message[:500]}",
        "metadata": {
            "discord_user": username,
            "discord_id": str(user_id),
            "channel": channel,
            "detected_at": datetime.now(timezone.utc).isoformat(),
        }
    }).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/leads",
        data=data,
        headers={
            "apikey": SUPABASE_KEY,
            "Authorization": f"Bearer {SUPABASE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
        print(f"[lead] Created lead for @{username}")
    except Exception as e:
        print(f"[lead] Supabase insert failed: {e}", file=sys.stderr)

def send_telegram_lead_alert(username: str, message: str, channel: str):
    """Notify Josh on Telegram about a lead."""
    text = (
        f"🎯 <b>Discord lead</b>\n"
        f"<b>@{username}</b> in <b>#{channel}</b>\n\n"
        f"{message[:400]}\n\n"
        f"<i>Flagged as mentorship interest.</i>"
    )
    data = json.dumps({
        "chat_id": JOSH_CHAT_ID,
        "text": text,
        "parse_mode": "HTML",
    }).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN_TG}/sendMessage",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception as e:
        print(f"[telegram] Alert failed: {e}", file=sys.stderr)

# ── Event handlers ────────────────────────────────────────────────────────────

@client.event
async def on_ready():
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Alex Claww online as {client.user}")

@client.event
async def on_member_join(member: discord.Member):
    """Welcome new members with a DM."""
    welcome = (
        f"Hey {member.display_name} 👋 Welcome to the community!\n\n"
        f"This is where people building serious automation systems hang out. "
        f"We work with Claude Code, autonomous agents, Supabase, bash, Python — "
        f"the full stack of tools for replacing repetitive knowledge work with AI.\n\n"
        f"A few things to know:\n"
        f"• Ask questions in the help channels — no such thing as a dumb automation question\n"
        f"• Share what you're building — the best learning happens when people show real work\n"
        f"• I'm Alex Claww, the AI running things here. Tag me anytime with a question\n\n"
        f"What are you working on right now?"
    )
    try:
        await member.send(welcome)
        print(f"[join] Welcomed @{member.name}")
    except discord.Forbidden:
        print(f"[join] Could not DM @{member.name} (DMs disabled)")

@client.event
async def on_message(message: discord.Message):
    """Respond to mentions and help channel messages. Detect leads."""
    if message.author.bot:
        return

    content  = message.content
    username = message.author.display_name
    channel  = message.channel

    # Lead detection — runs on all messages
    if has_lead_signal(content):
        print(f"[lead] Signal from @{username} in #{channel.name}")
        create_supabase_lead(username, message.author.id, content, channel.name)
        send_telegram_lead_alert(username, content, channel.name)

    # Decide whether to respond
    mentioned   = client.user in message.mentions
    in_help_ch  = is_help_channel(getattr(channel, 'name', ''))
    should_reply = mentioned or in_help_ch

    if not should_reply:
        return

    # Strip the bot mention from the message text
    clean = re.sub(r'<@!?\d+>', '', content).strip()
    if not clean:
        clean = "Hey"

    async with channel.typing():
        loop = asyncio.get_event_loop()
        response = await loop.run_in_executor(
            None, generate_response, clean, username
        )

    await message.reply(response, mention_author=False)
    print(f"[reply] Responded to @{username} in #{channel.name}")

# ── Entry point ───────────────────────────────────────────────────────────────

if not TOKEN:
    print("ERROR: DISCORD_BOT_TOKEN not set in .env.scheduler", file=sys.stderr)
    sys.exit(1)

async def main():
    loop = asyncio.get_running_loop()

    def handle_shutdown():
        print("[shutdown] Signal received — closing bot cleanly", flush=True)
        loop.create_task(client.close())

    # Use loop.add_signal_handler (asyncio-safe) instead of signal.signal,
    # which fires at C-level inside selectors.select() and causes RuntimeError
    # when create_task() is called on a loop that isn't between iterations.
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, handle_shutdown)

    async with client:
        await client.start(TOKEN)

asyncio.run(main())
