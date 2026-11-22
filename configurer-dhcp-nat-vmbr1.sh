#!/usr/bin/env bash
# Configure uniquement DHCP + NAT pour un bridge Proxmox déjà créé dans le GUI.
# Ce script NE crée PAS vmbr1 et NE modifie PAS /etc/network/interfaces.
#
# Prérequis dans Proxmox GUI:
#   Node -> System -> Network -> Create -> Linux Bridge
#   Name       : vmbr1
#   IPv4/CIDR  : 10.10.10.1/24
#   Gateway    : vide
#   Ports      : vide
#   Autostart  : oui
#
# Usage:
#   sudo ./configurer-dhcp-nat-vmbr1.sh

set -Eeuo pipefail

BRIDGE="${BRIDGE:-vmbr1}"
BRIDGE_IP="${BRIDGE_IP:-10.10.10.1}"
LAN_CIDR="${LAN_CIDR:-10.10.10.0/24}"
DHCP_START="${DHCP_START:-10.10.10.100}"
DHCP_END="${DHCP_END:-10.10.10.200}"
DHCP_NETMASK="${DHCP_NETMASK:-255.255.255.0}"
DNS1="${DNS1:-1.1.1.1}"
DNS2="${DNS2:-8.8.8.8}"

log() {
    printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    printf '\n[ERREUR] %s\n' "$*" >&2
    exit 1
}

[[ "$EUID" -eq 0 ]] || die "Lancez ce script avec sudo."

command -v ip >/dev/null || die "La commande ip est absente."
command -v iptables >/dev/null || die "iptables est absent."

# -----------------------------------------------------------------------------
# 1. Vérifier que vmbr1 a déjà été créé via l'interface Proxmox
# -----------------------------------------------------------------------------
log "Vérification du bridge ${BRIDGE}"

ip link show "$BRIDGE" >/dev/null 2>&1 ||
    die "${BRIDGE} n'existe pas. Créez-le d'abord dans Proxmox GUI."

ip -4 addr show "$BRIDGE" | grep -Fq "${BRIDGE_IP}/24" ||
    die "${BRIDGE} n'a pas l'adresse ${BRIDGE_IP}/24."

log "${BRIDGE} est prêt."

# -----------------------------------------------------------------------------
# 2. Installer dnsmasq-base si nécessaire, sans dépôt Enterprise
# -----------------------------------------------------------------------------
disable_enterprise_repo() {
    local f
    for f in \
        /etc/apt/sources.list.d/pve-enterprise.sources \
        /etc/apt/sources.list.d/pve-enterprise.list
    do
        if [[ -f "$f" ]] && grep -q 'enterprise\.proxmox\.com' "$f" 2>/dev/null; then
            log "Désactivation du dépôt Proxmox Enterprise : $f"
            mv "$f" "${f}.disabled"
        fi
    done
}

if ! command -v dnsmasq >/dev/null 2>&1; then
    log "Installation de dnsmasq-base"
    disable_enterprise_repo
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq-base
fi

# -----------------------------------------------------------------------------
# 3. DHCP uniquement sur vmbr1
# -----------------------------------------------------------------------------
log "Configuration DHCP : ${DHCP_START} -> ${DHCP_END}"

install -d -m 0755 /var/lib/misc

cat > "/etc/dnsmasq-${BRIDGE}.conf" <<EOF
port=0
interface=${BRIDGE}
bind-dynamic
dhcp-authoritative

dhcp-range=${DHCP_START},${DHCP_END},${DHCP_NETMASK},12h
dhcp-option=option:router,${BRIDGE_IP}
dhcp-option=option:dns-server,${DNS1},${DNS2}

dhcp-leasefile=/var/lib/misc/dnsmasq-${BRIDGE}.leases
pid-file=/run/dnsmasq-${BRIDGE}.pid
EOF

dnsmasq --test --conf-file="/etc/dnsmasq-${BRIDGE}.conf"

cat > "/etc/systemd/system/dnsmasq-${BRIDGE}.service" <<EOF
[Unit]
Description=DHCP dnsmasq pour ${BRIDGE}
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/bin/test -d /sys/class/net/${BRIDGE}
ExecStart=/usr/sbin/dnsmasq --no-daemon --conf-file=/etc/dnsmasq-${BRIDGE}.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Ne pas utiliser le service dnsmasq générique.
systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl enable --now "dnsmasq-${BRIDGE}.service"

systemctl is-active --quiet "dnsmasq-${BRIDGE}.service" ||
    die "Le service DHCP n'est pas actif."

log "DHCP actif."

# -----------------------------------------------------------------------------
# 4. Activer le routage IPv4
# -----------------------------------------------------------------------------
log "Activation du routage IPv4"

cat > /etc/sysctl.d/99-proxmox-vm-nat.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

sysctl -w net.ipv4.ip_forward=1 >/dev/null

# -----------------------------------------------------------------------------
# 5. NAT/MASQUERADE vers l'interface AWS
# -----------------------------------------------------------------------------
WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Impossible de détecter l'interface WAN."

log "Interface WAN détectée : ${WAN_IF}"
log "Configuration NAT : ${LAN_CIDR} -> ${WAN_IF}"

cat > /usr/local/sbin/proxmox-vm-nat.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE}"
LAN="${LAN_CIDR}"
WAN_IF="\$(ip -4 route show default | awk 'NR==1 {print \$5}')"

[[ -n "\$WAN_IF" ]] || exit 1

sysctl -w net.ipv4.ip_forward=1 >/dev/null

iptables -t nat -C POSTROUTING \
  -s "\$LAN" -o "\$WAN_IF" -j MASQUERADE 2>/dev/null ||
iptables -t nat -A POSTROUTING \
  -s "\$LAN" -o "\$WAN_IF" -j MASQUERADE

iptables -C FORWARD \
  -i "\$BRIDGE" -o "\$WAN_IF" -j ACCEPT 2>/dev/null ||
iptables -A FORWARD \
  -i "\$BRIDGE" -o "\$WAN_IF" -j ACCEPT

iptables -C FORWARD \
  -i "\$WAN_IF" -o "\$BRIDGE" \
  -m conntrack --ctstate RELATED,ESTABLISHED \
  -j ACCEPT 2>/dev/null ||
iptables -A FORWARD \
  -i "\$WAN_IF" -o "\$BRIDGE" \
  -m conntrack --ctstate RELATED,ESTABLISHED \
  -j ACCEPT
EOF

chmod 0750 /usr/local/sbin/proxmox-vm-nat.sh

cat > /etc/systemd/system/proxmox-vm-nat.service <<'EOF'
[Unit]
Description=NAT pour le réseau privé des VM Proxmox
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/proxmox-vm-nat.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now proxmox-vm-nat.service

systemctl is-active --quiet proxmox-vm-nat.service ||
    die "Le service NAT n'est pas actif."

# -----------------------------------------------------------------------------
# 6. Vérifications
# -----------------------------------------------------------------------------
echo
echo "================ RESULTAT ================"
ip -4 -br addr show "$BRIDGE"
echo
echo "DHCP : $(systemctl is-active dnsmasq-${BRIDGE}.service)"
echo "NAT  : $(systemctl is-active proxmox-vm-nat.service)"
echo "IP forwarding : $(sysctl -n net.ipv4.ip_forward)"
echo "WAN : ${WAN_IF}"
echo
echo "Règle NAT :"
iptables -t nat -S POSTROUTING | grep "$LAN_CIDR" || true
echo
echo "Pour une VM :"
echo "  Bridge   : ${BRIDGE}"
echo "  IPv4     : DHCP / automatique"
echo "  Adresse  : ${DHCP_START} -> ${DHCP_END}"
echo "  Gateway  : ${BRIDGE_IP}"
echo "=========================================="
