# Mission Control PWA - Home Screen Installation Guide

## What's New

✅ **Progressive Web App** — Install to your iPhone/iPad home screen
✅ **Task Management** — Add, check off, and manage tasks in real-time
✅ **Heartbeat Integration** — System checks tasks every 30 mins, alerts on urgent items
✅ **Offline Support** — Service worker caches core UI (works without internet)
✅ **Real-time Sync** — Supabase updates appear instantly across all tabs

---

## How to Install on Safari (iPhone/iPad)

### Step 1: Open in Safari
Go to: `http://localhost:8080/` on your iPhone/iPad (or use the network IP: `http://192.168.1.4:8080/`)

### Step 2: Install to Home Screen
1. Tap the **Share** button (square with arrow)
2. Scroll down and tap **Add to Home Screen**
3. Customize name (e.g., "Mission Control")
4. Tap **Add**

Done! You now have a native-feeling app icon on your home screen.

### Step 3: Use Like an App
- Opens full-screen (no browser UI)
- Touch ID / Face ID to unlock
- Back/forward swipe gestures
- Independent from Safari tabs

---

## Task Board Features

### Adding Tasks
1. Click **Add Task** at the top
2. Type task name (required)
3. Select priority: Low / Medium / High / **URGENT**
4. Press Enter or click **Add**

### Managing Tasks
- **Click circle icon** → Mark as done (green checkmark)
- **Click again** → Undo (back to circle)
- **Delete button** → Remove task permanently

### Task Board Shows
- **Total**: All tasks created
- **Done**: Completed tasks
- **Active**: In progress tasks
- **Blocked**: Stuck tasks (manual update)

### Status Updates
Right now: Manual check-off (you click the circle)

Soon: Heartbeat automation will:
- Check task board at 12pm daily
- Alert you on Telegram if any URGENT tasks pending
- Post daily completion rate to Discord
- Suggest task prioritization

---

## Real-Time Sync

Tasks are stored in Supabase. They sync:
- **Across devices** — Update on phone, see on Mac instantly
- **Live dashboard** — Mission Control on web updates in real-time
- **Offline queued** — Add tasks offline, they sync when reconnected

---

## Heartbeat + Task Board

Every day at 12pm, the system:

1. **Scans task board**
   - URGENT tasks? → Telegram alert
   - Tasks stuck >2h? → Discord post
   - Completion rate? → Log it

2. **Checks email queue**
   - Escalations pending? → Alert Josh
   - Backlog growing? → Post status

3. **Reviews client repos**
   - New commits? → Mention in Discord

4. **Generates summary**
   - "All systems nominal. 5 tasks completed today."
   - OR "🚨 URGENT: [tasks] need attention"

---

## Tips for Safari PWA

### Recommended
- ✅ Use with Face ID (auto-unlock)
- ✅ Add to home screen on both iPhone + iPad
- ✅ Keep tasks up-to-date (refresh for latest)
- ✅ Check Telegram for daily heartbeat alerts

### Limitations (Safari PWA vs Native App)
- Cannot send push notifications (yet) — We use Telegram for alerts instead
- No home screen badge count — Heartbeat tells you via Telegram
- Cannot run in background — Tasks check via cron server-side

### Workaround: Add Web Clip Icon
1. Go to home screen
2. Edit → Add widget
3. Create blank shortcut with Mission Control URL
4. Assigns custom icon + color

---

## Architecture

```
iPhone Safari PWA
  ↓
(Service Worker caches core UI)
  ↓
Supabase Realtime (live sync)
  ↓
Task Board (your input)
  ↓
Heartbeat Cron (12pm daily)
  ↓
Telegram alerts (urgent)
  ↓
Discord digest (summary)
```

---

## What Happens When You Add a Task

1. **You type & click Add** (on iPhone or Mac)
2. **Supabase receives insert** (real-time)
3. **All tabs update** (magic! 🪄)
4. **Heartbeat includes it tomorrow** (at 12pm)
5. **If URGENT** → Telegram pings you
6. **Check it off** → Counts toward daily completion rate

---

## Pro Tips

- **Mobile + Desktop combo**: Use iPhone for quick check-offs, Mac for detailed task review
- **URGENT for today**: Use URGENT priority, will get Telegram alert at 12pm heartbeat
- **Batch add**: Add 5 tasks quick, then start knocking them out
- **Export your data**: Task history lives in Supabase forever (backups included)

---

## Next Updates (Planned)

- [ ] Task categories (Work / Personal / Cold Outreach)
- [ ] Due dates with reminders
- [ ] Subtasks (break big tasks into smaller ones)
- [ ] Assign tasks to agents (Sophia, Alex, etc.)
- [ ] Push notifications (via service worker when browsers support it)
- [ ] Dark/Light mode toggle
- [ ] Export tasks as CSV

---

## Testing the Setup

**On your iPhone:**
```
1. Install to home screen
2. Tap the icon
3. Click "Add Task"
4. Type: "Test PWA installation"
5. Click "Add"
6. Refresh Safari
7. Task still there? ✅ It's working!
```

**Heartbeat test:**
```
Today at 12pm, you should get Telegram ping:
"[HEARTBEAT] 1 task pending. 0 URGENT."

If you don't get it, check:
- Telegram bot pairing active? (run: openclaw pairing list telegram)
- Heartbeat cron enabled? (cron list)
```

---

**You now have a fully installable task management app that syncs in real-time and alerts you on urgent items. Welcome to the future. 🚀**
