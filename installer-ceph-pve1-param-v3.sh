#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PVE1 - Installation Ceph Tentacle + INIT + premier MON
#
# Usage:
#   sudo ./installer-ceph-pve1-param-v3.sh \
#       <IP_PVE1> <PUBLIC_NETWORK_CIDR> [CLUSTER_NETWORK_CIDR]
#
# Exemple:
#   sudo ./installer-ceph-pve1-param-v3.sh \
#       172.31.88.51 172.31.80.0/20
#
# IMPORTANT:
# - Ne définit PAS mon_host avant le premier MON.
# - Ne crée PAS manuellement [mon.pve1] avant le premier MON.
# - Force l'adresse du premier MON avec:
#       pveceph mon create --mon-address <IP_PVE1>
# - Le premier MON crée automatiquement un MGR avec Proxmox VE.
# ============================================================

die() { echo "ERREUR: $*" >&2; exit 1; }

usage() {
    echo "Usage: sudo $0 <IP_PVE1> <PUBLIC_NETWORK_CIDR> [CLUSTER_NETWORK_CIDR]"
    echo "Exemple: sudo $0 172.31.88.51 172.31.80.0/20"
    exit 1
}

[[ $# -ge 2 && $# -le 3 ]] || usage
[[ $EUID -eq 0 ]] || die "Exécutez avec sudo."

PVE1_IP="$1"
PUBLIC_NETWORK="$2"
CLUSTER_NETWORK="${3:-$PUBLIC_NETWORK}"
CEPH_CONF="/etc/pve/ceph.conf"

[[ "$(hostname -s)" == "pve1" ]] || \
    die "Ce script doit être exécuté sur pve1 (hostname actuel: $(hostname -s))."

python3 - "$PVE1_IP" "$PUBLIC_NETWORK" "$CLUSTER_NETWORK" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
pub = ipaddress.ip_network(sys.argv[2], strict=False)
clu = ipaddress.ip_network(sys.argv[3], strict=False)
if ip.version != 4 or pub.version != 4 or clu.version != 4:
    raise SystemExit("ERREUR: IPv4 uniquement.")
if ip not in pub:
    raise SystemExit(f"ERREUR: {ip} n'appartient pas à {pub}.")
print("Validation IP/CIDR: OK")
PY

WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
LOCAL_IP="$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1)"

echo "Interface AWS : $WAN_IF"
echo "IP détectée   : $LOCAL_IP"
echo "IP attendue   : $PVE1_IP"

[[ "$LOCAL_IP" == "$PVE1_IP" ]] || \
    die "IP locale $LOCAL_IP != IP PVE1 passée en paramètre $PVE1_IP."

echo
echo "=== Résolution pve1 ==="
PVE1_RESOLVED="$(getent ahostsv4 pve1 | awk 'NR==1 {print $1}' || true)"
echo "pve1 -> $PVE1_RESOLVED"

if [[ "$PVE1_RESOLVED" != "$PVE1_IP" ]]; then
    echo "Correction de /etc/hosts..."
    cp -a /etc/hosts "/etc/hosts.before-ceph.$(date +%Y%m%d-%H%M%S)"
    TMP="$(mktemp)"
    awk '
    {
        drop=0
        for (i=2; i<=NF; i++) {
            if ($i=="pve1" || $i=="pve1.lab.local") drop=1
        }
        if (!drop) print
    }' /etc/hosts > "$TMP"
    printf "\n%s  pve1.lab.local pve1\n" "$PVE1_IP" >> "$TMP"
    cat "$TMP" > /etc/hosts
    rm -f "$TMP"
fi

[[ "$(getent ahostsv4 pve1 | awk 'NR==1 {print $1}')" == "$PVE1_IP" ]] || \
    die "pve1 ne résout pas vers $PVE1_IP."

echo
echo "=== Vérification état Ceph existant ==="
if [[ -f "$CEPH_CONF" ]]; then
    echo "Une configuration Ceph existe déjà."
    echo "Utilisez le script de reprise, pas ce script de première installation."
    exit 3
fi

echo
echo "=== Installation Ceph Tentacle ==="
pveceph install --version tentacle --repository no-subscription

CEPH_VER="$(ceph --version 2>/dev/null || true)"
echo "$CEPH_VER"
grep -qE 'ceph version 20\.' <<< "$CEPH_VER" || \
    die "Ceph actif n'est pas en 20.x Tentacle."

echo
echo "=== Initialisation Ceph ==="
pveceph init \
    --network "$PUBLIC_NETWORK" \
    --cluster-network "$CLUSTER_NETWORK"

[[ -f "$CEPH_CONF" ]] || die "$CEPH_CONF absent après init."

echo
echo "=== Vérification config AVANT premier MON ==="
grep -nE 'fsid|cluster_network|public_network|mon_host|public_addr' "$CEPH_CONF" || true

# Sécurité: mon_host ne doit pas être préconfiguré avant le bootstrap du premier MON.
if grep -Eq '^[[:space:]]*mon_host[[:space:]]*=' "$CEPH_CONF"; then
    die "mon_host existe déjà avant le premier MON; arrêt pour éviter le bootstrap incorrect."
fi

echo
echo "=== Création du premier MON sur $PVE1_IP ==="
timeout 120 pveceph mon create --mon-address "$PVE1_IP"

sleep 5

echo
echo "=== Vérification du MON ==="
systemctl is-active --quiet ceph-mon@pve1 || \
    die "ceph-mon@pve1 n'est pas actif."

echo
echo "=== Vérification du MGR ==="
# Le premier MON auto-crée normalement le MGR.
if ! systemctl is-active --quiet ceph-mgr@pve1; then
    echo "MGR non actif après création du premier MON, création explicite..."
    timeout 90 pveceph mgr create
fi

sleep 5

echo
echo "=== Résultat ==="
ceph --version
echo
ceph -s
echo
echo "--- config ---"
grep -nE 'fsid|cluster_network|public_network|mon_host|public_addr' "$CEPH_CONF" || true
echo
echo "--- monmap ---"
ceph mon dump | grep -E 'mon\.pve1|epoch|fsid' || true
echo
echo "--- ports MON ---"
ss -lntp | grep -E ':(3300|6789)\b' || true

echo
echo "============================================================"
echo "Terminé."
echo "MON pve1 attendu sur $PVE1_IP:3300 et $PVE1_IP:6789."
echo "============================================================"
