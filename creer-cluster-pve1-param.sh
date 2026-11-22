#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./creer-cluster-pve1-param.sh <IP_PVE1> <IP_PVE2> [NOM_CLUSTER]
#
# Exemple:
#   sudo ./creer-cluster-pve1-param.sh 172.31.0.55 172.31.12.194
#   sudo ./creer-cluster-pve1-param.sh 172.31.0.55 172.31.12.194 cluster-tp
#
# Prérequis:
# - vmbr1 déjà créé dans l'interface Proxmox
# - PVE1 et PVE2 peuvent communiquer via leurs IP privées AWS
# - Le cluster doit utiliser les IP privées AWS, jamais 10.10.10.1

die() {
    echo "ERREUR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: sudo $0 <IP_PVE1> <IP_PVE2> [NOM_CLUSTER]"
    echo "Exemple: sudo $0 172.31.0.55 172.31.12.194 cluster-tp"
    exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage
[[ $EUID -eq 0 ]] || die "Exécutez ce script avec sudo."

PVE1_IP="$1"
PVE2_IP="$2"
CLUSTER_NAME="${3:-cluster-tp}"

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
echo " PVE1 - Création du cluster"
echo "============================================================"
echo "PVE1          : $PVE1_IP"
echo "PVE2          : $PVE2_IP"
echo "Nom du cluster: $CLUSTER_NAME"
echo

echo "=== 1. Vérification de l'IP privée de cette machine ==="
WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Impossible de déterminer l'interface par défaut."

ACTUAL_IP="$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
echo "Interface : $WAN_IF"
echo "Détectée  : $ACTUAL_IP"
echo "Attendue  : $PVE1_IP"

[[ "$ACTUAL_IP" == "$PVE1_IP" ]] || \
    die "Vous n'êtes pas sur PVE1 ou l'IP passée en paramètre est incorrecte."

echo
echo "=== 2. Vérification de vmbr1 ==="
ip link show vmbr1 >/dev/null 2>&1 || \
    die "vmbr1 n'existe pas. Créez-le d'abord dans l'interface Proxmox."
ip -4 -br addr show vmbr1 || true

echo
echo "=== 3. Configuration hostname / hosts ==="
hostnamectl set-hostname "$PVE1_NAME"
echo "$PVE1_NAME" > /etc/hostname

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

echo
echo "=== 4. Vérification de la résolution ==="
echo "pve1:"
getent ahostsv4 pve1 | head -n3
echo "pve2:"
getent ahostsv4 pve2 | head -n3

R1="$(getent ahostsv4 pve1 | awk 'NR==1 {print $1}')"
R2="$(getent ahostsv4 pve2 | awk 'NR==1 {print $1}')"
[[ "$R1" == "$PVE1_IP" ]] || die "pve1 ne résout pas vers $PVE1_IP."
[[ "$R2" == "$PVE2_IP" ]] || die "pve2 ne résout pas vers $PVE2_IP."

echo
echo "=== 5. Vérification d'un cluster existant ==="
if [[ -f /etc/pve/corosync.conf ]]; then
    echo "Un cluster existe déjà:"
    grep -nE 'name:|ring0_addr:|cluster_name:|config_version:' /etc/pve/corosync.conf || true
    die "Le script n'écrase pas une configuration Corosync existante."
fi

echo
echo "=== 6. Création du cluster ==="
pvecm create "$CLUSTER_NAME" --link0 "$PVE1_IP"

sleep 3

echo
echo "=== 7. Vérification ==="
pvecm nodes
echo
pvecm status
echo
grep -nE 'name:|ring0_addr:|cluster_name:|config_version:' /etc/pve/corosync.conf

echo
echo "============================================================"
echo "PVE1 terminé."
echo "Link 0 PVE1 = $PVE1_IP"
echo "Exécutez maintenant le script PVE2 avec les mêmes IP."
echo "============================================================"
