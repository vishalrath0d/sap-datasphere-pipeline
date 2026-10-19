#!/usr/bin/env bash
# Installs the SAP Datasphere CLI (real mode only).
# The CLI follows Datasphere's release train (2026.21.0 = wave 2026.21) and needs Node 20-24 /
# npm 9-11 (SAP CLI guide 2.1 and the package's "engines"). Pin DS_CLI_VERSION and bump deliberately.
source "$(dirname "$0")/lib.sh"

if [ "$DS_MODE" = "mock" ]; then
  log "DS_MODE=mock - using the built-in simulator, nothing to install"
  python3 --version >&2
  exit 0
fi

command -v node >/dev/null || die "node is required (the CLI is an npm package)"
major="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$major" -lt 20 ] || [ "$major" -gt 24 ]; then
  msg="Node $(node -v) is outside the CLI's supported range 20-24 (the CLI warns and 'might not behave as expected')"
  if [ -n "${CI:-}" ]; then die "$msg - use a node:22 image"; else log "WARN: $msg"; fi
fi

version="${DS_CLI_VERSION:-2026.21.0}"
if command -v datasphere >/dev/null && [ "$(datasphere --version 2>/dev/null | head -n1)" = "$version" ]; then
  log "@sap/datasphere-cli $version already installed"
else
  log "installing @sap/datasphere-cli@$version"
  npm install -g --no-fund --no-audit "@sap/datasphere-cli@$version" >&2
fi
datasphere --version | head -n1
