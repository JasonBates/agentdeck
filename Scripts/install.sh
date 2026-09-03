#!/usr/bin/env bash
# Build, install to a stable path, sign, provision launchd, and reconcile the Herdr and
# Tailscale configuration that makes AgentDeck a complete machine-level installation.
# `--uninstall` removes the resources AgentDeck owns; `--dry-run` previews it.
#
# Signing is Developer ID when one is installed and ad-hoc otherwise. The difference only
# matters for Full Disk Access, which the optional Claude-quota feature needs so its
# `codexbar` subprocess can read Safari's cookie jar — a headless process without FDA
# fails with "No Claude session key found in browser cookies".
#
# TCC keys a grant to the binary's identity. Ad-hoc signing produces a new code hash on
# every build, so a rebuilt binary looks like a different program and the grant is
# silently dropped — Claude usage just goes stale with no error. Signing with a stable
# Developer ID keeps the identity constant across rebuilds, so the grant survives.
# Without one, re-grant FDA after each install.

set -euo pipefail

usage() {
    cat <<'USAGE'
usage: Scripts/install.sh [--uninstall] [--dry-run]

  (no flags)    build, sign, install, and reconcile launchd/Herdr/Tailscale
  --uninstall   remove the service, routes, and AgentDeck-owned Herdr config
  --dry-run     with --uninstall, print what would be removed and change nothing
USAGE
}

MODE=install
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --uninstall) MODE=uninstall ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_LABEL="com.agentdeck.bridge"
DEST="${AGENTDECK_DEST:-$HOME/.local/bin/agentdeck-bridge}"
LABEL="${AGENTDECK_LABEL:-$DEFAULT_LABEL}"
PLIST="${AGENTDECK_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LOG="${AGENTDECK_LOG:-$HOME/Library/Logs/agentdeck.log}"
SERVICE_PATH="${AGENTDECK_PATH:-$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
IDENTITY="${AGENTDECK_IDENTITY:-}"
PUBLIC_HOST="${AGENTDECK_PUBLIC_HOST:-}"
BRIDGE_PORT="${AGENTDECK_PORT:-9798}"
PUBLIC_PORT="${AGENTDECK_PUBLIC_PORT:-9797}"
PUBLIC_PATH="${AGENTDECK_PUBLIC_PATH:-/deck}"
HERDR_CONFIG="${AGENTDECK_HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}"
HERDR_MODE="${AGENTDECK_CONFIGURE_HERDR:-auto}"
TAILSCALE_MODE="${AGENTDECK_CONFIGURE_TAILSCALE:-auto}"
DOMAIN="gui/$(id -u)"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

die() {
    echo "error: $*" >&2
    exit 1
}

require() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Secondary test installs deliberately do not mutate the one machine-wide Herdr layout
# or production routes. Set an explicit on/off value to override that auto policy.
managed_mode_enabled() {
    local value="$1"
    # Keep this compatible with the Bash 3.2 that ships with macOS.
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        on|true|1) return 0 ;;
        off|false|0) return 1 ;;
        auto) [[ "$LABEL" == "$DEFAULT_LABEL" && "$BRIDGE_PORT" == "9798" ]] ;;
        *) die "expected on, off, or auto; got $value" ;;
    esac
}

reload_herdr_config() {
    if herdr server reload-config >/dev/null 2>&1; then
        echo "==> reloaded Herdr config"
    else
        echo "==> Herdr is not running; sidebar config will load on its next start"
    fi
}

# bootout returns before the old job has finished tearing down, and bootstrapping into a
# domain that still holds the label fails with "Input/output error" — which left
# production stopped, since bootout had already succeeded. Wait for the label to go.
bootout_and_wait() {
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
    launchctl bootout "$DOMAIN/$LABEL" || true
    for _ in $(seq 1 50); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    echo "warning: $LABEL is still loaded after bootout" >&2
}

if [[ "$MODE" == uninstall ]]; then
    prefix="==>"
    (( DRY_RUN )) && prefix="would"

    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "$prefix stop $LABEL"
        (( DRY_RUN )) || bootout_and_wait
    else
        echo "==> $LABEL is not loaded"
    fi

    for path in "$PLIST" "$DEST"; do
        if [[ -e "$path" ]]; then
            echo "$prefix remove $path"
            (( DRY_RUN )) || rm -f "$path"
        else
            echo "==> already absent: $path"
        fi
    done

    if managed_mode_enabled "$TAILSCALE_MODE"; then
        if (( DRY_RUN )); then
            echo "would remove Tailscale routes $PUBLIC_PATH and HTTPS port $PUBLIC_PORT"
        elif command -v tailscale >/dev/null 2>&1; then
            echo "==> removing Tailscale routes"
            tailscale serve --set-path="$PUBLIC_PATH" off >/dev/null 2>&1 || true
            tailscale serve --https="$PUBLIC_PORT" off >/dev/null 2>&1 || true
        fi
    fi

    if managed_mode_enabled "$HERDR_MODE"; then
        if (( DRY_RUN )); then
            echo "would remove AgentDeck's table from $HERDR_CONFIG"
        elif [[ -f "$HERDR_CONFIG" ]]; then
            require python3
            python3 "$REPO/Scripts/configure_herdr.py" remove --config "$HERDR_CONFIG"
            if command -v herdr >/dev/null 2>&1; then
                HERDR_CONFIG_PATH="$HERDR_CONFIG" herdr config check
                reload_herdr_config
            fi
        fi
    fi

    echo
    echo "Left in place: $LOG"
    echo "  Logs outlive the install deliberately — they are the only record of why a"
    echo "  bridge was misbehaving before it was removed."
    exit 0
fi

if managed_mode_enabled "$HERDR_MODE"; then
    require herdr
    require python3
    if [[ -f "$HERDR_CONFIG" ]]; then
        HERDR_CONFIG_PATH="$HERDR_CONFIG" herdr config check
    fi
fi
if managed_mode_enabled "$TAILSCALE_MODE"; then
    require tailscale
fi
require swift
require codesign
require security
require plutil
require launchctl
require curl

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/^[^"]*"\(Developer ID Application:.*\)".*$/\1/p' |
        head -n 1)"
fi

if [[ -z "$PUBLIC_HOST" ]] && command -v tailscale >/dev/null 2>&1; then
    PUBLIC_HOST="$(tailscale status --json 2>/dev/null |
        plutil -extract Self.DNSName raw -o - -- - 2>/dev/null |
        sed 's/\.$//' || true)"
fi
ADHOC=0
if [[ -z "$IDENTITY" ]]; then
    ADHOC=1
    echo "note: no Developer ID Application identity found; signing ad hoc."
    echo "      Everything works. Only the optional Claude-quota feature is affected:"
    echo "      its Full Disk Access grant must be renewed after each install."
fi

cd "$REPO"

echo "==> building release"
swift build -c release

echo "==> installing to $DEST"
mkdir -p "$(dirname "$DEST")"
# Copy to a temp name and move: overwriting a running binary in place fails with ETXTBSY.
cp .build/release/AgentDeckBridge "$DEST.new"
mv -f "$DEST.new" "$DEST"

echo "==> signing"
if (( ADHOC )); then
    codesign --force --sign - "$DEST"
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$DEST"
fi
codesign --verify --strict "$DEST"
codesign -dv "$DEST" 2>&1 | grep -E 'Authority=Developer ID|TeamIdentifier|Signature=adhoc' || true

echo "==> provisioning $PLIST"
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
PLIST_TEMP="$PLIST.new"
plutil -create xml1 "$PLIST_TEMP"
plutil -insert Label -string "$LABEL" "$PLIST_TEMP"
plutil -insert ProgramArguments -array "$PLIST_TEMP"
plutil -insert ProgramArguments.0 -string "$DEST" "$PLIST_TEMP"
plutil -insert EnvironmentVariables -dictionary "$PLIST_TEMP"
plutil -insert EnvironmentVariables.PATH -string "$SERVICE_PATH" "$PLIST_TEMP"
plutil -insert EnvironmentVariables.AGENTDECK_PORT -string "$BRIDGE_PORT" "$PLIST_TEMP"
# Persist runtime choices supplied to the installer. Otherwise an invocation such as
# `AGENTDECK_MODEL=off Scripts/install.sh` would affect the build shell but disappear
# when launchd starts the bridge.
for variable in \
    AGENTDECK_INTERVAL \
    AGENTDECK_MODEL \
    AGENTDECK_TITLE_MODEL \
    AGENTDECK_NAMES \
    AGENTDECK_TAB_TITLES \
    AGENTDECK_PUBLIC
do
    value="${!variable-}"
    if [[ -n "$value" ]]; then
        plutil -insert "EnvironmentVariables.$variable" -string "$value" "$PLIST_TEMP"
    fi
done
if [[ -n "$PUBLIC_HOST" ]]; then
    plutil -insert EnvironmentVariables.AGENTDECK_PUBLIC_HOST -string "$PUBLIC_HOST" "$PLIST_TEMP"
fi
# The bridge answers only for addresses it has been told about. AGENTDECK_PUBLIC_HOST
# covers the /deck path on 443; the dedicated HTTPS port is a distinct origin and is
# declared here, alongside anything the caller supplied.
ORIGINS="${AGENTDECK_ALLOWED_ORIGINS:-}"
if [[ -n "$PUBLIC_HOST" ]] && managed_mode_enabled "$TAILSCALE_MODE"; then
    ORIGINS="${ORIGINS:+$ORIGINS,}https://$PUBLIC_HOST:$PUBLIC_PORT"
fi
if [[ -n "$ORIGINS" ]]; then
    plutil -insert EnvironmentVariables.AGENTDECK_ALLOWED_ORIGINS -string "$ORIGINS" "$PLIST_TEMP"
fi
plutil -insert KeepAlive -bool YES "$PLIST_TEMP"
plutil -insert RunAtLoad -bool YES "$PLIST_TEMP"
plutil -insert ProcessType -string Background "$PLIST_TEMP"
plutil -insert StandardOutPath -string "$LOG" "$PLIST_TEMP"
plutil -insert StandardErrorPath -string "$LOG" "$PLIST_TEMP"
plutil -lint "$PLIST_TEMP"
mv -f "$PLIST_TEMP" "$PLIST"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "==> reloading launchd agent"
else
    echo "==> loading launchd agent"
fi
bootout_and_wait
launchctl bootstrap "$DOMAIN" "$PLIST"

ready=false
for _ in $(seq 1 50); do
    if curl -fsS "http://127.0.0.1:$BRIDGE_PORT/api/snapshot" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 0.2
done
[[ "$ready" == true ]] || die "bridge did not become ready on 127.0.0.1:$BRIDGE_PORT"

if managed_mode_enabled "$HERDR_MODE"; then
    echo "==> provisioning Herdr sidebar"
    python3 "$REPO/Scripts/configure_herdr.py" apply --config "$HERDR_CONFIG"
    HERDR_CONFIG_PATH="$HERDR_CONFIG" herdr config check
    reload_herdr_config
fi

if managed_mode_enabled "$TAILSCALE_MODE"; then
    echo "==> publishing through Tailscale Serve"
    tailscale serve --bg --https="$PUBLIC_PORT" "http://127.0.0.1:$BRIDGE_PORT" >/dev/null
    tailscale serve --bg --set-path="$PUBLIC_PATH" "http://127.0.0.1:$BRIDGE_PORT" >/dev/null
fi

echo
echo "Done. AgentDeck is listening on http://127.0.0.1:$BRIDGE_PORT"
if [[ -n "$PUBLIC_HOST" ]] && managed_mode_enabled "$TAILSCALE_MODE"; then
    echo "  https://$PUBLIC_HOST$PUBLIC_PATH"
    echo "  https://$PUBLIC_HOST:$PUBLIC_PORT/"
fi
echo "Claude quota in the footer is optional and needs Full Disk Access for:"
echo "  $DEST"
(( ADHOC )) && echo "  (ad-hoc signed: re-grant it after every install)"
exit 0
