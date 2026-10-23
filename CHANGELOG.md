# Changelog

## 0.2.0

Neu: Container-Variante und deutlich schlankere VM.

```bash
# VM
bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/v0.2.0/claude-box.sh)"
# Container
TYPE=lxc bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/v0.2.0/claude-box.sh)"
```

- `TYPE=lxc`: Debian-13-Container ohne Desktop, Claude Code + Headless-Chromium über Playwright-MCP, Remote Control als systemd-Dienst
- VM verschlankt: Openbox + xterm + Chrome statt XFCE/LightDM; kein Docker, Python, Node vorinstalliert (Claude installiert bei Bedarf selbst)
- VM: User, Passwort und SSH-Keys über Proxmox' eigene Cloud-Init-Felder
- Standardgröße 2 vCPU, 4 GB RAM, 32 GB Disk
- Isoliertes Netz `vmbr9` gilt für beide Varianten

Pre-Release: noch nicht auf echter Proxmox-Hardware getestet.

## 0.1.0

Erste Version von **claude-box**: eine Proxmox-VM für Claude Code mit Remote Control und Chrome.

Installation auf dem Proxmox-Host als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/v0.1.0/claude-box.sh)"
```

- Ubuntu 24.04 per Cloud-Init: XFCE (Autologin), Google Chrome + Claude-in-Chrome-Erweiterung, Claude Code, Docker, Python, Node, git, tmux
- `claude remote-control` startet automatisch – Steuerung aus der Claude-App (Handy/Browser)
- Standardmäßig isoliertes NAT-Netz `vmbr9`: Internet ja, Heimnetz und Proxmox-Host nein
- Snapshot `clean-install` nach der Installation
- Konfiguration über Umgebungsvariablen (siehe README)

Pre-Release: noch nicht auf echter Proxmox-Hardware getestet.
