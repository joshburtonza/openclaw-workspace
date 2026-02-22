# Video Topic Bank — Amalfi AI / Josh Burton

## Brand Context
- **Who**: Josh Burton, founder of Amalfi AI (AI agency)
- **Origin story**: Got retrenched Sept 2025 → built an AI agency from scratch
- **Face of the brand**: Personal brand tied to business (authentic, raw, no corporate BS)
- **Vibe**: SA startup energy — sharp, real, sarcastic, accessible

## Target Audience
- Business owners (SA + global)
- Developers and tech builders
- AI agency owners (peers + competitors)
- Self-employed / freelancers
- Non-techies who are curious about AI
- AI enthusiasts

## Format
- **Primary**: Short-form TikTok (Kallaway method — see video-script-method.md once added)
- **Secondary**: YouTube (same topics, longer format — flag with `[YT VERSION NEEDED]`)

---

## Rotating Topic Bank

### Pillar 1: The Origin Story (Josh's Journey)
1. "I got retrenched and built an AI agency in 90 days — here's what happened"
2. "What no one tells you about getting retrenched in your 30s"
3. "I replaced my salary with AI automation — the honest version"
4. "From employee to agency owner: the 3 things that actually mattered"
5. "Why retrenchment was the best thing that ever happened to me (I hate that it's true)"

### Pillar 2: AI Demystified (For Non-Techies)
6. "What ChatGPT actually is — explained in 60 seconds for normal people"
7. "The one AI tool every small business in SA needs right now"
8. "Stop being scared of AI. Here's why it's not taking your job (yet)"
9. "I automated my entire client email system — here's how"
10. "AI agents explained: what they are, what they do, why you should care"
11. "5 things AI can do for your business that you're not using yet"

### Pillar 3: SA Business Reality
12. "Running an AI agency from South Africa — the honest truth"
13. "Why SA entrepreneurs are actually ahead of the curve on AI adoption"
14. "Load shedding, slow internet, and still building — the SA startup reality"
15. "How to sell AI services to SA businesses (what works vs what doesn't)"
16. "The SA market is underserved for AI. Here's the opportunity."

### Pillar 4: Agency Life
17. "What it's actually like to run an AI agency in 2025/2026"
18. "How I manage 3 clients with automated systems and no full-time team"
19. "Cold outreach that doesn't suck — what I learned sending 500+ emails"
20. "Client red flags I learned the hard way (AI agency edition)"
21. "The tools running my entire agency — full stack breakdown"

### Pillar 5: Quick Wins & Hot Takes
22. "The AI workflow that saved me 10 hours this week"
23. "Stop paying for software you can automate for free"
24. "Controversial: most AI agencies are selling smoke and mirrors"
25. "The 3 prompts I use every single day (actually useful, not generic)"
26. "Why your business doesn't need an AI strategy — it needs an AI experiment"

---

## Trending Pull Instructions

At 7am, also search for 1-2 trending angles:
- Search X/Twitter for: "AI agency", "automation", "South Africa business", "Claude AI", "ChatGPT"
- Search Google Trends: "AI tools 2026", "automation small business"
- Layer trending angle onto a Pillar topic (don't chase pure trends — anchor to brand)

---

## Rotation Logic

The 7am cron picks 3 from the bank + 1 trending:
- Track last used topic index in `/tmp/video-topic-index` (increments daily, resets at 26)
- Mix pillars: don't run same pillar back to back
- Mark `[USED: YYYY-MM-DD]` when a topic is consumed

---

## YouTube Notes
- Same Kallaway structure, but expand each section (2-3x length)
- Add intro bumper: "Hey — I'm Josh, I build AI systems for SA businesses"
- Add CTA at end: follow, comment, book a call
- Flag topics that are especially YouTube-worthy with `[YT VERSION NEEDED]`
