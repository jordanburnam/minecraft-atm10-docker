#!/bin/bash
set -e

CF_API_BASE="https://api.curseforge.com/v1"
ATM10_PROJECT_ID="${CF_PROJECT_ID:-925200}"

# Resolve and install the requested pack. For "latest", check CurseForge on
# every container start and skip the download when the recorded file ID matches.
PACK_MARKER="/data/.atm10-server-pack.json"
PACK_VERSION="${MODPACK_VERSION:-latest}"
PACK_MISSING=false
if [ ! -d "/data/mods" ] || [ -z "$(ls -A /data/mods 2>/dev/null)" ]; then
    PACK_MISSING=true
fi

if [ "$PACK_VERSION" = "latest" ] || [ "$PACK_MISSING" = true ]; then
    echo "=========================================="
    echo " Checking ATM10 server pack (version: ${PACK_VERSION})..."
    echo "=========================================="

    if [ -z "${CF_API_KEY:-}" ]; then
        echo "ERROR: CF_API_KEY environment variable is required."
        echo "Get one at https://console.curseforge.com/"
        exit 1
    fi

    # Query CurseForge for available versions
    echo "Querying CurseForge API..."
    FILES_JSON=$(curl -sf -H "x-api-key: ${CF_API_KEY}" \
        "${CF_API_BASE}/mods/${ATM10_PROJECT_ID}/files?pageSize=50&sortOrder=desc&sortField=1")

    if [ -z "$FILES_JSON" ]; then
        echo "ERROR: Failed to query CurseForge API. Check your CF_API_KEY."
        exit 1
    fi

    # Find the server pack file ID: match specific version or grab latest.
    if [ "$PACK_VERSION" = "latest" ]; then
        SERVER_PACK_ID=$(echo "$FILES_JSON" | jq -r \
            '[.data[] | select(.serverPackFileId != null)] | .[0].serverPackFileId // empty')
        MATCHED_NAME=$(echo "$FILES_JSON" | jq -r \
            '[.data[] | select(.serverPackFileId != null)] | .[0].displayName // empty')
        LATEST_CLIENT_NAME=$(echo "$FILES_JSON" | jq -r \
            '[.data[] | select(.isServerPack != true)] | .[0].displayName // empty')
        if [ -n "$LATEST_CLIENT_NAME" ] && [ "$LATEST_CLIENT_NAME" != "$MATCHED_NAME" ]; then
            echo "Latest client release: ${LATEST_CLIENT_NAME}; no server pack is attached."
            echo "Using newest available server pack: ${MATCHED_NAME}. Clients must match this version."
        fi
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

    INSTALLED_PACK_ID=$(jq -r '.serverPackFileId // empty' "$PACK_MARKER" 2>/dev/null || true)
    if [ "$PACK_MISSING" = false ] && [ "$INSTALLED_PACK_ID" = "$SERVER_PACK_ID" ]; then
        echo "ATM10 is current: ${MATCHED_NAME} (server pack ID: ${SERVER_PACK_ID})"
    else
        DOWNLOAD_URL=$(curl -sf -H "x-api-key: ${CF_API_KEY}" \
            "${CF_API_BASE}/mods/${ATM10_PROJECT_ID}/files/${SERVER_PACK_ID}/download-url" | \
            jq -r '.data // empty')

        if [ -z "$DOWNLOAD_URL" ]; then
            echo "ERROR: Could not get download URL for server pack."
            exit 1
        fi

        echo "Installing: ${MATCHED_NAME} (server pack ID: ${SERVER_PACK_ID})"
        rm -rf /tmp/serverpack /tmp/serverpack.zip
        curl -fL --retry 3 -o /tmp/serverpack.zip "$DOWNLOAD_URL"
        unzip -tq /tmp/serverpack.zip
        unzip -oq /tmp/serverpack.zip -d /tmp/serverpack

        # Handle packs containing one wrapper directory.
        PACK_ROOT="/tmp/serverpack"
        EXTRACTED_DIRS=$(find "$PACK_ROOT" -mindepth 1 -maxdepth 1 -type d)
        EXTRACTED_FILES=$(find "$PACK_ROOT" -mindepth 1 -maxdepth 1 -type f)
        if [ -n "$EXTRACTED_DIRS" ] && [ -z "$EXTRACTED_FILES" ] && [ "$(echo "$EXTRACTED_DIRS" | wc -l)" -eq 1 ]; then
            PACK_ROOT="$EXTRACTED_DIRS"
        fi

        # Remove pack-managed directories so deleted mods cannot survive an update.
        for path in mods config defaultconfigs kubejs libraries datapacks patchouli_books; do
            if [ -e "$PACK_ROOT/$path" ]; then
                rm -rf "/data/$path"
            fi
        done

        # Preserve server-owned state and local runtime settings across overlays.
        PRESERVE_DIR="/tmp/serverpack-preserve"
        rm -rf "$PRESERVE_DIR"
        mkdir -p "$PRESERVE_DIR"
        for file in server.properties eula.txt ops.json whitelist.json \
            banned-ips.json banned-players.json user_jvm_args.txt server-icon.png; do
            if [ -f "/data/$file" ]; then
                cp -a "/data/$file" "$PRESERVE_DIR/$file"
            fi
        done
        cp -a "$PACK_ROOT"/. /data/
        cp -a "$PRESERVE_DIR"/. /data/

        jq -n \
            --arg serverPackFileId "$SERVER_PACK_ID" \
            --arg displayName "$MATCHED_NAME" \
            '{serverPackFileId: $serverPackFileId, displayName: $displayName}' \
            > "${PACK_MARKER}.tmp"
        mv "${PACK_MARKER}.tmp" "$PACK_MARKER"
        rm -rf /tmp/serverpack.zip /tmp/serverpack "$PRESERVE_DIR"

        echo "=========================================="
        echo " Server pack installed: ${MATCHED_NAME}"
        echo "=========================================="
    fi
fi

# Accept EULA
if [ ! -f "/data/eula.txt" ] || ! grep -q "eula=true" /data/eula.txt; then
    echo "eula=true" > /data/eula.txt
    echo "EULA accepted."
fi

# Make startserver.sh executable
chmod +x /data/startserver.sh 2>/dev/null || true

# Some server packs include libraries for an older NeoForge build. Force the
# bundled installer to run when the version required by startserver.sh is absent.
NEOFORGE_VERSION=$(sed -n 's/^NEOFORGE_VERSION=//p' /data/startserver.sh | head -n 1)
if [ -n "$NEOFORGE_VERSION" ] && \
   [ ! -f "/data/libraries/net/neoforged/neoforge/${NEOFORGE_VERSION}/unix_args.txt" ]; then
    echo "NeoForge ${NEOFORGE_VERSION} runtime is missing; reinstalling it..."
    rm -rf /data/libraries
fi

# Run NeoForge install first. This creates server.properties before overrides.
cd /data
ATM10_INSTALL_ONLY=true bash startserver.sh || true

# Uses grep -v to remove old lines, then appends new values.
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

# Keep remote access gated by Minecraft's built-in whitelist.
apply_property "white-list" "true"
apply_property "enforce-whitelist" "true"

# Merge configured operators into saved access lists. Profile lookup failures
# must never revoke existing access, including manually whitelisted players.
if [ -n "${OPS:-}" ]; then
    echo "Configuring server operators and whitelist..."
    OPS_JSON="[]"
    WHITELIST_JSON="[]"
    if [ -f /data/ops.json ]; then
        OPS_JSON=$(jq -e 'if type == "array" then . else error("Invalid ops.json") end' /data/ops.json)
    fi
    if [ -f /data/whitelist.json ]; then
        WHITELIST_JSON=$(jq -e 'if type == "array" then . else error("Invalid whitelist.json") end' /data/whitelist.json)
    fi
    IFS=',' read -ra OP_LIST <<< "$OPS"
    for USERNAME in "${OP_LIST[@]}"; do
        USERNAME=$(echo "$USERNAME" | xargs)
        if [[ ! "$USERNAME" =~ ^[A-Za-z0-9_]{1,16}$ ]]; then
            echo "  WARNING: Invalid Minecraft username '${USERNAME}'; preserving existing access."
            continue
        fi

        # Reuse trusted local UUIDs before depending on an external lookup.
        FORMATTED_UUID=""
        for PROFILE_FILE in /data/ops.json /data/whitelist.json /data/usercache.json; do
            [ -f "$PROFILE_FILE" ] || continue
            FORMATTED_UUID=$(jq -r --arg name "$USERNAME" '
                .[] | select((.name // "" | ascii_downcase) == ($name | ascii_downcase))
                | .uuid // empty
                | select(test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
            ' "$PROFILE_FILE" 2>/dev/null | head -n 1)
            if [ -n "$FORMATTED_UUID" ]; then
                echo "  Using saved UUID for ${USERNAME}."
                break
            fi
        done

        if [ -z "$FORMATTED_UUID" ]; then
            for PROFILE_URL in \
                "https://api.minecraftservices.com/minecraft/profile/lookup/name/${USERNAME}" \
                "https://api.mojang.com/users/profiles/minecraft/${USERNAME}"; do
                PROFILE=$(curl -fsS --connect-timeout 5 --max-time 15 --retry 2 --retry-delay 1 "$PROFILE_URL" || true)
                RAW_UUID=$(echo "$PROFILE" | jq -r --arg name "$USERNAME" '
                    select((.name // "" | ascii_downcase) == ($name | ascii_downcase))
                    | .id // empty | select(test("^[0-9a-fA-F]{32}$"))
                ' 2>/dev/null || true)
                if [ -n "$RAW_UUID" ]; then
                    FORMATTED_UUID=$(echo "$RAW_UUID" | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)/\1-\2-\3-\4-\5/')
                    break
                fi
            done
        fi

        if [ -z "$FORMATTED_UUID" ]; then
            echo "  WARNING: Could not resolve Minecraft user '${USERNAME}'; preserving existing access."
            continue
        fi

        OPS_JSON=$(echo "$OPS_JSON" | jq --arg uuid "$FORMATTED_UUID" --arg name "$USERNAME" '
            [.[] | select(.uuid != $uuid and ((.name | ascii_downcase) != ($name | ascii_downcase)))]
            + [{uuid: $uuid, name: $name, level: 4, bypassesPlayerLimit: false}]')
        WHITELIST_JSON=$(echo "$WHITELIST_JSON" | jq --arg uuid "$FORMATTED_UUID" --arg name "$USERNAME" '
            [.[] | select(.uuid != $uuid and ((.name | ascii_downcase) != ($name | ascii_downcase)))]
            + [{uuid: $uuid, name: $name}]')
        echo "  Ensured OP and whitelist: ${USERNAME} (${FORMATTED_UUID})"
    done
    printf '%s\n' "$OPS_JSON" > /data/ops.json.tmp
    printf '%s\n' "$WHITELIST_JSON" > /data/whitelist.json.tmp
    mv /data/ops.json.tmp /data/ops.json
    mv /data/whitelist.json.tmp /data/whitelist.json
fi

exec /bin/bash startserver.sh
