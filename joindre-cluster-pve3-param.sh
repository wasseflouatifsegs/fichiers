#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo ./joindre-cluster-pve3-param.sh <IP_PVE1> <IP_PVE2> <IP_PVE3>
#
# Exemple:
#   sudo ./joindre-cluster-pve3-param.sh 172.31.0.55 172.31.12.194 172.31.8.100

die() {
    echo "ERREUR: $*" >&2
    exit 1
}

usage() {
    echo "Usage: sudo $0 <IP_PVE1> <IP_PVE2> <IP_PVE3>"
    echo "Exemple: sudo $0 172.31.0.55 172.31.12.194 172.31.8.100"
    exit 1
}

[[ $# -eq 3 ]] || usage
[[ $EUID -eq 0 ]] || die "Exécutez ce script avec sudo."

PVE1_IP="$1"
PVE2_IP="$2"
PVE3_IP="$3"

PVE1_NAME="pve1"
PVE1_FQDN="pve1.lab.local"
PVE2_NAME="pve2"
PVE2_FQDN="pve2.lab.local"
PVE3_NAME="pve3"
PVE3_FQDN="pve3.lab.local"

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
valid_ipv4 "$PVE3_IP" || die "IP PVE3 invalide: $PVE3_IP"

[[ "$PVE1_IP" != "$PVE2_IP" ]] || die "PVE1 et PVE2 ont la même IP."
[[ "$PVE1_IP" != "$PVE3_IP" ]] || die "PVE1 et PVE3 ont la même IP."
[[ "$PVE2_IP" != "$PVE3_IP" ]] || die "PVE2 et PVE3 ont la même IP."

echo "============================================================"
echo " PVE3 - Jonction au cluster Proxmox"
echo "============================================================"
echo "PVE1 : $PVE1_IP"
echo "PVE2 : $PVE2_IP"
echo "PVE3 : $PVE3_IP"
echo

echo "=== 1. Vérification de l'IP privée locale ==="
WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Impossible de déterminer l'interface réseau par défaut."

ACTUAL_IP="$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
echo "Interface AWS : $WAN_IF"
echo "IP détectée   : $ACTUAL_IP"
echo "IP attendue   : $PVE3_IP"

[[ "$ACTUAL_IP" == "$PVE3_IP" ]] || die "Cette machine n'a pas l'IP PVE3 attendue ($PVE3_IP)."

echo
echo "=== 2. Vérification de vmbr1 ==="
ip link show vmbr1 >/dev/null 2>&1 || die "vmbr1 n'existe pas. Créez-le d'abord dans l'interface Proxmox."
ip -4 -br addr show vmbr1 || true

echo
echo "=== 3. Vérification : PVE3 doit être autonome ==="
if [[ -f /etc/pve/corosync.conf ]]; then
    echo "Une configuration Corosync existe déjà sur PVE3 :"
    grep -nE 'name:|ring0_addr:|cluster_name:|config_version:' /etc/pve/corosync.conf || true
    die "Ce nœud est déjà membre d'un cluster."
fi

echo
echo "=== 4. Configuration hostname / /etc/hosts ==="
hostnamectl set-hostname "$PVE3_NAME"
echo "$PVE3_NAME" > /etc/hostname

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
$PVE3_IP  $PVE3_FQDN $PVE3_NAME
EOF

systemctl disable --now proxmox-aws-complet.service 2>/dev/null || true
systemctl disable --now proxmox-aws-installer.service 2>/dev/null || true

if [[ -f /etc/default/proxmox-aws-complet ]]; then
    sed -i 's/^PVE_FQDN=.*/PVE_FQDN=pve3.lab.local/' /etc/default/proxmox-aws-complet || true
fi

echo
echo "=== 5. Redémarrage des services Proxmox ==="
systemctl restart pve-cluster
sleep 3
pvecm updatecerts --force || true
systemctl restart pvedaemon pveproxy pvestatd

echo
echo "=== 6. Vérification identité / résolution ==="
echo "hostname -s : $(hostname -s)"
echo "hostname -f : $(hostname -f)"
echo

getent ahostsv4 "$PVE1_NAME" | head -n3
getent ahostsv4 "$PVE2_NAME" | head -n3
getent ahostsv4 "$PVE3_NAME" | head -n3

[[ "$(hostname -s)" == "$PVE3_NAME" ]] || die "Le hostname local n'est pas pve3."

R1="$(getent ahostsv4 "$PVE1_NAME" | awk 'NR==1 {print $1}')"
R2="$(getent ahostsv4 "$PVE2_NAME" | awk 'NR==1 {print $1}')"
R3="$(getent ahostsv4 "$PVE3_NAME" | awk 'NR==1 {print $1}')"

[[ "$R1" == "$PVE1_IP" ]] || die "pve1 ne résout pas vers $PVE1_IP."
[[ "$R2" == "$PVE2_IP" ]] || die "pve2 ne résout pas vers $PVE2_IP."
[[ "$R3" == "$PVE3_IP" ]] || die "pve3 ne résout pas vers $PVE3_IP."

echo
echo "=== 7. Tests réseau ==="
ping -c 2 -W 2 "$PVE1_IP" || die "PVE1 ($PVE1_IP) n'est pas joignable."
ping -c 2 -W 2 "$PVE2_IP" || echo "ATTENTION: PVE2 ($PVE2_IP) ne répond pas au ping."

echo
echo "=== 8. Jonction au cluster ==="
echo "Le mot de passe ROOT de PVE1 sera demandé."
echo "Commande : pvecm add $PVE1_IP --link0 $PVE3_IP"
echo

pvecm add "$PVE1_IP" --link0 "$PVE3_IP"

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
echo "PVE3 ajouté au cluster."
echo "Attendu :"
echo "  pve1 Link 0 = $PVE1_IP"
echo "  pve2 Link 0 = $PVE2_IP"
echo "  pve3 Link 0 = $PVE3_IP"
echo "10.10.10.1 reste uniquement l'adresse de vmbr1."
echo "============================================================"
