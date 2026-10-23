#!/usr/bin/env bash

# Copyright (c) 2026 waldonso2
# License: MIT | https://github.com/waldonso2/Proxmox-Claude-Desktop-Script-/raw/main/LICENSE
# Source: https://code.claude.com/docs/en/remote-control
#
# claude-box.sh – legt auf Proxmox VE eine VM für Claude Code an
# (Remote Control + Chrome-Integration + CLI-Toolchain).
#
# Ausführen auf dem Proxmox-Host als root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/waldonso2/Proxmox-Claude-Desktop-Script-/main/claude-box.sh)"
# Anpassen per Umgebungsvariablen, z. B.:
#   CORES=8 MEM=16384 DISK=128 BRIDGE=vmbr1 VLAN=50 bash claude-box.sh
set -euo pipefail

# ---------- Einstellungen ----------
VMID="${VMID:-$(pvesh get /cluster/nextid)}"
NAME="${NAME:-claude-box}"
CORES="${CORES:-4}"
MEM="${MEM:-8192}"               # MB
DISK="${DISK:-64}"               # GB
STORAGE="${STORAGE:-local-lvm}"  # VM-Disk + Cloud-Init-Drive
SNIPPETS="${SNIPPETS:-local}"    # Storage für Cloud-Init-Snippets
BRIDGE="${BRIDGE:-vmbr0}"
VLAN="${VLAN:-}"                 # leer = kein VLAN-Tag
# ISOLATE=1: eigenes NAT-Netz 10.99.0.0/24 – Internet ja, Heimnetz & Proxmox-Host nein.
# ISOLATE=0: VM hängt direkt an $BRIDGE (z. B. mit VLAN=50, falls dein Router VLANs kann).
ISOLATE="${ISOLATE:-1}"
ISO_BRIDGE="${ISO_BRIDGE:-vmbr9}"
NAMESERVER="${NAMESERVER:-1.1.1.1}"
SSH_KEYS_FILE="${SSH_KEYS_FILE:-/root/.ssh/authorized_keys}"
PASSWORD="${PASSWORD:-$(openssl rand -base64 12 | tr -d '/+=')}"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_DIR="/var/lib/vz/template/cloudimg"
IMG="$IMG_DIR/noble-server-cloudimg-amd64.img"

log() { echo -e "\e[1;34m[claude-box]\e[0m $*"; }
die() { echo -e "\e[1;31m[claude-box] FEHLER:\e[0m $*" >&2; exit 1; }

command -v qm >/dev/null || die "Muss auf einem Proxmox-VE-Host laufen."
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
qm status "$VMID" &>/dev/null && die "VMID $VMID existiert bereits."

# ---------- Cloud-Image holen ----------
mkdir -p "$IMG_DIR"
if [[ ! -f "$IMG" || -n "$(find "$IMG" -mtime +14 2>/dev/null)" ]]; then
  log "Lade Ubuntu 24.04 Cloud-Image …"
  wget -q --show-progress -O "$IMG.tmp" "$IMG_URL" && mv "$IMG.tmp" "$IMG"
fi

# ---------- Snippets-Storage aktivieren ----------
if ! pvesm status --content snippets 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$SNIPPETS"; then
  log "Aktiviere Inhaltstyp 'snippets' auf Storage '$SNIPPETS' …"
  CUR=$(pvesh get "/storage/$SNIPPETS" --output-format json | python3 -c 'import sys,json;print(json.load(sys.stdin)["content"])')
  pvesm set "$SNIPPETS" --content "$CUR,snippets"
fi
SNIPPET_NAME="${NAME}-${VMID}-user.yaml"
SNIPPET_PATH=$(pvesm path "$SNIPPETS:snippets/$SNIPPET_NAME")
mkdir -p "$(dirname "$SNIPPET_PATH")"

# ---------- SSH-Keys ----------
SSH_KEYS_YAML=""
if [[ -f "$SSH_KEYS_FILE" ]]; then
  while IFS= read -r k; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    SSH_KEYS_YAML+="      - \"${k//\"/\\\"}\""$'\n'
  done < "$SSH_KEYS_FILE"
fi
[[ -z "$SSH_KEYS_YAML" ]] && SSH_KEYS_YAML='      []'$'\n'

# ---------- Cloud-Init ----------
log "Schreibe Cloud-Init nach $SNIPPET_PATH"
cat > "$SNIPPET_PATH" <<'YAML'
#cloud-config
hostname: __NAME__
timezone: Europe/Berlin
locale: de_DE.UTF-8
keyboard:
  layout: de
users:
  - name: claude
    shell: /bin/bash
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    ssh_authorized_keys:
__SSHKEYS__
chpasswd:
  expire: false
  users:
    - {name: claude, password: "__PASSWORD__", type: text}
ssh_pwauth: true
package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - xfce4
  - xfce4-terminal
  - lightdm
  - lightdm-gtk-greeter
  - dbus-x11
  - fonts-noto
  - tmux
  - git
  - curl
  - wget
  - jq
  - ripgrep
  - unzip
  - htop
  - build-essential
  - python3
  - python3-pip
  - python3-venv
  - pipx
  - nodejs
  - npm
  - docker.io
  - docker-compose-v2
write_files:
  # Automatischer Login in XFCE, damit Chrome immer läuft
  - path: /etc/lightdm/lightdm.conf.d/50-autologin.conf
    content: |
      [Seat:*]
      autologin-user=claude
      autologin-session=xfce
  # "Claude in Chrome"-Erweiterung automatisch installieren
  - path: /etc/opt/chrome/policies/managed/claude.json
    content: |
      {
        "ExtensionInstallForcelist": ["fcoeoabgfenejglbffodgkkbkcdhcgfn"],
        "RestoreOnStartup": 1
      }
  # Startskript: Chrome + Claude Code Remote Control in tmux
  - path: /usr/local/bin/claude-box-start
    permissions: "0755"
    content: |
      #!/bin/bash
      export PATH="$HOME/.local/bin:$PATH"
      mkdir -p "$HOME/workspace"
      pgrep -u "$USER" -x chrome >/dev/null || google-chrome --no-first-run --no-default-browser-check &
      sleep 4
      if ! tmux has-session -t claude 2>/dev/null; then
        tmux new-session -d -s claude -c "$HOME/workspace" \
          'bash -lc "claude remote-control; echo; echo \"Remote Control beendet. Erstes Mal? Einfach: claude  → einloggen → /chrome (Enabled by default) → exit, dann: claude-box-start\"; exec bash"'
      fi
      pgrep -u "$USER" -f "tmux attach -t claude" >/dev/null || xfce4-terminal --maximize -e "tmux attach -t claude" &
  - path: /etc/xdg/autostart/claude-box.desktop
    content: |
      [Desktop Entry]
      Type=Application
      Name=Claude Box
      Exec=/usr/local/bin/claude-box-start
      X-GNOME-Autostart-enabled=true
runcmd:
  - systemctl enable --now qemu-guest-agent
  # Google Chrome
  - install -d -m 0755 /etc/apt/keyrings
  - curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
  - echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
  - apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable
  # Bildschirmsperre/Screensaver entfernen (sonst sperrt sich die Sitzung)
  - DEBIAN_FRONTEND=noninteractive apt-get purge -y light-locker xfce4-screensaver || true
  - usermod -aG docker claude
  # Claude Code (nativer Installer)
  - sudo -u claude -H bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  - sudo -u claude -H bash -c 'grep -q ".local/bin" ~/.bashrc || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'
  - sudo -u claude -H mkdir -p /home/claude/workspace
  - systemctl set-default graphical.target
  - systemctl start lightdm
YAML

sed -i "s|__NAME__|$NAME|; s|__PASSWORD__|$PASSWORD|" "$SNIPPET_PATH"
python3 - "$SNIPPET_PATH" "$SSH_KEYS_YAML" <<'PY'
import sys
p, keys = sys.argv[1], sys.argv[2].rstrip("\n")
s = open(p).read().replace("__SSHKEYS__", keys)
open(p, "w").write(s)
PY

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
      # VM darf keine privaten Netze erreichen (Heimnetz, Docker-Netze, Tailscale)
      for n in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
        echo "    post-up   iptables -I FORWARD -i $ISO_BRIDGE -d $n -j DROP"
        echo "    post-down iptables -D FORWARD -i $ISO_BRIDGE -d $n -j DROP"
      done
      # VM darf den Proxmox-Host nicht ansprechen (GUI :8006, SSH) – nur Antworten auf Host-Verbindungen
      echo "    post-up   iptables -I INPUT -i $ISO_BRIDGE -j DROP"
      echo "    post-up   iptables -I INPUT -i $ISO_BRIDGE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      echo "    post-down iptables -D INPUT -i $ISO_BRIDGE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"
      echo "    post-down iptables -D INPUT -i $ISO_BRIDGE -j DROP"
    } >> /etc/network/interfaces
    ifreload -a
  fi
  BRIDGE="$ISO_BRIDGE"; VLAN=""
  # shortcut: IP aus VMID abgeleitet, kollidiert erst bei >230 claude-boxen
  VM_IP="10.99.0.$(( VMID % 230 + 20 ))"
  IPCONFIG="ip=$VM_IP/24,gw=10.99.0.1"
fi

# ---------- VM anlegen ----------
NET="virtio,bridge=$BRIDGE"; [[ -n "$VLAN" ]] && NET+=",tag=$VLAN"
log "Erzeuge VM $VMID ($NAME): ${CORES} vCPU, ${MEM} MB RAM, ${DISK} GB Disk"
qm create "$VMID" --name "$NAME" --ostype l26 --machine q35 \
  --cores "$CORES" --cpu host --memory "$MEM" --balloon 0 \
  --scsihw virtio-scsi-single --net0 "$NET" \
  --agent enabled=1 --vga std --tags claude
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,ssd=1,iothread=1" >/dev/null
qm resize "$VMID" scsi0 "${DISK}G"
qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 \
  --ipconfig0 "$IPCONFIG" --nameserver "$NAMESERVER" --cicustom "user=$SNIPPETS:snippets/$SNIPPET_NAME" >/dev/null
qm start "$VMID"

# ---------- Warten bis Cloud-Init fertig ist ----------
log "VM bootet und installiert (dauert ca. 5–15 Min.) …"
for _ in $(seq 1 180); do qm agent "$VMID" ping &>/dev/null && break; sleep 10; done
DONE=0
for _ in $(seq 1 180); do
  if qm guest exec "$VMID" -- test -f /var/lib/cloud/instance/boot-finished 2>/dev/null | grep -q '"exitcode" : 0'; then
    DONE=1; break
  fi
  sleep 10
done
[[ $DONE -eq 1 ]] || log "Warnung: Cloud-Init nach 30 Min. nicht fertig – bitte Konsole prüfen."

IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | python3 -c '
import sys,json
for i in json.load(sys.stdin):
    if i.get("name")=="lo": continue
    for a in i.get("ip-addresses",[]):
        if a.get("ip-address-type")=="ipv4": print(a["ip-address"]); sys.exit()
' || true)

if [[ $DONE -eq 1 ]]; then
  qm snapshot "$VMID" clean-install --description "Frisch installiert, noch nicht eingeloggt" >/dev/null && \
    log "Snapshot 'clean-install' angelegt."
fi

cat <<EOF

======================================================
 claude-box ist bereit
------------------------------------------------------
 VMID:      $VMID
 IP:        ${IP:-unbekannt (siehe Proxmox-Übersicht)}
 Login:     claude / $PASSWORD
 SSH:       ssh claude@${IP:-<ip>}
            (isoliert: vom LAN über den Host: ssh -J root@<proxmox> claude@${IP:-<ip>})
------------------------------------------------------
 Einmalig in der Proxmox-Konsole der VM (Desktop):
  1. Im Terminal: claude   → mit deinem Claude-Konto einloggen
  2. /chrome → "Enabled by default", dann /exit
  3. In Chrome bei claude.ai einloggen (Erweiterung ist schon da)
  4. Im Terminal: claude remote-control   (oder VM neu starten)
  5. Danach: qm snapshot $VMID logged-in
 Dann erscheint die Maschine in der Claude-App unter Code.
======================================================
EOF
