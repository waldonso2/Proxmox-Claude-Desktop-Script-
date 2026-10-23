# claude-box – ein Proxmox-Rechner für Claude Code

Ein Skript, ein Rechner für Claude Code, gesteuert per
[Remote Control](https://code.claude.com/docs/en/remote-control) aus der Claude-App
(Handy, Browser) – ohne Port-Freigabe oder VPN.

| | `TYPE=vm` (Standard) | `TYPE=lxc` |
|---|---|---|
| System | Ubuntu 24.04, eigener Kernel | Debian 13, teilt den Host-Kernel |
| Browser | Google Chrome mit [Claude in Chrome](https://code.claude.com/docs/en/chrome) – mit deinen Logins | Headless-Chromium über Playwright-MCP – ohne Logins |
| Oberfläche | Mini-Desktop (Openbox, Terminal + Chrome) in der Proxmox-Konsole | nur Shell |
| Isolation | stark | schwächer (Kernel-Lücke = Host) |
| Ressourcen (Standard) | 2 vCPU, 4 GB RAM, 32 GB | 2 vCPU, 4 GB RAM, 32 GB |

Bewusst minimal: Claude Code, Browser, git, tmux, curl. Alles Weitere (Docker,
Python, …) installiert Claude bei Bedarf selbst – der User `claude` hat sudo.

## Installation

Auf dem Proxmox-Host als root (am besten über die Shell in der Proxmox-Weboberfläche):

```bash
# VM
bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/main/claude-box.sh)"
# Container
TYPE=lxc bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/main/claude-box.sh)"
```

Am Ende stehen ID, IP, User, Passwort und die einmaligen Login-Schritte im Terminal
und in den **Notizen** der VM bzw. des Containers (Proxmox-UI → Übersicht).
Außerdem gibt es einen Snapshot `clean-install`.

### Einmalig: einloggen

**VM** – in der Proxmox-Konsole der VM (Terminal + Chrome sind schon offen):

1. `claude` → mit deinem Claude-Konto einloggen (Pro/Max – API-Keys gehen für
   Remote Control nicht), dann `/chrome` → „Enabled by default“, `/exit`.
2. In Chrome bei claude.ai einloggen.
3. `claude remote-control`
4. Auf dem Host: `qm snapshot <ID> logged-in`

**LXC** – auf dem Host:

1. `pct enter <ID>`, dann `su - claude`
2. `claude` → einloggen, `/exit`
3. `sudo systemctl restart claude-rc` (Session ansehen: `tmux attach -t claude`)
4. Auf dem Host: `pct snapshot <ID> logged-in`

Danach erscheint die Maschine in der Claude-App unter **Code** und startet nach
jedem Reboot automatisch wieder.

## Netzwerk

Standardmäßig (`ISOLATE=1`) legt das Skript auf dem Host die Bridge `vmbr9`
(`10.99.0.0/24`) mit NAT an:

- Internet: ja
- Heimnetz, private Netze, Tailscale (`100.64.0.0/10`): gesperrt
- Proxmox-Host selbst (Weboberfläche, SSH): gesperrt

VM vom LAN erreichen: `ssh -J root@<proxmox> claude@10.99.0.x`.
Vor der Änderung wird `/etc/network/interfaces` gesichert.

## Optionen

Als Umgebungsvariablen vor dem Aufruf, z. B.
`TYPE=lxc CORES=4 MEM=8192 bash -c "$(curl -fsSL …)"`.

| Variable        | Standard                     | Bedeutung                                  |
|-----------------|------------------------------|--------------------------------------------|
| `TYPE`          | `vm`                         | `vm` oder `lxc`                            |
| `VMID`          | nächste freie                | ID                                         |
| `NAME`          | `claude-box`                 | Name / Hostname                            |
| `CORES`         | `2`                          | vCPUs                                      |
| `MEM`           | `4096`                       | RAM in MB                                  |
| `DISK`          | `32`                         | Disk in GB                                 |
| `STORAGE`       | `local-lvm`                  | Storage für Disk / Rootfs                  |
| `SNIPPETS`      | `local`                      | VM: Storage für das Cloud-Init-Snippet     |
| `TEMPLATES`     | `local`                      | LXC: Storage für das Debian-Template       |
| `ISOLATE`       | `1`                          | `0` = direkt an `BRIDGE` hängen            |
| `BRIDGE`        | `vmbr0`                      | nur bei `ISOLATE=0`                        |
| `VLAN`          | –                            | VLAN-Tag, nur bei `ISOLATE=0`              |
| `NAMESERVER`    | `1.1.1.1`                    | DNS                                        |
| `PASSWORD`      | zufällig                     | Passwort für User `claude`                 |
| `SSH_KEYS_FILE` | `/root/.ssh/authorized_keys` | VM: SSH-Keys für User `claude`             |

## Voraussetzungen

Proxmox VE 8 (VM: `import-from` ab 7.2), Internetzugang vom Host, ein Claude-Pro/Max-Abo.

## Sicherheit

Wer deine Claude-Sitzung kontrolliert, hat sudo in dieser Maschine und – bei der
VM – Zugriff auf alles, womit du dich in deren Chrome einloggst. Deshalb: isoliertes
Netz lassen, nur Konten verwenden, die Claude nutzen soll, und das Passwort ändern
(es steht im Klartext in den Proxmox-Notizen – nach dem Ändern dort löschen).
Für Arbeit mit echten Logins die VM nehmen, nicht den Container.
