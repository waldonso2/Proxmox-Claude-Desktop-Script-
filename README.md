# claude-box – eine Proxmox-VM für Claude Code

Ein Skript, eine VM: Ubuntu 24.04 mit XFCE-Desktop, Google Chrome samt
[Claude-in-Chrome](https://code.claude.com/docs/en/chrome)-Erweiterung, Claude Code,
Docker, Python, Node, git und tmux. Claude Code läuft dauerhaft mit
[Remote Control](https://code.claude.com/docs/en/remote-control) – du steuerst die
Maschine aus der Claude-App (Handy, Browser), ohne Port-Freigabe oder VPN.

## Installation

Auf dem Proxmox-Host als root (am besten über die Shell in der Proxmox-Weboberfläche):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/main/claude-box.sh)"
```

Dauer: ca. 5–15 Minuten. Am Ende stehen VMID, IP und Passwort im Terminal, und es
gibt einen Snapshot `clean-install`.

### Einmalig in der VM-Konsole

1. Im offenen Terminal `claude` starten und mit deinem Claude-Konto einloggen
   (Pro/Max – API-Keys funktionieren für Remote Control nicht).
2. `/chrome` → „Enabled by default“, dann `/exit`.
3. In Chrome bei claude.ai einloggen.
4. VM neu starten – ab jetzt startet `claude remote-control` automatisch.
5. Auf dem Host: `qm snapshot <VMID> logged-in`.

Danach erscheint die Maschine in der Claude-App unter **Code**.

## Netzwerk

Standardmäßig (`ISOLATE=1`) legt das Skript auf dem Host die Bridge `vmbr9`
(`10.99.0.0/24`) mit NAT an:

- Internet: ja
- Heimnetz, private Netze, Tailscale (`100.64.0.0/10`): gesperrt
- Proxmox-Host selbst (Weboberfläche, SSH): gesperrt

Zugriff vom LAN: `ssh -J root@<proxmox> claude@10.99.0.x`.
Vor der Änderung wird `/etc/network/interfaces` gesichert.

## Optionen

Als Umgebungsvariablen vor dem Aufruf, z. B.
`CORES=8 MEM=16384 bash -c "$(curl -fsSL …)"`.

| Variable     | Standard                    | Bedeutung                                        |
|--------------|-----------------------------|--------------------------------------------------|
| `VMID`       | nächste freie               | VM-ID                                            |
| `NAME`       | `claude-box`                | VM-Name / Hostname                               |
| `CORES`      | `4`                         | vCPUs                                            |
| `MEM`        | `8192`                      | RAM in MB                                        |
| `DISK`       | `64`                        | Disk in GB                                       |
| `STORAGE`    | `local-lvm`                 | Storage für Disk + Cloud-Init                    |
| `SNIPPETS`   | `local`                     | Storage für das Cloud-Init-Snippet               |
| `ISOLATE`    | `1`                         | `0` = VM direkt an `BRIDGE` hängen               |
| `BRIDGE`     | `vmbr0`                     | nur bei `ISOLATE=0`                              |
| `VLAN`       | –                           | VLAN-Tag, nur bei `ISOLATE=0`                    |
| `NAMESERVER` | `1.1.1.1`                   | DNS der VM                                       |
| `PASSWORD`   | zufällig                    | Passwort für User `claude`                       |
| `SSH_KEYS_FILE` | `/root/.ssh/authorized_keys` | SSH-Keys, die in die VM übernommen werden    |

## Voraussetzungen

Proxmox VE 7.2 oder neuer (`import-from`), Internetzugang vom Host, ein Claude-Pro/Max-Abo.

## Sicherheit

Wer deine Claude-Sitzung kontrolliert, hat sudo in dieser VM und Zugriff auf alles,
womit du dich in deren Chrome einloggst. Deshalb: isoliertes Netz lassen, nur
Konten verwenden, die Claude nutzen soll, und das ausgegebene Passwort ändern.
