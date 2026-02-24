# Tailscale Remote Access Setup

## 1. What This Gives You

Tailscale creates a secure peer to peer encrypted tunnel between Josh's MacBook and the Race Technik Mac Mini. It has the following benefits:

- No port forwarding required on any router
- No dynamic DNS setup or maintenance
- Works through any NAT or firewall automatically
- Josh can SSH into the Mac Mini from anywhere in the world as if it were on the same local network
- Claude Code on Josh's MacBook can send tasks directly to the Mac Mini's Claude instance via Supabase, and the Mac Mini picks them up and runs them autonomously
- Zero ongoing infrastructure to manage

---

## 2. Install on Race Technik Mac Mini

Run these commands on the Mac Mini (logged in as farhaan):

```bash
brew install tailscale
```

Start the Tailscale daemon and connect to the network:

```bash
sudo tailscaled
tailscale up
```

Tailscale will print a URL to authenticate in a browser. Open it, log in with the Amalfi AI Google account (or create a free Tailscale account), and authorize the device.

After login, note the Tailscale IP address shown. It will be in the format `100.x.x.x`. Write this down. You will need it for SSH config on Josh's MacBook.

Enable SSH on the Mac Mini so it accepts remote connections:

1. Open System Settings
2. Go to General
3. Go to Sharing
4. Find Remote Login and turn it ON

Then add an allowlist to the SSH config so only the farhaan user can log in remotely:

```bash
sudo nano /etc/ssh/sshd_config
```

Add this line at the bottom of the file:

```
AllowUsers farhaan
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`), then restart SSH:

```bash
sudo launchctl kickstart -k system/com.openssh.sshd
```

---

## 3. Install on Josh's MacBook

Run these commands on Josh's MacBook:

```bash
brew install tailscale
tailscale up
```

Authenticate in the browser using the same Tailscale account used on the Mac Mini. Both machines are now on the same Tailscale private network and can reach each other by their `100.x.x.x` addresses.

Verify connectivity by pinging the Mac Mini:

```bash
ping 100.x.x.x
```

---

## 4. Set Up SSH Key Auth (No Passwords)

Password prompts every time you connect are impractical for automation. Set up key based authentication instead.

On Josh's MacBook, generate a dedicated SSH key for this connection:

```bash
ssh-keygen -t ed25519 -C "josh@amalfiai-to-race-technik" -f ~/.ssh/race_technik
```

When prompted for a passphrase, leave it empty (press Enter twice) so scripts can connect without interaction.

Copy the public key to the Mac Mini:

```bash
ssh-copy-id -i ~/.ssh/race_technik.pub farhaan@<tailscale-ip>
```

Replace `<tailscale-ip>` with the actual `100.x.x.x` address you noted earlier. It will prompt for farhaan's Mac Mini password once, then store the key.

Test that key auth works:

```bash
ssh -i ~/.ssh/race_technik farhaan@<tailscale-ip> echo ok
```

You should see `ok` printed without any password prompt.

---

## 5. Add SSH Config Alias on Josh's MacBook

Edit `~/.ssh/config` on Josh's MacBook (create it if it does not exist):

```
Host rt-macmini
  HostName 100.x.x.x
  User farhaan
  IdentityFile ~/.ssh/race_technik
  ServerAliveInterval 60
```

Replace `100.x.x.x` with the actual Tailscale IP of the Mac Mini.

After saving, you can now SSH using just:

```bash
ssh rt-macmini
```

No IP address, no key flag, no username needed.

---

## 6. Set Up tmux on Mac Mini for Persistent Claude Sessions

Without tmux, closing your SSH connection kills any Claude session running inside it. tmux keeps sessions alive on the server side regardless of connection state.

Install tmux on the Mac Mini:

```bash
brew install tmux
```

Create a minimal tmux config to enable mouse support:

```bash
echo "set -g mouse on" > ~/.tmux.conf
```

Start a persistent Claude session in the background from Josh's MacBook:

```bash
ssh rt-macmini 'tmux new-session -d -s claude "unset CLAUDECODE && claude"'
```

This creates a detached tmux session named `claude` running the Claude Code CLI. It stays alive even if you disconnect.

To attach to the session and interact with it from Josh's MacBook:

```bash
ssh -t rt-macmini 'tmux attach -t claude'
```

Press `Ctrl+B` then `D` to detach without killing the session.

---

## 7. The `rt` Shortcut on Josh's MacBook

Add this alias to `~/.zshrc` on Josh's MacBook:

```bash
alias rt='ssh -t rt-macmini "tmux new-session -A -s claude \"unset CLAUDECODE && claude\""'
```

The `-A` flag means: attach to an existing session named `claude` if one exists, or create a new one if not. This means you can safely run `rt` multiple times and it will always land in the right session.

After adding the alias, reload your shell:

```bash
source ~/.zshrc
```

Now simply type `rt` from anywhere on Josh's MacBook to instantly open an interactive Claude Code session running on the Race Technik Mac Mini.
