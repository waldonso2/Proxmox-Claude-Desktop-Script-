# Changelog

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
