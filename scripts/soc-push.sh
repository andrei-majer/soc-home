#!/usr/bin/env bash
# ============================================================================
# soc-push.sh — push this repo everywhere it needs to go, then verify.
#
# There are FOUR copies of this repo and they must not drift:
#   local (.13)  ->  origin (GitHub, private)
#                ->  forgejo (self-hosted on .15:2222)
#                ->  .20:/opt/soc-home  (the Ansible control node - what actually RUNS)
#
# Doing that by hand is three commands and it went wrong repeatedly on 2026-08-20:
# Forgejo was silently 3 commits behind because pushing to it is a separate step,
# and forgetting the control-node pull means .20 keeps converging STALE code.
#
# Failure policy is deliberately asymmetric:
#   * GitHub  = hard fail. It is the canonical remote.
#   * Forgejo = warn only. It lives on the .15 hypervisor, which reboots and has a
#               power schedule, so an unreachable mirror must not block a deploy.
#   * .20     = warn only, with a fallback: if the Forgejo pull is not possible we
#               push straight into /opt/soc-home, which has
#               receive.denyCurrentBranch=updateInstead and so updates its worktree.
#
# Usage:  bash scripts/soc-push.sh [branch]      (default: main)
# ============================================================================
set -uo pipefail

BRANCH="${1:-main}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1

# .20 rejects the Forgejo key this repo pins via core.sshCommand, so the direct
# push fallback needs the fleet key explicitly.
SOC20_SSH='ssh -i ~/.ssh/openwrt -o IdentitiesOnly=yes -o BatchMode=yes'

ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }

short() { git rev-parse --short "$1" 2>/dev/null || echo "-------"; }

echo "== soc-push: branch '$BRANCH' =="

# --- 0. refuse to deploy a half-finished tree -------------------------------
if [ -n "$(git status --porcelain)" ]; then
    fail "working tree is dirty - commit or stash first:"
    git status --short | sed 's/^/        /'
    exit 1
fi
LOCAL="$(short "$BRANCH")"
ok "local $BRANCH = $LOCAL (clean)"

# --- 1. GitHub (canonical - hard fail) --------------------------------------
# Show the output on failure: the pre-push hook rejects unparseable files, and a
# bare "FAIL" with the reason swallowed would be useless.
if out=$(git push origin "$BRANCH" 2>&1); then
    ok "pushed to origin (GitHub)"
else
    fail "push to origin (GitHub) failed - stopping, nothing else was attempted"
    echo "$out" | sed 's/^/        /'
    exit 1
fi

# --- 2. Forgejo mirror on .15 (soft) ----------------------------------------
FORGEJO_OK=0
if out=$(timeout 45 git push forgejo "$BRANCH" 2>&1); then
    ok "pushed to forgejo (.15)"
    FORGEJO_OK=1
else
    warn "push to forgejo (.15) failed - is the hypervisor up? Will deploy to .20 directly."
    echo "$out" | sed 's/^/        /' | head -4
fi

# --- 3. deploy to the control node ------------------------------------------
DEPLOYED=0
if [ "$FORGEJO_OK" -eq 1 ] && \
   timeout 60 ssh -o BatchMode=yes -o ConnectTimeout=15 s \
       "cd /opt/soc-home && git pull --ff-only --quiet" >/dev/null 2>&1; then
    ok "deployed to .20 (git pull from forgejo)"
    DEPLOYED=1
elif timeout 60 git -c core.sshCommand="$SOC20_SSH" push soc20 "$BRANCH" >/dev/null 2>&1; then
    ok "deployed to .20 (direct push fallback)"
    DEPLOYED=1
else
    warn "could not deploy to .20 - it will keep converging the PREVIOUS commit"
fi

# --- 4. verify all four actually agree --------------------------------------
echo "== verify =="
REMOTE_GH="$(git ls-remote origin "$BRANCH" 2>/dev/null | cut -c1-7)"
REMOTE_FJ="$(timeout 30 git ls-remote forgejo "$BRANCH" 2>/dev/null | cut -c1-7)"
REMOTE_20="$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=15 s \
             'cd /opt/soc-home && git rev-parse --short HEAD' 2>/dev/null)"

printf '  %-22s %s\n' "local"            "$LOCAL"
printf '  %-22s %s\n' "origin (GitHub)"  "${REMOTE_GH:-unreachable}"
printf '  %-22s %s\n' "forgejo (.15)"    "${REMOTE_FJ:-unreachable}"
printf '  %-22s %s\n' ".20 control node" "${REMOTE_20:-unreachable}"

RC=0
[ "$REMOTE_GH" = "$LOCAL" ] || { fail "GitHub is not at $LOCAL"; RC=1; }
[ "$REMOTE_FJ" = "$LOCAL" ] || { warn "forgejo is not at $LOCAL"; }
[ "$REMOTE_20" = "$LOCAL" ] || { warn ".20 is not at $LOCAL - converges would use stale code"; }

if [ "$RC" -eq 0 ] && [ "$DEPLOYED" -eq 1 ] && [ "$REMOTE_20" = "$LOCAL" ]; then
    echo "== all copies in sync =="
fi
exit "$RC"
