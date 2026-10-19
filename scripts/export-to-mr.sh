#!/usr/bin/env bash
# After export.sh: if definitions/ changed, commit to a new branch and open a merge request,
# so every change made in the Datasphere UI goes through review before it can be promoted.
# Needs a GitLab project access token (role Developer, scope write_repository) in GL_PUSH_TOKEN.
#
# Usage: scripts/export-to-mr.sh <env>
source "$(dirname "$0")/lib.sh"

env="${1:?usage: export-to-mr.sh <env>}"
cd "$ROOT"

if [ -z "$(git status --porcelain -- definitions)" ]; then
  log "no differences between $env and Git - nothing to propose"
  exit 0
fi

: "${GL_PUSH_TOKEN:?set GL_PUSH_TOKEN (project access token with write_repository) as a masked CI/CD variable}"
: "${CI_SERVER_HOST:?must run inside GitLab CI}"
: "${CI_PROJECT_PATH:?must run inside GitLab CI}"
: "${CI_DEFAULT_BRANCH:?must run inside GitLab CI}"

branch="export/${env}-$(date -u +%Y%m%d-%H%M)"
git config user.name  "datasphere-export-bot"
git config user.email "datasphere-export-bot@noreply.invalid"
git checkout -b "$branch"
git add -- definitions
git commit -m "chore(export): sync definitions from $env ($(date -u +%F))"

git diff --stat HEAD~1 -- definitions >&2
log "pushing $branch and opening a merge request"
git push "https://oauth2:${GL_PUSH_TOKEN}@${CI_SERVER_HOST}/${CI_PROJECT_PATH}.git" "HEAD:refs/heads/${branch}" \
  -o merge_request.create \
  -o merge_request.target="$CI_DEFAULT_BRANCH" \
  -o merge_request.title="Sync definitions from $env ($(date -u +%F))" \
  -o merge_request.remove_source_branch
