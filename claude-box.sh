#!/usr/bin/env bash

# Copyright (c) 2026 waldonso2
# License: MIT | https://github.com/waldonso2/Proxmox-Claude-Desktop-Script-/raw/main/LICENSE
# Source: https://code.claude.com/docs/en/remote-control
#
# claude-box.sh – Rechner für Claude Code auf Proxmox VE, gesteuert per Remote Control.
#   TYPE=vm  (Standard): Ubuntu-VM mit Mini-Desktop, Chrome + Claude-in-Chrome
#   TYPE=lxc           : Debian-Container ohne Desktop, Headless-Chromium über Playwright-MCP
#
# Ausführen auf dem Proxmox-Host als root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/main/claude-box.sh)"
#   TYPE=lxc bash -c "$(curl -fsSL …)"
set -euo pipefail

# ---------- Einstellungen ----------
TYPE="${TYPE:-vm}"
VMID="${VMID:-$(pvesh get /cluster/nextid)}"
NAME="${NAME:-claude-box}"
CORES="${CORES:-2}"
MEM="${MEM:-4096}"               # MB
DISK="${DISK:-32}"               # GB
STORAGE="${STORAGE:-local-lvm}"  # Disk / Rootfs
SNIPPETS="${SNIPPETS:-local}"    # VM: Storage für das Cloud-Init-Snippet
TEMPLATES="${TEMPLATES:-local}"  # LXC: Storage für das Debian-Template
BRIDGE="${BRIDGE:-vmbr0}"
VLAN="${VLAN:-}"
# ISOLATE=1: eigenes NAT-Netz 10.99.0.0/24 – Internet ja, Heimnetz & Proxmox-Host nein.
ISOLATE="${ISOLATE:-1}"
ISO_BRIDGE="${ISO_BRIDGE:-vmbr9}"
NAMESERVER="${NAMESERVER:-1.1.1.1}"
SSH_KEYS_FILE="${SSH_KEYS_FILE:-/root/.ssh/authorized_keys}"
PASSWORD="${PASSWORD:-$(openssl rand -base64 12 | tr -d '/+=')}"
PLAYWRIGHT_MCP="@playwright/mcp@0.0.83"

log() { echo -e "\e[1;34m[claude-box]\e[0m $*"; }
die() { echo -e "\e[1;31m[claude-box] FEHLER:\e[0m $*" >&2; exit 1; }

command -v qm >/dev/null || die "Muss auf einem Proxmox-VE-Host laufen."
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
[[ $TYPE == vm || $TYPE == lxc ]] || die "TYPE muss vm oder lxc sein."
{ qm status "$VMID" || pct status "$VMID"; } &>/dev/null && die "ID $VMID ist schon belegt."

# ---------- Isoliertes Netz (Bridge ohne Uplink + NAT + Sperren) ----------
IPCONFIG="ip=dhcp"
if [[ $ISOLATE == 1 ]]; then
  if ! grep -q "^iface $ISO_BRIDGE " /etc/network/interfaces; then
    [[ -e /etc/network/interfaces.new ]] && die "Offene Netzwerkänderungen in der Proxmox-GUI – erst anwenden oder verwerfen."
    UPLINK=$(ip route show default | awk '{print $5; exit}')
    [[ -n "$UPLINK" ]] || die "Keine Default-Route gefunden."
    log "Lege isoliertes Netz $ISO_BRIDGE (10.99.0.0/24, NAT über $UPLINK) an …"
    cp /etc/network/interfaces "/etc/network/interfaces.bak-claude-box-$(date +%s)"
    {
      echo ""
      echo "# claude-box: isoliertes Netz – Internet ja, Heimnetz/Host nein"
      echo "auto $ISO_BRIDGE"
      echo "iface $ISO_BRIDGE inet static"
      echo "    address 10.99.0.1/24"
      echo "    bridge-ports none"
      echo "    bridge-stp off"
      echo "    bridge-fd 0"
      echo "    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward"
      echo "    post-up   iptables -t nat -A POSTROUTING -s 10.99.0.0/24 -o $UPLINK -j MASQUERADE"
      echo "    post-down iptables -t nat -D POSTROUTING -s 10.99.0.0/24 -o $UPLINK -j MASQUERADE"
      echo "    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1"
      echo "    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1"
      # keine privaten Netze (Heimnetz, Docker-Netze, Tailscale)
      for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
        echo "    post-up   iptables -I FORWARD -i $ISO_BRIDGE -d $n -j DROP"
        echo "    post-down iptables -D FORWARD -i $ISO_BRIDGE -d $n -j DROP"
      done
      # kein Zugriff auf den Proxmox-Host (GUI :8006, SSH) – nur Antworten auf Host-Verbindungen
      echo "    post-up   iptables -I INPUT -i $ISO_BRIDGE -j DROP"
      echo "    post-up   iptables -I INPUT -i $ISO_BRIDGE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      echo "    post-down iptables -D INPUT -i $ISO_BRIDGE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      echo "    post-down iptables -D INPUT -i $ISO_BRIDGE -j DROP"
    } >> /etc/network/interfaces
    ifreload -a
  fi
  BRIDGE="$ISO_BRIDGE"; VLAN=""
  # shortcut: IP aus der ID abgeleitet, kollidiert erst bei >230 claude-boxen
  IP="10.99.0.$(( VMID % 230 + 20 ))"
  IPCONFIG="ip=$IP/24,gw=10.99.0.1"
fi

if [[ $TYPE == vm ]]; then
  # ---------- VM: Ubuntu-Cloud-Image + Cloud-Init ----------
  IMG=/var/lib/vz/template/cloudimg/noble-server-cloudimg-amd64.img
  mkdir -p "$(dirname "$IMG")"
  if [[ ! -f "$IMG" || -n "$(find "$IMG" -mtime +14)" ]]; then
    log "Lade Ubuntu 24.04 Cloud-Image …"
    wget -q --show-progress -O "$IMG.tmp" https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    mv "$IMG.tmp" "$IMG"
  fi

  if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIPPETS"; then
    log "Aktiviere Inhaltstyp 'snippets' auf Storage '$SNIPPETS' …"
    pvesm set "$SNIPPETS" --content "$(pvesh get "/storage/$SNIPPETS" --output-format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["content"])'),snippets"
  fi
  SNIPPET_PATH=$(pvesm path "$SNIPPETS:snippets/claude-box-vendor.yaml")
  mkdir -p "$(dirname "$SNIPPET_PATH")"
  # Vendor-Data: Pakete & Desktop. User, Passwort, SSH-Keys, Hostname setzt Proxmox selbst.
  cat > "$SNIPPET_PATH" <<'YAML'
#cloud-config
timezone: Europe/Berlin
keyboard:
  layout: de
packages: [qemu-guest-agent, xserver-xorg-core, xserver-xorg-input-libinput, xinit, openbox, xterm, tmux, git, curl]
write_files:
  # "Claude in Chrome"-Erweiterung automatisch installieren
  - path: /etc/opt/chrome/policies/managed/claude.json
    content: '{"ExtensionInstallForcelist": ["fcoeoabgfenejglbffodgkkbkcdhcgfn"]}'
  # Autologin auf tty1 → startx → Chrome + Terminal mit Remote Control
  - path: /etc/systemd/system/getty@tty1.service.d/autologin.conf
    content: |
      [Service]
      ExecStart=
      ExecStart=-/sbin/agetty --autologin claude --noclear %I $TERM
  - path: /home/claude/.bash_profile
    owner: claude:claude
    defer: true
    content: |
      export PATH="$HOME/.local/bin:$PATH"
      [ -f ~/.bashrc ] && . ~/.bashrc
      [ -z "$DISPLAY" ] && [ "$(tty)" = /dev/tty1 ] && exec startx
  - path: /home/claude/.xinitrc
    owner: claude:claude
    defer: true
    content: |
      google-chrome --no-first-run --no-default-browser-check &
      xterm -maximized -fa Monospace -fs 11 -e tmux new -A -s claude -c ~/workspace 'claude remote-control; exec bash' &
      exec openbox
runcmd:
  - systemctl enable --now qemu-guest-agent
  - curl -fsSLo /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  - DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/chrome.deb && rm /tmp/chrome.deb
  - sudo -u claude -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash && mkdir -p ~/workspace'
  - systemctl daemon-reload && systemctl restart getty@tty1
YAML

  NET="virtio,bridge=$BRIDGE${VLAN:+,tag=$VLAN}"
  log "Erzeuge VM $VMID ($NAME): $CORES vCPU, $MEM MB RAM, $DISK GB Disk"
  qm create "$VMID" --name "$NAME" --ostype l26 --machine q35 --cpu host \
    --cores "$CORES" --memory "$MEM" --scsihw virtio-scsi-single --net0 "$NET" \
    --agent enabled=1 --vga std --onboot 1 --tags claude
  qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,ssd=1,iothread=1" >/dev/null
  qm resize "$VMID" scsi0 "${DISK}G"
  qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 \
    --ciuser claude --cipassword "$PASSWORD" --ipconfig0 "$IPCONFIG" --nameserver "$NAMESERVER" \
    --cicustom "vendor=$SNIPPETS:snippets/claude-box-vendor.yaml" >/dev/null
  [[ -s $SSH_KEYS_FILE ]] && qm set "$VMID" --sshkeys "$SSH_KEYS_FILE" >/dev/null
  qm start "$VMID"

  log "VM bootet und installiert (ca. 5–10 Min.) …"
  for _ in $(seq 1 90); do qm agent "$VMID" ping &>/dev/null && break; sleep 10; done
  if qm guest exec "$VMID" --timeout 3600 -- cloud-init status --wait 2>/dev/null | grep -q '"exitcode" : 0'; then
    qm snapshot "$VMID" clean-install >/dev/null && log "Snapshot 'clean-install' angelegt."
  else
    log "Warnung: Cloud-Init nicht sauber fertig – Konsole prüfen (cloud-init status --long)."
  fi
  [[ -n ${IP:-} ]] || IP=$(qm guest exec "$VMID" -- hostname -I 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin).get("out-data","").split()[0])' || true)
  FIRST_STEPS="Proxmox-Konsole der VM (Desktop mit Terminal + Chrome):
  1. Im Terminal: claude  → einloggen, dann /chrome → \"Enabled by default\", /exit
  2. In Chrome bei claude.ai einloggen
  3. Im Terminal: claude remote-control
  4. Auf dem Host: qm snapshot $VMID logged-in"
else
  # ---------- LXC: Debian 13, ohne Desktop ----------
  pveam update >/dev/null
  TPL=$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard' | sort -V | tail -1)
  [[ -n $TPL ]] || die "Kein Debian-13-Template gefunden."
  pveam list "$TEMPLATES" | grep -q "$TPL" || pveam download "$TEMPLATES" "$TPL"

  log "Erzeuge Container $VMID ($NAME): $CORES vCPU, $MEM MB RAM, $DISK GB Disk"
  pct create "$VMID" "$TEMPLATES:vztmpl/$TPL" --hostname "$NAME" --unprivileged 1 --features nesting=1 \
    --cores "$CORES" --memory "$MEM" --swap 512 --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=$BRIDGE,$IPCONFIG${VLAN:+,tag=$VLAN}" --nameserver "$NAMESERVER" \
    --onboot 1 --tags claude --start 1 >/dev/null
  for _ in $(seq 1 30); do pct exec "$VMID" -- getent hosts deb.debian.org &>/dev/null && break; sleep 2; done

  log "Installiere Claude Code + Headless-Chromium (ca. 3–5 Min.) …"
  pct exec "$VMID" -- env PASSWORD="$PASSWORD" PLAYWRIGHT_MCP="$PLAYWRIGHT_MCP" bash -s <<'SETUP'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends sudo curl ca-certificates git tmux nodejs npm chromium fonts-liberation
useradd -m -s /bin/bash -G sudo claude
echo "claude:$PASSWORD" | chpasswd
echo 'claude ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claude
sudo -u claude -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash && mkdir -p ~/workspace'
sudo -u claude -H ~claude/.local/bin/claude mcp add --scope user playwright -- \
  npx -y "$PLAYWRIGHT_MCP" --headless --browser chromium --executable-path /usr/bin/chromium --no-sandbox
cat > /etc/systemd/system/claude-rc.service <<'EOF'
[Unit]
Description=Claude Code Remote Control (tmux-Session "claude")
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
User=claude
WorkingDirectory=/home/claude/workspace
ExecStart=/usr/bin/tmux new-session -d -s claude "bash -lc 'claude remote-control; exec bash'"
ExecStop=/usr/bin/tmux kill-session -t claude
[Install]
WantedBy=multi-user.target
EOF
systemctl enable claude-rc
SETUP
  pct snapshot "$VMID" clean-install >/dev/null && log "Snapshot 'clean-install' angelegt." || log "Warnung: Snapshot nicht möglich (Storage ohne Snapshots?)."
  [[ -n ${IP:-} ]] || IP=$(pct exec "$VMID" -- hostname -I | awk '{print $1}')
  FIRST_STEPS="Auf dem Host:
  1. pct enter $VMID   dann: su - claude
  2. claude  → einloggen, /exit
  3. sudo systemctl restart claude-rc   (Session ansehen: tmux attach -t claude)
  4. Auf dem Host: pct snapshot $VMID logged-in"
fi

# Zugangsdaten in die Notizen (Proxmox-UI → Übersicht) – stehen damit auch im Klartext in /etc/pve
PVE_CMD=qm; [[ $TYPE == lxc ]] && PVE_CMD=pct
$PVE_CMD set "$VMID" --description "## claude-box ($TYPE)

- **User:** \`claude\`
- **Passwort:** \`$PASSWORD\`
- **IP:** \`${IP:-unbekannt}\`

**Einmalig** – $FIRST_STEPS" >/dev/null

cat <<EOF

======================================================
 claude-box ($TYPE) ist bereit
------------------------------------------------------
 ID:        $VMID
 IP:        ${IP:-unbekannt}
 Login:     claude / $PASSWORD
------------------------------------------------------
 Einmalig – $FIRST_STEPS
 Danach erscheint die Maschine in der Claude-App unter Code.
======================================================
EOF
