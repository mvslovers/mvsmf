#!/usr/bin/env bash
set -e

echo "Creating default environment..."
[ -f .env ] || cp .env.example .env

echo "Loading environment..."
set -a
. ./.env
set +a

echo "Generating compile_commands.json..."
make compiledb

echo "Configuring Zowe profile..."

mkdir -p "$HOME/.zowe"
cat > "$HOME/.zowe/zowe.config.json" <<EOF
{
  "profiles": {
    "mvsmf": {
      "type": "zosmf",
      "properties": {
        "host": "${MVSMF_HOST}",
        "port": ${MVSMF_PORT},
        "protocol": "http",
        "user": "${MVSMF_USER}",
        "password": "${MVSMF_PASS}",
        "rejectUnauthorized": false
      }
    }
  },
  "defaults": {
    "zosmf": "mvsmf"
  }
}
EOF

echo "Setup complete."