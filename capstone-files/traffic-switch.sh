#!/usr/bin/env bash
# =============================================================================
# traffic-switch.sh  -  Blue/Green traffic control for an ALB weighted listener
#
# Commands:
#   status             Show listener weights, Green target health, alarm states
#   gate               Run the safety checks only (Green healthy + no alarms)
#   canary [PCT]       Gate, then send PCT% to Green (default 10)
#   switch             Gate, then send 100% to Green (needs a canary first)
#   rollback [reason]  Send 100% back to Blue (no gate: rollback must always work)
#   sample [N]         Send N requests to the ALB and count which version answered
#
# Safety features:
#   * Health gate: EVERY Green target must be exactly "healthy". The check
#     compares the state word exactly, so "unhealthy" can never pass.
#   * Alarm gate: refuses to shift traffic if a matching CloudWatch alarm is in ALARM.
#   * Read-back: after each change the script reads the listener again and
#     fails if the weights are not what it asked for.
#   * Only the listener's DEFAULT action is changed. Other listener rules
#     (such as the X-Test: green header rule) are left untouched.
#
# Settings (override with environment variables):
#   AWS_REGION      default ap-southeast-1
#   ALB_NAME        default bg-telco-dk-alb
#   TG_BLUE_NAME    default tg-blue-v1
#   TG_GREEN_NAME   default tg-green-v2
#   LISTENER_PORT   default 80
#   ALARM_PREFIX    default bg-telco-dk   (alarms whose names start with this)
#   SAMPLE_REQUESTS default 20
#   LOG_FILE        default ./traffic-switch.log
#   DRY_RUN=1       print what would change, change nothing
#   SKIP_ALARM_CHECK=1   skip the alarm gate (state this in your report)
#   FORCE=1         allow switch without a prior canary
#
# Requires: bash 4+, AWS CLI v2, curl. No secrets are stored in this file.
# =============================================================================
set -euo pipefail

REGION="${AWS_REGION:-ap-southeast-1}"
ALB_NAME="${ALB_NAME:-bg-telco-dk-alb}"
TG_BLUE_NAME="${TG_BLUE_NAME:-tg-blue-v1}"
TG_GREEN_NAME="${TG_GREEN_NAME:-tg-green-v2}"
LISTENER_PORT="${LISTENER_PORT:-80}"
ALARM_PREFIX="${ALARM_PREFIX:-bg-telco-dk}"
SAMPLE_REQUESTS="${SAMPLE_REQUESTS:-20}"
LOG_FILE="${LOG_FILE:-./traffic-switch.log}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_ALARM_CHECK="${SKIP_ALARM_CHECK:-0}"
FORCE="${FORCE:-0}"
export AWS_DEFAULT_REGION="$REGION"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# ---------- look up resources by name (no hard-coded IDs) ----------
lookup() {
  ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text) \
    || die "ALB '$ALB_NAME' not found in $REGION"
  ALB_DNS=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
    --query 'LoadBalancers[0].DNSName' --output text)
  LISTENER_ARN=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`${LISTENER_PORT}\`].ListenerArn | [0]" --output text)
  [[ -n "$LISTENER_ARN" && "$LISTENER_ARN" != "None" ]] \
    || die "No listener on port $LISTENER_PORT"
  TG_BLUE=$(aws elbv2 describe-target-groups --names "$TG_BLUE_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text) \
    || die "Target group '$TG_BLUE_NAME' not found"
  TG_GREEN=$(aws elbv2 describe-target-groups --names "$TG_GREEN_NAME" \
    --query 'TargetGroups[0].TargetGroupArn' --output text) \
    || die "Target group '$TG_GREEN_NAME' not found"
}

# ---------- weights ----------
current_weights() {   # prints: <target-group-arn> <weight>  (one line each)
  aws elbv2 describe-listeners --listener-arns "$LISTENER_ARN" \
    --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]' \
    --output text
}

get_weight() {        # $1 = target group ARN
  current_weights | awk -v a="$1" '$1==a {print $2}'
}

set_weights() {       # $1 = Green percent (0-100); Blue gets the rest
  local green=$1 blue=$((100 - $1)) gb gg
  log "Requested weights: Blue=$blue Green=$green"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1: no change made"
    return 0
  fi
  aws elbv2 modify-listener --listener-arn "$LISTENER_ARN" \
    --default-actions "[{\"Type\":\"forward\",\"ForwardConfig\":{\"TargetGroups\":[{\"TargetGroupArn\":\"$TG_BLUE\",\"Weight\":$blue},{\"TargetGroupArn\":\"$TG_GREEN\",\"Weight\":$green}]}}]" \
    >/dev/null || die "modify-listener failed"
  gb=$(get_weight "$TG_BLUE"); gg=$(get_weight "$TG_GREEN")
  [[ "$gb" == "$blue" && "$gg" == "$green" ]] \
    || die "Read-back mismatch: Blue=$gb Green=$gg (expected $blue/$green)"
  log "Confirmed on listener: Blue=$gb Green=$gg"
}

# ---------- safety gates ----------
health_gate() {
  local states s count=0
  states=$(aws elbv2 describe-target-health --target-group-arn "$TG_GREEN" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  for s in $states; do
    count=$((count + 1))
    [[ "$s" == "healthy" ]] || die "Health gate FAILED: a Green target is '$s'"
  done
  [[ "$count" -ge 1 ]] || die "Health gate FAILED: no targets registered in Green"
  log "Health gate PASSED: $count Green target(s), all 'healthy'"
}

alarm_gate() {
  local total firing
  if [[ "$SKIP_ALARM_CHECK" == "1" ]]; then
    log "WARNING: alarm gate skipped (SKIP_ALARM_CHECK=1)"
    return 0
  fi
  total=$(aws cloudwatch describe-alarms --alarm-name-prefix "$ALARM_PREFIX" \
    --query 'length(MetricAlarms)' --output text)
  [[ "$total" -ge 1 ]] \
    || die "Alarm gate FAILED: no alarms start with '$ALARM_PREFIX'. Set ALARM_PREFIX or SKIP_ALARM_CHECK=1"
  firing=$(aws cloudwatch describe-alarms --alarm-name-prefix "$ALARM_PREFIX" \
    --state-value ALARM --query 'MetricAlarms[].AlarmName' --output text)
  [[ -z "$firing" ]] || die "Alarm gate FAILED: in ALARM -> $firing"
  log "Alarm gate PASSED: $total alarm(s) checked, none in ALARM"
}

# ---------- verification ----------
sample() {            # $1 = number of requests
  local n=${1:-$SAMPLE_REQUESTS} i out code ver color key k
  declare -A counts=()
  log "Sampling $n requests to http://$ALB_DNS/"
  for ((i = 1; i <= n; i++)); do
    out=$(curl -s -o /dev/null -D - --max-time 5 "http://$ALB_DNS/" | tr -d '\r') || out=""
    code=$(printf '%s\n' "$out" | head -1 | awk '{print $2}')
    ver=$(printf '%s\n' "$out" | awk -F': ' 'tolower($1)=="x-app-version"{print $2}')
    color=$(printf '%s\n' "$out" | awk -F': ' 'tolower($1)=="x-app-color"{print $2}')
    key="HTTP ${code:-none} | version ${ver:-none} | colour ${color:-none}"
    counts[$key]=$(( ${counts[$key]:-0} + 1 ))
  done
  for k in "${!counts[@]}"; do
    log "  $k : ${counts[$k]} of $n"
  done
}

# ---------- commands ----------
cmd_status() {
  local b g
  b=$(get_weight "$TG_BLUE"); g=$(get_weight "$TG_GREEN")
  log "Listener :$LISTENER_PORT weights -> Blue=${b:-?} Green=${g:-?}"
  log "Blue  target health: $(aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
  log "Green target health: $(aws elbv2 describe-target-health --target-group-arn "$TG_GREEN" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
  aws cloudwatch describe-alarms --alarm-name-prefix "$ALARM_PREFIX" \
    --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
}

cmd_gate() { health_gate; alarm_gate; }

cmd_canary() {
  local pct=${1:-10}
  [[ "$pct" =~ ^[0-9]+$ && "$pct" -ge 1 && "$pct" -le 50 ]] \
    || die "Canary percent must be a whole number from 1 to 50"
  cmd_gate
  set_weights "$pct"
  sample
  if [[ "$DRY_RUN" == "1" ]]; then log "Dry run finished. No traffic was changed."; else log "Canary at ${pct}% is live. Watch CloudWatch, then run switch or rollback."; fi
}

cmd_switch() {
  local g
  g=$(get_weight "$TG_GREEN")
  if [[ "${g:-0}" -lt 1 && "$FORCE" != "1" ]]; then
    die "Green has no traffic yet. Run a canary first (or set FORCE=1)"
  fi
  cmd_gate
  set_weights 100
  sample
  if [[ "$DRY_RUN" == "1" ]]; then log "Dry run finished. No traffic was changed."; else log "Green now has 100%. Keep Blue running until Green is stable."; fi
}

cmd_rollback() {
  local reason=${1:-manual}
  log "ROLLBACK started. Reason: $reason"
  local blue_states
  blue_states=$(aws elbv2 describe-target-health --target-group-arn "$TG_BLUE" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)
  log "Blue target health before rollback: ${blue_states:-none}"
  case " $blue_states " in
    *" healthy "*) ;;
    *) log "WARNING: Blue has no healthy target. Rolling back anyway; fix Blue now." ;;
  esac
  if [[ "$(get_weight "$TG_GREEN")" == "0" ]]; then
    log "Green already at 0. Nothing to change; verifying only."
  else
    set_weights 0
  fi
  sample
  log "ROLLBACK finished. Check that every sampled response says colour blue."
}

usage() { sed -n '2,36p' "$0"; }

main() {
  local cmd=${1:-help}
  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
  esac
  lookup
  case "$cmd" in
    status)   cmd_status ;;
    gate)     cmd_gate ;;
    canary)   cmd_canary "${2:-10}" ;;
    switch)   cmd_switch ;;
    rollback) cmd_rollback "${2:-manual}" ;;
    sample)   sample "${2:-$SAMPLE_REQUESTS}" ;;
    *)        usage; exit 1 ;;
  esac
}

main "$@"
