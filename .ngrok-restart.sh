#!/bin/bash
# Kill existing ngrok and restart with basic auth on same static domain
pkill -f ngrok 2>/dev/null
sleep 2
nohup ngrok http 18789 \
  --domain=nonvoluble-arythmically-virgen.ngrok-free.dev \
  --basic-auth="josh:Amalfi2026!" \
  > /tmp/ngrok.log 2>&1 &
sleep 3
curl -s http://localhost:4040/api/tunnels | python3 -c "
import sys, json
d = json.load(sys.stdin)
for t in d.get('tunnels', []):
    print('✅ Tunnel live:', t.get('public_url'))
"
