#!/bin/sh
# Substitute QWENPAW_PORT in supervisord template and start supervisord.
# Default port 8088; override at runtime with -e QWENPAW_PORT=3000.
set -e

# Build policy reaches the actual mounted working directory through C6 boot.
# Persisted user choices and uninstall tombstones take precedence there.
export QWENPAW_CHANNEL_PRESET="${QWENPAW_CHANNEL_PRESET:-light}"

is_auth_enabled() {
  if [ "${QWENPAW_AUTH_ENABLED+x}" ]; then
    flag="${QWENPAW_AUTH_ENABLED}"
  else
    flag="${COPAW_AUTH_ENABLED:-}"
  fi
  flag="$(printf '%s' "$flag" | tr '[:upper:]' '[:lower:]')"
  [ "$flag" = "true" ] || [ "$flag" = "1" ] || [ "$flag" = "yes" ]
}

warn_if_auth_off_container_bind() {
  if is_auth_enabled; then
    return
  fi

  cat >&2 <<EOF
============================================================
SECURITY NOTICE: QwenPaw is running in Docker without authentication.

QwenPaw cannot verify whether access to the service is limited to a trusted
network. Anyone who can reach the service may access QwenPaw APIs without login.

Recommended:
  - Restrict access to a trusted network or protected environment.
  - Enable authentication with QWENPAW_AUTH_ENABLED=true if untrusted users or
    processes may reach the service.
============================================================
EOF
}

# Seed plugins baked into the image (deploy/Dockerfile.offline) into the
# effective working dir. The working dir may be a bind mount (/workspace in
# Hub mode) or a named volume, both of which hide image content, so copy each
# missing baked plugin on start. `.baked-plugins` remembers what we already
# handled: a plugin the user later uninstalls (or disables) stays that way,
# while plugins added by a newer image are still seeded. Images without
# /opt/qwenpaw-baked-plugins (e.g. the default deploy/Dockerfile) are unaffected.
seed_baked_plugins() {
  baked_dir="/opt/qwenpaw-baked-plugins"
  [ -d "$baked_dir" ] || return 0

  plugins_dir="${QWENPAW_WORKING_DIR:-/app/working}/plugins"
  marker="$plugins_dir/.baked-plugins"
  mkdir -p "$plugins_dir"

  for source in "$baked_dir"/*; do
    [ -d "$source" ] || continue
    [ -f "$source/plugin.json" ] || continue
    plugin_id="$(basename "$source")"

    if grep -qxF "$plugin_id" "$marker" 2>/dev/null; then
      continue
    fi

    target="$plugins_dir/$plugin_id"
    if [ ! -e "$target" ] && [ ! -e "$target.disabled" ]; then
      if ! cp -a "$source" "$target"; then
        echo "⚠️  Failed to seed baked plugin: ${plugin_id}" >&2
        continue
      fi
      echo "✓ Seeded baked plugin: ${plugin_id}"
    fi
    printf '%s\n' "$plugin_id" >> "$marker"
  done
}

seed_baked_plugins

# Auto-initialize if config.json is missing (bind mount with empty directory).
if [ ! -f "${QWENPAW_WORKING_DIR}/config.json" ]; then
  echo "⚠️  No config.json found in ${QWENPAW_WORKING_DIR}"
  echo "📦 Running initialization..."
  qwenpaw init --defaults --accept-security
  echo "✅ Initialization complete!"
else
  echo "✓ Config found in ${QWENPAW_WORKING_DIR}, skipping initialization."
fi

export QWENPAW_PORT="${QWENPAW_PORT:-8088}"
warn_if_auth_off_container_bind
envsubst '${QWENPAW_PORT}' \
  < /etc/supervisor/conf.d/supervisord.conf.template \
  > /etc/supervisor/conf.d/supervisord.conf
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
