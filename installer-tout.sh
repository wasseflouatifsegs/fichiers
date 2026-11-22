#!/usr/bin/env bash
# Enchaîne automatiquement les trois scripts d'installation de Proxmox sur AWS :
#   1) install-proxmox-aws-complet-v3.sh   (redémarre la machine au milieu)
#   2) creer-vmbr1.sh                      (remplace la manipulation dans l'interface)
#   3) configurer-dhcp-nat-vmbr1.sh
#
# Le redémarrage est géré : un service systemd reprend les étapes 2 et 3
# une fois la phase 2 du premier script terminée.
#
# Les trois scripts doivent être dans le même dossier que celui-ci
# (par exemple /root/fichiers). S'il en manque un, il est téléchargé
# depuis le dépôt GitHub.
#
# Usage : sudo bash installer-tout.sh          # demande le nom (défaut : pve1)
#         sudo bash installer-tout.sh pve2     # nom donné directement
# Suivi après le redémarrage : journalctl -fu proxmox-installer-tout
#                             ou tail -f /var/log/proxmox-installer-tout.log

set -Eeuo pipefail

SCRIPT1="install-proxmox-aws-complet-v3.sh"
SCRIPT2="creer-vmbr1.sh"
SCRIPT3="configurer-dhcp-nat-vmbr1.sh"
REPO_RAW="https://raw.githubusercontent.com/wasseflouatifsegs/fichiers/main"

WORK_DIR="/usr/local/lib/proxmox-installer-tout"
SELF="${WORK_DIR}/installer-tout.sh"
STATE_DIR="/var/lib/proxmox-installer-tout"
SUITE_PENDING="${STATE_DIR}/suite.pending"
DONE_FILE="${STATE_DIR}/complete"
LOG_FILE="/var/log/proxmox-installer-tout.log"
SERVICE="proxmox-installer-tout"
SERVICE_FILE="/etc/systemd/system/${SERVICE}.service"

# Fichiers d'état du premier script
S1_STATE_DIR="/var/lib/proxmox-aws-complet"
S1_SERVICE="proxmox-aws-complet.service"

# Paramètres transmis au premier script
export AUTO_REBOOT="yes"
export REQUIRE_KVM="${REQUIRE_KVM:-no}"     # pas bloquant sans virtualisation imbriquée
PVE_DOMAIN="${PVE_DOMAIN:-lab.local}"
DEFAULT_NODE_NAME="pve1"

mkdir -p "$STATE_DIR" "$WORK_DIR"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '\n[%s] === %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n[AVERTISSEMENT] %s\n' "$*" >&2; }
die()  { printf '\n[ERREUR] %s\n' "$*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Lancez ce script avec sudo."

# -----------------------------------------------------------------------------
# Préparation : copie des trois scripts dans un dossier fixe
# -----------------------------------------------------------------------------
prepare_scripts() {
    local src_dir f
    src_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

    for f in "$SCRIPT1" "$SCRIPT2" "$SCRIPT3"; do
        if [[ -f "${src_dir}/${f}" ]]; then
            [[ "${src_dir}/${f}" -ef "${WORK_DIR}/${f}" ]] || cp "${src_dir}/${f}" "${WORK_DIR}/${f}"
        elif [[ ! -f "${WORK_DIR}/${f}" ]]; then
            log "Téléchargement de ${f} depuis GitHub"
            wget -qO "${WORK_DIR}/${f}" "${REPO_RAW}/${f}" \
                || die "${f} est introuvable dans ${src_dir} et sur GitHub."
        fi
        # Supprime d'éventuelles fins de ligne Windows.
        sed -i 's/\r$//' "${WORK_DIR}/${f}"
        chmod 0750 "${WORK_DIR}/${f}"
    done

    [[ "$(readlink -f "$0")" == "$SELF" ]] || install -m 0750 "$0" "$SELF"
    sed -i 's/\r$//' "$SELF"
}

install_suite_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Suite de l'installation Proxmox (vmbr1, DHCP, NAT)
Wants=network-online.target
After=network-online.target ${S1_SERVICE}
ConditionPathExists=${SUITE_PENDING}

[Service]
Type=oneshot
TimeoutStartSec=0
ExecStart=${SELF} --suite
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$SERVICE" >/dev/null 2>&1
}

remove_suite_service() {
    rm -f "$SUITE_PENDING"
    systemctl disable "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
}

# -----------------------------------------------------------------------------
# Nom du nœud : à fixer AVANT d'installer Proxmox. Le changer après crée
# un nœud fantôme et casse les certificats (erreur 596 dans l'interface).
# -----------------------------------------------------------------------------
choose_node_name() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "Nom du nœud Proxmox [${DEFAULT_NODE_NAME}] : " name
        fi
        name="${name:-$DEFAULT_NODE_NAME}"
    fi

    [[ "$name" =~ ^[a-z][a-z0-9-]{0,62}$ ]] \
        || die "Nom invalide : « ${name} » (minuscules, chiffres et tirets, ex. pve1)."

    if command -v pvesh >/dev/null && [[ "$(hostname -s)" != "$name" ]]; then
        die "Proxmox est déjà installé sous le nom « $(hostname -s) ». Le renommer casserait le nœud : installez sur une instance neuve."
    fi

    export PVE_FQDN="${name}.${PVE_DOMAIN}"
    log "Nom du nœud : ${name} (${PVE_FQDN})"

    # Fixe le nom tout de suite et empêche cloud-init de remettre
    # le nom AWS (ip-172-...) au redémarrage.
    hostnamectl set-hostname "$name"
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        printf 'preserve_hostname: true\nmanage_etc_hosts: false\n' \
            > /etc/cloud/cloud.cfg.d/99-proxmox-hostname.cfg
    fi
}

# -----------------------------------------------------------------------------
# Étape 1 : installation de Proxmox (avec redémarrage)
# -----------------------------------------------------------------------------
start() {
    if [[ -e "$DONE_FILE" ]]; then
        log "Installation déjà terminée. Pour recommencer : rm -rf ${STATE_DIR}"
        exit 0
    fi

    choose_node_name "${1:-}"
    prepare_scripts
    touch "$SUITE_PENDING"
    install_suite_service

    log "Étape 1/3 : ${SCRIPT1}"
    local rc=0
    bash "${WORK_DIR}/${SCRIPT1}" || rc=$?

    # Si le premier script a lancé le redémarrage, on s'arrête ici :
    # le service reprendra les étapes 2 et 3 après le démarrage.
    if [[ -e "${S1_STATE_DIR}/stage2.pending" && "$(uname -r)" != *-pve* ]]; then
        log "Redémarrage en cours. La suite reprendra automatiquement."
        log "Après reconnexion : journalctl -fu ${SERVICE}"
        exit 0
    fi

    [[ $rc -eq 0 ]] || warn "${SCRIPT1} s'est terminé avec le code ${rc}."
    suite
}

# Quand le premier script s'arrête en erreur, sa phase 2 reste programmée
# et se relancerait à chaque redémarrage en réécrivant le réseau.
# On la marque donc comme terminée.
close_script1() {
    rm -f "${S1_STATE_DIR}/stage2.pending"
    touch "${S1_STATE_DIR}/complete"
    systemctl disable "$S1_SERVICE" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${S1_SERVICE}"
    systemctl daemon-reload
}

# -----------------------------------------------------------------------------
# Étapes 2 et 3 : vmbr1 puis DHCP/NAT
# -----------------------------------------------------------------------------
suite() {
    log "Attente de la fin de la phase 2 de ${SCRIPT1}"
    while systemctl is-active --quiet "$S1_SERVICE" \
       || [[ "$(systemctl is-active "$S1_SERVICE" 2>/dev/null)" == "activating" ]]; do
        sleep 10
    done

    if [[ -e "${S1_STATE_DIR}/complete" ]]; then
        log "Étape 1/3 terminée avec succès."
    elif grep -q "n'est pas visible dans Proxmox" /var/log/proxmox-aws-complet.log 2>/dev/null \
         && command -v pvesh >/dev/null; then
        # Cas habituel : le premier script s'arrête sur
        #   [ERREUR] vmbr1 fonctionne sous Linux mais n'est pas visible dans Proxmox
        # C'est le moment où la manipulation réseau était faite à la main :
        # l'étape 2 (creer-vmbr1.sh) la fait maintenant automatiquement.
        log "Erreur attendue de ${SCRIPT1} (vmbr1 non visible dans Proxmox) : manipulation réseau automatique."
        close_script1
    elif command -v pvesh >/dev/null && [[ "$(uname -r)" == *-pve* ]]; then
        # Proxmox est installé ; seule sa partie réseau a pu échouer,
        # ce que les étapes 2 et 3 refont.
        warn "${SCRIPT1} n'a pas fini sa partie réseau, mais Proxmox est installé : on continue."
        close_script1
    else
        die "Proxmox n'est pas installé. Consultez /var/log/proxmox-aws-complet.log"
    fi

    # Laisse le temps à pve-cluster de monter /etc/pve après le démarrage.
    local i
    for i in {1..30}; do
        [[ -d "/etc/pve/nodes/$(hostname -s)" ]] && break
        sleep 2
    done

    log "Étape 2/3 : ${SCRIPT2}"
    bash "${WORK_DIR}/${SCRIPT2}" || die "${SCRIPT2} a échoué."

    log "Étape 3/3 : ${SCRIPT3}"
    bash "${WORK_DIR}/${SCRIPT3}" || die "${SCRIPT3} a échoué."

    remove_suite_service
    touch "$DONE_FILE"

    log "Installation complète terminée."
    [[ -f /root/PROXMOX-AWS-COMPLET.txt ]] && cat /root/PROXMOX-AWS-COMPLET.txt || true
}

case "${1:-}" in
    --suite)   suite ;;
    -h|--help) echo "Usage : sudo bash $0 [nom_du_noeud]   (défaut : ${DEFAULT_NODE_NAME})" ;;
    *)         start "${1:-}" ;;
esac
