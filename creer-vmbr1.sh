#!/usr/bin/env bash
# Crée vmbr1 exactement comme dans l'interface Proxmox :
#   Nœud -> Système -> Réseau -> Créer -> Linux Bridge
#   Nom             : vmbr1
#   IPv4/CIDR       : 10.10.10.1/24
#   Passerelle      : vide
#   Ports du pont   : vide
#   Démarrage auto  : coché
#   Gère les VLAN   : non
#   Commentaire     : Private VM Network
# puis clique sur « Appliquer la configuration ».
#
# Ordre d'utilisation :
#   1) install-proxmox-aws-complet-v3.sh
#   2) creer-vmbr1.sh            <- ce script
#   3) configurer-dhcp-nat-vmbr1.sh
#
# Usage : sudo bash creer-vmbr1.sh

set -Eeuo pipefail

BRIDGE="${BRIDGE:-vmbr1}"
CIDR="${CIDR:-10.10.10.1/24}"
COMMENT="${COMMENT:-Private VM Network}"

log()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n[AVERTISSEMENT] %s\n' "$*" >&2; }
die()  { printf '\n[ERREUR] %s\n' "$*" >&2; exit 1; }

bridge_ok() {
    ip -4 addr show "$BRIDGE" 2>/dev/null | grep -Fq "$CIDR"
}

[[ "$EUID" -eq 0 ]] || die "Lancez ce script avec sudo."
command -v pvesh >/dev/null || die "pvesh est absent : Proxmox VE n'est pas installé."

NODE="$(hostname -s)"
[[ -d "/etc/pve/nodes/${NODE}" ]] \
    || die "Le nœud ${NODE} est introuvable dans /etc/pve. Proxmox est-il démarré ?"

# -----------------------------------------------------------------------------
# 1. « Créer -> Linux Bridge » (ou « Éditer » s'il existe déjà)
# -----------------------------------------------------------------------------
log "Création de ${BRIDGE} (${CIDR}) sur le nœud ${NODE}"

# Équivalent de « Revenir en arrière » : annule des changements restés en attente.
pvesh delete "/nodes/${NODE}/network" >/dev/null 2>&1 || true

ARGS=(--type bridge --cidr "$CIDR" --autostart 1 --comments "$COMMENT")

if pvesh get "/nodes/${NODE}/network/${BRIDGE}" >/dev/null 2>&1; then
    log "${BRIDGE} existe déjà : mise à jour (comme « Éditer »)."
    pvesh set "/nodes/${NODE}/network/${BRIDGE}" "${ARGS[@]}"
else
    pvesh create "/nodes/${NODE}/network" --iface "$BRIDGE" "${ARGS[@]}"
fi

# -----------------------------------------------------------------------------
# 2. « Appliquer la configuration »
# -----------------------------------------------------------------------------
log "Application de la configuration"
pvesh set "/nodes/${NODE}/network" || true
sleep 3

# -----------------------------------------------------------------------------
# 3. Secours si l'application a échoué (ifreload -a peut échouer sur AWS
#    à cause de l'interface principale gérée par cloud-init/systemd-networkd)
# -----------------------------------------------------------------------------
if ! bridge_ok; then
    warn "L'application globale a échoué : activation de ${BRIDGE} seul."

    if [[ -f /etc/network/interfaces.new ]]; then
        cp -a /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
        mv /etc/network/interfaces.new /etc/network/interfaces
    fi

    ifup "$BRIDGE" 2>&1 || ifup --force "$BRIDGE" 2>&1 || true
fi

if ! bridge_ok; then
    warn "ifup a échoué : création directe de ${BRIDGE} (valable jusqu'au prochain redémarrage)."
    ip link show "$BRIDGE" >/dev/null 2>&1 || ip link add name "$BRIDGE" type bridge
    ip addr replace "$CIDR" dev "$BRIDGE"
    ip link set "$BRIDGE" up
fi

bridge_ok || die "${BRIDGE} n'a pas pu être activé avec l'adresse ${CIDR}."

# Recrée le bridge au démarrage si ifupdown2 n'y arrive pas.
cat > "/etc/systemd/system/${BRIDGE}-up.service" <<EOF
[Unit]
Description=Garantit que ${BRIDGE} existe avec ${CIDR}
After=network.target networking.service
Before=dnsmasq-${BRIDGE}.service proxmox-vm-nat.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'ip link show ${BRIDGE} >/dev/null 2>&1 || ip link add name ${BRIDGE} type bridge; ip addr replace ${CIDR} dev ${BRIDGE}; ip link set ${BRIDGE} up'

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${BRIDGE}-up.service" >/dev/null 2>&1

# -----------------------------------------------------------------------------
# 4. Résultat
# -----------------------------------------------------------------------------
echo
echo "================ RESULTAT ================"
ip -br addr show "$BRIDGE"
echo
echo "${BRIDGE} est prêt. Lancez maintenant :"
echo "  sudo ./configurer-dhcp-nat-vmbr1.sh"
echo "=========================================="
