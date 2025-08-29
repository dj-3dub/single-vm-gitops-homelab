#!/usr/bin/env bash
# fix-swap.sh — keep /swapfile, remove /swap.img, guard against cloud-init, and summarize
# Usage: sudo bash /root/fix-swap.sh
# Optional: SWAP_SIZE=4G SWAP_KEEP=/swapfile SWAP_REMOVE=/swap.img

set -Eeuo pipefail

SWAP_KEEP="${SWAP_KEEP:-/swapfile}"
SWAP_REMOVE="${SWAP_REMOVE:-/swap.img}"
SWAP_SIZE="${SWAP_SIZE:-4G}"
FSTAB="/etc/fstab"
CLOUD_DIR="/etc/cloud/cloud.cfg.d"
CLOUD_CFG="${CLOUD_DIR}/99-disable-swap-img.cfg"

log()  { printf "\n%s\n" "$*"; }
ok()   { printf "OK: %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*"; }
die()  { printf "ERR: %s\n" "$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "${f}.bak.${ts}"
  ok "Backed up $f to ${f}.bak.${ts}"
}

comment_fstab_path() {
  # Safely comment any non-comment line whose FIRST FIELD equals the path
  local path="$1"
  local tmp; tmp="$(mktemp)"
  awk -v p="$path" '
    {
      if ($0 !~ /^[[:space:]]*#/ && $1 == p) { print "# " $0 }
      else { print }
    }
  ' "$FSTAB" > "$tmp" && mv "$tmp" "$FSTAB"
}

ensure_line_once() {
  # ensure_line_once <file> <exact_line>
  local f="$1" line="$2"
  grep -Fxq "$line" "$f" 2>/dev/null || echo "$line" >> "$f"
}

main() {
  require_root
  log "fix-swap: starting (keep=${SWAP_KEEP}, remove=${SWAP_REMOVE}, size=${SWAP_SIZE})"

  log "Step 0: Current swap status"
  swapon --show || true
  printf "\nCurrent fstab swap lines:\n"
  grep -nE '(^|[[:space:]])swap([[:space:]]|$)' "$FSTAB" || echo "(no swap lines found)"

  log "Step 1: Disable and remove ${SWAP_REMOVE} (if present)"
  swapoff "$SWAP_REMOVE" 2>/dev/null || true
  backup_file "$FSTAB"
  comment_fstab_path "$SWAP_REMOVE"
  rm -f "$SWAP_REMOVE" 2>/dev/null || true
  ok "Disabled and removed ${SWAP_REMOVE} (if it existed)."

  log "Step 2: Ensure ${SWAP_KEEP} exists, is ${SWAP_SIZE}, secure, and formatted"
  if [[ ! -f "$SWAP_KEEP" ]]; then
    if command -v fallocate >/dev/null 2>&1; then
      fallocate -l "$SWAP_SIZE" "$SWAP_KEEP" || true
    fi
    if [[ ! -s "$SWAP_KEEP" ]]; then
      dd if=/dev/zero of="$SWAP_KEEP" bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=none
    fi
  else
    current_bytes=$(stat -c %s "$SWAP_KEEP" 2>/dev/null || echo 0)
    target_bytes=$(( ${SWAP_SIZE%G} * 1024 * 1024 * 1024 ))
    if (( current_bytes < target_bytes )); then
      swapoff "$SWAP_KEEP" 2>/dev/null || true
      rm -f "$SWAP_KEEP"
      if command -v fallocate >/dev/null 2>&1; then
        fallocate -l "$SWAP_SIZE" "$SWAP_KEEP" || true
      fi
      if [[ ! -s "$SWAP_KEEP" ]]; then
        dd if=/dev/zero of="$SWAP_KEEP" bs=1M count=$(( ${SWAP_SIZE%G} * 1024 )) status=none
      fi
    fi
  fi

  chmod 600 "$SWAP_KEEP"
  if ! swapon --show=NAME | awk 'NR>1{print $1}' | grep -Fxq "$SWAP_KEEP"; then
    mkswap "$SWAP_KEEP" >/dev/null
  fi

  ensure_line_once "$FSTAB" "$SWAP_KEEP none swap sw 0 0"
  swapon -a

  log "Step 3: Prevent cloud-init from recreating ${SWAP_REMOVE}"
  mkdir -p "$CLOUD_DIR"
  cat > "$CLOUD_CFG" <<EOF
swap:
  filename: ${SWAP_REMOVE}
  size: 0
EOF
  chmod 644 "$CLOUD_CFG"
  ok "Wrote ${CLOUD_CFG}"

  log "Step 4: Verification"
  active="$(swapon --show)"
  fstab_view="$(grep -nE '(^|[[:space:]])swap([[:space:]]|$)' "$FSTAB" || true)"

  # compute summary
  only_keep_active="no"
  actives=$(echo "$active" | awk 'NR>1{print $1}')
  if [[ -n "$actives" ]]; then
    if echo "$actives" | grep -Fxq "$SWAP_KEEP" && ! echo "$actives" | grep -Fxq "$SWAP_REMOVE"; then
      only_keep_active="yes"
    fi
  else
    only_keep_active="no (no active swap?)"
  fi

  printf "\n==================== SWAP SUMMARY ====================\n"
  printf "Keep file:        %s\n" "$SWAP_KEEP"
  printf "Removed file:     %s (should be gone)\n" "$SWAP_REMOVE"
  printf "Cloud-init guard: %s (exists)\n" "$CLOUD_CFG"
  printf "\nActive swap (swapon --show):\n%s\n" "${active:-<none>}"
  printf "\n/etc/fstab swap lines:\n%s\n" "${fstab_view:-<none>}"
  printf "\nOnly '%s' active: %s\n" "$SWAP_KEEP" "$only_keep_active"
  printf "======================================================\n"
  ok "Done."
}

main "$@"
