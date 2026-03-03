#!/usr/bin/env bash
set -e

echo "Creating default environment..."
if [ ! -f .env ]; then
  cp .env.example .env
fi

echo "Loading environment..."
set -a
source .env
set +a

echo "Installing Zowe CLI..."
npm install -g @zowe/cli

echo "Generating compile_commands.json..."
make compiledb

echo "Configuring Zowe profile..."

if ! zowe config list profiles | grep -q mvsmf; then
  zowe config init --global-config

  zowe config set profiles.mvsmf.type=zosmf
  zowe config set profiles.mvsmf.properties.host="$MVSMF_HOST"
  zowe config set profiles.mvsmf.properties.port="$MVSMF_PORT"
  zowe config set profiles.mvsmf.properties.user="$MVSMF_USER"
  zowe config set profiles.mvsmf.properties.password="$MVSMF_PASS"
  zowe config set profiles.mvsmf.properties.rejectUnauthorized=false

  zowe config set defaults.zosmf=mvsmf
fi

echo "Setup complete."