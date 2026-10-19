#!/usr/bin/env bash
# Locally, read .env (git-ignored) so no `source .env` is needed before `make ...`.
# (zsh's `source .env` would not export the variables to make or the scripts anyway.)
# Variables already set in the environment win; CI never reads it; DS_NO_DOTENV=1 skips it.
# Usage: source scripts/env.sh   (from any script; finds the repo root itself)
_ENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -z "${CI:-}" ] && [ "${DS_NO_DOTENV:-0}" != "1" ] && [ -f "$_ENV_ROOT/.env" ]; then
  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in ''|'#'*) continue ;; esac
    _key="${_line%%=*}"; _val="${_line#*=}"
    case "$_key" in *[!A-Za-z0-9_]*|'') continue ;; esac
    _val="${_val%\"}"; _val="${_val#\"}"
    if [ -z "${!_key+x}" ]; then export "$_key=$_val"; fi
  done <"$_ENV_ROOT/.env"
  unset _line _key _val
fi
unset _ENV_ROOT
