#!/bin/bash
# =============================================================================
# install.sh — CC_POST_BUILD_HOOK
# Exécuté à chaque déploiement (build).
# Responsabilités :
#   - Détecter la version actuellement installée sur le FS Bucket
#   - Calculer le chemin de migration si nécessaire (step-by-step)
#   - Télécharger et appliquer chaque version intermédiaire dans l'ordre
#   - Extraire la version finale à la racine du projet
#
# Variables optionnelles :
#   NEXTCLOUD_VERSION : version cible (défaut : latest stable)
#   Pour épingler : clever env set NEXTCLOUD_VERSION 32.0.6
#   Pour toujours avoir la latest : ne pas définir la variable
#
# Règle de migration Nextcloud :
#   On ne peut pas sauter plus d'une version majeure à la fois.
#   Ex : 30 → 31 → 32 → 33 (3 étapes, pas 30 → 33 directement)
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

# Extrait le numéro de version majeure (ex: "30.0.6" → "30")
major_version() {
    echo "$1" | cut -d. -f1
}

# Récupère la dernière version stable d'une branche majeure donnée
# Ex: latest_in_major 31 → "31.0.5"
latest_in_major() {
    local major="$1"
    local ver
    ver=$(curl -s "https://download.nextcloud.com/server/releases/" \
        | grep -oP "nextcloud-${major}\.[0-9]+\.[0-9]+\.zip" \
        | grep -v "beta\|rc\|RC" \
        | sed 's/nextcloud-//;s/\.zip//' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1)
    echo "$ver"
}

# Télécharge une version Nextcloud, extrait et écrase les fichiers en place
# Le dossier config/ est préservé (symlink vers FS Bucket géré par run.sh)
apply_version() {
    local version="$1"
    echo "[INFO] Application de Nextcloud $version..."
    wget -q "https://download.nextcloud.com/server/releases/nextcloud-${version}.zip" \
        -O nextcloud-dl.zip
    unzip -q nextcloud-dl.zip

    # Supprimer config/ extrait — on garde celui du FS Bucket
    rm -rf nextcloud/config

    # Écraser les fichiers Nextcloud en place (préserve scripts/, config-git/, app/, etc.)
    shopt -s dotglob
    cp -rf nextcloud/* .
    rm -rf nextcloud nextcloud-dl.zip
    echo "[OK] Nextcloud $version extrait."
}

# -----------------------------------------------------------------------------
# Résolution de la version cible
# -----------------------------------------------------------------------------
if [ -z "$NEXTCLOUD_VERSION" ]; then
    echo "[INFO] NEXTCLOUD_VERSION non définie — récupération de la dernière version stable..."
    NC_TARGET=$(curl -s "https://api.github.com/repos/nextcloud/server/releases/latest" \
        | grep '"tag_name"' \
        | sed 's/.*"v\([^"]*\)".*/\1/')
    if [ -z "$NC_TARGET" ]; then
        echo "[WARN] Impossible de récupérer la version depuis GitHub — fallback sur 33.0.0"
        NC_TARGET="33.0.0"
    fi
    echo "[INFO] Dernière version stable détectée : $NC_TARGET"
else
    NC_TARGET="$NEXTCLOUD_VERSION"
    echo "[INFO] Version cible épinglée : $NC_TARGET"
fi

# -----------------------------------------------------------------------------
# Détection de la version actuellement installée sur le FS Bucket
# APP_HOME est injecté par Clever Cloud — pointe vers /home/bas/app_<id>
# Le FS Bucket est déjà monté à ce stade du build
# -----------------------------------------------------------------------------
CURRENT_CONFIG="${APP_HOME}/app/storage/config/config.php"
NC_CURRENT=""

if [ -f "$CURRENT_CONFIG" ]; then
    NC_CURRENT=$(php -r "
        \$CONFIG = [];
        include '$CURRENT_CONFIG';
        echo isset(\$CONFIG['version']) ? \$CONFIG['version'] : '';
    " 2>/dev/null || echo "")
    # config['version'] = "30.0.6.1" — on garde les 3 premiers segments
    NC_CURRENT=$(echo "$NC_CURRENT" | cut -d. -f1-3)
fi

# -----------------------------------------------------------------------------
# Calcul du chemin de migration
# -----------------------------------------------------------------------------
if [ -z "$NC_CURRENT" ]; then
    echo "[INFO] Aucune installation existante détectée — installation directe de $NC_TARGET."
    apply_version "$NC_TARGET"
else
    MAJOR_CURRENT=$(major_version "$NC_CURRENT")
    MAJOR_TARGET=$(major_version "$NC_TARGET")
    echo "[INFO] Version actuelle : $NC_CURRENT (majeure : $MAJOR_CURRENT)"
    echo "[INFO] Version cible    : $NC_TARGET (majeure : $MAJOR_TARGET)"

    if [ "$MAJOR_CURRENT" -eq "$MAJOR_TARGET" ]; then
        # Même branche majeure — mise à jour directe ou rien
        echo "[INFO] Même version majeure — mise à jour directe."
        apply_version "$NC_TARGET"

    elif [ "$MAJOR_TARGET" -lt "$MAJOR_CURRENT" ]; then
        # Downgrade — interdit
        echo "[ERR] Downgrade interdit : $NC_CURRENT → $NC_TARGET"
        echo "[ERR] Supprimez NEXTCLOUD_VERSION ou définissez une version >= $NC_CURRENT"
        exit 1

    else
        # Migration step-by-step : on passe par chaque version majeure intermédiaire
        echo "[INFO] Migration step-by-step nécessaire : $NC_CURRENT → $NC_TARGET"
        echo "[INFO] Étapes : majeure $MAJOR_CURRENT → $MAJOR_TARGET"

        # Appliquer chaque version majeure intermédiaire
        STEP=$MAJOR_CURRENT
        while [ "$STEP" -lt "$MAJOR_TARGET" ]; do
            NEXT=$((STEP + 1))
            # Récupérer la dernière version stable de la branche intermédiaire
            STEP_VERSION=$(latest_in_major "$NEXT")
            if [ -z "$STEP_VERSION" ]; then
                echo "[ERR] Impossible de trouver une version stable pour la branche $NEXT"
                exit 1
            fi
            echo "[INFO] Étape intermédiaire : → $STEP_VERSION"
            apply_version "$STEP_VERSION"

            # Lancer occ upgrade pour cette étape intermédiaire
            # Le symlink config/ n'existe pas encore ici (run.sh le crée)
            # mais config.php est accessible via APP_HOME/app/storage/config/
            # On crée un symlink temporaire pour que occ puisse lire la config
            if [ ! -L "config" ] && [ ! -d "config" ]; then
                ln -s "${APP_HOME}/app/storage/config" config
                TEMP_SYMLINK=1
            fi

            echo "[INFO] Migration base de données vers $STEP_VERSION..."
            php occ upgrade --no-interaction
            EXIT_CODE=$?

            # Nettoyer le symlink temporaire si on l'a créé
            [ "${TEMP_SYMLINK:-0}" = "1" ] && rm -f config && unset TEMP_SYMLINK

            if [ $EXIT_CODE -ne 0 ]; then
                echo "[ERR] occ upgrade a échoué pour $STEP_VERSION — migration interrompue."
                echo "[ERR] L'instance reste sur la dernière version stable appliquée."
                exit 1
            fi

            echo "[OK] Migration vers $STEP_VERSION réussie."
            STEP=$NEXT
        done

        # Appliquer la version cible finale
        echo "[INFO] Application de la version cible finale : $NC_TARGET"
        apply_version "$NC_TARGET"
    fi
fi

echo "[OK] Nextcloud $NC_TARGET prêt pour le démarrage."

# Garantit les permissions d'exécution sur tous les scripts
chmod +x scripts/run.sh scripts/install.sh scripts/skeleton.sh scripts/cron.sh 2>/dev/null || true
