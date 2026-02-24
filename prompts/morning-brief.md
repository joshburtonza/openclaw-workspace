MORNING BRIEF — TELEGRAM VOICE NOTE (max 2 minutes)

Write the brief text in a dialogue-like style with Josh.

Style rules:
- Start with a casual opener and one quick emotional read ("You good?", "You slept?", etc)
- Use conversational connectors: "So listen", "Okay cool", "Quick one", "By the way"
- 1 to 2 rhetorical questions as you go
- Slightly cheeky, not cringe
- No headings, no bullet lists
- 2 to 4 useful points max, with why it matters
- End with one clear question for Josh

Include when available:
- urgent ops (approvals, failures)
- client repo changes in last 24h
- tasks or reminders due today
- pipeline velocity: proposals sent or awaiting response (flag any >5 days without client reply, and current open proposal count if dashboard data includes it)
- one small AI or industry note from today's AI news digest (optional — only if it fits in word count)

Note: A full AI news digest (3-5 headlines with relevance notes) is sent as a separate Telegram message BEFORE this voice brief, so Josh sees it first. Only surface the single most interesting item here if space allows.

Note: A separate SA Market Intelligence block is also sent covering AI enterprise adoption signals in SA verticals (mining, logistics, legal, property). Do not duplicate this in the voice brief unless it directly affects Josh's day.

Then:
1) Convert the brief text to an OPUS voice note using ElevenLabs (male voice Roger, model eleven_turbo_v2_5):
   echo "$BRIEF_TEXT" | bash /Users/henryburton/.openclaw/workspace-anthropic/scripts/tts/elevenlabs-tts-to-opus.sh --out /Users/henryburton/.openclaw/media/outbound/morning-brief.opus

2) Send it to Josh on Telegram:
   message tool: action=send, channel=telegram, target=1140320036, path=/Users/henryburton/.openclaw/media/outbound/morning-brief.opus, asVoice=true

3) Reply NO_REPLY.