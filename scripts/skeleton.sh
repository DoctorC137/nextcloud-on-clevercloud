#!/bin/bash
# =============================================================================
# skeleton.sh — CC_RUN_SUCCEEDED_HOOK
# Exécuté après chaque démarrage réussi d'Apache.
# Upload les fichiers d'exemple du skeleton Nextcloud via WebDAV.
#
# Marqueur : fichier .skeleton_done sur le FS Bucket contenant l'instanceid.
#   → instanceid correspond   : déjà fait, rien à faire
#   → instanceid différent    : nouvelle installation, upload nécessaire
#   → fichier absent          : premier démarrage, upload nécessaire
#
# Si l'utilisateur supprime ses fichiers → marqueur intact → pas de réimport.
# Si destroy+redeploy → nouvel instanceid → skeleton re-uploadé.
#
# NOTE réseau : dans le contexte CC_RUN_SUCCEEDED_HOOK, le réseau sortant est
# restreint — les appels vers le domaine externe (cleverapps.io) sont bloqués.
# On passe par localhost:$PORT (port interne Apache, injecté par Clever Cloud)
# avec un header Host pour que Nextcloud accepte la requête.
#
# NOTE $0 : dans le contexte CC_RUN_SUCCEEDED_HOOK, $0 vaut "-bash" (shell de
# login), donc dirname/$0 est invalide. On détecte REAL_APP via le glob app_*
# comme dans run.sh.
# =============================================================================

set -e

# Détection du répertoire applicatif — même méthode que run.sh
REAL_APP=$(ls -d /home/bas/app_*/ 2>/dev/null | head -1 | sed 's|/$||')
if [ -z "$REAL_APP" ]; then
    echo "[ERR] Impossible de localiser le répertoire applicatif."
    exit 1
fi

NC_STORAGE="$REAL_APP/app/storage"
MARKER_FILE="$NC_STORAGE/.skeleton_done"
SKELETON_DIR="$REAL_APP/core/skeleton"

# Port Apache injecté par Clever Cloud — évite le hardcode de 8080
NC_PORT="${PORT:-8080}"
NC_LOCAL="http://localhost:$NC_PORT/remote.php/dav/files/$NEXTCLOUD_ADMIN_USER"
NC_AUTH="$NEXTCLOUD_ADMIN_USER:$NEXTCLOUD_ADMIN_PASSWORD"
NC_HOST_HEADER="Host: $NEXTCLOUD_DOMAIN"

echo "[INFO] REAL_APP=$REAL_APP"
echo "[INFO] Port Apache=$NC_PORT"

# -----------------------------------------------------------------------------
# Réécriture de la crontab avec le chemin réel de l'instance courante.
# Clever Cloud enregistre cron.json avec l'app ID figé au moment du déploiement.
# On corrige ici après que Clever Cloud a importé sa crontab.
# -----------------------------------------------------------------------------
mkdir -p /home/bas/.cache/crontab
echo "*/5 * * * * $REAL_APP/scripts/cron.sh" | crontab -
echo "[OK] Crontab mise à jour : $REAL_APP/scripts/cron.sh"

# -----------------------------------------------------------------------------
# Attente que WebDAV + objectstore S3 soient pleinement opérationnels.
# On teste une vraie écriture PUT via localhost:$PORT.
# On attend jusqu'à 5 minutes (60 × 5s) pour couvrir les démarrages lents.
# -----------------------------------------------------------------------------
echo "[INFO] Attente de l'objectstore S3..."
READY=0
for i in $(seq 1 60); do
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -u "$NC_AUTH" \
        -H "$NC_HOST_HEADER" \
        -X PUT --data-binary "ready" \
        --max-time 10 \
        "$NC_LOCAL/.skeleton_check" 2>/dev/null)
    if [ "$HTTP" = "201" ] || [ "$HTTP" = "204" ]; then
        curl -s -X DELETE \
            -u "$NC_AUTH" \
            -H "$NC_HOST_HEADER" \
            "$NC_LOCAL/.skeleton_check" \
            -o /dev/null --max-time 10 2>/dev/null || true
        READY=1
        echo "[OK] ObjectStore prêt après $i tentative(s)."
        break
    fi
    sleep 5
done

if [ "$READY" = "0" ]; then
    echo "[ERR] Timeout — objectstore S3 non disponible après 5 minutes."
    exit 1
fi

# -----------------------------------------------------------------------------
# Lecture de l'instanceid depuis config.php (pas de dépendance PostgreSQL).
# -----------------------------------------------------------------------------
INSTANCE_ID=$(php -r "
    \$CONFIG = [];
    \$cfg_file = '$NC_STORAGE/config/config.php';
    if (file_exists(\$cfg_file)) {
        include \$cfg_file;
        echo isset(\$CONFIG['instanceid']) ? \$CONFIG['instanceid'] : '';
    }
" 2>/dev/null || echo "")

if [ -z "$INSTANCE_ID" ]; then
    echo "[ERR] instanceid introuvable dans config.php."
    exit 1
fi

# -----------------------------------------------------------------------------
# Vérification du marqueur
# -----------------------------------------------------------------------------
if [ -f "$MARKER_FILE" ] && [ "$(cat "$MARKER_FILE" 2>/dev/null)" = "$INSTANCE_ID" ]; then
    echo "[INFO] Skeleton déjà uploadé pour cette instance, rien à faire."
    exit 0
fi

echo "[INFO] Upload du skeleton Nextcloud (instanceid: $INSTANCE_ID)..."

# -----------------------------------------------------------------------------
# Création des dossiers de premier niveau
# -----------------------------------------------------------------------------
while IFS= read -r d; do
    DIRNAME=$(basename "$d")
    ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$DIRNAME")
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X MKCOL \
        -u "$NC_AUTH" \
        -H "$NC_HOST_HEADER" \
        --max-time 30 \
        "$NC_LOCAL/$ENCODED" 2>/dev/null)
    # 201 = créé, 405 = déjà existant — les deux sont acceptables
    [ "$HTTP" != "201" ] && [ "$HTTP" != "405" ] && \
        echo "[WARN] MKCOL $DIRNAME : HTTP $HTTP"
done < <(find "$SKELETON_DIR" -mindepth 1 -maxdepth 1 -type d)

# -----------------------------------------------------------------------------
# Upload de tous les fichiers récursivement
# -----------------------------------------------------------------------------
ERRORS=0
while IFS= read -r f; do
    REL="${f#$SKELETON_DIR/}"
    ENCODED=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$REL")
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT \
        -u "$NC_AUTH" \
        -H "$NC_HOST_HEADER" \
        --max-time 120 \
        "$NC_LOCAL/$ENCODED" --data-binary "@$f" 2>/dev/null)
    if [ "$HTTP" != "201" ] && [ "$HTTP" != "204" ]; then
        echo "[WARN] PUT échoué ($HTTP) : $REL"
        ERRORS=$((ERRORS + 1))
    fi
done < <(find "$SKELETON_DIR" -type f)

if [ "$ERRORS" -gt 0 ]; then
    echo "[WARN] $ERRORS fichier(s) n'ont pas pu être uploadés."
fi

# -----------------------------------------------------------------------------
# Écriture du marqueur sur le FS Bucket
# -----------------------------------------------------------------------------
echo "$INSTANCE_ID" > "$MARKER_FILE"
echo "[OK] Skeleton uploadé."
