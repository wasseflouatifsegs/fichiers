#!/bin/bash
# À lancer dans le terminal d'AWS Academy, une fois pve1 créé à la main.
#
# Reproduit « Lancer davantage comme ceci » de la console EC2 :
#   1. AWS exporte la configuration complète de pve1
#      (aws ec2 get-launch-template-data) ;
#   2. elle devient un modèle de lancement ;
#   3. pve2 et pve3 sont lancés depuis ce modèle, avec leur propre nom
#      et des données utilisateur qui clonent le dépôt et lancent
#      installer-tout.sh ;
#   4. la même installation est lancée sur pve1 par SSH (ou les commandes
#      sont affichées si la clé SSH n'est pas trouvée).
#
# Usage : ./lancer-comme-pve1.sh

set -euo pipefail

# ---------- Paramètres ----------
DEFAULT_REGION="us-east-1"
SOURCE_NAME="pve1"
NEW_NAMES=("pve2" "pve3")
REPO_URL="https://github.com/wasseflouatifsegs/fichiers.git"
INSTANCE_PROFILE="LabInstanceProfile"      # profil qui porte le rôle LabRole
SSH_USER="admin"                           # utilisateur des AMI Debian
TEMPLATE_NAME="comme-${SOURCE_NAME}-$(date +%Y%m%d-%H%M%S)"

command -v aws >/dev/null || { echo "Erreur : AWS CLI non installée."; exit 1; }
command -v python3 >/dev/null || { echo "Erreur : python3 est nécessaire."; exit 1; }

# ---------- 0. Identifiants et région ----------
echo "=== Identifiants AWS ==="
USE_EXISTING="n"
# Le terminal d'AWS Academy a ses propres identifiants (rôle « runserver »)
# qui n'ont pas le droit de gérer EC2 : on vérifie un vrai droit EC2.
if aws ec2 describe-instances --region "$DEFAULT_REGION" --max-results 5 >/dev/null 2>&1; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  read -r -p "Des identifiants EC2 valides existent déjà (compte $ACCOUNT). Les utiliser ? [O/n] " REP
  [[ "${REP:-O}" =~ ^[OoYy]$ ]] && USE_EXISTING="o"
else
  echo "Les identifiants actuels ne permettent pas de gérer EC2 : collez ceux du lab."
fi

if [ "$USE_EXISTING" != "o" ]; then
  echo "(Learner Lab : bouton 'AWS Details' puis 'AWS CLI : Show')"
  read -r -p "aws_access_key_id     : " AWS_ACCESS_KEY_ID
  read -r -s -p "aws_secret_access_key : " AWS_SECRET_ACCESS_KEY; echo
  read -r -s -p "aws_session_token     : " AWS_SESSION_TOKEN; echo
  if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    echo "Erreur : la clé d'accès et la clé secrète sont obligatoires."; exit 1
  fi
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  if [ -n "$AWS_SESSION_TOKEN" ]; then export AWS_SESSION_TOKEN; else unset AWS_SESSION_TOKEN; fi
fi

read -r -p "Région [$DEFAULT_REGION] : " REGION
REGION="${REGION:-$DEFAULT_REGION}"
export AWS_DEFAULT_REGION="$REGION"

aws sts get-caller-identity >/dev/null 2>&1 \
  || { echo "Erreur : identifiants refusés par AWS (expirés ou mal copiés ?)."; exit 1; }
aws ec2 describe-instances --max-results 5 >/dev/null 2>&1 \
  || { echo "Erreur : ces identifiants n'ont pas le droit de gérer EC2 (prenez ceux de 'AWS Details')."; exit 1; }

read -r -s -p "Mot de passe root@pam pour Proxmox (Entrée = défaut du script) : " PVE_PW; echo
ENV_PW=""
[ -n "$PVE_PW" ] && ENV_PW="PVE_ROOT_PASSWORD=$(printf '%q' "$PVE_PW") "

# ---------- 1. Trouver pve1 ----------
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$SOURCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text)
NB=$(wc -w <<< "$INSTANCE_IDS")
[ "$NB" -eq 1 ] || { echo "Erreur : $NB instance(s) nommée(s) '$SOURCE_NAME' dans $REGION, il en faut une."; exit 1; }
SOURCE_ID="$INSTANCE_IDS"

for NAME in "${NEW_NAMES[@]}"; do
  OTHER=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)
  [ -z "$OTHER" ] || { echo "Erreur : une instance '$NAME' existe déjà ($OTHER)."; exit 1; }
done

# ---------- 2. « Lancer davantage comme ceci » : configuration de pve1 ----------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "Export de la configuration de $SOURCE_NAME ($SOURCE_ID)..."
aws ec2 get-launch-template-data --instance-id "$SOURCE_ID" \
  --query "LaunchTemplateData" --output json > "$WORK/source.json"

# On retire ce qui est propre à pve1 (adresses IP, nom, données utilisateur)
# et on fixe le rôle LabRole. Tout le reste est repris tel quel.
python3 - "$WORK/source.json" "$WORK/template.json" "$INSTANCE_PROFILE" <<'PY'
import json, sys
src, dst, profile = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(src))

for key in ("TagSpecifications", "UserData"):
    d.pop(key, None)

for ni in d.get("NetworkInterfaces", []):
    for key in ("PrivateIpAddress", "PrivateIpAddresses", "SecondaryPrivateIpAddressCount",
                "Ipv6Addresses", "Ipv6AddressCount", "Ipv4Prefixes", "Ipv6Prefixes",
                "NetworkInterfaceId"):
        ni.pop(key, None)

d["IamInstanceProfile"] = {"Name": profile}

# Supprime les sections vides, refusées par create-launch-template.
d = {k: v for k, v in d.items() if v not in ([], {}, None)}
json.dump(d, open(dst, "w"), indent=2)

ni = (d.get("NetworkInterfaces") or [{}])[0]
print("AMI               :", d.get("ImageId"))
print("Type              :", d.get("InstanceType"))
print("Sous-réseau       :", ni.get("SubnetId"))
print("Groupes sécurité  :", " ".join(ni.get("Groups", [])))
print("IP publique       :", ni.get("AssociatePublicIpAddress"))
print("Clé SSH           :", d.get("KeyName"))
for b in d.get("BlockDeviceMappings", []):
    e = b.get("Ebs", {})
    print("Disque            :", b.get("DeviceName"), e.get("VolumeSize"), "Go", e.get("VolumeType"))
print("Options CPU       :", json.dumps(d.get("CpuOptions", {})))
PY

echo
read -r -p "Lancer ${NEW_NAMES[*]} comme $SOURCE_NAME et installer Proxmox sur les 3 ? [O/n] " REP
[[ "${REP:-O}" =~ ^[OoYy]$ ]] || { echo "Annulé."; exit 0; }

echo "Création du modèle de lancement $TEMPLATE_NAME..."
TEMPLATE_ID=$(aws ec2 create-launch-template --launch-template-name "$TEMPLATE_NAME" \
  --version-description "Comme $SOURCE_NAME ($SOURCE_ID)" \
  --launch-template-data "file://$WORK/template.json" \
  --query "LaunchTemplate.LaunchTemplateId" --output text)

# Commandes d'installation (vos commandes, en mode non interactif)
install_commands() {
  local name="$1"
  cat <<EOF
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git
rm -rf /root/fichiers
git clone $REPO_URL /root/fichiers
cd /root/fichiers
chmod +x *.sh
env ${ENV_PW}./installer-tout.sh $name
EOF
}

# ---------- 3. Lancer pve2 et pve3 depuis le modèle ----------
NEW_IDS=()
for NAME in "${NEW_NAMES[@]}"; do
  {
    echo '#!/bin/bash'
    echo 'exec > >(tee -a /var/log/user-data.log) 2>&1'
    install_commands "$NAME"
  } > "$WORK/user-data-$NAME.sh"

  echo "Lancement de $NAME..."
  ID=$(aws ec2 run-instances \
    --launch-template "LaunchTemplateId=$TEMPLATE_ID,Version=1" \
    --user-data "file://$WORK/user-data-$NAME.sh" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
                         "ResourceType=volume,Tags=[{Key=Name,Value=$NAME}]" \
    --query "Instances[0].InstanceId" --output text)
  echo "$NAME : $ID"
  NEW_IDS+=("$ID")
done

# ---------- 4. Installation sur pve1 par SSH ----------
echo
echo "=== Installation sur $SOURCE_NAME ==="
STATE=$(aws ec2 describe-instances --instance-ids "$SOURCE_ID" \
  --query "Reservations[0].Instances[0].State.Name" --output text)
if [ "$STATE" != "running" ]; then
  echo "Démarrage de $SOURCE_NAME..."
  aws ec2 start-instances --instance-ids "$SOURCE_ID" >/dev/null
  aws ec2 wait instance-running --instance-ids "$SOURCE_ID"
fi
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$SOURCE_ID" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
KEY_NAME=$(aws ec2 describe-instances --instance-ids "$SOURCE_ID" \
  --query "Reservations[0].Instances[0].KeyName" --output text)

KEY_FILE=""
for f in ~/.ssh/labsuser.pem ~/labsuser.pem ~/environment/labsuser.pem ~/.ssh/"$KEY_NAME".pem; do
  [ -f "$f" ] && { KEY_FILE="$f"; break; }
done
if [ -z "$KEY_FILE" ]; then
  read -r -p "Chemin de labsuser.pem (Entrée = installer pve1 à la main) : " KEY_FILE
fi

PVE1_OK="n"
if [ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ]; then
  chmod 400 "$KEY_FILE" 2>/dev/null || true
  echo "Connexion SSH à $SOURCE_NAME ($PUBLIC_IP)..."
  for i in {1..12}; do
    ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
        "$SSH_USER@$PUBLIC_IP" true 2>/dev/null && break
    sleep 10
  done
  # Lancement détaché : le redémarrage de l'installation couperait la session SSH.
  if { echo 'exec > >(tee -a /var/log/user-data.log) 2>&1'; install_commands "$SOURCE_NAME"; } \
     | ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$SSH_USER@$PUBLIC_IP" \
         "cat > /tmp/install-pve.sh && sudo nohup setsid bash /tmp/install-pve.sh >/dev/null 2>&1 < /dev/null &"; then
    PVE1_OK="o"
    echo "Installation lancée sur $SOURCE_NAME."
  else
    echo "Échec de la connexion SSH à $SOURCE_NAME."
  fi
fi

if [ "$PVE1_OK" != "o" ]; then
  echo
  echo "Connectez-vous à $SOURCE_NAME (ssh -i labsuser.pem $SSH_USER@$PUBLIC_IP) et tapez :"
  echo "  sudo apt-get update && sudo apt-get install -y git"
  echo "  git clone $REPO_URL && cd fichiers && chmod +x *.sh"
  echo "  sudo ./installer-tout.sh $SOURCE_NAME"
fi

# ---------- 5. Résultat ----------
echo
echo "Attente du démarrage de ${NEW_NAMES[*]}..."
aws ec2 wait instance-running --instance-ids "${NEW_IDS[@]}"

aws ec2 describe-instances --instance-ids "$SOURCE_ID" "${NEW_IDS[@]}" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,PrivateIpAddress,PublicIpAddress]" \
  --output table

cat <<EOF

Modèle de lancement conservé : $TEMPLATE_NAME ($TEMPLATE_ID)
(pour d'autres nœuds : EC2 -> Modèles de lancement, ou supprimez-le s'il ne sert plus)

L'installation tourne seule sur les 3 machines (15-20 min, avec un redémarrage).
Suivi sur chaque machine :
  sudo tail -f /var/log/user-data.log               # clonage + début
  sudo tail -f /var/log/proxmox-aws-complet.log     # installation Proxmox
  sudo tail -f /var/log/proxmox-installer-tout.log  # vmbr1, DHCP, NAT
Interface : https://<IP publique>:8006  (root@pam)
EOF
