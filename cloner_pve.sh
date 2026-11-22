#!/bin/bash
# Lit la configuration de l'instance EC2 "pve1" et crée deux nouvelles
# instances similaires "pve2" et "pve3" (même AMI de base, même type,
# même réseau, même disque), puis y copie les scripts du dépôt GitHub.
#
# Prérequis : AWS CLI v2 installée.
# Usage     : ./cloner_pve.sh
# Le script demande les identifiants AWS (ceux de "AWS Details" dans le Learner Lab).

set -euo pipefail

# ---------- Paramètres ----------
DEFAULT_REGION="us-east-1"                 # région habituelle d'AWS Academy
SOURCE_NAME="pve1"
NEW_NAMES=("pve2" "pve3")
REPO_URL="https://github.com/wasseflouatifsegs/fichiers.git"
DEST_DIR="/root/fichiers"
IAM_ROLE="LabRole"                         # rôle IAM attribué à pve2 et pve3

command -v aws >/dev/null || { echo "Erreur : AWS CLI non installée."; exit 1; }

# ---------- 0. Identifiants et région ----------
echo "=== Identifiants AWS ==="
echo "(Learner Lab : bouton 'AWS Details' puis 'AWS CLI : Show')"

USE_EXISTING="n"
if aws sts get-caller-identity >/dev/null 2>&1; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  read -r -p "Des identifiants valides existent déjà (compte $ACCOUNT). Les utiliser ? [O/n] " REP
  [[ "${REP:-O}" =~ ^[OoYy]$ ]] && USE_EXISTING="o"
fi

if [ "$USE_EXISTING" != "o" ]; then
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

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Erreur : identifiants refusés par AWS (expirés ou mal copiés ?)."
  exit 1
fi
echo "Connecté au compte $(aws sts get-caller-identity --query Account --output text), région $REGION."

# ---------- 1. Trouver pve1 ----------
echo "Recherche de l'instance '$SOURCE_NAME'..."
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$SOURCE_NAME" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text)

NB=$(wc -w <<< "$INSTANCE_IDS")
if [ "$NB" -ne 1 ]; then
  echo "Erreur : $NB instance(s) nommée(s) '$SOURCE_NAME' trouvée(s) dans $REGION, il en faut exactement une."
  exit 1
fi
SOURCE_ID="$INSTANCE_IDS"

# ---------- 2. Récupérer ses informations ----------
read -r AMI_ID INSTANCE_TYPE SUBNET_ID KEY_NAME ROOT_DEVICE PUBLIC_IP <<< "$(aws ec2 describe-instances \
  --instance-ids "$SOURCE_ID" \
  --query "Reservations[0].Instances[0].[ImageId,InstanceType,SubnetId,KeyName,RootDeviceName,PublicIpAddress]" \
  --output text)"

SG_IDS=$(aws ec2 describe-instances --instance-ids "$SOURCE_ID" \
  --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" --output text)

# Disque racine : taille et type
ROOT_VOL_ID=$(aws ec2 describe-instances --instance-ids "$SOURCE_ID" \
  --query "Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName=='$ROOT_DEVICE'].Ebs.VolumeId | [0]" \
  --output text)
read -r ROOT_SIZE ROOT_TYPE <<< "$(aws ec2 describe-volumes --volume-ids "$ROOT_VOL_ID" \
  --query "Volumes[0].[Size,VolumeType]" --output text)"

# L'AMI de base de pve1 doit toujours exister
if ! aws ec2 describe-images --image-ids "$AMI_ID" --query "Images[0].ImageId" --output text >/dev/null 2>&1; then
  echo "Erreur : l'AMI $AMI_ID utilisée par $SOURCE_NAME n'est plus disponible."
  exit 1
fi

# Profil d'instance contenant LabRole (LabInstanceProfile dans AWS Academy)
INSTANCE_PROFILE=$(aws iam list-instance-profiles-for-role --role-name "$IAM_ROLE" \
  --query "InstanceProfiles[0].InstanceProfileName" --output text 2>/dev/null || true)
if [ -z "$INSTANCE_PROFILE" ] || [ "$INSTANCE_PROFILE" = "None" ]; then
  INSTANCE_PROFILE="LabInstanceProfile"
fi

echo "=== Informations de $SOURCE_NAME ($SOURCE_ID) ==="
echo "AMI               : $AMI_ID"
echo "Type              : $INSTANCE_TYPE"
echo "Sous-réseau       : $SUBNET_ID"
echo "Groupes sécurité  : $SG_IDS"
echo "Clé SSH           : $KEY_NAME"
echo "Disque racine     : $ROOT_DEVICE, $ROOT_SIZE Go, $ROOT_TYPE"
echo "IP publique       : $PUBLIC_IP"
echo "Rôle IAM          : $IAM_ROLE (profil $INSTANCE_PROFILE)"
echo

read -r -p "Créer ${NEW_NAMES[*]} avec cette configuration ? [O/n] " REP
[[ "${REP:-O}" =~ ^[OoYy]$ ]] || { echo "Annulé."; exit 0; }

BLOCK_DEVICES="[{\"DeviceName\":\"$ROOT_DEVICE\",\"Ebs\":{\"VolumeSize\":$ROOT_SIZE,\"VolumeType\":\"$ROOT_TYPE\",\"DeleteOnTermination\":true}}]"

# ---------- 3. Créer pve2 et pve3 ----------
NEW_IDS=()
for NAME in "${NEW_NAMES[@]}"; do
  USER_DATA=$(mktemp)
  cat > "$USER_DATA" <<EOF
#!/bin/bash
# Exécuté par cloud-init au premier démarrage de $NAME
set -e
IP=\$(hostname -I | awk '{print \$1}')

# Nom d'hôte de la machine (Proxmox exige une entrée correcte dans /etc/hosts)
hostnamectl set-hostname $NAME
sed -i "/\b$NAME\b/d" /etc/hosts
echo "\$IP $NAME.localdomain $NAME" >> /etc/hosts

# Récupération des scripts du dépôt
command -v git >/dev/null || { apt-get update && apt-get install -y git; }
rm -rf $DEST_DIR
git clone $REPO_URL $DEST_DIR
chmod +x $DEST_DIR/*.sh 2>/dev/null || true
EOF

  OPTS=(--image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE"
        --subnet-id "$SUBNET_ID" --security-group-ids $SG_IDS
        --block-device-mappings "$BLOCK_DEVICES"
        --iam-instance-profile "Name=$INSTANCE_PROFILE"
        --user-data "file://$USER_DATA"
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]")
  [ "$KEY_NAME" != "None" ] && OPTS+=(--key-name "$KEY_NAME")
  [ "$PUBLIC_IP" != "None" ] && OPTS+=(--associate-public-ip-address)

  echo "Création de $NAME..."
  ID=$(aws ec2 run-instances "${OPTS[@]}" --query "Instances[0].InstanceId" --output text)
  rm -f "$USER_DATA"
  echo "$NAME : $ID"
  NEW_IDS+=("$ID")
done

# ---------- 4. Attendre et afficher le résultat ----------
echo "Attente du démarrage des instances..."
aws ec2 wait instance-running --instance-ids "${NEW_IDS[@]}"

aws ec2 describe-instances --instance-ids "${NEW_IDS[@]}" \
  --query "Reservations[].Instances[].[Tags[?Key=='Name']|[0].Value,InstanceId,PrivateIpAddress,PublicIpAddress]" \
  --output table

echo "Terminé. Les scripts seront dans $DEST_DIR sur chaque instance après le premier démarrage."
