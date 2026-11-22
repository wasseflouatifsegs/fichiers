#!/usr/bin/env bash
# Installation automatisée de Proxmox VE 9 sur une instance AWS Debian 13.
#
# Fonctionnement :
#   Phase 1 : vérifications, dépôt Proxmox, noyau PVE, puis redémarrage.
#   Phase 2 : reprise automatique par systemd, installation de Proxmox,
#             configuration complète de vmbr1, DHCP et NAT.
#
# Réseau VM par défaut :
#   vmbr1      : 10.10.10.1/24
#   DHCP       : 10.10.10.100 -> 10.10.10.200
#   DNS        : 1.1.1.1, 8.8.8.8
#
# IMPORTANT :
# - L'instance EC2 doit prendre en charge la virtualisation imbriquée.
# - L'option "Nested virtualization" doit être activée AVANT l'exécution.
# - Le script ne modifie pas l'interface réseau AWS principale.
# - Prévu pour un laboratoire/TP, pas pour une production Proxmox sur AWS.
# - Compatible avec une AMI Debian Cloud démarrée en Legacy BIOS ou en UEFI.
# - Conserve grub-cloud-amd64 et empêche APT de le remplacer par grub-pc.

set -Eeuo pipefail
umask 027

INSTALLER_VERSION="2.2-complet"
STATE_DIR="/var/lib/proxmox-aws-complet"
STATE_STAGE2="${STATE_DIR}/stage2.pending"
STATE_COMPLETE="${STATE_DIR}/complete"
LOG_FILE="/var/log/proxmox-aws-complet.log"
INSTALL_PATH="/usr/local/sbin/install-proxmox-aws-complet.sh"
CONFIG_FILE="/etc/default/proxmox-aws-complet"
SERVICE_FILE="/etc/systemd/system/proxmox-aws-complet.service"
SUMMARY_FILE="/root/PROXMOX-AWS-COMPLET.txt"
PVE_REPO_FILE="/etc/apt/sources.list.d/pve-no-subscription.sources"

mkdir -p "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; trap - ERR; echo "[ERREUR] Ligne ${LINENO}: code ${rc}. Consultez ${LOG_FILE}." >&2; exit ${rc}' ERR

log()  { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\n[AVERTISSEMENT] %s\n' "$*" >&2; }
die()  { printf '\n[ERREUR] %s\n' "$*" >&2; exit 1; }

# Charge les paramètres persistés lors de la reprise après redémarrage.
if [[ -r "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

PVE_FQDN="${PVE_FQDN:-pve1.lab.local}"
PVE_BRIDGE="${PVE_BRIDGE:-vmbr1}"
PVE_LAN_ADDRESS="${PVE_LAN_ADDRESS:-10.10.10.1/24}"
PVE_LAN_NETWORK="${PVE_LAN_NETWORK:-10.10.10.0/24}"
DHCP_START="${DHCP_START:-10.10.10.100}"
DHCP_END="${DHCP_END:-10.10.10.200}"
DHCP_NETMASK="${DHCP_NETMASK:-255.255.255.0}"
DHCP_DNS1="${DHCP_DNS1:-1.1.1.1}"
DHCP_DNS2="${DHCP_DNS2:-8.8.8.8}"
AUTO_REBOOT="${AUTO_REBOOT:-yes}"
REQUIRE_KVM="${REQUIRE_KVM:-yes}"
PVE_ROOT_PASSWORD="${PVE_ROOT_PASSWORD:-root}"

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Exécutez ce script avec sudo : sudo bash $0"
}

validate_settings() {
    [[ "$PVE_FQDN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "PVE_FQDN invalide : $PVE_FQDN"
    [[ "$PVE_FQDN" == *.* ]] \
        || die "PVE_FQDN doit être un nom complet, par exemple pve1.lab.local."
    [[ "$PVE_BRIDGE" =~ ^vmbr[0-9]{1,4}$ ]] \
        || die "PVE_BRIDGE doit ressembler à vmbr1."
    [[ "$PVE_LAN_ADDRESS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
        || die "PVE_LAN_ADDRESS invalide : $PVE_LAN_ADDRESS"
    [[ "$PVE_LAN_NETWORK" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
        || die "PVE_LAN_NETWORK invalide : $PVE_LAN_NETWORK"
    [[ "$AUTO_REBOOT" =~ ^(yes|no)$ ]] \
        || die "AUTO_REBOOT doit valoir yes ou no."
    [[ "$REQUIRE_KVM" =~ ^(yes|no)$ ]] \
        || die "REQUIRE_KVM doit valoir yes ou no."
}

check_os() {
    [[ "$(uname -m)" == "x86_64" ]] \
        || die "Ce script nécessite une instance EC2 x86_64, pas $(uname -m)."

    [[ -r /etc/os-release ]] || die "/etc/os-release est introuvable."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "13" ]] \
        || die "Système requis : Debian 13. Détecté : ${PRETTY_NAME:-inconnu}."
}

get_wan_interface() {
    ip -4 route show default | awk 'NR == 1 {print $5}'
}

get_private_ip() {
    local wan_if="$1"
    ip -4 -o address show dev "$wan_if" scope global \
        | awk 'NR == 1 {split($4, a, "/"); print a[1]}'
}

check_kvm() {
    log "Vérification de la virtualisation imbriquée"

    if ! grep -Eq '\b(vmx|svm)\b' /proc/cpuinfo; then
        if [[ "$REQUIRE_KVM" == "yes" ]]; then
            die "Les extensions vmx/svm ne sont pas visibles. Activez Nested virtualization dans AWS et utilisez une famille EC2 compatible."
        fi
        warn "vmx/svm absent : Proxmox sera installé, mais les VM KVM ne fonctionneront pas correctement."
        return 0
    fi

    modprobe kvm || true
    if grep -q '\bvmx\b' /proc/cpuinfo; then
        modprobe kvm_intel || true
    elif grep -q '\bsvm\b' /proc/cpuinfo; then
        modprobe kvm_amd || true
    fi

    if [[ ! -e /dev/kvm ]]; then
        if [[ "$REQUIRE_KVM" == "yes" ]]; then
            die "/dev/kvm est absent malgré vmx/svm. Vérifiez le type d'instance et l'option Nested virtualization."
        fi
        warn "/dev/kvm est absent."
        return 0
    fi

    log "KVM est disponible : $(ls -l /dev/kvm)"
}

configure_hostname() {
    local wan_if private_ip short_name
    wan_if="$(get_wan_interface)"
    [[ -n "$wan_if" ]] || die "Impossible de détecter l'interface AWS par défaut."

    private_ip="$(get_private_ip "$wan_if")"
    [[ -n "$private_ip" ]] || die "Impossible de détecter l'adresse IPv4 privée AWS."

    short_name="${PVE_FQDN%%.*}"
    log "Configuration du nom : ${PVE_FQDN} -> ${private_ip}"
    hostnamectl set-hostname "$PVE_FQDN"

    cp -a /etc/hosts "/etc/hosts.before-proxmox-aws.$(date +%s)"
    sed -i '/# BEGIN PROXMOX-AWS-COMPLET/,/# END PROXMOX-AWS-COMPLET/d' /etc/hosts
    cat >> /etc/hosts <<HOSTS

# BEGIN PROXMOX-AWS-COMPLET
${private_ip} ${PVE_FQDN} ${short_name}
# END PROXMOX-AWS-COMPLET
HOSTS

    getent hosts "$PVE_FQDN" >/dev/null \
        || die "Le FQDN ${PVE_FQDN} ne peut pas être résolu localement."
}

set_root_password() {
    local pw1 pw2 root_status

    if [[ -n "${PVE_ROOT_PASSWORD:-}" ]]; then
        printf 'root:%s\n' "$PVE_ROOT_PASSWORD" | chpasswd
        unset PVE_ROOT_PASSWORD
        log "Mot de passe root configuré depuis PVE_ROOT_PASSWORD."
        return 0
    fi

    root_status="$(passwd -S root 2>/dev/null | awk '{print $2}' || true)"
    if [[ "$root_status" == "P" ]]; then
        log "Le compte root possède déjà un mot de passe ; il est conservé."
        return 0
    fi

    [[ -t 0 ]] || die "Le compte root est verrouillé. Relancez en mode interactif ou fournissez PVE_ROOT_PASSWORD."

    while true; do
        read -r -s -p "Nouveau mot de passe pour root@pam : " pw1
        printf '\n'
        read -r -s -p "Confirmez le mot de passe : " pw2
        printf '\n'
        [[ -n "$pw1" ]] || { warn "Le mot de passe ne peut pas être vide."; continue; }
        [[ "$pw1" == "$pw2" ]] || { warn "Les mots de passe ne correspondent pas."; continue; }
        break
    done

    printf 'root:%s\n' "$pw1" | chpasswd
    unset pw1 pw2
    log "Mot de passe root configuré."
}


boot_mode() {
    if [[ -d /sys/firmware/efi ]]; then
        printf 'uefi'
    else
        printf 'bios'
    fi
}

package_installed_or_pending() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -qE '^(ii|i.|.i)'
}

repair_cloud_bootloader() {
    local mode
    mode="$(boot_mode)"
    export DEBIAN_FRONTEND=noninteractive

    log "Mode de démarrage détecté : ${mode^^}"

    # Les AMI Debian Cloud utilisent grub-cloud-amd64. Ce paquet est conçu
    # pour les images cloud et contient la configuration pour PC/BIOS et EFI.
    # Il ne faut pas le remplacer par grub-pc ou grub-efi-amd64.
    if ! package_installed_or_pending grub-cloud-amd64; then
        die "grub-cloud-amd64 est absent. Ce script attend une AMI Debian Cloud officielle."
    fi

    if [[ -f /etc/default/grub ]]; then
        cp -a /etc/default/grub "/etc/default/grub.before-proxmox-aws.$(date +%s)"
    fi

    if package_installed_or_pending grub-pc; then
        warn "grub-pc a été sélectionné par APT ; purge du méta-paquet tout en conservant grub-pc-bin."
        dpkg --purge --force-all grub-pc 2>/dev/null \
            || dpkg --remove --force-remove-reinstreq grub-pc 2>/dev/null \
            || true
    fi

    if package_installed_or_pending grub-efi-amd64; then
        warn "grub-efi-amd64 est présent ; purge du méta-paquet et conservation de grub-cloud-amd64."
        dpkg --purge --force-all grub-efi-amd64 2>/dev/null \
            || dpkg --remove --force-remove-reinstreq grub-efi-amd64 2>/dev/null \
            || true
    fi

    # Répare la transaction interrompue et restaure explicitement la
    # configuration du chargeur cloud, sans réinstaller grub-pc recommandé.
    apt-get \
        -o APT::Install-Recommends=false \
        -o Dpkg::Options::=--force-confnew \
        -f install --reinstall -y grub-cloud-amd64

    dpkg --force-confold --configure -a

    apt-get \
        -o APT::Install-Recommends=false \
        -o Dpkg::Options::=--force-confold \
        -f install -y

    apt-mark manual grub-cloud-amd64 >/dev/null 2>&1 || true
    update-grub

    if [[ "$mode" == "uefi" ]]; then
        findmnt /boot/efi >/dev/null 2>&1 \
            || warn "UEFI détecté, mais /boot/efi n'est pas monté. Vérifiez l'AMI avant tout redémarrage."
    fi
}

disable_enterprise_repositories() {
    local f changed=0

    # Proxmox peut recréer le dépôt Enterprise lors de l'installation
    # de certains paquets. Sans abonnement il provoque un 401.
    for f in \
        /etc/apt/sources.list.d/pve-enterprise.sources \
        /etc/apt/sources.list.d/pve-enterprise.list \
        /etc/apt/sources.list.d/ceph.sources \
        /etc/apt/sources.list.d/ceph.list
    do
        if [[ -f "$f" ]] && grep -q 'enterprise\.proxmox\.com' "$f" 2>/dev/null; then
            log "Désactivation du dépôt Enterprise : $f"
            mv "$f" "${f}.disabled"
            changed=1
        fi
    done

    # Cas où une ligne Enterprise aurait été ajoutée dans sources.list
    # ou dans un autre fichier .list/.sources.
    while IFS= read -r -d '' f; do
        case "$f" in
            "$PVE_REPO_FILE") continue ;;
        esac

        if grep -q 'enterprise\.proxmox\.com' "$f" 2>/dev/null; then
            log "Neutralisation des lignes Enterprise dans : $f"

            if [[ "$f" == *.list ]]; then
                sed -i '/enterprise\.proxmox\.com/s/^[[:space:]]*deb/# disabled-no-subscription: deb/' "$f"
            elif [[ "$f" == *.sources ]]; then
                # Les fichiers deb822 .sources ne se commentent pas ligne à ligne
                # de manière fiable. On les renomme donc entièrement.
                mv "$f" "${f}.disabled"
            fi
            changed=1
        fi
    done < <(
        find /etc/apt \
            -maxdepth 2 \
            -type f \
            \( -name '*.list' -o -name '*.sources' \) \
            -print0 2>/dev/null
    )

    if (( changed )); then
        log "Dépôts Proxmox Enterprise désactivés (mode sans abonnement)."
    fi
}

apt_update_retry() {
    local attempt
    for attempt in {1..12}; do
        disable_enterprise_repositories
        if apt-get update; then
            return 0
        fi
        warn "apt-get update a échoué, tentative ${attempt}/12."
        sleep 10
    done
    die "Impossible de mettre à jour les dépôts APT."
}

configure_proxmox_repository() {
    log "Ajout du dépôt officiel Proxmox VE 9 pour Debian 13"
    install -d -m 0755 /usr/share/keyrings
    wget -qO /usr/share/keyrings/proxmox-archive-keyring-trixie.gpg \
        https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
    chmod 0644 /usr/share/keyrings/proxmox-archive-keyring-trixie.gpg

    cat > "$PVE_REPO_FILE" <<'REPO'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring-trixie.gpg
REPO
    chmod 0644 "$PVE_REPO_FILE"
}

save_configuration() {
    cat > "$CONFIG_FILE" <<CONFIG
PVE_FQDN=${PVE_FQDN}
PVE_BRIDGE=${PVE_BRIDGE}
PVE_LAN_ADDRESS=${PVE_LAN_ADDRESS}
PVE_LAN_NETWORK=${PVE_LAN_NETWORK}
DHCP_START=${DHCP_START}
DHCP_END=${DHCP_END}
DHCP_NETMASK=${DHCP_NETMASK}
DHCP_DNS1=${DHCP_DNS1}
DHCP_DNS2=${DHCP_DNS2}
AUTO_REBOOT=${AUTO_REBOOT}
REQUIRE_KVM=${REQUIRE_KVM}
CONFIG
    chmod 0600 "$CONFIG_FILE"
}

install_resume_service() {
    [[ -f "$0" ]] || die "Téléchargez le script dans un fichier avant de l'exécuter."
    install -m 0750 "$0" "$INSTALL_PATH"

    cat > "$SERVICE_FILE" <<SERVICE
[Unit]
Description=Suite de l'installation complète Proxmox VE sur AWS
Wants=network-online.target
After=network-online.target
ConditionPathExists=${STATE_STAGE2}

[Service]
Type=oneshot
EnvironmentFile=-${CONFIG_FILE}
ExecStart=${INSTALL_PATH} --stage2
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable proxmox-aws-complet.service
}

phase1() {
    require_root
    validate_settings
    check_os

    if [[ -e "$STATE_COMPLETE" ]]; then
        log "Installation déjà terminée. Consultez ${SUMMARY_FILE}."
        exit 0
    fi

    check_kvm
    configure_hostname
    disable_enterprise_repositories
    set_root_password
    save_configuration

    export DEBIAN_FRONTEND=noninteractive
    log "Mise à jour de Debian et installation des prérequis"
    apt_update_retry

    # Sur une première exécution propre, le dépôt PVE n'existe pas encore :
    # on met alors Debian à jour avant de l'ajouter. En reprise après échec,
    # le dépôt peut déjà exister ; on évite un full-upgrade prématuré de PVE.
    if [[ ! -e "$PVE_REPO_FILE" ]]; then
        apt-get -o Dpkg::Options::=--force-confold -y full-upgrade
    else
        warn "Dépôt Proxmox déjà présent : reprise détectée, full-upgrade initial ignoré."
    fi

    apt-get -o Dpkg::Options::=--force-confold install -y \
        wget curl ca-certificates gnupg openssh-server sudo

    configure_proxmox_repository
    apt_update_retry
    repair_cloud_bootloader

    log "Installation du noyau Proxmox sans remplacer le chargeur cloud AWS"
    apt-get \
        -o APT::Install-Recommends=false \
        -o Dpkg::Options::=--force-confold \
        install -y proxmox-default-kernel
    update-grub

    touch "$STATE_STAGE2"
    install_resume_service

    log "Phase 1 terminée. Un redémarrage est nécessaire pour charger le noyau Proxmox."
    if [[ "$AUTO_REBOOT" == "yes" ]]; then
        log "Redémarrage automatique maintenant. La phase 2 reprendra via systemd."
        sync
        systemctl reboot
    else
        printf '\nRedémarrez manuellement avec : sudo reboot\n'
        printf 'La phase 2 démarrera automatiquement au prochain démarrage.\n'
    fi
}

preseed_postfix() {
    echo "postfix postfix/mailname string ${PVE_FQDN}" | debconf-set-selections
    echo "postfix postfix/main_mailer_type select Local only" | debconf-set-selections

    # Évite les questions interactives d'iptables-persistent.
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
}

install_proxmox_packages() {
    export DEBIAN_FRONTEND=noninteractive
    preseed_postfix
    disable_enterprise_repositories
    apt_update_retry
    repair_cloud_bootloader

    log "Installation de Proxmox VE et des outils réseau"
    apt-get \
        -o APT::Install-Recommends=false \
        -o Dpkg::Options::=--force-confold \
        install -y \
        proxmox-ve \
        postfix \
        open-iscsi \
        chrony \
        ifupdown2 \
        iptables-persistent

    systemctl enable --now pveproxy pvedaemon pvestatd chrony

    # L'installation de Proxmox peut recréer pve-enterprise.sources.
    # On le désactive immédiatement avant toute étape réseau / apt suivante.
    disable_enterprise_repositories
}

configure_vm_network() {
    local main_interfaces="/etc/network/interfaces"
    local interfaces_d="/etc/network/interfaces.d"
    local backup_dir="/root/proxmox-network-backup-$(date +%Y%m%d-%H%M%S)"
    local bridge_ip="${PVE_LAN_ADDRESS%%/*}"
    local node wan_if tmp disabled_dir dup_count

    node="$(hostname -s)"
    wan_if="$(get_wan_interface)"
    [[ -n "$wan_if" ]] || die "Impossible de détecter l'interface WAN AWS."

    log "Configuration complète du réseau privé ${PVE_BRIDGE}"

    mkdir -p "$backup_dir"
    touch "$main_interfaces"
    cp -a "$main_interfaces" "$backup_dir/interfaces"
    if [[ -d "$interfaces_d" ]]; then
        cp -a "$interfaces_d" "$backup_dir/interfaces.d"
    fi

    install -d -m 0755 "$interfaces_d"
    disabled_dir="${backup_dir}/disabled-interfaces.d"
    mkdir -p "$disabled_dir"

    while IFS= read -r -d '' f; do
        if grep -Eq "^[[:space:]]*iface[[:space:]]+${PVE_BRIDGE}([[:space:]]|$)" "$f" ||
           [[ "$(basename "$f")" == "${PVE_BRIDGE}.disabled."* ]]; then
            log "Déplacement de l'ancienne définition : $f"
            mv "$f" "$disabled_dir/$(basename "$f").$(date +%s)"
        fi
    done < <(find "$interfaces_d" -maxdepth 1 -type f -print0)

    cp -a "$main_interfaces" "${main_interfaces}.before-vmbr1.$(date +%s)"
    sed -i "/# BEGIN PRIVATE-BRIDGE-${PVE_BRIDGE}/,/# END PRIVATE-BRIDGE-${PVE_BRIDGE}/d" \
        "$main_interfaces"

    if grep -Eq "^[[:space:]]*iface[[:space:]]+${PVE_BRIDGE}([[:space:]]|$)" \
       "$main_interfaces"; then
        die "Une ancienne définition non gérée de ${PVE_BRIDGE} existe déjà dans ${main_interfaces}. Sauvegarde : ${backup_dir}"
    fi

    cat >> "$main_interfaces" <<BRIDGE

# BEGIN PRIVATE-BRIDGE-${PVE_BRIDGE}
auto ${PVE_BRIDGE}
iface ${PVE_BRIDGE} inet static
    address ${PVE_LAN_ADDRESS}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
# END PRIVATE-BRIDGE-${PVE_BRIDGE}
BRIDGE

    tmp="$(mktemp)"
    awk '
        /^[[:space:]]*(source|source-directory)[[:space:]]+/ { next }
        { print }
    ' "$main_interfaces" > "$tmp"

    cat >> "$tmp" <<'SRC'

source /etc/network/interfaces.d/*
SRC

    install -o root -g root -m 0644 "$tmp" "$main_interfaces"
    rm -f "$tmp"

    # grep retourne 1 lorsqu'aucune définition n'est trouvée.
    # Avec "set -o pipefail", cela ne doit PAS être traité comme une erreur :
    # zéro occurrence est précisément le résultat attendu ici.
    dup_count="$(
        { grep -RhsE "^[[:space:]]*iface[[:space:]]+${PVE_BRIDGE}([[:space:]]|$)" \
            "$interfaces_d" 2>/dev/null || true; } | wc -l
    )"
    [[ "$dup_count" -eq 0 ]] ||
        die "Une définition de ${PVE_BRIDGE} subsiste dans ${interfaces_d}."

    log "Aucune définition concurrente de ${PVE_BRIDGE} dans ${interfaces_d}."

    ifquery "$PVE_BRIDGE" >/dev/null ||
        die "${PVE_BRIDGE} n'est pas reconnu par ifupdown2."

    if ! ip link show "$PVE_BRIDGE" >/dev/null 2>&1; then
        ifup "$PVE_BRIDGE"
    elif ! ip -4 addr show "$PVE_BRIDGE" | grep -Fq "${bridge_ip}/24"; then
        ifup --force "$PVE_BRIDGE"
    fi

    ip link show "$PVE_BRIDGE" >/dev/null ||
        die "${PVE_BRIDGE} n'existe pas côté Linux."
    ip -4 addr show "$PVE_BRIDGE" | grep -Fq "${bridge_ip}/24" ||
        die "${PVE_BRIDGE} n'a pas l'adresse ${PVE_LAN_ADDRESS}."

    systemctl restart pvedaemon
    systemctl restart pveproxy
    sleep 2

    if pvesh get "/nodes/${node}/network" --output-format json 2>/dev/null |
       grep -q "\"iface\":\"${PVE_BRIDGE}\""; then
        log "${PVE_BRIDGE} est visible dans l'API Proxmox."
    else
        echo
        echo "===== /etc/network/interfaces ====="
        cat "$main_interfaces"
        echo
        echo "===== pvesh network ====="
        pvesh get "/nodes/${node}/network" || true
        die "${PVE_BRIDGE} fonctionne sous Linux mais n'est pas visible dans Proxmox. Sauvegarde : ${backup_dir}"
    fi

    log "Configuration DHCP ${DHCP_START} -> ${DHCP_END}"

    if ! command -v dnsmasq >/dev/null 2>&1; then
        apt_update_retry
        DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq-base
    fi

    install -d -m 0755 /var/lib/misc

    cat > "/etc/dnsmasq-${PVE_BRIDGE}.conf" <<DNSMASQ
port=0
interface=${PVE_BRIDGE}
bind-dynamic
dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_NETMASK},12h
dhcp-option=option:router,${bridge_ip}
dhcp-option=option:dns-server,${DHCP_DNS1},${DHCP_DNS2}
dhcp-leasefile=/var/lib/misc/dnsmasq-${PVE_BRIDGE}.leases
pid-file=/run/dnsmasq-${PVE_BRIDGE}.pid
DNSMASQ

    dnsmasq --test --conf-file="/etc/dnsmasq-${PVE_BRIDGE}.conf"

    cat > "/etc/systemd/system/dnsmasq-${PVE_BRIDGE}.service" <<SERVICE
[Unit]
Description=DHCP dnsmasq pour ${PVE_BRIDGE}
After=network.target

[Service]
Type=simple
ExecStartPre=/usr/bin/test -d /sys/class/net/${PVE_BRIDGE}
ExecStart=/usr/sbin/dnsmasq --no-daemon --conf-file=/etc/dnsmasq-${PVE_BRIDGE}.conf
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
    systemctl daemon-reload
    systemctl enable --now "dnsmasq-${PVE_BRIDGE}.service"
    systemctl is-active --quiet "dnsmasq-${PVE_BRIDGE}.service" ||
        die "Le DHCP dnsmasq-${PVE_BRIDGE} n'est pas actif."

    log "Activation du NAT : ${PVE_LAN_NETWORK} -> ${wan_if}"

    cat > /etc/sysctl.d/99-proxmox-aws-nat.conf <<'SYSCTL'
net.ipv4.ip_forward=1
SYSCTL
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    cat > /usr/local/sbin/proxmox-vm-nat.sh <<NATSCRIPT
#!/usr/bin/env bash
set -euo pipefail
BRIDGE="${PVE_BRIDGE}"
LAN="${PVE_LAN_NETWORK}"
WAN_IF="\$(ip -4 route show default | awk 'NR==1 {print \$5}')"
[[ -n "\$WAN_IF" ]] || exit 1

sysctl -w net.ipv4.ip_forward=1 >/dev/null

iptables -t nat -C POSTROUTING -s "\$LAN" -o "\$WAN_IF" -j MASQUERADE 2>/dev/null ||
iptables -t nat -A POSTROUTING -s "\$LAN" -o "\$WAN_IF" -j MASQUERADE

iptables -C FORWARD -i "\$BRIDGE" -o "\$WAN_IF" -j ACCEPT 2>/dev/null ||
iptables -A FORWARD -i "\$BRIDGE" -o "\$WAN_IF" -j ACCEPT

iptables -C FORWARD -i "\$WAN_IF" -o "\$BRIDGE" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||
iptables -A FORWARD -i "\$WAN_IF" -o "\$BRIDGE" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
NATSCRIPT
    chmod 0750 /usr/local/sbin/proxmox-vm-nat.sh

    cat > /etc/systemd/system/proxmox-vm-nat.service <<NATSVC
[Unit]
Description=NAT pour les VM Proxmox sur ${PVE_BRIDGE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/proxmox-vm-nat.sh

[Install]
WantedBy=multi-user.target
NATSVC

    systemctl daemon-reload
    systemctl enable --now proxmox-vm-nat.service

    systemctl is-active --quiet proxmox-vm-nat.service ||
        die "Le service NAT n'est pas actif."

    iptables -t nat -C POSTROUTING \
        -s "$PVE_LAN_NETWORK" -o "$wan_if" -j MASQUERADE 2>/dev/null ||
        die "La règle MASQUERADE est absente."

    log "Réseau VM opérationnel : ${PVE_BRIDGE}, DHCP et NAT actifs."
}


get_public_ip_optional() {
    local token public_ip
    token="$(curl -fsS --connect-timeout 2 -X PUT \
        -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
        http://169.254.169.254/latest/api/token 2>/dev/null || true)"
    [[ -n "$token" ]] || return 0

    public_ip="$(curl -fsS --connect-timeout 2 \
        -H "X-aws-ec2-metadata-token: ${token}" \
        http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)"
    printf '%s' "$public_ip"
}

write_summary() {
    local wan_if private_ip public_ip kernel
    wan_if="$(get_wan_interface)"
    private_ip="$(get_private_ip "$wan_if")"
    public_ip="$(get_public_ip_optional)"
    kernel="$(uname -r)"

    cat > "$SUMMARY_FILE" <<SUMMARY
Installation Proxmox VE sur AWS terminée
========================================

Version du script : ${INSTALLER_VERSION}
Hôte              : ${PVE_FQDN}
Noyau              : ${kernel}
Interface AWS      : ${wan_if}
IP privée AWS      : ${private_ip}
IP publique AWS    : ${public_ip:-non détectée}
Bridge des VM      : ${PVE_BRIDGE}
Adresse du bridge  : ${PVE_LAN_ADDRESS}
Réseau des VM      : ${PVE_LAN_NETWORK}

Interface Proxmox  : https://${public_ip:-IP_PUBLIQUE_AWS}:8006
Compte             : root@pam

Configuration d'une VM :
- Bridge : ${PVE_BRIDGE}
- IPv4 : DHCP / automatique
- Plage DHCP : ${DHCP_START} -> ${DHCP_END}
- Passerelle : ${PVE_LAN_ADDRESS%%/*}
- DNS : ${DHCP_DNS1}, ${DHCP_DNS2}

AWS Security Group :
- TCP 22 depuis votre adresse IP
- TCP 8006 depuis votre adresse IP

Vérifications :
- systemctl status pveproxy
- ss -lntp | grep 8006
- ip address show ${PVE_BRIDGE}
- systemctl is-active dnsmasq-${PVE_BRIDGE}
- systemctl is-active proxmox-vm-nat
- pvesh get /nodes/$(hostname -s)/network
- iptables -t nat -S POSTROUTING
- cat ${LOG_FILE}
SUMMARY
    chmod 0600 "$SUMMARY_FILE"
}

finish_installation() {
    rm -f "$STATE_STAGE2"
    touch "$STATE_COMPLETE"
    systemctl disable proxmox-aws-complet.service >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    write_summary

    log "Installation terminée."
    cat "$SUMMARY_FILE"
}

phase2() {
    require_root
    validate_settings
    check_os

    if [[ -e "$STATE_COMPLETE" ]]; then
        log "Installation déjà terminée. Consultez ${SUMMARY_FILE}."
        exit 0
    fi

    if [[ "$(uname -r)" != *-pve* ]]; then
        die "Le noyau actif ($(uname -r)) n'est pas un noyau PVE. Vérifiez GRUB puis redémarrez avant de relancer : sudo ${INSTALL_PATH} --stage2"
    fi

    check_kvm
    configure_hostname
    disable_enterprise_repositories
    install_proxmox_packages
    configure_vm_network
    finish_installation
}

usage() {
    cat <<USAGE
Usage :
  sudo bash $0
  sudo $INSTALL_PATH --stage2

Variables optionnelles :
  PVE_FQDN=pve1.lab.local
  PVE_BRIDGE=vmbr1
  PVE_LAN_ADDRESS=10.10.10.1/24
  PVE_LAN_NETWORK=10.10.10.0/24
  DHCP_START=10.10.10.100
  DHCP_END=10.10.10.200
  DHCP_DNS1=1.1.1.1
  DHCP_DNS2=8.8.8.8
  AUTO_REBOOT=yes|no
  REQUIRE_KVM=yes|no
  PVE_ROOT_PASSWORD='mot-de-passe'   # défaut LAB : root

Exemple :
  sudo env PVE_FQDN=pve1.lab.local \\
    PVE_LAN_ADDRESS=10.20.0.1/24 \\
    PVE_LAN_NETWORK=10.20.0.0/24 \\
    bash $0
USAGE
}

main() {
    case "${1:-}" in
        --stage2|--resume)
            phase2
            ;;
        -h|--help)
            usage
            ;;
        "")
            if [[ -e "$STATE_STAGE2" ]]; then
                phase2
            else
                phase1
            fi
            ;;
        *)
            usage
            die "Option inconnue : $1"
            ;;
    esac
}

main "$@"
