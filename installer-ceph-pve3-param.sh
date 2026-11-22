#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Installation Ceph + MON + MGR sur PVE3
#
# Usage:
#   sudo ./installer-ceph-pve3-param.sh <IP_PVE1> <IP_PVE3> <PUBLIC_NETWORK_CIDR> [CLUSTER_NETWORK_CIDR]
#
# Exemple:
#   sudo ./installer-ceph-pve3-param.sh 172.31.0.55 <IP_PVE3> 172.31.0.0/20 172.31.0.0/20
#
# Si CLUSTER_NETWORK_CIDR est omis, il prend la même valeur
# que PUBLIC_NETWORK_CIDR.
#
# Prérequis:
# - Le cluster Ceph a DEJA été initialisé sur pve1.
# - mon.pve1 fonctionne déjà.
# - pve3 est déjà membre du cluster Proxmox.
# - /etc/pve/ceph.conf est visible sur pve3.
#
# Le script:
# 1. vérifie hostname et IP locale
# 2. installe Ceph si nécessaire
# 3. vérifie /etc/pve/ceph.conf
# 4. force les réseaux globaux Ceph
# 5. vérifie l'accès au MON pve1
# 6. crée mon.pve3
# 7. force l'adresse du MON pve3
# 8. crée mgr.pve3
# ============================================================

die() {
    echo "ERREUR: $*" >&2
    exit 1
}

usage() {
    echo "Usage:"
    echo "  sudo $0 <IP_PVE1> <IP_PVE3> <PUBLIC_NETWORK_CIDR> [CLUSTER_NETWORK_CIDR]"
    echo
    echo "Exemple:"
    echo "  sudo $0 172.31.0.55 172.31.12.194 172.31.0.0/20 172.31.0.0/20"
    exit 1
}

[[ $# -ge 3 && $# -le 4 ]] || usage
[[ $EUID -eq 0 ]] || die "Exécutez ce script avec sudo."

PVE1_IP="$1"
LOCAL_IP="$2"
PUBLIC_NETWORK="$3"
CLUSTER_NETWORK="${4:-$PUBLIC_NETWORK}"

NODE_NAME="pve3"
NODE_FQDN="pve3.lab.local"
CEPH_CONF="/etc/pve/ceph.conf"

echo "============================================================"
echo " Installation Ceph - PVE3"
echo "============================================================"
echo "PVE1 IP         : $PVE1_IP"
echo "PVE3 IP         : $LOCAL_IP"
echo "Public network  : $PUBLIC_NETWORK"
echo "Cluster network : $CLUSTER_NETWORK"
echo

command -v python3 >/dev/null 2>&1 || die "python3 est requis."

python3 - "$PVE1_IP" "$LOCAL_IP" "$PUBLIC_NETWORK" "$CLUSTER_NETWORK" <<'PY'
import ipaddress, sys
pve1 = ipaddress.ip_address(sys.argv[1])
local = ipaddress.ip_address(sys.argv[2])
public = ipaddress.ip_network(sys.argv[3], strict=False)
cluster = ipaddress.ip_network(sys.argv[4], strict=False)

for ip, label in [(pve1, "PVE1"), (local, "LOCAL")]:
    if ip.version != 4:
        raise SystemExit(f"ERREUR: {label} doit être IPv4.")
    if ip not in public:
        raise SystemExit(f"ERREUR: {label} {ip} n'appartient pas au public_network {public}.")

if cluster.version != 4:
    raise SystemExit("ERREUR: cluster_network doit être IPv4.")

print("Validation IP/CIDR OK")
PY

echo
echo "=== 1. Vérification du noeud ==="

CURRENT_NODE="$(hostname -s)"
[[ "$CURRENT_NODE" == "$NODE_NAME" ]] ||     die "Ce script doit être exécuté sur $NODE_NAME. hostname -s retourne '$CURRENT_NODE'."

WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
[[ -n "$WAN_IF" ]] || die "Impossible de déterminer l'interface réseau par défaut."

ACTUAL_IP="$(
    ip -4 -o addr show dev "$WAN_IF" |
    awk '{print $4}' |
    cut -d/ -f1 |
    head -n1
)"

echo "Noeud         : $CURRENT_NODE"
echo "Interface AWS : $WAN_IF"
echo "IP détectée   : $ACTUAL_IP"
echo "IP attendue   : $LOCAL_IP"

[[ "$ACTUAL_IP" == "$LOCAL_IP" ]] ||     die "L'IP locale ($ACTUAL_IP) ne correspond pas à l'IP passée ($LOCAL_IP)."

echo
echo "=== 2. Vérification de la résolution locale ==="

LOCAL_RESOLVED="$(getent ahostsv4 "$NODE_NAME" | awk 'NR==1 {print $1}' || true)"
PVE1_RESOLVED="$(getent ahostsv4 pve1 | awk 'NR==1 {print $1}' || true)"

echo "pve1  -> $PVE1_RESOLVED"
echo "$NODE_NAME -> $LOCAL_RESOLVED"

[[ "$PVE1_RESOLVED" == "$PVE1_IP" ]] ||     die "pve1 ne résout pas vers $PVE1_IP. Corrigez /etc/hosts avant de continuer."

[[ "$LOCAL_RESOLVED" == "$LOCAL_IP" ]] ||     die "$NODE_NAME ne résout pas vers $LOCAL_IP. Corrigez /etc/hosts avant de continuer."

echo
echo "=== 3. Installation Ceph ==="

if command -v ceph >/dev/null 2>&1; then
    echo "Ceph est déjà installé:"
    ceph --version
else
    pveceph install
    ceph --version
fi

echo
echo "=== 4. Vérification de la configuration Ceph partagée ==="

[[ -f "$CEPH_CONF" ]] ||     die "$CEPH_CONF absent. Initialisez d'abord Ceph sur pve1."

echo "Configuration Ceph détectée:"
grep -nE 'fsid|cluster_network|mon_host|public_network|public_addr' "$CEPH_CONF" || true

echo
echo "=== 5. Mise à jour des réseaux Ceph ==="

cp -a "$CEPH_CONF" "/root/ceph.conf.before-pve3.$(date +%Y%m%d-%H%M%S)"

python3 - "$CEPH_CONF" "$PVE1_IP" "$LOCAL_IP" "$PUBLIC_NETWORK" "$CLUSTER_NETWORK" "$NODE_NAME" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
pve1_ip = sys.argv[2]
local_ip = sys.argv[3]
public_net = sys.argv[4]
cluster_net = sys.argv[5]
node = sys.argv[6]

lines = path.read_text().splitlines()

def set_key(lines, section, key, value):
    header = f"[{section}]"
    start = None
    end = len(lines)

    for i, line in enumerate(lines):
        if line.strip() == header:
            start = i
            break

    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines.append(header)
        lines.append(f"    {key} = {value}")
        return lines

    for i in range(start + 1, len(lines)):
        s = lines[i].strip()
        if s.startswith("[") and s.endswith("]"):
            end = i
            break

    for i in range(start + 1, end):
        s = lines[i].strip()
        if "=" in s and s.split("=", 1)[0].strip() == key:
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())] or "    "
            lines[i] = f"{indent}{key} = {value}"
            return lines

    lines.insert(start + 1, f"    {key} = {value}")
    return lines

lines = set_key(lines, "global", "cluster_network", cluster_net)
lines = set_key(lines, "global", "mon_host", pve1_ip)
lines = set_key(lines, "global", "public_network", public_net)
lines = set_key(lines, f"mon.{node}", "public_addr", local_ip)

path.write_text("\n".join(lines) + "\n")
PY

echo
echo "Paramètres réseau Ceph:"
grep -nE 'cluster_network|mon_host|public_network|public_addr' "$CEPH_CONF"

echo
echo "=== 6. Test du MON pve1 ==="

if timeout 12 ceph -m "$PVE1_IP:3300" -s >/dev/null 2>&1; then
    echo "Connexion au MON pve1 OK."
else
    die "Impossible de joindre/authentifier le cluster Ceph via $PVE1_IP:3300."
fi

echo
echo "=== 7. Création du MON $NODE_NAME ==="

if systemctl is-active --quiet "ceph-mon@${NODE_NAME}.service"; then
    echo "ceph-mon@${NODE_NAME} est déjà actif."
else
    pveceph mon create
fi

sleep 5

echo
echo "=== 8. Correction explicite de l'adresse MON ==="

ceph mon set-addrs "$NODE_NAME"     "[v2:${LOCAL_IP}:3300/0,v1:${LOCAL_IP}:6789/0]"

systemctl restart "ceph-mon@${NODE_NAME}"
sleep 5

systemctl is-active --quiet "ceph-mon@${NODE_NAME}.service" ||     die "ceph-mon@${NODE_NAME} n'est pas actif."

echo
echo "=== 9. Création du MGR $NODE_NAME ==="

if systemctl is-active --quiet "ceph-mgr@${NODE_NAME}.service"; then
    echo "ceph-mgr@${NODE_NAME} est déjà actif."
else
    pveceph mgr create
fi

sleep 5

echo
echo "============================================================"
echo " Vérification finale"
echo "============================================================"

echo
echo "--- Ports MON locaux ---"
ss -lntp | grep -E ':(3300|6789)\b' || true

echo
echo "--- Monmap ---"
ceph mon dump | grep -E "mon\.pve1|mon\.${NODE_NAME}|epoch|fsid" || true

echo
echo "--- MGR ---"
ceph mgr dump | grep -E 'active_name|standbys' || true

echo
echo "--- Ceph status ---"
ceph -s

echo
echo "Attendu:"
echo "  cluster_network = $CLUSTER_NETWORK"
echo "  mon_host        = $PVE1_IP"
echo "  public_network  = $PUBLIC_NETWORK"
echo "  public_addr $NODE_NAME = $LOCAL_IP"
echo "  MON $NODE_NAME = $LOCAL_IP:3300 / $LOCAL_IP:6789"
echo "  MGR $NODE_NAME = actif ou standby"
echo "============================================================"
