#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# agent-loop.sh — shipyard autonomous delivery loop (minimal, P1).
#
# Loop engineering, not "let the model decide": THIS script owns control flow.
# Each iteration takes ONE issue through a bounded pipeline with a FRESH agent
# session per step, and the merge gate is HARD signals first, agent judgement
# second (docs/PLAN.md §9).
#
#   pick todo issue → worktree+branch → DEV (Sonnet) → commit/push/PR
#   → fresh REVIEW (Opus by default) waits for green CI → hard-gate + approve
#   → squash-merge
#   → issue done. Failures re-inject as context (Ralph "pressure cooker").
#   Exhausted attempts/rounds → "blocked" + phone notification (escalation).
#
# STATUS MODEL
#   Project v2 configured: current Sprint iteration + Status are authoritative.
#   No board configured: issue labels remain the backward-compatible queue.
# Labels are still mirrored in Project mode so older automations keep working.
#
# Prereqs on the host: git, gh (authenticated), jq, and Claude Code (`claude`).
# Run from a repo initialised by shipyard. Drive it from your phone via Happy:
#   ./.project/loop/agent-loop.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

LOOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE="$REPO_ROOT/.project/state.json"

# shellcheck source=/dev/null
source "$LOOP_DIR/claude-invoke.sh"

# ── Config (overridable via env) ─────────────────────────────────────────────
: "${SHIPYARD_BASE:=develop}"                 # integration branch
: "${SHIPYARD_TODO_LABEL:=status:todo}"
: "${SHIPYARD_WIP_LABEL:=status:in-progress}"
: "${SHIPYARD_REVIEW_LABEL:=status:in-review}"
: "${SHIPYARD_BLOCKED_LABEL:=status:blocked}"
: "${SHIPYARD_REVIEW_MODEL:=opus}"           # T45 may use haiku to minimise quota
: "${SHIPYARD_PROJECT_LIMIT:=500}"

MAX_ITERS="$(jq -r '.loop.max_iterations_per_sprint // 50' "$STATE")"
MAX_ATTEMPTS="$(jq -r '.loop.max_attempts_per_issue // 3' "$STATE")"
MAX_REVIEW="$(jq -r '.loop.max_review_rounds // 3' "$STATE")"

# Worktree parallelism (P5.3): how many issues to process concurrently. Default 1
# = fully sequential (unchanged behaviour). Each issue already lives in its own
# worktree (.worktrees/issue-<n>) + branch feat/<n>, so they don't collide; the
# shared state.json, worktree creation, and PR merges are serialized with flock.
: "${SHIPYARD_PARALLELISM:=1}"

# ── Notifications (phone alerts via the bundled notifier or a custom command) ─
# Auto-use .project/loop/notify.sh when present and nothing else is configured, so
# escalations reach your phone without extra wiring (see docs/REMOTE.md).
if [ -z "${SHIPYARD_NOTIFY_CMD:-}" ] && [ -x "$LOOP_DIR/notify.sh" ]; then
    SHIPYARD_NOTIFY_CMD="$LOOP_DIR/notify.sh"
fi
shipyard_notify() {
    local msg; msg="$(printf '%s' "$1" | shipyard_redact)"
    echo "🔔 $msg"
    [ -n "${SHIPYARD_NOTIFY_CMD:-}" ] && "${SHIPYARD_NOTIFY_CMD}" "$msg" 2>/dev/null || true
}
log() { echo "── $*"; }

# ── state.json helpers (best-effort, atomic) ─────────────────────────────────
# All state mutations are serialized with flock (_with_lock, from claude-invoke.sh)
# so concurrent process_issue workers (SHIPYARD_PARALLELISM>1) can't lose updates.
# NB: the *_unlocked bodies must never call another locked helper — nesting the
# same lock file would self-deadlock flock. Each locked helper is self-contained.
_state_set() { _with_lock "${STATE}.lock" _state_set_unlocked "$1"; }
_state_set_unlocked() {   # _state_set_unlocked <jq-expression>
    local tmp="$STATE.tmp.$$"
    jq "$1" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
set_current_issue() { _state_set ".loop.current_issue=${1:-null} | .loop.status=\"running\""; }
bump_attempt() { _with_lock "${STATE}.lock" _bump_attempt_unlocked "$1"; }  # echoes new count
_bump_attempt_unlocked() {
    local n="$1" cur tmp="$STATE.tmp.$$"
    cur="$(jq -r ".loop.attempts[\"$n\"] // 0" "$STATE")"
    cur=$((cur + 1))
    jq ".loop.attempts[\"$n\"]=$cur" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
    echo "$cur"
}
# Record a structured blocker (issue + kind + human-readable cause + the exact
# command the human should run). Uses --arg so reason/remediation can contain any
# characters. Keeps escalated_issues (numbers) for backward-compat.
_record_blocker() { _with_lock "${STATE}.lock" _record_blocker_unlocked "$@"; }
_record_blocker_unlocked() {  # _record_blocker <issue> <kind> <reason> <remediation>
    local n="$1" kind="$2" reason="$3" rem="$4" tmp="$STATE.tmp.$$"
    jq --argjson n "$n" --arg k "$kind" --arg r "$reason" --arg m "$rem" \
       '.loop.escalated_issues += [$n] | .loop.status="blocked"
        | .loop.blockers = ((.loop.blockers // []) + [{issue:$n,kind:$k,reason:$r,remediation:$m}])' \
       "$STATE" >"$tmp" 2>/dev/null && mv "$tmp" "$STATE" || rm -f "$tmp"
}

# Map an error blob to (reason, remediation). This is what turns an opaque
# "blocked" into "here is the exact command YOU need to run". Fields are joined
# with a unit-separator (0x1f) so neither can be split accidentally.
classify_blocker() {  # classify_blocker <text>  → "reason<US>remediation"
    local t="$1" reason rem
    if grep -qiE 'required scopes|missing.*scope|read:project|project.*scope|gh auth refresh' <<<"$t"; then
        reason="le jeton GitHub n'a pas le scope requis (ex. Projects v2)"
        rem="gh auth refresh -s project -s read:project"
    elif grep -qiE 'protected branch|branch protection|required status check|not allowed to push|GH006' <<<"$t"; then
        reason="une règle de protection de branche bloque le push/merge sur $SHIPYARD_BASE"
        rem="ajuste la protection de la branche $SHIPYARD_BASE (Settings → Branches) puis remets le label $SHIPYARD_TODO_LABEL"
    elif grep -qiE 'HTTP 40[13]|forbidden|not authorized|must have admin|permission|insufficient' <<<"$t"; then
        reason="permissions GitHub insuffisantes (droits repo / environnement)"
        rem="vérifie tes droits sur le repo, puis: gh auth status  (et gh auth refresh si besoin)"
    elif grep -qiE 'secret|credential|unauthorized|HTTP 401|token .* (not set|invalid)|env(ironment)? var' <<<"$t"; then
        reason="un secret / identifiant est manquant ou invalide"
        rem="ajoute le secret manquant (ex. gh secret set <NOM>) puis remets le label $SHIPYARD_TODO_LABEL"
    else
        reason="blocage non catégorisé (voir logs de la boucle)"
        rem="inspecte la PR/issue et les logs, corrige, puis remets le label $SHIPYARD_TODO_LABEL"
    fi
    printf '%s\x1f%s' "$reason" "$rem"
}

# Unified escalation: label → blocked, record the structured blocker, COMMENT on
# the issue with the exact remediation command, and notify. One place, so every
# dead-end tells the human precisely what to do.
escalate() {  # escalate <issue> <kind> <reason> <remediation> [from-label]
    local n="$1" kind="$2" reason="$3" rem="$4" from="${5:-$SHIPYARD_WIP_LABEL}"
    reason="$(printf '%s' "$reason" | shipyard_redact)"
    rem="$(printf '%s' "$rem" | shipyard_redact)"
    set_status "$n" "$from" "$SHIPYARD_BLOCKED_LABEL"
    _record_blocker "$n" "$kind" "$reason" "$rem"
    local body
    body="$(printf '🚧 **Besoin humain — la boucle est en pause sur cette issue**\n\n- **Type** : %s\n- **Cause** : %s\n- **Action à lancer par toi** :\n\n```bash\n%s\n```\n\nQuand c'\''est réglé, remets le label `%s` sur cette issue pour relancer la boucle.' \
        "$kind" "$reason" "$rem" "$SHIPYARD_TODO_LABEL")"
    gh issue comment "$n" --body "$body" >/dev/null 2>&1 || true
    [ -n "${RUN_LEDGER:-}" ] && printf 'escalated\t%s\t%s\t%s\n' "$n" "$kind" "$reason" >>"$RUN_LEDGER" 2>/dev/null || true
    shipyard_notify "🚧 Issue #$n bloquée ($kind) — à lancer: $rem"
}

# ── Label / Project v2 helpers ───────────────────────────────────────────────
# Project mode is enabled by state.json.loop.board_id. The repository owner is
# the default board owner; loop.board_owner can override it for cross-owner boards.
PROJECT_ENABLED=0
PROJECT_NUMBER=""
PROJECT_OWNER=""
PROJECT_ID=""
PROJECT_STATUS_FIELD=""
PROJECT_SPRINT_FIELD=""
PROJECT_FIELDS=""
PROJECT_ITERATIONS=""

project_items() {
    gh project item-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" \
        --format json --limit "$SHIPYARD_PROJECT_LIMIT" 2>/dev/null
}

project_set_current_iteration() { # <iteration-json> <ordinal>
    local value="$1" ordinal="$2" id title start duration tmp="$STATE.tmp.$$"
    id="$(jq -r '.id' <<<"$value")"; title="$(jq -r '.title' <<<"$value")"
    start="$(jq -r '.startDate' <<<"$value")"; duration="$(jq -r '.duration' <<<"$value")"
    jq --arg id "$id" --arg title "$title" --arg start "$start" --argjson duration "$duration" \
       --argjson sprint "$ordinal" \
       '.loop.current_iteration={id:$id,title:$title,start_date:$start,duration:$duration}
        | .current_sprint=$sprint' "$STATE" >"$tmp" && mv "$tmp" "$STATE"
    log "project sprint selected: $title ($start, ${duration}d)"
}

project_iteration_has_todo() { # <title>
    local title="$1" slug
    slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    project_items | jq -e --arg sprint "$title" --arg slug "$slug" '
      any(.items[]?;
        .content.type == "Issue" and .content.repository == $slug and
        .status == "Todo" and ((.sprint.title // .sprint) == $sprint))' >/dev/null 2>&1
}

project_init() {
    PROJECT_NUMBER="$(jq -r '.loop.board_id // empty' "$STATE")"
    [ -n "$PROJECT_NUMBER" ] || return 0
    PROJECT_OWNER="$(jq -r '.loop.board_owner // empty' "$STATE")"
    [ -n "$PROJECT_OWNER" ] || PROJECT_OWNER="$(gh repo view --json owner --jq .owner.login 2>/dev/null || true)"
    [ -n "$PROJECT_OWNER" ] || { log "Project v2: cannot resolve board owner"; return 1; }
    PROJECT_ID="$(gh project view "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --jq .id 2>/dev/null || true)"
    [ -n "$PROJECT_ID" ] || { log "Project v2 #$PROJECT_NUMBER is unavailable (check project/read:project scopes)"; return 1; }
    PROJECT_FIELDS="$(gh project field-list "$PROJECT_NUMBER" --owner "$PROJECT_OWNER" --format json --limit 100 2>/dev/null || true)"
    PROJECT_STATUS_FIELD="$(jq -r '.fields[]? | select(.name=="Status") | .id' <<<"$PROJECT_FIELDS" | head -1)"
    PROJECT_SPRINT_FIELD="$(jq -r '.fields[]? | select(.name=="Sprint") | .id' <<<"$PROJECT_FIELDS" | head -1)"
    [ -n "$PROJECT_STATUS_FIELD" ] && [ -n "$PROJECT_SPRINT_FIELD" ] || {
        log "Project v2 requires the Status and Sprint fields"; return 1; }
    PROJECT_ITERATIONS="$(gh api graphql -f query='query($id:ID!){node(id:$id){... on ProjectV2{field(name:"Sprint"){... on ProjectV2IterationField{configuration{iterations{id title startDate duration} completedIterations{id title startDate duration}}}}}}}' \
        -f id="$PROJECT_ID" --jq '.data.node.field.configuration | [.completedIterations[],.iterations[]] | unique_by(.id) | sort_by(.startDate)' 2>/dev/null || true)"
    [ "$(jq -r 'length' <<<"${PROJECT_ITERATIONS:-[]}" 2>/dev/null || echo 0)" -gt 0 ] || {
        log "Project v2 Sprint field has no iterations"; return 1; }
    PROJECT_ENABLED=1

    local saved today selected ordinal=1 row i=0
    saved="$(jq -r '.loop.current_iteration.id // empty' "$STATE")"
    today="$(date +%F)"
    selected="$(jq -c --arg id "$saved" 'if $id=="" then empty else .[] | select(.id==$id) end' <<<"$PROJECT_ITERATIONS" | head -1)"
    if [ -z "$selected" ]; then
        selected="$(jq -c --arg today "$today" '.[] | select(.startDate <= $today) | select(((.startDate | strptime("%Y-%m-%d") | mktime) + (.duration*86400)) > ($today | strptime("%Y-%m-%d") | mktime))' <<<"$PROJECT_ITERATIONS" 2>/dev/null | head -1)"
    fi
    if [ -z "$selected" ]; then
        while IFS= read -r row; do
            if project_iteration_has_todo "$(jq -r .title <<<"$row")"; then selected="$row"; break; fi
        done < <(jq -c '.[]' <<<"$PROJECT_ITERATIONS")
    fi
    [ -n "$selected" ] || selected="$(jq -c '.[0]' <<<"$PROJECT_ITERATIONS")"
    while IFS= read -r row; do
        i=$((i + 1)); [ "$(jq -r .id <<<"$row")" = "$(jq -r .id <<<"$selected")" ] && { ordinal="$i"; break; }
    done < <(jq -c '.[]' <<<"$PROJECT_ITERATIONS")
    project_set_current_iteration "$selected" "$ordinal"
}

project_item_id() { # <issue>
    local n="$1" slug
    slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    project_items | jq -r --argjson n "$n" --arg slug "$slug" \
      '.items[]? | select(.content.type=="Issue" and .content.number==$n and .content.repository==$slug) | .id' | head -1
}

project_set_status() { # <issue> <Todo|In Progress|In Review|Done|Blocked>
    [ "$PROJECT_ENABLED" = 1 ] || return 0
    local n="$1" target="$2" item option
    item="$(project_item_id "$n")"
    option="$(jq -r --arg name "$target" '.fields[]? | select(.name=="Status") | .options[]? | select(.name==$name) | .id' <<<"$PROJECT_FIELDS" | head -1)"
    [ -n "$item" ] && [ -n "$option" ] || { log "Project v2: cannot set #$n to '$target'"; return 1; }
    gh project item-edit --id "$item" --project-id "$PROJECT_ID" --field-id "$PROJECT_STATUS_FIELD" \
        --single-select-option-id "$option" >/dev/null 2>&1
}

project_advance_if_drained() {
    [ "$PROJECT_ENABLED" = 1 ] || return 1
    local current current_pos next row pos=0
    current="$(jq -r '.loop.current_iteration.id // empty' "$STATE")"
    current_pos="$(jq -r --arg id "$current" 'to_entries[] | select(.value.id==$id) | .key' <<<"$PROJECT_ITERATIONS" | head -1)"
    [ -n "$current_pos" ] || return 1
    while IFS= read -r row; do
        pos=$((pos + 1))
        [ "$pos" -le "$((current_pos + 1))" ] && continue
        if project_iteration_has_todo "$(jq -r .title <<<"$row")"; then
            next="$row"
            project_set_current_iteration "$next" "$pos"
            shipyard_notify "⏭️ Sprint suivant prêt — $(jq -r .title <<<"$next")"
            return 0
        fi
    done < <(jq -c '.[]' <<<"$PROJECT_ITERATIONS")
    log "project sprint drained — no later Sprint with Todo items"
    return 1
}

set_status() {  # set_status <issue> <remove-label> <add-label>
    local n="$1" rm="$2" add="$3"
    gh issue edit "$n" --remove-label "$rm" --add-label "$add" >/dev/null 2>&1 || \
        gh issue edit "$n" --add-label "$add" >/dev/null 2>&1 || true
    case "$add" in
        "$SHIPYARD_TODO_LABEL")    project_set_status "$n" "Todo" || true ;;
        "$SHIPYARD_WIP_LABEL")     project_set_status "$n" "In Progress" || true ;;
        "$SHIPYARD_REVIEW_LABEL")  project_set_status "$n" "In Review" || true ;;
        "$SHIPYARD_BLOCKED_LABEL") project_set_status "$n" "Blocked" || true ;;
    esac
}

next_todo_issue() {  # echoes the next issue number, or empty
    if [ "$PROJECT_ENABLED" = 1 ]; then
        local sprint slug
        sprint="$(jq -r '.loop.current_iteration.title // empty' "$STATE")"
        slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
        project_items | jq -r --arg sprint "$sprint" --arg slug "$slug" '
          [.items[]? | select(.content.type=="Issue" and .content.repository==$slug and
            .status=="Todo" and ((.sprint.title // .sprint)==$sprint)) | .content.number] | sort | .[0] // empty'
        return
    fi
    gh issue list --state open --label "$SHIPYARD_TODO_LABEL" \
        --json number --jq 'sort_by(.number) | .[0].number // empty' 2>/dev/null
}

loop_is_paused() {
    jq -e '.loop.status == "paused"' "$STATE" >/dev/null 2>&1
}

# Stable stack knowledge, injected into every agent prompt so the model doesn't
# rediscover the toolchain each fresh session. Reads .stack_profile from state.json;
# emits nothing when absent (backward-compatible with minimal state files).
stack_context() {
    [ -f "$STATE" ] || return 0
    jq -r '
      .stack_profile // empty
      | [ "## Stack du projet (contexte stable — ne pas redécouvrir)",
          (if (.languages // []) | length > 0 then "- Langages : " + (.languages | join(", ")) else empty end),
          (if .package_manager then "- Gestionnaire de paquets : " + .package_manager else empty end),
          ((.commands // {}) | to_entries
             | map(select(.value != null and .value != ""))
             | map("- commande `" + .key + "` : `" + .value + "`") | .[]),
          (if .notes then "- Notes : " + .notes else empty end)
        ]
      | map(select(. != null)) | join("\n")
    ' "$STATE" 2>/dev/null
}

# ── Build a prompt file from a template + runtime context ────────────────────
render_prompt() {  # render_prompt <template> <context-file> → path to a temp prompt
    local tpl="$1" ctx="$2" out sc
    out="$(mktemp)"
    cat "$tpl" >"$out"
    sc="$(stack_context)"
    if [ -n "$sc" ]; then
        printf '\n\n---\n%s\n' "$sc" >>"$out"
    fi
    printf '\n\n---\n# Contexte de la tâche\n\n' >>"$out"
    cat "$ctx" >>"$out"
    echo "$out"
}

# Hard gate on CI. Returns 0 only when every check has completed and passed.
# Crucially, it WAITS for checks to register on a brand-new PR (they don't appear
# instantly) instead of treating "no checks reported yet" as a failure — that race
# otherwise burns a wasted review/fix round. Times out to "not green" after ~5 min.
: "${SHIPYARD_CI_TIMEOUT:=300}"   # seconds
ci_is_green() {
    local pr="$1" waited=0 out rc
    while [ "$waited" -lt "$SHIPYARD_CI_TIMEOUT" ]; do
        out="$(gh pr checks "$pr" 2>&1)"; rc=$?
        if grep -qiE 'no checks reported|no checks found' <<<"$out"; then
            sleep 8; waited=$((waited + 8)); continue      # not registered yet → wait
        fi
        case "$rc" in
            0) return 0 ;;                                  # all checks passed
            8) sleep 8; waited=$((waited + 8)); continue ;; # pending → wait
            *) return 1 ;;                                  # a check failed
        esac
    done
    log "PR #$pr — CI gate timed out after ${SHIPYARD_CI_TIMEOUT}s"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Process a single issue end to end. Returns 0 on merge, 1 on escalation/failure.
# ─────────────────────────────────────────────────────────────────────────────
process_issue() {
    local n="$1"
    local branch="feat/${n}"
    local wt="$REPO_ROOT/.worktrees/issue-${n}"

    set_current_issue "$n"
    local attempt; attempt="$(bump_attempt "$n")"
    if [ "$attempt" -gt "$MAX_ATTEMPTS" ]; then
        log "issue #$n exceeded max attempts ($MAX_ATTEMPTS) → escalate"
        escalate "$n" "max-attempts" \
            "l'issue a été retentée $MAX_ATTEMPTS fois sans aboutir" \
            "inspecte l'issue et la dernière PR ; précise ou scinde la spec, puis remets le label $SHIPYARD_TODO_LABEL"
        return 1
    fi

    log "issue #$n — attempt $attempt/$MAX_ATTEMPTS"
    set_status "$n" "$SHIPYARD_TODO_LABEL" "$SHIPYARD_WIP_LABEL"

    # Fresh worktree off the latest base branch. Serialized: concurrent workers
    # touching the shared .git (worktree registry + ref creation) can race.
    _setup_worktree() {
        git fetch --quiet origin "$SHIPYARD_BASE" || true
        rm -rf "$wt"
        git worktree remove --force "$wt" 2>/dev/null || true
        git worktree add -B "$branch" "$wt" "origin/$SHIPYARD_BASE" >/dev/null 2>&1 \
            || git worktree add -B "$branch" "$wt" >/dev/null
    }
    _with_lock "$REPO_ROOT/.project/.git.lock" _setup_worktree

    # Issue context (goal + acceptance criteria live in the issue body).
    local ctx; ctx="$(mktemp)"
    gh issue view "$n" --json number,title,body,labels \
        --template '## Issue #{{.number}} — {{.title}}

{{.body}}

Labels: {{range .labels}}{{.name}} {{end}}' >"$ctx" 2>/dev/null || echo "Issue #$n" >"$ctx"

    # ── DEV step (Sonnet, fresh context) ─────────────────────────────────────
    local dev_prompt dev_out commit_msg dev_capture
    dev_prompt="$(render_prompt "$LOOP_DIR/prompt-dev.md" "$ctx")"
    dev_capture="$(mktemp)"
    if ! (
        cd "$wt"
        claude_invoke sonnet "$dev_prompt" | shipyard_redact >"$dev_capture"
    ); then
        rm -f "$dev_capture"
        log "dev session failed for #$n"
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
            git worktree remove --force "$wt" 2>/dev/null || true
            escalate "$n" "max-attempts" \
                "la session de développement a échoué $attempt fois" \
                "inspecte les logs et l'issue, corrige la cause, puis remets le label $SHIPYARD_TODO_LABEL"
        fi
        return 1
    fi
    dev_out="$(<"$dev_capture")"
    rm -f "$dev_capture"

    # The agent can raise a non-code blocker it cannot resolve itself (a missing
    # secret/token, a permission, an external service): it emits NEEDS-HUMAN: … .
    # We escalate with that message instead of committing empty work.
    if grep -q '^NEEDS-HUMAN:' <<<"$dev_out"; then
        local need; need="$(grep -m1 '^NEEDS-HUMAN:' <<<"$dev_out" | sed 's/^NEEDS-HUMAN:[[:space:]]*//')"
        log "issue #$n — dev signaled a human-blocking dependency"
        git worktree remove --force "$wt" 2>/dev/null || true
        escalate "$n" "needs-human" "$need" \
            "règle le point ci-dessus (voir le commentaire), puis remets le label $SHIPYARD_TODO_LABEL"
        return 1
    fi

    commit_msg="$(grep -m1 '^COMMIT:' <<<"$dev_out" | sed 's/^COMMIT:[[:space:]]*//')"
    [ -z "$commit_msg" ] && commit_msg="feat: address issue #$n"
    commit_msg="$(printf '%s' "$commit_msg" | shipyard_redact)"

    # Orchestrator owns git (deterministic). Capture output so a push/auth failure
    # is classified into an actionable blocker, distinct from "nothing produced".
    local gitout
    gitout="$( cd "$wt" && {
        git add -A
        if git diff --cached --quiet; then echo '__NOCHANGES__'; exit 42; fi
        git commit -q -m "$commit_msg" -m "Closes #$n"
        git push -q -u origin "$branch" --force-with-lease
      } 2>&1 )" || {
        if grep -q '__NOCHANGES__' <<<"$gitout"; then
            log "no changes produced for #$n → escalate"
            git worktree remove --force "$wt" 2>/dev/null || true
            escalate "$n" "no-output" \
                "l'agent n'a produit aucun changement de fichier" \
                "inspecte l'issue (spec trop vague ?) puis remets le label $SHIPYARD_TODO_LABEL"
        else
            log "commit/push failed for #$n → escalate"
            local cb reason rem; cb="$(classify_blocker "$gitout")"
            reason="${cb%%$'\x1f'*}"; rem="${cb#*$'\x1f'}"
            escalate "$n" "push-failed" "$reason" "$rem"
        fi
        return 1; }

    # ── Open (or reuse) the PR against the integration branch ────────────────
    local pr
    pr="$(gh pr list --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null)"
    local prout=""
    if [ -z "$pr" ]; then
        prout="$(gh pr create --base "$SHIPYARD_BASE" --head "$branch" \
            --title "$commit_msg" --body "Automated by shipyard loop. Closes #$n." 2>&1)" || true
        pr="$(gh pr list --head "$branch" --json number --jq '.[0].number // empty' 2>/dev/null)"
    fi
    if [ -z "$pr" ]; then
        log "could not open PR for #$n → escalate"
        local cb reason rem; cb="$(classify_blocker "$prout")"
        reason="${cb%%$'\x1f'*}"; rem="${cb#*$'\x1f'}"
        escalate "$n" "pr-failed" "$reason" "$rem"
        return 1
    fi
    set_status "$n" "$SHIPYARD_WIP_LABEL" "$SHIPYARD_REVIEW_LABEL"
    shipyard_notify "📤 PR #$pr ouverte pour l'issue #$n"

    # ── REVIEW loop: HARD gate (CI) first, agent judgement second ────────────
    local round=0 verdict review_out review_ctx review_prompt
    while [ "$round" -lt "$MAX_REVIEW" ]; do
        round=$((round + 1))

        # Hard gate: objective signals. Waits for checks to register + complete.
        if ! ci_is_green "$pr"; then
            log "PR #$pr — CI not green (round $round)"
            verdict="request-changes"
            review_out="La CI n'est pas verte. Corrige les échecs (tests, lint, Trivy)."
        else
            # Fresh reviewer session — judges acceptance criteria only. Opus remains
            # the production default; bounded E2E fixtures may select Haiku explicitly.
            review_ctx="$(mktemp)"
            { cat "$ctx"
              echo; echo "## Diff de la PR #$pr"; echo
              gh pr diff "$pr" 2>/dev/null | head -c 60000
            } >"$review_ctx"
            review_prompt="$(render_prompt "$LOOP_DIR/prompt-review.md" "$review_ctx")"
            review_out="$(claude_invoke "$SHIPYARD_REVIEW_MODEL" "$review_prompt")" || { log "review failed #$pr"; break; }
            verdict="$(grep -m1 '^VERDICT:' <<<"$review_out" | sed 's/^VERDICT:[[:space:]]*//' | tr 'A-Z' 'a-z')"
        fi

        if [ "$verdict" = "approve" ]; then
            # Serialize merges: two PRs merging into the same base at once can trip
            # "base out of date" / branch-protection races. One at a time is safe.
            # `gh pr merge --delete-branch` can report a non-zero exit after the
            # server has already merged the PR (for example when local/remote branch
            # cleanup races with branch protection). Reconcile with authoritative
            # server state before turning a successful delivery into an escalation.
            _pr_is_merged() {
                [ "$(gh pr view "$pr" --json state --jq .state 2>/dev/null || true)" = "MERGED" ]
            }
            _do_merge() {
                gh pr merge "$pr" --squash --delete-branch >/dev/null 2>&1 && return 0
                _pr_is_merged && return 0
                gh pr merge "$pr" --squash >/dev/null 2>&1 && return 0
                _pr_is_merged
            }
            _with_lock "$REPO_ROOT/.project/.merge.lock" _do_merge \
                || { log "merge failed for PR #$pr"; break; }
            git worktree remove --force "$wt" 2>/dev/null || true
            project_set_status "$n" "Done" || true
            gh issue edit "$n" --remove-label "$SHIPYARD_REVIEW_LABEL" >/dev/null 2>&1 || true
            gh issue close "$n" --reason completed >/dev/null 2>&1 || true
            log "issue #$n merged via PR #$pr ✅"
            [ -n "${RUN_LEDGER:-}" ] && printf 'merged\t%s\t%s\t%s\n' "$n" "$pr" "$round" >>"$RUN_LEDGER" 2>/dev/null || true
            shipyard_notify "✅ Issue #$n mergée (PR #$pr)"
            return 0
        fi

        # request-changes → re-inject failures as context and fix (pressure cooker)
        log "PR #$pr — request-changes (round $round/$MAX_REVIEW), fixing"
        local fix_ctx fix_prompt fix_out fix_capture
        fix_ctx="$(mktemp)"
        { cat "$ctx"; echo; echo "## Retour de review à corriger"; echo; echo "$review_out"; } >"$fix_ctx"
        fix_prompt="$(render_prompt "$LOOP_DIR/prompt-dev.md" "$fix_ctx")"
        fix_capture="$(mktemp)"
        ( cd "$wt"; claude_invoke sonnet "$fix_prompt" | shipyard_redact >"$fix_capture" ) \
            || { rm -f "$fix_capture"; log "fix session failed #$n"; break; }
        fix_out="$(<"$fix_capture")"
        rm -f "$fix_capture"
        # A human-blocking dependency can surface during a fix round too.
        if grep -q '^NEEDS-HUMAN:' <<<"$fix_out"; then
            local need2; need2="$(grep -m1 '^NEEDS-HUMAN:' <<<"$fix_out" | sed 's/^NEEDS-HUMAN:[[:space:]]*//')"
            log "issue #$n — fix step signaled a human-blocking dependency"
            git worktree remove --force "$wt" 2>/dev/null || true
            escalate "$n" "needs-human" "$need2" \
                "règle le point ci-dessus puis remets le label $SHIPYARD_TODO_LABEL" "$SHIPYARD_REVIEW_LABEL"
            return 1
        fi
        ( cd "$wt"
          fixmsg="$(grep -m1 '^COMMIT:' <<<"$fix_out" | sed 's/^COMMIT:[[:space:]]*//')"
          git add -A
          git diff --cached --quiet || git commit -q -m "${fixmsg:-fix: address review on #$n}"
          git push -q origin "$branch" --force-with-lease
        ) || { log "fix push failed #$n"; break; }
    done

    # Review budget exhausted → escalate (actionable).
    escalate "$n" "review-exhausted" \
        "la PR #$pr n'a pas été validée après $MAX_REVIEW tours de review" \
        "relis la PR #$pr et ses commentaires, corrige à la main si besoin, puis remets le label $SHIPYARD_TODO_LABEL" \
        "$SHIPYARD_REVIEW_LABEL"
    return 1
}

# ── Sprint retrospective (auto, end of a drained sprint) ─────────────────────
# Where the retro file lives: the vault's sprints dir in vault mode, else the
# repo's .project/sprints. Mirrors render-templates.sh path resolution.
retro_dir() {
    local vp; vp="$(jq -r '.vault_project_path // ""' "$STATE" 2>/dev/null || true)"
    if [ -n "$vp" ] && [ "$vp" != "null" ]; then echo "$vp/sprints"; else echo "$REPO_ROOT/.project/sprints"; fi
}

# Generate a retrospective from the run LEDGER. Facts are computed here
# (deterministic, authoritative); the qualitative analysis is a fresh, cheap
# agent session grounded strictly in those facts. Writes a markdown file and —
# for async phone review — opens a GitHub issue (idempotent per sprint). Fully
# best-effort: never fails the loop. Disable with SHIPYARD_RETRO=0; file-only
# with SHIPYARD_RETRO_ISSUE=0; model via SHIPYARD_RETRO_MODEL (default haiku).
sprint_retrospective() {
    [ -f "${RUN_LEDGER:-}" ] || return 0
    local merged_ct esc_ct sprint_no today dir file facts prompt prose pend
    merged_ct="$(grep -c '^merged' "$RUN_LEDGER" || true)";       merged_ct="${merged_ct:-0}"
    esc_ct="$(grep -c '^escalated' "$RUN_LEDGER" || true)";       esc_ct="${esc_ct:-0}"
    [ "$merged_ct" -eq 0 ] && [ "$esc_ct" -eq 0 ] && return 0     # nothing worth a retro

    sprint_no="$(jq -r '.current_sprint // 1' "$STATE" 2>/dev/null || echo 1)"
    today="$(date +%F 2>/dev/null || echo '')"
    dir="$(retro_dir)"; mkdir -p "$dir" 2>/dev/null || true
    file="$dir/retro-sprint-$(printf '%03d' "$sprint_no" 2>/dev/null || echo "$sprint_no").md"
    pend="$(jq -r '(.loop.blockers // []) | length' "$STATE" 2>/dev/null || echo 0)"

    # 1) Deterministic facts block.
    facts="$(mktemp)"
    {
        echo "### Résultats (faits)"
        echo "- Issues livrées (mergées) : $merged_ct"
        grep '^merged' "$RUN_LEDGER" 2>/dev/null | while IFS=$'\t' read -r _ n pr rounds; do
            echo "  - #$n (PR #$pr, ${rounds:-?} tour(s) de review)"
        done
        echo "- Issues escaladées (bloquées) : $esc_ct"
        grep '^escalated' "$RUN_LEDGER" 2>/dev/null | while IFS=$'\t' read -r _ n kind reason; do
            echo "  - #$n — $kind : $reason"
        done
        echo "- Blocages en attente d'action humaine : $pend"
    } >"$facts"

    # 2) Qualitative analysis — fresh, cheap agent, grounded in the facts.
    prose=""
    if [ "${SHIPYARD_RETRO_ANALYSIS:-1}" != 0 ]; then
        prompt="$(mktemp)"
        cat "$LOOP_DIR/prompt-retro.md" >"$prompt"
        { printf '\n\n---\n# Faits du sprint %s\n\n' "$sprint_no"; cat "$facts"; } >>"$prompt"
        prose="$(claude_invoke "${SHIPYARD_RETRO_MODEL:-haiku}" "$prompt" 2>/dev/null || true)"
        rm -f "$prompt"
    fi

    # 3) Assemble the file (facts authoritative; prose is the qualitative layer).
    {
        echo "# Rétrospective — Sprint $sprint_no"
        [ -n "$today" ] && echo "> Généré automatiquement par la boucle shipyard le $today"
        echo
        cat "$facts"
        if [ -n "$prose" ]; then echo; echo "### Analyse"; echo; printf '%s\n' "$prose"; fi
    } >"$file"
    rm -f "$facts"
    log "retrospective written: $file"

    # 4) Async surface: one GitHub issue per sprint (idempotent), so you review it
    #    from your phone. Labelled 'retro' only — never status:todo, so the loop
    #    won't pick it up as work.
    if [ "${SHIPYARD_RETRO_ISSUE:-1}" != 0 ]; then
        local title existing
        title="chore(retro): sprint $sprint_no — $merged_ct livrée(s), $esc_ct bloquée(s)"
        existing="$(gh issue list --state open --search "chore(retro): sprint $sprint_no in:title" \
                      --json number --jq '.[0].number // empty' 2>/dev/null || true)"
        if [ -z "$existing" ]; then
            gh label create retro --color 5319e7 --description "Sprint retrospective" >/dev/null 2>&1 || true
            if gh issue create --title "$title" --label retro --body-file "$file" >/dev/null 2>&1; then
                log "retrospective issue opened"
            else
                log "could not open retro issue (non-fatal — file is on disk)"
            fi
        else
            log "retro issue already open (#$existing) — updated the file only"
        fi
    fi

    shipyard_notify "📊 Rétro sprint $sprint_no prête — $merged_ct livrée(s), $esc_ct bloquée(s)"
    return 0
}

# On (re)start, resume any issue a previous run left mid-flight (killed, rebooted, or
# picked up after a long back-off). status:blocked issues are left alone — they wait for
# a human. process_issue is idempotent (reuses the existing branch/PR), so this is safe.
recover_in_flight() {
    local n lbl handled=0 current slug items
    if [ "$PROJECT_ENABLED" = 1 ]; then
        current="$(jq -r '.loop.current_iteration.title // empty' "$STATE")"
        slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
        items="$(project_items)"
    fi
    for lbl in "$SHIPYARD_WIP_LABEL" "$SHIPYARD_REVIEW_LABEL"; do
        for n in $(gh issue list --state open --label "$lbl" \
                     --json number --jq 'sort_by(.number) | .[].number' 2>/dev/null); do
            if [ "$PROJECT_ENABLED" = 1 ] && ! jq -e --argjson n "$n" --arg sprint "$current" --arg slug "$slug" '
                any(.items[]?; .content.type=="Issue" and .content.number==$n and
                    .content.repository==$slug and ((.sprint.title // .sprint)==$sprint))' <<<"$items" >/dev/null; then
                continue
            fi
            log "resume: recovering in-flight issue #$n (was '$lbl')"
            process_issue "$n" || log "issue #$n did not complete on recovery"
            handled=1
        done
    done
    [ "$handled" = 1 ] && log "resume: in-flight recovery done"
    return 0
}

# ── Main loop ────────────────────────────────────────────────────────────────
main() {
    command -v gh   >/dev/null || { echo "gh not found" >&2; exit 1; }
    command -v jq   >/dev/null || { echo "jq not found" >&2; exit 1; }
    command -v claude >/dev/null || { echo "claude (Claude Code) not found" >&2; exit 1; }

    log "shipyard loop: base=$SHIPYARD_BASE max_iters=$MAX_ITERS parallelism=$SHIPYARD_PARALLELISM"
    [ -n "${SHIPYARD_FALLBACK_API_KEY:-}" ] && log "API-key fallback: armed (used only if Max is rate-limited)"
    if [ "$SHIPYARD_PARALLELISM" -gt 1 ] && ! command -v flock >/dev/null 2>&1; then
        log "WARN: SHIPYARD_PARALLELISM>1 but flock is missing — falling back to sequential (unsafe otherwise)"
        SHIPYARD_PARALLELISM=1
    fi
    # Per-run ledger: process_issue/escalate append merged/escalated rows here; the
    # end-of-run retrospective reads it. Kept for the whole run (recovery included).
    RUN_LEDGER="$(mktemp)"; trap 'rm -f "$RUN_LEDGER"' EXIT
    if ! project_init; then
        _state_set '.loop.status="blocked" | .loop.paused_reason="project-sync" | .loop.current_issue=null'
        shipyard_notify "🚧 Boucle bloquée — impossible de lire le Project v2 / Sprint"
        return 1
    fi
    _state_set '.loop.status="running" | .loop.paused_reason=null | .loop.resume_after=null'
    recover_in_flight
    # A previous run may have paused immediately after completing the final item
    # of a Sprint. On resume, advance before asking for work so that checkpoint
    # cannot strand the loop on an already-drained iteration.
    if [ "$PROJECT_ENABLED" = 1 ] && [ -z "$(next_todo_issue)" ]; then
        project_advance_if_drained || true
    fi
    local iter=0 issue
    while [ "$iter" -lt "$MAX_ITERS" ]; do
        # /deliver pause writes this status asynchronously. Honour it only at
        # iteration boundaries so an in-flight issue reaches a consistent state.
        if loop_is_paused; then
            log "manual pause observed between iterations"
            break
        fi
        # Throttle: with parallelism, wait for a free worker slot before pulling more.
        if [ "$SHIPYARD_PARALLELISM" -gt 1 ]; then
            while [ "$(jobs -rp | wc -l)" -ge "$SHIPYARD_PARALLELISM" ]; do
                wait -n 2>/dev/null || sleep 1
            done
        fi
        issue="$(next_todo_issue)"
        if [ -z "$issue" ]; then
            log "queue empty — nothing left in $SHIPYARD_TODO_LABEL"
            break
        fi
        iter=$((iter + 1))
        if [ "$SHIPYARD_PARALLELISM" -gt 1 ]; then
            # Claim the issue synchronously (todo→wip) BEFORE backgrounding so the next
            # next_todo_issue can't hand the same issue to a second worker.
            set_status "$issue" "$SHIPYARD_TODO_LABEL" "$SHIPYARD_WIP_LABEL"
            ( process_issue "$issue" || log "issue #$issue did not merge (see above)" ) &
        else
            process_issue "$issue" || log "issue #$issue did not merge (see above)"
        fi
    done
    [ "$SHIPYARD_PARALLELISM" -gt 1 ] && wait   # drain in-flight workers
    [ "$iter" -ge "$MAX_ITERS" ] && log "iteration cap reached ($MAX_ITERS)"
    log "loop finished after $iter iteration(s)"
    # A manual pause is durable: leave the loop paused so /deliver status reports
    # the truth. /deliver resume starts a new run, which clears the pause metadata.
    if loop_is_paused; then
        _state_set '.loop.current_issue=null'
        shipyard_notify "⏸️ Boucle en pause manuelle après $iter itération(s)"
        return 0
    fi
    # Sprint drained (or cap hit) with real work done → auto retrospective. This
    # runs BEFORE the final idle checkpoint on purpose: sprint_retrospective calls
    # claude_invoke, whose success checkpoint flips status back to "running", so
    # idle must be the last write to leave a correct terminal state.
    if [ "$iter" -gt 0 ] && [ "${SHIPYARD_RETRO:-1}" != 0 ]; then
        sprint_retrospective || log "retrospective step failed (non-fatal)"
    fi
    if [ "$iter" -gt 0 ]; then
        project_advance_if_drained || true
    fi
    # Preserve a terminal blocker instead of masking it as idle. A later run will
    # set running again after the human has returned the issue to status:todo.
    if jq -e '.loop.status == "blocked"' "$STATE" >/dev/null 2>&1; then
        _state_set '.loop.current_issue=null'
    else
        _state_set '.loop.status="idle" | .loop.current_issue=null'
    fi
    shipyard_notify "🏁 Boucle terminée — $iter itération(s)"
}

if [ "${SHIPYARD_SOURCE_ONLY:-0}" != 1 ]; then
    main "$@"
fi
