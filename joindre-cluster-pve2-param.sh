#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./joindre-cluster-pve2-param.sh <IP_PVE1> <IP_PVE2>
#
# Exemple:
#   sudo ./joindre-cluster-pve2-param.sh 172.31.0.55 172.31.12.194
#
# Prérequis:
# - vmbr1 déjà créé dans l'interface Proxmox
# - PVE1 a déjà créé le cluster
# - PVE1 et PVE2 peuvent communiquer via leurs IP privées AWS
# - Le cluster doit utiliser les IP privées AWS, jamais 10.10.10.1

die() {
    echo "ERREUR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: sudo $0 <IP_PVE1> <IP_PVE2>"
    echo "Exemple: sudo $0 172.31.0.55 172.31.12.194"
    exit 1
}

[[ $# -eq 2 ]] || usage
[[ $EUID -eq 0 ]] || die "Exécutez ce script avec sudo."

PVE1_IP="$1"
PVE2_IP="$2"

PVE1_NAME="pve1"
PVE1_FQDN="pve1.lab.local"
PVE2_NAME="pve2"
PVE2_FQDN="pve2.lab.local"

valid_ipv4() {
    local ip="$1" IFS=.
    local -a octets
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( o >= 0 && o <= 255 )) || return 1
    done
}

valid_ipv4 "$PVE1_IP" || die "IP PVE1 invalide: $PVE1_IP"
valid_ipv4 "$PVE2_IP" || die "IP PVE2 invalide: $PVE2_IP"
[[ "$PVE1_IP" != "$PVE2_IP" ]] || die "Les deux IP doivent être différentes."

echo "============================================================"
echo " PVE2 - Jonction au cluster"
echo "============================================================"
echo "PVE1 : $PVE1_IP"
echo "PVE2 : $PVE2_IP"
echo

echo "=== 1. Vérification de l'IP privée de cette machine ==="
WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Impossible de déterminer l'interface par défaut."

ACTUAL_IP="$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
echo "Interface : $WAN_IF"
echo "Détectée  : $ACTUAL_IP"
echo "Attendue  : $PVE2_IP"

[[ "$ACTUAL_IP" == "$PVE2_IP" ]] || \
    die "Vous n'êtes pas sur PVE2 ou l'IP passée en paramètre est incorrecte."

echo
echo "=== 2. Vérification de vmbr1 ==="
ip link show vmbr1 >/dev/null 2>&1 || \
    die "vmbr1 n'existe pas. Créez-le d'abord dans l'interface Proxmox."
ip -4 -br addr show vmbr1 || true

echo
echo "=== 3. PVE2 doit être autonome avant la jonction ==="
if [[ -f /etc/pve/corosync.conf ]]; then
    echo "Une configuration Corosync existe déjà:"
    grep -nE 'name:|ring0_addr:|cluster_name:|config_version:' /etc/pve/corosync.conf || true
    die "PVE2 est déjà membre d'un cluster. Nettoyez-le avant de continuer."
fi

echo
echo "=== 4. Configuration hostname / hosts ==="
hostnamectl set-hostname "$PVE2_NAME"
echo "$PVE2_NAME" > /etc/hostname

mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-proxmox-hostname.cfg <<'EOF'
preserve_hostname: true
manage_etc_hosts: false
EOF

cp -a /etc/hosts "/etc/hosts.backup.$(date +%Y%m%d-%H%M%S)"
cat > /etc/hosts <<EOF
127.0.0.1 localhost

$PVE1_IP  $PVE1_FQDN $PVE1_NAME
$PVE2_IP  $PVE2_FQDN $PVE2_NAME
EOF

# Empêche d'anciens scripts AWS de remettre le hostname pve1.
systemctl disable --now proxmox-aws-complet.service 2>/dev/null || true
systemctl disable --now proxmox-aws-installer.service 2>/dev/null || true

if [[ -f /etc/default/proxmox-aws-complet ]]; then
    sed -i 's/^PVE_FQDN=.*/PVE_FQDN=pve2.lab.local/' /etc/default/proxmox-aws-complet || true
fi

echo
echo "=== 5. Redémarrage pmxcfs après renommage ==="
systemctl restart pve-cluster
sleep 3

pvecm updatecerts --force || true
systemctl restart pvedaemon pveproxy pvestatd

echo
echo "=== 6. Vérification identité / résolution ==="
echo "hostname -s: $(hostname -s)"
echo "hostname -f: $(hostname -f)"
echo

getent ahostsv4 pve1 | head -n3
getent ahostsv4 pve2 | head -n3

[[ "$(hostname -s)" == "pve2" ]] || die "Le hostname local n'est pas pve2."

R1="$(getent ahostsv4 pve1 | awk 'NR==1 {print $1}')"
R2="$(getent ahostsv4 pve2 | awk 'NR==1 {print $1}')"
[[ "$R1" == "$PVE1_IP" ]] || die "pve1 ne résout pas vers $PVE1_IP."
[[ "$R2" == "$PVE2_IP" ]] || die "pve2 ne résout pas vers $PVE2_IP."

echo
echo "=== 7. Test réseau vers PVE1 ==="
ping -c 3 -W 2 "$PVE1_IP" || \
    die "PVE1 n'est pas joignable. Vérifiez VPC / subnet / Security Group AWS."

echo
echo "=== 8. Jonction au cluster ==="
echo "Le mot de passe ROOT de PVE1 sera demandé."
echo
echo "Commande:"
echo "  pvecm add $PVE1_IP --link0 $PVE2_IP"
echo

pvecm add "$PVE1_IP" --link0 "$PVE2_IP"

sleep 5

echo
echo "=== 9. Vérification finale ==="
pvecm nodes
echo
pvecm status
echo
grep -nE 'name:|ring0_addr:|cluster_name:|config_version:' /etc/pve/corosync.conf

echo
echo "============================================================"
echo "PVE2 terminé."
echo "Link 0 PVE1 = $PVE1_IP"
echo "Link 0 PVE2 = $PVE2_IP"
echo "10.10.10.1 reste uniquement l'adresse de vmbr1."
echo "============================================================"
