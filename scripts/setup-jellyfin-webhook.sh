#!/usr/bin/env bash
# ==============================================================================
# Cine-Claw v2: Jellyfin -> Tiramisu Webhook Auto-Configuration Script
#
# Purpose:
#   Installs the Jellyfin Webhook plugin and configures it to notify Tiramisu
#   (:9080/plex/webhook) on PlaybackStart, PlaybackProgress, and PlaybackStop.
#
#   When playback starts, Tiramisu extracts the IMDb ID from the webhook payload,
#   matches the active swarm, and activates Priority Mode + Aggressive Sequential
#   piece downloading for near-instant TTFF (Time-To-First-Frame < 0.1s).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-a4151fee9ef64ea6b23b185f8fe2720e}"
TIRAMISU_WEBHOOK_URL="${TIRAMISU_WEBHOOK_URL:-http://tiramisu:9080/plex/webhook}"
CLEANUP_WEBHOOK_URL="${CLEANUP_WEBHOOK_URL:-http://tracker-proxy:9118/api/stream/webhook/deleted}"
DATA_DIR="${DATA_DIR:-$REPO_ROOT/data}"

if [ -z "${COMPOSE_CMD:-}" ]; then
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        COMPOSE_CMD="docker compose"
    fi
fi

PLUGIN_DIR="$DATA_DIR/jellyfin/config/plugins/Webhook"
CONFIG_DIR="$DATA_DIR/jellyfin/config/plugins/configurations"
CONFIG_XML="$CONFIG_DIR/Jellyfin.Plugin.Webhook.xml"

PLUGIN_ZIP_URL="https://repo.jellyfin.org/files/plugin/webhook/webhook_21.0.0.0.zip"
PLUGIN_GUID="71552a5a5c5c4350a2aeebe451a30173"

# Handlebars notification payload templates
TEMPLATE_RAW='{"event":"{{NotificationType}}","Metadata":{"title":"{{{Name}}}","grandparentTitle":"{{{SeriesName}}}","librarySectionType":"{{ItemType}}","guid":"imdb://{{Provider_imdb}}","Guid":[{"id":"imdb://{{Provider_imdb}}"}]}}'
CLEANUP_TEMPLATE_RAW='{"event":"{{NotificationType}}","itemId":"{{ItemId}}","name":"{{{Name}}}","seriesName":"{{{SeriesName}}}","itemType":"{{ItemType}}","path":"{{{Path}}}","imdbId":"{{Provider_imdb}}"}'

echo "=================================================================="
echo " Cine-Claw v2 — Setting up Jellyfin Webhooks (Priority & Cleanup) "
echo "=================================================================="

# 1. Verify system dependencies
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed."; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo "Error: unzip is required but not installed."; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "Error: base64 is required but not installed."; exit 1; }

# 2. Install Webhook plugin files
mkdir -p "$PLUGIN_DIR"
mkdir -p "$CONFIG_DIR"

if [[ ! -f "$PLUGIN_DIR/Jellyfin.Plugin.Webhook.dll" ]]; then
    echo "[1/4] Downloading Jellyfin Webhook plugin (v21.0.0.0)..."
    TMP_ZIP="/tmp/jellyfin_webhook_$$.zip"
    curl -fsSL -o "$TMP_ZIP" "$PLUGIN_ZIP_URL"
    echo "      Extracting to $PLUGIN_DIR..."
    unzip -qo "$TMP_ZIP" -d "$PLUGIN_DIR"
    rm -f "$TMP_ZIP"
    echo "      Plugin files successfully installed."
    NEED_RESTART=true
else
    echo "[1/4] Webhook plugin files already present in $PLUGIN_DIR."
    NEED_RESTART=false
fi

# 3. Compute Base64 representations of the templates
TEMPLATE_BASE64=$(printf "%s" "$TEMPLATE_RAW" | base64 | tr -d '\r\n')
CLEANUP_TEMPLATE_BASE64=$(printf "%s" "$CLEANUP_TEMPLATE_RAW" | base64 | tr -d '\r\n')

# 4. Generate persistent XML configuration
echo "[2/4] Writing configuration to $CONFIG_XML..."
cat <<EOF > "$CONFIG_XML"
<?xml version="1.0" encoding="utf-8"?>
<PluginConfiguration xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <ServerUrl>$JELLYFIN_URL</ServerUrl>
  <DiscordOptions />
  <GenericOptions>
    <GenericOption>
      <NotificationTypes>
        <NotificationType>PlaybackStart</NotificationType>
        <NotificationType>PlaybackProgress</NotificationType>
        <NotificationType>PlaybackStop</NotificationType>
      </NotificationTypes>
      <WebhookName>Tiramisu Priority Mode</WebhookName>
      <WebhookUri>$TIRAMISU_WEBHOOK_URL</WebhookUri>
      <EnableMovies>true</EnableMovies>
      <EnableEpisodes>true</EnableEpisodes>
      <EnableSeries>false</EnableSeries>
      <EnableSeasons>false</EnableSeasons>
      <EnableAlbums>false</EnableAlbums>
      <EnableSongs>false</EnableSongs>
      <EnableVideos>false</EnableVideos>
      <SendAllProperties>false</SendAllProperties>
      <TrimWhitespace>true</TrimWhitespace>
      <SkipEmptyMessageBody>false</SkipEmptyMessageBody>
      <EnableWebhook>true</EnableWebhook>
      <Template>$TEMPLATE_BASE64</Template>
      <UserFilter />
      <Headers>
        <GenericOptionValue>
          <Key>Content-Type</Key>
          <Value>application/json</Value>
        </GenericOptionValue>
      </Headers>
      <Fields />
    </GenericOption>
    <GenericOption>
      <NotificationTypes>
        <NotificationType>ItemDeleted</NotificationType>
      </NotificationTypes>
      <WebhookName>Cine-Claw Auto Cleanup</WebhookName>
      <WebhookUri>$CLEANUP_WEBHOOK_URL</WebhookUri>
      <EnableMovies>true</EnableMovies>
      <EnableEpisodes>true</EnableEpisodes>
      <EnableSeries>true</EnableSeries>
      <EnableSeasons>true</EnableSeasons>
      <EnableAlbums>false</EnableAlbums>
      <EnableSongs>false</EnableSongs>
      <EnableVideos>false</EnableVideos>
      <SendAllProperties>false</SendAllProperties>
      <TrimWhitespace>true</TrimWhitespace>
      <SkipEmptyMessageBody>false</SkipEmptyMessageBody>
      <EnableWebhook>true</EnableWebhook>
      <Template>$CLEANUP_TEMPLATE_BASE64</Template>
      <UserFilter />
      <Headers>
        <GenericOptionValue>
          <Key>Content-Type</Key>
          <Value>application/json</Value>
        </GenericOptionValue>
      </Headers>
      <Fields />
    </GenericOption>
  </GenericOptions>
  <GenericFormOptions />
  <GotifyOptions />
  <PushbulletOptions />
  <PushoverOptions />
  <SlackOptions />
  <SmtpOptions />
  <MqttOptions />
</PluginConfiguration>
EOF

echo "      Configuration XML written."

# 5. Check if Jellyfin container is running
echo "[3/4] Checking Jellyfin service status..."
if $COMPOSE_CMD ps 2>/dev/null | grep -i "jellyfin" | grep -q "Up"; then
    # Check if Webhook plugin is already active
    IS_ACTIVE=$(curl -s "$JELLYFIN_URL/Plugins" -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" 2>/dev/null | grep -i "Webhook" || true)

    if [[ -z "$IS_ACTIVE" || "$NEED_RESTART" == "true" ]]; then
        echo "      Restarting Jellyfin container to activate Webhook plugin..."
        $COMPOSE_CMD restart jellyfin
        
        echo -n "      Waiting for Jellyfin to become healthy..."
        for i in {1..30}; do
            if curl -s -f "$JELLYFIN_URL/health" >/dev/null 2>&1; then
                echo " ready!"
                break
            fi
            echo -n "."
            sleep 1
        done
    else
        echo "      Webhook plugin is already active in Jellyfin."
    fi

    # Hot-reload configuration via API to avoid needing another restart
    echo "      Pushing configuration to Jellyfin API..."
    API_PAYLOAD=$(cat <<JSON
{
  "ServerUrl": "$JELLYFIN_URL",
  "DiscordOptions": [],
  "GenericOptions": [
    {
      "WebhookName": "Tiramisu Priority Mode",
      "WebhookUri": "$TIRAMISU_WEBHOOK_URL",
      "EnableWebhook": true,
      "NotificationTypes": [
        "PlaybackStart",
        "PlaybackProgress",
        "PlaybackStop"
      ],
      "UserFilter": [],
      "EnableMovies": true,
      "EnableEpisodes": true,
      "EnableSeasons": false,
      "EnableSeries": false,
      "EnableAlbums": false,
      "EnableSongs": false,
      "EnableVideos": false,
      "SendAllProperties": false,
      "TrimWhitespace": true,
      "SkipEmptyMessageBody": false,
      "Template": "$TEMPLATE_BASE64",
      "Headers": [
        {
          "Key": "Content-Type",
          "Value": "application/json"
        }
      ],
      "Fields": []
    },
    {
      "WebhookName": "Cine-Claw Auto Cleanup",
      "WebhookUri": "$CLEANUP_WEBHOOK_URL",
      "EnableWebhook": true,
      "NotificationTypes": [
        "ItemDeleted"
      ],
      "UserFilter": [],
      "EnableMovies": true,
      "EnableEpisodes": true,
      "EnableSeasons": true,
      "EnableSeries": true,
      "EnableAlbums": false,
      "EnableSongs": false,
      "EnableVideos": false,
      "SendAllProperties": false,
      "TrimWhitespace": true,
      "SkipEmptyMessageBody": false,
      "Template": "$CLEANUP_TEMPLATE_BASE64",
      "Headers": [
        {
          "Key": "Content-Type",
          "Value": "application/json"
        }
      ],
      "Fields": []
    }
  ],
  "GenericFormOptions": [],
  "GotifyOptions": [],
  "PushbulletOptions": [],
  "PushoverOptions": [],
  "SlackOptions": [],
  "SmtpOptions": [],
  "MqttOptions": []
}
JSON
)

    curl -s -f -X POST "$JELLYFIN_URL/Plugins/$PLUGIN_GUID/Configuration" \
      -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" \
      -H "Content-Type: application/json" \
      -d "$API_PAYLOAD" >/dev/null
    echo "      Configuration successfully synced via API."
else
    echo "      Notice: Jellyfin container is not running. Configuration will take effect on next start."
fi

# 6. Verification
echo "[4/4] Verifying webhook integration..."
if curl -s "$JELLYFIN_URL/Plugins" -H "Authorization: MediaBrowser Token=\"$JELLYFIN_API_KEY\"" 2>/dev/null | grep -q "71552a5a5c5c4350a2aeebe451a30173"; then
    echo "      ✓ Jellyfin Webhook plugin: ACTIVE"
else
    echo "      ⚠ Warning: Webhook plugin not verified via API (check Jellyfin logs)."
fi

if curl -s -f "http://localhost:9080/metrics" >/dev/null 2>&1; then
    echo "      ✓ Tiramisu webhook receiver (:9080): REACHABLE"
else
    echo "      ⚠ Warning: Tiramisu port 9080 is not reachable on localhost."
fi

echo ""
echo "=================================================================="
echo " Setup complete! Playback in Jellyfin will now trigger Tiramisu"
echo " Priority Mode & Aggressive initial piece download automatically."
echo "=================================================================="
