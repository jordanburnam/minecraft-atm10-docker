#!/bin/bash
set -e

CF_API_BASE="https://api.curseforge.com/v1"
ATM10_PROJECT_ID="${CF_PROJECT_ID:-925200}"

# Check if the server pack has been downloaded (mods dir populated)
if [ ! -d "/data/mods" ] || [ -z "$(ls -A /data/mods 2>/dev/null)" ]; then
    echo "=========================================="
    echo " ATM10 server pack not found, downloading..."
    echo "=========================================="

    if [ -z "${CF_API_KEY:-}" ]; then
        echo "ERROR: CF_API_KEY environment variable is required."
        echo "Get one at https://console.curseforge.com/"
        exit 1
    fi

    # Query CurseForge for available versions
    PACK_VERSION="${MODPACK_VERSION:-latest}"
    echo "Querying CurseForge API for ATM10 server pack (version: ${PACK_VERSION})..."
    FILES_JSON=$(curl -sf -H "x-api-key: ${CF_API_KEY}" \
        "${CF_API_BASE}/mods/${ATM10_PROJECT_ID}/files?pageSize=50&sortOrder=desc&sortField=1")

    if [ -z "$FILES_JSON" ]; then
        echo "ERROR: Failed to query CurseForge API. Check your CF_API_KEY."
        exit 1
    fi

    # Find the server pack file ID — match specific version or grab latest
    if [ "$PACK_VERSION" = "latest" ]; then
        SERVER_PACK_ID=$(echo "$FILES_JSON" | jq -r \
            '[.data[] | select(.serverPackFileId != null)] | .[0].serverPackFileId // empty')
        MATCHED_NAME=$(echo "$FILES_JSON" | jq -r \
            '[.data[] | select(.serverPackFileId != null)] | .[0].displayName // empty')
    else
        SERVER_PACK_ID=$(echo "$FILES_JSON" | jq -r --arg v "$PACK_VERSION" \
            '[.data[] | select(.serverPackFileId != null and (.displayName | endswith("-" + $v)))] | .[0].serverPackFileId // empty')
        MATCHED_NAME=$(echo "$FILES_JSON" | jq -r --arg v "$PACK_VERSION" \
            '[.data[] | select(.serverPackFileId != null and (.displayName | endswith("-" + $v)))] | .[0].displayName // empty')
    fi

    if [ -z "$SERVER_PACK_ID" ]; then
        echo "ERROR: Could not find server pack for version '${PACK_VERSION}'."
        echo "Available versions:"
        echo "$FILES_JSON" | jq -r '.data[] | select(.serverPackFileId != null) | .displayName'
        exit 1
    fi

    echo "Found: ${MATCHED_NAME} (server pack ID: ${SERVER_PACK_ID})"

    # Get download URL
    DOWNLOAD_URL=$(curl -sf -H "x-api-key: ${CF_API_KEY}" \
        "${CF_API_BASE}/mods/${ATM10_PROJECT_ID}/files/${SERVER_PACK_ID}/download-url" | \
        jq -r '.data // empty')

    if [ -z "$DOWNLOAD_URL" ]; then
        echo "ERROR: Could not get download URL for server pack."
        exit 1
    fi

    echo "Downloading: ${DOWNLOAD_URL}"
    curl -L -o /tmp/serverpack.zip "${DOWNLOAD_URL}"

    echo "Extracting server pack to /data..."
    unzip -o /tmp/serverpack.zip -d /tmp/serverpack

    # Handle case where zip contains a single nested directory
    EXTRACTED_DIRS=$(find /tmp/serverpack -mindepth 1 -maxdepth 1 -type d)
    EXTRACTED_FILES=$(find /tmp/serverpack -mindepth 1 -maxdepth 1 -type f)

    if [ -n "$EXTRACTED_DIRS" ] && [ -z "$EXTRACTED_FILES" ] && [ "$(echo "$EXTRACTED_DIRS" | wc -l)" -eq 1 ]; then
        echo "Server pack has nested directory, moving contents up..."
        cp -rf "$EXTRACTED_DIRS"/* /data/ 2>/dev/null || true
        cp -rf "$EXTRACTED_DIRS"/.* /data/ 2>/dev/null || true
    else
        cp -rf /tmp/serverpack/* /data/ 2>/dev/null || true
    fi

    rm -rf /tmp/serverpack.zip /tmp/serverpack

    echo "=========================================="
    echo " Server pack installed!"
    echo "=========================================="
fi

# Accept EULA
if [ ! -f "/data/eula.txt" ] || ! grep -q "eula=true" /data/eula.txt; then
    echo "eula=true" > /data/eula.txt
    echo "EULA accepted."
fi

# Make startserver.sh executable
chmod +x /data/startserver.sh 2>/dev/null || true

# Run NeoForge install first (startserver.sh with INSTALL_ONLY)
# This ensures server.properties gets generated before we override it
cd /data
ATM10_INSTALL_ONLY=true bash startserver.sh || true

# Now apply server.properties overrides from env vars
# Uses grep -v to remove old line, then appends new value (avoids sed regex issues)
apply_property() {
    local key="$1" value="$2"
    if [ -f /data/server.properties ]; then
        grep -v "^${key}=" /data/server.properties > /tmp/server.properties.tmp || true
        mv /tmp/server.properties.tmp /data/server.properties
    fi
    echo "${key}=${value}" >> /data/server.properties
}

if [ -n "${WORLD_SEED:-}" ]; then
    apply_property "level-seed" "${WORLD_SEED}"
    echo "World seed set to: ${WORLD_SEED}"
fi
if [ -n "${DIFFICULTY:-}" ]; then
    apply_property "difficulty" "${DIFFICULTY}"
    echo "Difficulty set to: ${DIFFICULTY}"
fi

# Configure server operators from OPS env var (comma-separated Minecraft usernames)
if [ -n "${OPS:-}" ]; then
    echo "Configuring server operators..."
    OPS_JSON="[]"
    IFS=',' read -ra OP_LIST <<< "$OPS"
    for USERNAME in "${OP_LIST[@]}"; do
        USERNAME=$(echo "$USERNAME" | xargs)
        PROFILE=$(curl -sf "https://api.mojang.com/users/profiles/minecraft/${USERNAME}" || true)
        if [ -n "$PROFILE" ]; then
            RAW_UUID=$(echo "$PROFILE" | jq -r '.id')
            FORMATTED_UUID=$(echo "$RAW_UUID" | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
            OPS_JSON=$(echo "$OPS_JSON" | jq --arg uuid "$FORMATTED_UUID" --arg name "$USERNAME" \
                '. += [{"uuid": $uuid, "name": $name, "level": 4, "bypassesPlayerLimit": false}]')
            echo "  Added OP: ${USERNAME} (${FORMATTED_UUID})"
        else
            echo "  WARNING: Could not find Minecraft user '${USERNAME}', skipping"
        fi
    done
    echo "$OPS_JSON" > /data/ops.json
fi

exec /bin/bash startserver.sh
