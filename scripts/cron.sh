#!/bin/bash -l
# =============================================================================
# cron.sh — Cron Nextcloud pour Clever Cloud
# Appelé via clevercloud/cron.json toutes les 5 minutes.
# Le -l dans le shebang est obligatoire pour accéder aux variables d'env CC.
# Sans FS Bucket : logs vers syslog (visible dans clever logs --alias nextcloud)
# =============================================================================

REAL_APP=$(ls -d /home/bas/app_*/ 2>/dev/null | head -1 | sed 's|/$||')
[ -z "$REAL_APP" ] && exit 1

# .ncdata est requis par occ/cron.php — recréé si absent (data/ est éphémère)
[ ! -f "$REAL_APP/data/.ncdata" ] && \
    echo "# Nextcloud data directory" > "$REAL_APP/data/.ncdata"

php "$REAL_APP/cron.php" 2>&1 | logger -t nextcloud-cron

# Sync custom_apps/ vers S3 si des changements ont eu lieu (capture les installs UI)
# Comparaison par checksum : on ne push que si le contenu a changé depuis le dernier push.
APPS_HASH_FILE="/tmp/.custom_apps_hash"
CURRENT_HASH=$(find "$REAL_APP/custom_apps" -type f -name "*.php" 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
PREVIOUS_HASH=$(cat "$APPS_HASH_FILE" 2>/dev/null || echo "")
if [ -n "$CURRENT_HASH" ] && [ "$CURRENT_HASH" != "$PREVIOUS_HASH" ]; then
    bash "$REAL_APP/scripts/sync-apps.sh" push 2>&1 | logger -t nextcloud-sync-apps
    echo "$CURRENT_HASH" > "$APPS_HASH_FILE"
fi
