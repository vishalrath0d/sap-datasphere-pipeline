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
    case "$_val" in \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;; \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;; esac
    if [ -z "${!_key+x}" ]; then export "$_key=$_val"; fi
  done <"$_ENV_ROOT/.env"
  unset _line _key _val
fi
unset _ENV_ROOT

# ---- cross-platform helpers (macOS, Linux, Windows Git Bash) ----------------------------------
# Windows often has `python` or `py -3` instead of `python3`; every script calls python3.
if ! command -v python3 >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then python3() { python "$@"; }
  elif command -v py >/dev/null 2>&1; then python3() { py -3 "$@"; }
  fi
  if declare -F python3 >/dev/null; then export -f python3; fi   # visible to child scripts too
fi

# open_url URL - open a page in the default browser on any OS
open_url() {
  case "$(uname -s)" in
    Darwin) open "$1" ;;
    MINGW*|MSYS*|CYGWIN*) cmd.exe //c start "" "$1" ;;
    *) xdg-open "$1" >/dev/null 2>&1 ;;
  esac
}
