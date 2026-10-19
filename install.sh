#!/usr/bin/env bash
# =============================================================================
#  Ariznodes(TM) HVM Panel v3.5 - installer & manager  (c) 2026 Ariznodes, all rights reserved                      v3.5.0
# -----------------------------------------------------------------------------
#  Supported : Ubuntu 22.04 / 24.04, Debian 12   (x86_64 or aarch64, root)
#  Install   : sudo bash install.sh
#  Manage    : sudo bash install.sh <command>
#
#  Commands  : install (default) | upgrade | status | doctor | logs | backup
#              restore <file> | reset-admin [user] | uninstall | help
#  Flags     : -y/--yes  --docker-only  --harden/--no-harden  --no-tunnel
#              --port N  --domain D  --config FILE
#
#  Every long-running step shows a live spinner with elapsed time and the last
#  log line, has a hard timeout, and writes full output to the install log.
#  A failed install can simply be re-run: finished steps are skipped and your
#  answers are remembered in /etc/ariznodes/install.conf.
# =============================================================================
set -Eeuo pipefail

ORIG_ARGS=("$@")
SCRIPT_NAME="${BASH_SOURCE[0]:-install.sh}"
VERSION="3.5.0"
APP=/opt/ariznodes
CONF_DIR=/etc/ariznodes
CONF="$CONF_DIR/install.conf"
STATE_DIR="$CONF_DIR/state"
LOG=/var/log/ariznodes-install.log
BACKUP_DIR=/var/backups/ariznodes
PORT="${PORT:-8080}"
# One-command installs: after you push this file to GitHub, set your raw URL here (or export UPDATE_URL).
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/ArizNodesOp/ariznodes-hvm/main/install.sh}"
STEP_NO=0; STEP_TOTAL=14
TIPS=("tip: finished steps are skipped if you re-run" "tip: 2FA and recovery codes live under Account" "tip: pick a theme with the dots in the sidebar" "tip: run 'doctor' any time for a health check" "tip: daily rewards give coins that extend servers" "tip: nodes let you add capacity from other VPSes")
CMD="install"
ASSUME_YES=0
NO_TUNNEL=0
PORT_FLAG=0
CONFIG_FILE=""
EXTRA_ARGS=()
LXD_OK=0
DOCKER_OK=0
SELFTEST_FAIL=0
export PATH="$PATH:/snap/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Non-interactive apt: needrestart / debconf prompts are what usually makes a
# "silent" installer look frozen on Ubuntu 22.04+.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef
          -o DPkg::Lock::Timeout=300 -o Acquire::Retries=3 --no-install-recommends)

# --------------------------------------------------------------------------- UI
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'
  C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_CYN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

_ts()  { date '+%F %T'; }
_log() { printf '[%s] %s\n' "$(_ts)" "$*" >>"$LOG" 2>/dev/null || true; }
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_RST" "$*"; _log "INFO  $*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_RST" "$*"; _log "OK    $*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; _log "WARN  $*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; _log "ERROR $*"; }
die()  { err "$*"; exit 1; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

banner() {
  cat <<EOF
${C_CYN}
   +--------------------------------------------------+
   |   ARIZNODES(TM)  HVM  PANEL        v${VERSION}        |
   |   LXC + KVM/QEMU  |  Discord-verified  |  Dark   |
   +--------------------------------------------------+${C_RST}
EOF
}

usage() {
  cat <<EOF
Ariznodes(TM) HVM Panel installer v${VERSION}

Usage: sudo bash ${SCRIPT_NAME} [command] [flags]

Commands
  install            Full install (default). Safe to re-run after a failure.
  upgrade            Re-deploy panel code + dependencies, keep data and secrets.
  status             Short health summary.
  doctor             Detailed diagnostics (services, ports, tunnel, Discord).
  logs               Follow web + bot logs.
  backup             Backup database and secrets now.
  restore <file>     Restore a backup made by 'backup'.
  reset-admin [user] Generate a new password for a panel account (default: admin).
  uninstall          Remove the panel (asks before touching VPS data).
  self-update        Download the newest installer from your GitHub URL, then upgrade.
  diag               Write a support bundle (no secrets) to /root.
  node-test          API node: find out why it does not connect.

Flags
  -y, --yes          No questions; use saved config / env vars / defaults.
  --docker-only      Skip LXD (no KVM VMs; containers run on Docker).
  --harden           Also configure UFW firewall + fail2ban.   (--no-harden to skip)
  --no-tunnel        Do not install Cloudflare Tunnel.
  --node             API node installation (connect to an existing panel).
  --port N           Local panel port (default 8080).
  --domain D         Panel domain.
  --config FILE      Source variables from FILE (DOMAIN=..., DISCORD_BOT_TOKEN=...).

Unattended example
  DOMAIN=panel.example.com DISCORD_BOT_TOKEN=... DISCORD_CLIENT_ID=... \\
  DISCORD_CLIENT_SECRET=... DISCORD_GUILD_ID=... sudo -E bash ${SCRIPT_NAME} install -y
EOF
}

# --------------------------------------------------------------------- failure
_tail_log() {
  echo "${C_DIM}---- last log lines ($LOG) ----${C_RST}" >&2
  tail -n 20 "$LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
}
on_err() {
  local code=$? line="$1"
  trap - ERR
  err "Unexpected failure at line ${line} (exit ${code})."
  _tail_log
  echo "Fix the problem and re-run:  sudo bash ${SCRIPT_NAME} ${CMD}   (finished steps are skipped)" >&2
  exit "$code"
}
trap 'on_err $LINENO' ERR
trap 'resume_auto_updates' EXIT
trap 'echo; warn "Interrupted. Re-run the installer to continue."; exit 130' INT TERM

# ------------------------------------------------------------- step runner
# run_step "label" TIMEOUT_SECONDS command args...
# Live spinner (elapsed time + last log line) on a TTY, plain lines otherwise.
# Output goes to the log only. Returns the command's exit status.
run_step() {
  local label="$1" limit="$2"; shift 2
  local start=$SECONDS rc=0 pid i=0 frames='|/-\' last=""
  printf '\n----- %s -----\n' "$label" >>"$LOG"
  _log "STEP  $label"
  [ -t 1 ] || info "$label ..."
  timeout --foreground -k 15 "$limit" "$@" >>"$LOG" 2>&1 </dev/null &
  pid=$!
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      last="$(tail -n1 "$LOG" 2>/dev/null | tr -d '\r\033' | cut -c1-48)"
      if [ -z "$last" ] || [ $(( (SECONDS - start) / 8 % 2 )) -eq 1 ]; then last="${C_DIM}${TIPS[$(( (SECONDS - start) / 16 % ${#TIPS[@]} ))]}"; fi
      printf '\r\033[K%s[%s]%s %s %s(%ss)%s %s' "$C_CYN" "${frames:$((i % 4)):1}" "$C_RST" \
        "$label" "$C_DIM" "$((SECONDS - start))" "$C_RST" "$last"
      i=$((i + 1)); sleep 0.25
    done
    printf '\r\033[K'
  fi
  wait "$pid" || rc=$?
  [ "$rc" -eq 137 ] && { warn "Killed by the kernel (out of memory). Adding swap so the next attempt fits."; ensure_swap 3072; }
  if   [ "$rc" -eq 0 ];   then ok "$label ${C_DIM}($((SECONDS - start))s)${C_RST}"
  elif [ "$rc" -eq 124 ]; then warn "$label - timed out after ${limit}s"
  else                         warn "$label - failed (exit $rc)"
  fi
  return "$rc"
}
must() { # one automatic retry when the step was killed for lack of memory
  local label="$1" rc=0
  run_step "$@" || rc=$?
  if [ "$rc" -eq 137 ]; then run_step "$@" || rc=$?; fi
  [ "$rc" -eq 0 ] || { err "Required step failed: $label"; _tail_log; exit 1; }
}
soft() { run_step "$@" || true; }
retry() { # retry N "label" TIMEOUT command...
  local n="$1" label="$2" limit="$3"; shift 3
  local a=1
  while :; do
    run_step "$label (attempt $a/$n)" "$limit" "$@" && return 0
    [ "$a" -ge "$n" ] && return 1
    a=$((a + 1)); sleep 5
  done
}

# ------------------------------------------------------------ apt helpers
UU_STOPPED=0
stop_auto_updates() { # the usual culprit on a fresh VPS: unattended-upgrades holds the dpkg lock for minutes
  [ "$UU_STOPPED" -eq 1 ] && return 0
  systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service apt-daily.timer apt-daily-upgrade.timer >>"$LOG" 2>&1 || true
  systemctl mask --runtime apt-daily.timer apt-daily-upgrade.timer >>"$LOG" 2>&1 || true
  UU_STOPPED=1; _log "automatic updates paused for the install"
}
resume_auto_updates() {
  [ "$UU_STOPPED" -eq 1 ] || return 0; UU_STOPPED=0
  systemctl unmask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
}
lock_holders() { pgrep -x 'apt|apt-get|dpkg|unattended-upgr|apt.systemd.dai|aptitude|packagekitd' 2>/dev/null | tr '\n' ' ' || true; }
wait_apt_idle() { # free the lock instead of just waiting for it
  local waited=0 h; h="$(lock_holders)"; [ -n "${h// /}" ] || return 0
  warn "The package manager is busy (automatic updates). Taking over so you do not have to wait..."
  stop_auto_updates
  while h="$(lock_holders)"; [ -n "${h// /}" ]; do
    [ -t 1 ] && printf '\r\033[K%s[~]%s waiting for the apt lock  %ss  (holders: %s)' "$C_YLW" "$C_RST" "$waited" "$(echo $h | cut -c1-40)"
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -eq 30 ]; then pkill -TERM -x 'unattended-upgr' 2>/dev/null || true; pkill -TERM -x 'apt.systemd.dai' 2>/dev/null || true; fi
    if [ "$waited" -ge 80 ]; then
      [ -t 1 ] && printf '\n'; warn "Still locked after 80s - ending the stuck package job and repairing dpkg"
      pkill -KILL -x 'apt|apt-get|dpkg|unattended-upgr|apt.systemd.dai|aptitude|packagekitd' 2>/dev/null || true
      sleep 2; rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock
      dpkg --configure -a >>"$LOG" 2>&1 || true; break
    fi
  done
  [ -t 1 ] && printf '\r\033[K'; return 0
}
ensure_swap() { # ensure_swap MB - grow swap so low-memory VPSes survive apt/pip/snap
  local want="$1" have f=/swapfile-ariz
  have="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"; [ "$have" -ge "$want" ] && return 0
  [ "$(systemd-detect-virt -c 2>/dev/null || true)" = "none" ] || return 0
  swapoff "$f" 2>/dev/null || true; rm -f "$f"
  if { fallocate -l "${want}M" "$f" 2>>"$LOG" || dd if=/dev/zero of="$f" bs=1M count="$want" status=none 2>>"$LOG"; } && chmod 600 "$f" && mkswap "$f" >>"$LOG" 2>&1 && swapon "$f" 2>>"$LOG"; then
    grep -q "^$f " /etc/fstab || echo "$f none swap sw 0 0" >>/etc/fstab; sysctl -q vm.swappiness=60 2>/dev/null || true; ok "Swap ready (${want} MB)"
  else warn "Could not create swap (filesystem does not support it?)"; rm -f "$f"; fi
  return 0
}
mem_guard() { local a; a="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"; if [ "$a" -lt 350 ]; then warn "Only ${a} MB RAM free - clearing caches and adding swap"; sync; echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true; ensure_swap 3072; fi; return 0; }
phase() { # phase "Title" - overall progress bar
  STEP_NO=$((STEP_NO + 1)); local w=24 f i bar="" on="#" off="-"
  [[ "${LC_ALL:-${LANG:-}}" == *UTF-8* ]] && { on="█"; off="░"; }
  f=$(( STEP_NO * w / STEP_TOTAL )); for ((i = 0; i < w; i++)); do if [ "$i" -lt "$f" ]; then bar+="$on"; else bar+="$off"; fi; done
  printf '\n%s%s%s %s%2d/%d%s  %s%s%s\n' "$C_CYN" "$bar" "$C_RST" "$C_DIM" "$STEP_NO" "$STEP_TOTAL" "$C_RST" "$C_BLD" "$1" "$C_RST"; _log "PHASE $STEP_NO/$STEP_TOTAL $1"
}
splash() { # animated title card (skipped when not a terminal or NO_ANIM=1)
  if [ ! -t 1 ] || [ -n "${NO_ANIM:-}" ]; then banner; return 0; fi
  local t="  A R I Z N O D E S (TM)   H V M   P A N E L   v${VERSION}" i p
  echo; for ((i = 0; i < ${#t}; i++)); do printf '\033[1;38;5;%sm%s' "$((39 + (i * 2) % 12))" "${t:i:1}"; sleep 0.012; done; printf '%s\n' "$C_RST"
  printf '%s  LXC  |  KVM  |  Docker  |  Discord-verified  |  multi-node%s\n  ' "$C_DIM" "$C_RST"
  for p in $(seq 1 44); do printf '\033[38;5;%sm=' "$((39 + p % 12))"; sleep 0.01; done; printf '%s\n' "$C_RST"
}
celebrate() { [ -t 1 ] && [ -z "${NO_ANIM:-}" ] || return 0; local i; for i in $(seq 0 38); do printf '\r\033[K%*s%s' "$i" "" "${C_GRN}=====>${C_RST} ${C_BLD}liftoff${C_RST}"; sleep 0.02; done; printf '\r\033[K'; }
apt_install() {
  local lbl; lbl="$(printf '%.58s' "$*")"
  wait_apt_idle
  if ! run_step "Installing $lbl" 1500 apt-get install "${APT_OPTS[@]}" "$@"; then
    warn "Retrying after repairing the dpkg/apt state"
    soft "Repairing dpkg" 600 dpkg --configure -a
    soft "Refreshing package index" 600 apt-get update
    must "Installing $lbl" 1500 apt-get install "${APT_OPTS[@]}" "$@"
  fi
}

# --------------------------------------------------------------- small utils
gen_pass()  { openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-20; }
ver_ge()    { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
done_step() { [ -f "$STATE_DIR/$1" ]; }
mark_step() { mkdir -p "$STATE_DIR"; date +%s >"$STATE_DIR/$1"; }
interactive() { [ "$ASSUME_YES" -eq 0 ] && ( : </dev/tty ) 2>/dev/null; }

confirm() { # confirm "Question?" default(y|n)
  local q="$1" d="${2:-n}" a=""
  if ! interactive; then [ "$d" = y ] && return 0 || return 1; fi
  read -rp "$q [$([ "$d" = y ] && echo Y/n || echo y/N)]: " a </dev/tty || a=""
  a="${a:-$d}"; [[ "$a" =~ ^[Yy] ]] && return 0 || return 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  if have_cmd sudo && [ -f "${BASH_SOURCE[0]:-}" ]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
  fi
  die "Run as root:  sudo bash ${SCRIPT_NAME}"
}

init_log() {
  mkdir -p "$(dirname "$LOG")" "$CONF_DIR"; touch "$LOG"; chmod 600 "$LOG"
  _log "===== ${SCRIPT_NAME} ${CMD} v${VERSION} (user: ${SUDO_USER:-root}) ====="
}

parse_args() {
  if [ "$#" -gt 0 ] && [[ "$1" != -* ]]; then CMD="$1"; shift; fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -y|--yes)            ASSUME_YES=1 ;;
      --docker-only|--no-lxd) DOCKER_ONLY=1 ;;
      --harden)            HARDEN=1 ;;
      --no-harden)         HARDEN=0 ;;
      --no-tunnel)         NO_TUNNEL=1 ;;
      --node|--api-node)   INSTALL_MODE=node ;;
      --port)              PORT="${2:?--port needs a value}"; PORT_FLAG=1; shift ;;
      --domain)            DOMAIN="${2:?--domain needs a value}"; shift ;;
      --config)            CONFIG_FILE="${2:?--config needs a file}"; shift ;;
      -h|--help|help)      usage; exit 0 ;;
      *)                   EXTRA_ARGS+=("$1") ;;
    esac
    shift
  done
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    set -a; . "$CONFIG_FILE"; set +a
  fi
  [[ "$PORT" =~ ^[0-9]{4,5}$ ]] && [ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || die "Invalid --port: $PORT"
}

# ------------------------------------------------------------------ preflight
net_check() { # net_check "name" url required(1|0)
  local code
  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$2" 2>>"$LOG" || true)"
  if [ -n "$code" ] && [ "$code" != "000" ]; then ok "Reachable: $1"; return 0; fi
  if [ "$3" = 1 ]; then warn "Cannot reach $1 ($2) - installation will likely fail. Check DNS/firewall."; return 1; fi
  warn "Cannot reach $1 - related features may not work"; return 0
}

preflight() {
  info "Pre-flight checks"
  [ -r /etc/os-release ] || die "Cannot detect OS (/etc/os-release missing)"
  . /etc/os-release
  case "${ID:-}" in
    ubuntu) ver_ge "${VERSION_ID:-0}" 22.04 || die "Ubuntu 22.04+ required (found ${VERSION_ID:-?})" ;;
    debian) ver_ge "${VERSION_ID:-0}" 12    || die "Debian 12+ required (found ${VERSION_ID:-?})" ;;
    *) die "Unsupported OS '${PRETTY_NAME:-unknown}'. Use Ubuntu 22.04/24.04 or Debian 12." ;;
  esac
  ok "OS: ${PRETTY_NAME}"

  case "$(uname -m)" in x86_64|aarch64) ok "Architecture: $(uname -m)" ;; *) die "Unsupported architecture $(uname -m)" ;; esac
  [ -d /run/systemd/system ] || die "systemd is required (not running here - is this WSL or a minimal container?)"

  local ram disk cpus virt
  ram="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  disk="$(df -Pm / | awk 'NR==2 {print $4}')"
  cpus="$(nproc)"
  ok "Resources: ${cpus} CPU, ${ram} MB RAM, ${disk} MB free on /"
  [ "$disk" -ge 3000 ] || die "At least 3 GB of free disk space is required on /"
  [ "$disk" -ge 15000 ] || warn "Less than 15 GB free - you will not fit many VPS instances"
  [ "$ram" -ge 1024 ] || warn "Under 1 GB RAM - the panel runs, but VPS deployments will be very limited"

  virt="$(systemd-detect-virt -c 2>/dev/null || true)"
  if [ -n "$virt" ] && [ "$virt" != "none" ]; then
    warn "Running inside a container (${virt}). LXD/Docker need nesting enabled by your provider."
    [ "$virt" = "openvz" ] && die "OpenVZ cannot run LXD or Docker. Use a KVM VPS or bare metal."
  fi
  if [ -e /dev/kvm ]; then ok "KVM available - virtual machines supported"
  else warn "/dev/kvm not found - only containers will work (no KVM/QEMU VMs). Enable nested virtualization to fix."; fi

  if ss -ltnpH "sport = :${PORT}" 2>/dev/null | grep -q .; then
    ss -ltnpH "sport = :${PORT}" | grep -q gunicorn || die "Port ${PORT} is already in use by another program"
  fi

  have_cmd curl || { wait_apt_idle; must "Installing curl" 600 apt-get install "${APT_OPTS[@]}" curl ca-certificates; }
  net_check "PyPI"              "https://pypi.org/simple/pip/"        1 || true
  net_check "Discord API"       "https://discord.com/api/v10/gateway" 1 || true
  net_check "GitHub"            "https://github.com"                  0
  net_check "Docker Hub"        "https://registry-1.docker.io/v2/"    0
  net_check "Ubuntu image host" "https://images.lxd.canonical.com"    0
}

# --------------------------------------------------------------------- prompts
v_any()      { return 0; }
v_nonempty() { [ -n "$1" ] || { warn "A value is required."; return 1; }; }
v_domain()   {
  local re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
  [[ "$1" =~ $re ]] || { warn "Enter a bare domain such as panel.example.com (no https://, no path)."; return 1; }
}
v_snowflake()     { [[ "$1" =~ ^[0-9]{15,21}$ ]] || { warn "Expected a numeric Discord ID (15-21 digits). Enable Developer Mode and right-click > Copy ID."; return 1; }; }
v_opt_snowflake() { [ -z "$1" ] || v_snowflake "$1"; }
v_token()         { [[ "$1" =~ ^[A-Za-z0-9._-]{50,}$ ]] || { warn "That does not look like a Discord bot token (Developer Portal > Bot > Reset Token)."; return 1; }; }
v_cf_token()      { [ -z "$1" ] || [[ "$1" =~ ^[A-Za-z0-9=_-]{40,}$ ]] || { warn "That does not look like a Cloudflare Tunnel token."; return 1; }; }
v_site_key()      { [ -z "$1" ] || [[ "$1" =~ ^[A-Za-z0-9_-]{10,}$ ]] || { warn "Unexpected Turnstile key format."; return 1; }; }
norm_domain()     { local d="${1,,}"; d="${d#http://}"; d="${d#https://}"; printf '%s' "${d%%/*}"; }

# prompt VAR "Label" [default] [secret] [validator] [normalizer]
# A variable that is already set (env, --config, saved config) is validated and
# reused; empty-but-set optional variables are never re-asked.
prompt() {
  local var="$1" label="$2" def="${3:-}" secret="${4:-}" validator="${5:-v_any}" norm="${6:-}"
  local val="" tries=0
  if [[ -v $var ]]; then
    val="${!var}"; [ -n "$norm" ] && val="$($norm "$val")"
    if "$validator" "$val"; then printf -v "$var" '%s' "$val"; return 0; fi
    interactive || die "Invalid value for $var"
  elif ! interactive; then
    val="$def"; [ -n "$norm" ] && val="$($norm "$val")"
    "$validator" "$val" || die "Missing required setting: $var (set it as an env var, in --config, or run interactively)"
    printf -v "$var" '%s' "$val"; return 0
  fi
  while :; do
    if [ -n "$secret" ]; then read -rsp "  $label: " val </dev/tty || val=""; echo
    else read -rp "  $label${def:+ [$def]}: " val </dev/tty || val=""; fi
    val="$(printf '%s' "$val" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    val="${val:-$def}"; [ -n "$norm" ] && val="$($norm "$val")"
    if "$validator" "$val"; then break; fi
    tries=$((tries + 1)); [ "$tries" -ge 5 ] && die "Too many invalid answers for $var"
  done
  printf -v "$var" '%s' "$val"
}

# ----------------------------------------------------------- config persistence
CFG_VARS=(DOMAIN DISCORD_BOT_TOKEN DISCORD_CLIENT_ID DISCORD_CLIENT_SECRET DISCORD_GUILD_ID
          DISCORD_LOG_CHANNEL_ID TURNSTILE_SITE TURNSTILE_SECRET CF_TUNNEL_TOKEN CREATOR
          ADMIN_PASS DOCKER_ONLY HARDEN INSTALL_MODE PANEL_URL PANEL_KEY NODE_NAME NODE_URL)

save_config() {
  local v tmp="$CONF.tmp"
  mkdir -p "$CONF_DIR"; ( umask 077; : >"$tmp" )
  for v in "${CFG_VARS[@]}"; do
    [[ -v $v ]] && printf '%s=%q\n' "$v" "${!v}" >>"$tmp"
  done
  mv "$tmp" "$CONF"; chmod 600 "$CONF"
}
load_config() { # saved values never override anything already set by env/flags
  [ -f "$CONF" ] || return 0
  local line k v
  while IFS= read -r line; do
    k="${line%%=*}"
    for v in "${CFG_VARS[@]}"; do
      if [ "$k" = "$v" ] && ! [[ -v $v ]]; then eval "$line"; fi
    done
  done <"$CONF"
}
scrub_conf_secret() { [ -f "$CONF" ] && sed -i '/^ADMIN_PASS=/d' "$CONF" || true; }

# ----------------------------------------------------------- Discord validation
discord_get() { # discord_get /path  -> prints HTTP status; body in /tmp/.az_dc.$$
  local hf; hf="$(mktemp)"; chmod 600 "$hf"
  printf 'Authorization: Bot %s\n' "$DISCORD_BOT_TOKEN" >"$hf"
  curl -sS -m 10 -o "/tmp/.az_dc.$$" -w '%{http_code}' -H "@$hf" "https://discord.com/api/v10$1" 2>>"$LOG" || true
  rm -f "$hf"
}
verify_discord() {
  local code attempt=0
  while :; do
    code="$(discord_get /users/@me)"
    case "$code" in
      200) ok "Discord bot token valid ($(sed -n 's/.*"username": *"\([^"]*\)".*/\1/p' "/tmp/.az_dc.$$" | head -n1))"; break ;;
      401) warn "Discord rejected the bot token (401)."
           attempt=$((attempt + 1))
           if interactive && [ "$attempt" -lt 3 ]; then unset DISCORD_BOT_TOKEN; prompt DISCORD_BOT_TOKEN "Discord bot token" "" secret v_token; save_config
           else warn "Continuing with an invalid token - the bot service will not start until you fix DISCORD_BOT_TOKEN in $APP/.env"; break; fi ;;
      000) warn "Could not reach Discord to verify the token (network?). Continuing."; break ;;
      *)   warn "Unexpected Discord response ($code). Continuing."; break ;;
    esac
  done
  code="$(discord_get "/guilds/${DISCORD_GUILD_ID}")"
  case "$code" in
    200) ok "Bot is a member of the configured server" ;;
    403|404) warn "Bot is not in server ${DISCORD_GUILD_ID} yet. Invite it with the 'Manage Server' permission before the first deployment." ;;
  esac
  rm -f "/tmp/.az_dc.$$"
}

collect_inputs() {
  info "Configuration  (Enter = accept [default]; optional fields may stay empty)"
  prompt DOMAIN                "Panel domain (e.g. panel.example.com)" "" "" v_domain norm_domain
  prompt DISCORD_BOT_TOKEN     "Discord bot token"                      "" secret v_token
  prompt DISCORD_CLIENT_ID     "Discord application (client) ID"        "" "" v_snowflake
  prompt DISCORD_CLIENT_SECRET "Discord client secret"                  "" secret v_nonempty
  prompt DISCORD_GUILD_ID      "Discord server (guild) ID"              "" "" v_snowflake
  prompt DISCORD_LOG_CHANNEL_ID "Bot notice channel ID (optional)"      "" "" v_opt_snowflake
  prompt TURNSTILE_SITE        "Cloudflare Turnstile site key (optional, blocks bots)" "" "" v_site_key
  prompt TURNSTILE_SECRET      "Cloudflare Turnstile secret key (optional)" "" secret v_any
  if [ "$NO_TUNNEL" -eq 1 ]; then CF_TUNNEL_TOKEN=""; fi
  prompt CF_TUNNEL_TOKEN       "Cloudflare Tunnel token (optional, installs cloudflared)" "" secret v_cf_token
  prompt CREATOR               "Creator name shown on the About page" "ArizNodes Labs" "" v_nonempty
  if [ -z "${HARDEN:-}" ]; then  # empty/unset = not decided yet
    if confirm "Configure UFW firewall + fail2ban (keeps your SSH port open)?" n; then HARDEN=1; else HARDEN=0; fi
  fi
  [ -n "${DOCKER_ONLY:-}" ] || DOCKER_ONLY=0
  [ -n "${ADMIN_PASS:-}" ] || ADMIN_PASS="$(gen_pass)"
}

# ============================================================================
#  Application code (embedded so this file is the whole bundle)
# ============================================================================
write_app_files() {
  info "Deploying application files to $APP"
  mkdir -p "$APP/data"
# ---------------------------------------------------------------- core.py
cat > "$APP/core.py" <<'PYCORE'
"""Shared DB + provisioning layer used by both the web panel and the Discord bot."""
import json, os, shutil, sqlite3, subprocess, sys, time
from dotenv import load_dotenv
load_dotenv("/opt/ariznodes/.env")
from cryptography.fernet import Fernet
from werkzeug.security import generate_password_hash

DB = "/opt/ariznodes/data/panel.db"
PLANS = {  # invites needed -> resources and server slots
    "basic":  {"invites": 2,  "cpu": 1, "ram": 1024,  "disk": 10,  "slots": 1},
    "medium": {"invites": 4,  "cpu": 2, "ram": 2048,  "disk": 20,  "slots": 1},
    "large":  {"invites": 8,  "cpu": 4, "ram": 4096,  "disk": 40,  "slots": 2},
    "pro":    {"invites": 12, "cpu": 6, "ram": 8192,  "disk": 80,  "slots": 2},
    "elite":  {"invites": 20, "cpu": 8, "ram": 16384, "disk": 120, "slots": 3},
}
SCHEMA = """
CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, username TEXT UNIQUE NOT NULL, pw_hash TEXT NOT NULL,
  discord_id TEXT UNIQUE, discord_name TEXT, is_admin INTEGER DEFAULT 0, banned INTEGER DEFAULT 0,
  fails INTEGER DEFAULT 0, locked_until REAL DEFAULT 0, created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS invites(id INTEGER PRIMARY KEY, inviter_id TEXT NOT NULL, invitee_id TEXT UNIQUE NOT NULL,
  valid INTEGER DEFAULT 1, joined_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS vps(id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, name TEXT UNIQUE NOT NULL, plan TEXT,
  kind TEXT, image TEXT, engine TEXT, status TEXT DEFAULT 'pending', secret TEXT, created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS jobs(id INTEGER PRIMARY KEY, vps_id INTEGER, status TEXT DEFAULT 'pending', message TEXT,
  created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS alerts(id INTEGER PRIMARY KEY, kind TEXT, detail TEXT, created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX IF NOT EXISTS idx_inv ON invites(inviter_id, valid);
CREATE INDEX IF NOT EXISTS idx_vps_user ON vps(user_id);
CREATE INDEX IF NOT EXISTS idx_jobs_status ON jobs(status);
CREATE TABLE IF NOT EXISTS activity(id INTEGER PRIMARY KEY, user_id INTEGER, vps_id INTEGER, action TEXT, detail TEXT, ip TEXT,
  created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS tokens(id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, name TEXT, hash TEXT UNIQUE NOT NULL,
  created_at REAL DEFAULT (strftime('%s','now')));
CREATE INDEX IF NOT EXISTS idx_act_user ON activity(user_id, id);
CREATE INDEX IF NOT EXISTS idx_act_vps ON activity(vps_id, action);
CREATE TABLE IF NOT EXISTS nodes(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, url TEXT NOT NULL, key TEXT NOT NULL, caps TEXT,
  slots INTEGER DEFAULT 10, enabled INTEGER DEFAULT 1, last_ok REAL DEFAULT 0, created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS ip_bans(ip TEXT PRIMARY KEY, reason TEXT, created_at REAL DEFAULT (strftime('%s','now')));
CREATE TABLE IF NOT EXISTS recovery(id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, hash TEXT NOT NULL, used INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_rec ON recovery(user_id, hash);
"""
DEFAULTS = {"max_vps": "1", "registration": "1", "mining_autostop": "0", "announcement": "",
            "maintenance": "0", "vps_days": "0", "alert_webhook": "", "pinggy_token": "", "auto_tunnel": "1",
            "local_slots": "0", "docker_fallback": "0", "min_pw": "10", "max_fails": "5", "lock_min": "15", "sess_hours": "12",
            "admin_ips": "", "force_admin_2fa": "0", "force_all_2fa": "0", "ip_ban_after": "20"}
MIGRATIONS = [  # additive column upgrades; "duplicate column" errors just mean already applied
    "ALTER TABLE users ADD COLUMN totp_secret TEXT", "ALTER TABLE users ADD COLUMN totp_on INTEGER DEFAULT 0",
    "ALTER TABLE users ADD COLUMN sv INTEGER DEFAULT 0", "ALTER TABLE users ADD COLUMN bonus_invites INTEGER DEFAULT 0",
    "ALTER TABLE vps ADD COLUMN label TEXT", "ALTER TABLE vps ADD COLUMN ssh_state TEXT",
    "ALTER TABLE vps ADD COLUMN pinggy_on INTEGER DEFAULT 0", "ALTER TABLE vps ADD COLUMN pinggy_url TEXT",
    "ALTER TABLE vps ADD COLUMN sshx_url TEXT", "ALTER TABLE vps ADD COLUMN expires_at REAL DEFAULT 0",
    "ALTER TABLE users ADD COLUMN coins INTEGER DEFAULT 0", "ALTER TABLE users ADD COLUMN streak INTEGER DEFAULT 0", "ALTER TABLE users ADD COLUMN last_claim INTEGER DEFAULT 0",
    "ALTER TABLE vps ADD COLUMN node_id INTEGER DEFAULT 0", "ALTER TABLE vps ADD COLUMN suspended INTEGER DEFAULT 0", "ALTER TABLE vps ADD COLUMN susp_reason TEXT",
]
_F = Fernet(os.environ["FERNET_KEY"].encode()) if os.getenv("FERNET_KEY") else None

def db():
    c = sqlite3.connect(DB, timeout=15)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA foreign_keys=ON")
    return c

def q(sql, a=(), one=False):
    c = db()
    try:
        cur = c.execute(sql, a)
        return cur.fetchone() if one else cur.fetchall()
    finally:
        c.close()

def ex(sql, a=()):
    c = db()
    try:
        cur = c.execute(sql, a); c.commit(); return cur.lastrowid
    finally:
        c.close()

def init_db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = db(); c.executescript(SCHEMA)
    for k, v in DEFAULTS.items():
        c.execute("INSERT OR IGNORE INTO settings(key,value) VALUES(?,?)", (k, v))
    for stmt in MIGRATIONS:
        try: c.execute(stmt)
        except sqlite3.OperationalError: pass
    c.commit(); c.close()

def setting(k): 
    r = q("SELECT value FROM settings WHERE key=?", (k,), one=True)
    return r["value"] if r else DEFAULTS.get(k, "")

def alert(kind, detail):
    ex("INSERT INTO alerts(kind,detail) VALUES(?,?)", (kind, detail[:300]))
    hook = setting("alert_webhook")
    if kind != "audit" and hook.startswith(("https://discord.com/api/webhooks/", "https://discordapp.com/api/webhooks/")):
        try:
            import requests  # only Discord webhook URLs are ever called (validated when saved)
            requests.post(hook, json={"content": f"**[{kind}]** {detail}"[:1900]}, timeout=5)
        except Exception: pass
def enc(s): return _F.encrypt(s.encode()).decode()
def dec(s): return _F.decrypt(s.encode()).decode()
def valid_invites(discord_id):  # real invites + any bonus an admin granted to the linked panel account
    n = q("SELECT COUNT(*) n FROM invites WHERE inviter_id=? AND valid=1", (str(discord_id),), one=True)["n"]
    return n + q("SELECT COALESCE(SUM(bonus_invites),0) b FROM users WHERE discord_id=?", (str(discord_id),), one=True)["b"]

def plan_for(n):
    best = None
    for name, p in PLANS.items():  # ordered basic -> large
        if n >= p["invites"]: best = name
    return best

# ---------------------------------------------------------------- provisioning
import hashlib, hmac, re as _re, threading
_tl = threading.local()
def set_node(nid): _tl.node = int(nid or 0)

def _remote_run(node, cmd, timeout, inp):
    """Send a signed command to a node agent (see agent.py)."""
    import requests
    body = json.dumps({"cmd": cmd, "timeout": timeout, "inp": inp}); ts = str(int(time.time()))
    sig = hmac.new(dec(node["key"]).encode(), (ts + body).encode(), hashlib.sha256).hexdigest()
    try: j = requests.post(node["url"].rstrip("/") + "/agent/run", data=body, timeout=timeout + 20,
                           headers={"X-Ts": ts, "X-Sig": sig, "Content-Type": "application/json", "User-Agent": "Ariznodes-Panel/3.5"}).json()
    except Exception as e: raise RuntimeError(f"node {node['name']} unreachable: {str(e)[:120]}")
    if not j.get("ok"): raise RuntimeError(str(j.get("error", "remote error"))[-400:])
    return j.get("out", "")

def run(cmd, timeout=600, inp=None):
    nid = getattr(_tl, "node", 0)
    if nid:
        node = q("SELECT * FROM nodes WHERE id=?", (nid,), one=True)
        if not node: raise RuntimeError("node no longer exists")
        return _remote_run(node, list(cmd), timeout, inp)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=inp,
                       env={**os.environ, "PATH": "/snap/bin:/usr/local/bin:/usr/bin:/bin"})
    if r.returncode:
        raise RuntimeError(((r.stderr or r.stdout) or "command failed").strip()[-400:])
    return r.stdout

def have_lxc():
    try: run(["lxc", "info"], 20); return True
    except Exception: return False

def have_docker():
    try: run(["docker", "info"], 20); return True
    except Exception: return False

def have_kvm(): return os.path.exists("/dev/kvm")

def provision(name, plan, kind, image, password):
    """Create an LXC container/VM; fall back to Docker (containers only). Returns engine name."""
    p = PLANS[plan]
    if kind == "docker": return _docker_only(name, p, image, password)  # Docker servers never touch LXD
    if kind == "ct" and not have_lxc() and setting("docker_fallback") != "1":
        raise RuntimeError("LXD is not available on this node (an admin can enable the Docker fallback)")
    if have_lxc():
        base = ["lxc", "launch", f"ubuntu:{image}", name, "-c", f"limits.cpu={p['cpu']}",
                "-c", f"limits.memory={p['ram']}MiB"]
        extra = []
        if kind == "vm":
            if not getattr(_tl, "node", 0) and not have_kvm(): raise RuntimeError("This node has no /dev/kvm - VMs unavailable")
            extra = ["--vm"]
        try:
            run(base + ["-d", f"root,size={p['disk']}GiB"] + extra, 900)
        except RuntimeError as e:
            # LXD's default 'dir' storage cannot enforce disk quotas; retry without a size limit.
            if "quota" not in str(e).lower(): raise
            try: run(["lxc", "delete", "--force", name], 60)
            except RuntimeError: pass
            run(base + extra, 900)
        for _ in range(30):  # guest agent / init may need a moment
            try: run(["lxc", "exec", name, "--", "chpasswd"], 20, f"root:{password}\n"); return "lxc"
            except Exception: time.sleep(4)
        raise RuntimeError("Instance started but the guest never became ready")
    if kind == "vm": raise RuntimeError("VMs need LXD with KVM; falling back is only possible for containers")
    if not have_docker(): raise RuntimeError("Neither LXC nor Docker is available on this node")
    run(["docker", "run", "-d", "--name", name, "--restart", "unless-stopped", "--cpus", str(p["cpu"]),
         "--memory", f"{p['ram']}m", f"ubuntu:{image}", "sleep", "infinity"], 900)
    run(["docker", "exec", "-i", name, "chpasswd"], 20, f"root:{password}\n")
    return "docker"

def _docker_only(name, p, image, password):
    if not have_docker(): raise RuntimeError("Docker is not available on this node")
    run(["docker", "run", "-d", "--name", name, "--restart", "unless-stopped", "--cpus", str(p["cpu"]),
         "--memory", f"{p['ram']}m", f"ubuntu:{image}", "sleep", "infinity"], 900)
    run(["docker", "exec", "-i", name, "chpasswd"], 20, f"root:{password}\n")
    return "docker"

COMMON_PW = {"password", "password1", "password12", "password123", "123456789", "1234567890", "12345678910", "qwerty123", "qwertyuiop", "iloveyou1", "admin12345", "welcome123", "letmein123", "abc123456", "changeme123", "ariznodes1", "ariznodes123", "minecraft1", "minecraft123"}
def pw_ok(pw):
    p = pw.lower()
    return (int(setting("min_pw") or 10) <= len(pw) <= 128 and bool(_re.search(r"[A-Za-z]", pw)) and bool(_re.search(r"\d", pw))
            and p not in COMMON_PW and len(set(p)) >= 5)  # rejects weak and repetitive passwords

def autoban(ip):
    rules = [x for x in setting("admin_ips").split(",") if x.strip()]
    if ip.startswith("127.") or ip in rules: return
    n = q("SELECT COUNT(*) n FROM activity WHERE action='login_fail' AND ip=? AND created_at>?", (ip, time.time() - 600), one=True)["n"]
    if n >= int(setting("ip_ban_after") or 20):
        ex("INSERT OR IGNORE INTO ip_bans(ip,reason) VALUES(?,?)", (ip, "auto: repeated failed logins")); alert("security", f"{ip} auto-banned after repeated failed logins")

def pick_node(kind):
    """0 = this host. Fill the local host first, then the remote node with the most free slots."""
    set_node(0); eng = "docker" if kind == "docker" else "lxc"
    local = int(setting("local_slots") or 0)
    used = q("SELECT COUNT(*) n FROM vps WHERE node_id=0 AND status!='failed'", one=True)["n"]
    has = have_docker() if eng == "docker" else (have_lxc() or (kind == "ct" and setting("docker_fallback") == "1" and have_docker()))
    if has and (kind != "vm" or have_kvm()) and (local == 0 or used < local): return 0
    best = None
    for n in q("SELECT * FROM nodes WHERE enabled=1"):
        caps = json.loads(n["caps"] or "{}")
        if not caps.get(eng) or (kind == "vm" and not caps.get("kvm")): continue
        free = n["slots"] - q("SELECT COUNT(*) c FROM vps WHERE node_id=? AND status!='failed'", (n["id"],), one=True)["c"]
        if free > 0 and (best is None or free > best[0]): best = (free, n["id"])
    if best: return best[1]
    raise RuntimeError("No node has a free slot for this server type")

def control(engine, name, action):
    if action not in ("start", "stop", "restart", "delete"): raise ValueError("bad action")
    if engine == "lxc":
        if action == "delete": run(["lxc", "delete", "--force", name], 120)
        else: run(["lxc", action, name] + (["--force"] if action != "start" else []), 120)
    else:
        if action == "delete": run(["docker", "rm", "-f", name], 120)
        else: run(["docker", action, name], 120)

def state(engine, name):
    try:
        if engine == "lxc": s = json.loads(run(["lxc", "query", f"/1.0/instances/{name}/state"], 20))["status"].lower()
        else: s = run(["docker", "inspect", "-f", "{{.State.Status}}", name], 20).strip()
        return "stopped" if s == "exited" else s
    except Exception:
        return "unknown"

def exec_cmd(engine, name, cmd):
    base = ["lxc", "exec", name, "--"] if engine == "lxc" else ["docker", "exec", name]
    return run(base + ["bash", "-lc", cmd], 30)

if __name__ == "__main__":
    init_db()
    if len(sys.argv) > 2 and sys.argv[1] == "bootstrap":  # bootstrap <admin-username>; password via ADMIN_PASS env
        if not q("SELECT 1 FROM users WHERE username=?", (sys.argv[2],), one=True):
            ex("INSERT INTO users(username,pw_hash,is_admin) VALUES(?,?,1)",
               (sys.argv[2], generate_password_hash(os.environ["ADMIN_PASS"])))
            print("admin created")
PYCORE

# ---------------------------------------------------------------- app.py
cat > "$APP/app.py" <<'PYAPP'
import os, re, secrets, time
from functools import wraps
from urllib.parse import urlencode
import psutil, requests
from flask import Flask, request, session, redirect, render_template, flash, g, abort
from flask_limiter import Limiter
from jinja2 import DictLoader
from markupsafe import Markup
from werkzeug.security import check_password_hash, generate_password_hash
import core

DOMAIN = os.environ["DOMAIN"]
core.init_db()
app = Flask(__name__)
app.secret_key = os.environ["SECRET_KEY"]
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_PATH="/", SESSION_COOKIE_NAME=("__Host-ariz" if os.getenv("COOKIE_SECURE", "1") == "1" else "ariz"), SESSION_COOKIE_SAMESITE="Lax",
                  SESSION_COOKIE_SECURE=os.getenv("COOKIE_SECURE", "1") == "1",
                  PERMANENT_SESSION_LIFETIME=43200, MAX_CONTENT_LENGTH=64 * 1024)

def real_ip():  # app only listens on loopback, so CF-Connecting-IP can only come from our own tunnel
    return request.headers.get("CF-Connecting-IP") or request.remote_addr
def uahash(): return __import__("hashlib").sha256(request.headers.get("User-Agent", "").encode()).hexdigest()[:16]
limiter = Limiter(real_ip, app=app, default_limits=["240/minute"], storage_uri="memory://")
DUMMY = generate_password_hash("timing-equalizer")

# ---------------------------------------------------------------- helpers
def me():
    if "uid" not in session: return None
    if not hasattr(g, "me"):
        u = core.q("SELECT * FROM users WHERE id=?", (session["uid"],), one=True)
        if u and (u["banned"] or session.get("sv", 0) != u["sv"]): u = None  # sv bump = "sign out everywhere"
        g.me = u
    return g.me

def login_required(f):
    @wraps(f)
    def w(*a, **k):
        if not me(): session.clear(); return redirect("/login")
        return f(*a, **k)
    return w

def admin_required(f):
    @wraps(f)
    @login_required
    def w(*a, **k):
        if not me()["is_admin"]: abort(404)
        return f(*a, **k)
    return w

def human_ok():  # Cloudflare Turnstile keeps bots out of login/register
    sec = os.getenv("TURNSTILE_SECRET")
    if not sec: return True
    try:
        r = requests.post("https://challenges.cloudflare.com/turnstile/v0/siteverify", timeout=8,
                          data={"secret": sec, "response": request.form.get("cf-turnstile-response", ""), "remoteip": real_ip()})
        return bool(r.json().get("success"))
    except (requests.RequestException, ValueError):
        return False

def fmt_up(s):
    d, r = divmod(int(s), 86400); h, r = divmod(r, 3600)
    return f"{d}d {h}h {r // 60}m"

@app.before_request
def guard():
    g.nonce = secrets.token_urlsafe(16)
    if "csrf" not in session: session["csrf"] = secrets.token_urlsafe(32)
    if request.method == "POST" and not request.path.startswith("/api/v1/") and not secrets.compare_digest(request.form.get("csrf", ""), session["csrf"]): abort(400)

@app.after_request
def headers(r):
    r.headers["Content-Security-Policy"] = (f"default-src 'self'; script-src 'nonce-{g.nonce}' https://challenges.cloudflare.com; "
        "style-src 'self' 'unsafe-inline'; frame-src https://challenges.cloudflare.com; img-src 'self' data:; "
        "form-action 'self'; frame-ancestors 'none'; base-uri 'none'; object-src 'none'" + ("; upgrade-insecure-requests" if os.getenv("COOKIE_SECURE", "1") == "1" else ""))
    r.headers.update({"X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "same-origin",
                      "Strict-Transport-Security": "max-age=63072000; includeSubDomains", "Cache-Control": "no-store",
                      "Permissions-Policy": "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
                      "Cross-Origin-Opener-Policy": "same-origin", "Cross-Origin-Resource-Policy": "same-origin", "X-Permitted-Cross-Domain-Policies": "none"})
    return r

@app.context_processor
def ctx():
    return dict(me=me(), csrf=session.get("csrf"), nonce=g.get("nonce", ""), ts_site=os.getenv("TURNSTILE_SITE"),
                creator=os.getenv("CREATOR", "ArizNodes Labs"), PLANS=core.PLANS, announce=core.setting("announcement"))

ICONS = {
 "server": '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01"/>',
 "shield": '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',
 "user": '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',
 "bolt": '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
 "alert": '<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18h.01"/>',
 "trash": '<path d="M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14"/>',
 "play": '<path d="M7 4l13 8-13 8z"/>', "stop": '<rect x="6" y="6" width="12" height="12" rx="1"/>',
 "refresh": '<path d="M20 11a8 8 0 10-2 6M20 4v7h-7"/>',
 "link": '<path d="M10 14a4 4 0 005.7 0l3-3a4 4 0 00-5.7-5.7l-1 1M14 10a4 4 0 00-5.7 0l-3 3a4 4 0 005.7 5.7l1-1"/>',
 "logout": '<path d="M9 4H5v16h4M16 8l4 4-4 4M20 12H9"/>',
 "cpu": '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
 "lock": '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 018 0v4"/>',
 "grid": '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
 "sliders": '<path d="M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"/><circle cx="15" cy="6" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="17" cy="18" r="2"/>',
 "ban": '<circle cx="12" cy="12" r="9"/><path d="M5.6 5.6l12.8 12.8"/>',
}
app.jinja_env.globals["ico"] = lambda n: Markup(
    f'<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{ICONS[n]}</svg>')
app.jinja_env.filters["ts"] = lambda x: time.strftime("%Y-%m-%d %H:%M", time.gmtime(x or 0)) + " UTC"

# ---------------------------------------------------------------- public + auth
@app.route("/")
def home(): return render_template("home.html")

@app.route("/healthz")
def health(): return "ok"

@app.route("/register", methods=["GET", "POST"])
@limiter.limit("5/minute", methods=["POST"])
def register():
    if request.method == "POST":
        u, p = request.form.get("username", "").strip(), request.form.get("password", "")
        if core.setting("registration") != "1": flash("Registration is closed.", "err")
        elif not human_ok(): flash("Human verification failed.", "err")
        elif not re.fullmatch(r"[A-Za-z0-9_]{3,20}", u) or not core.pw_ok(p):
            flash(f"Username: 3-20 letters/digits/_. Password: {core.setting('min_pw')}+ characters with letters and numbers.", "err")
        elif core.q("SELECT 1 FROM users WHERE username=? COLLATE NOCASE", (u,), one=True): flash("Username taken.", "err")
        else:
            core.ex("INSERT INTO users(username,pw_hash) VALUES(?,?)", (u, generate_password_hash(p)))
            flash("Account created - log in.", "ok"); return redirect("/login")
    return render_template("auth.html", mode="register")

@app.route("/login", methods=["GET", "POST"])
@limiter.limit("10/minute", methods=["POST"])
def login():
    if request.method == "POST":
        pw = request.form.get("password", "")
        u = core.q("SELECT * FROM users WHERE username=? COLLATE NOCASE", (request.form.get("username", ""),), one=True)
        if not human_ok(): flash("Human verification failed.", "err")
        elif u and u["locked_until"] > time.time(): flash("Too many attempts. Try again in 15 minutes.", "err")
        elif u and check_password_hash(u["pw_hash"], pw):
            if u["banned"]: flash("This account is banned.", "err")
            else:
                core.ex("UPDATE users SET fails=0 WHERE id=?", (u["id"],))
                if u["totp_on"]:  # password OK, second factor still required
                    session.clear(); session["pre2fa"] = u["id"]; session["csrf"] = secrets.token_urlsafe(32); return redirect("/login/2fa")
                session.clear(); session["uid"] = u["id"]; session["sv"] = u["sv"]; session["ua"] = uahash(); session["csrf"] = secrets.token_urlsafe(32); session.permanent = True
                return redirect("/dashboard")
        else:
            if u:
                f = u["fails"] + 1  # lock after 5 failures
                core.ex("UPDATE users SET fails=?, locked_until=? WHERE id=?", (0 if f >= int(core.setting("max_fails")) else f, time.time() + int(core.setting("lock_min")) * 60 if f >= int(core.setting("max_fails")) else 0, u["id"]))
            else: check_password_hash(DUMMY, pw)
            core.ex("INSERT INTO activity(user_id,action,detail,ip) VALUES(?,?,?,?)", (u["id"] if u else None, "login_fail", request.form.get("username", "")[:30], real_ip()))
            core.autoban(real_ip()); time.sleep(0.6)  # slows password guessing
            flash("Invalid credentials.", "err")
    return render_template("auth.html", mode="login")

@app.post("/logout")
def logout(): session.clear(); return redirect("/")

# ---------------------------------------------------------------- Discord OAuth
@app.route("/discord/link")
@login_required
def d_link():
    session["ostate"] = secrets.token_urlsafe(16)
    return redirect("https://discord.com/oauth2/authorize?" + urlencode({
        "client_id": os.environ["DISCORD_CLIENT_ID"], "redirect_uri": f"https://{DOMAIN}/discord/callback",
        "response_type": "code", "scope": "identify", "state": session["ostate"], "prompt": "none"}))

@app.route("/discord/callback")
@login_required
def d_cb():
    st = session.pop("ostate", None)
    if not st or not secrets.compare_digest(st, request.args.get("state", "")): abort(400)
    try:
        t = requests.post("https://discord.com/api/oauth2/token", timeout=10, data={
            "client_id": os.environ["DISCORD_CLIENT_ID"], "client_secret": os.environ["DISCORD_CLIENT_SECRET"],
            "grant_type": "authorization_code", "code": request.args.get("code", ""),
            "redirect_uri": f"https://{DOMAIN}/discord/callback"}).json()
        d = requests.get("https://discord.com/api/users/@me", timeout=10, headers={"Authorization": f"Bearer {t['access_token']}"}).json()
        did = str(int(d["id"]))
    except Exception:
        flash("Discord authorization failed.", "err"); return redirect("/dashboard")
    if core.q("SELECT 1 FROM users WHERE discord_id=? AND id!=?", (did, me()["id"]), one=True):
        flash("That Discord account is already linked to another panel account.", "err")
    else:
        core.ex("UPDATE users SET discord_id=?, discord_name=? WHERE id=?", (did, d.get("username", did), me()["id"]))
        flash("Discord account linked.", "ok")
    return redirect("/dashboard")

# ---------------------------------------------------------------- user dashboard + VPS
@app.route("/dashboard")
@login_required
def dashboard():
    u = me(); n = core.valid_invites(u["discord_id"]) if u["discord_id"] else 0
    plan = core.plan_for(n)
    nxt = next(((k, p) for k, p in core.PLANS.items() if p["invites"] > n), None)
    vps = core.q("SELECT * FROM vps WHERE user_id=? ORDER BY id DESC", (u["id"],))
    return render_template("dash.html", n=n, plan=plan, nxt=nxt, vps=vps, max_vps=int(core.setting("max_vps")),
                           pct=min(100, int(100 * n / (nxt[1]["invites"] if nxt else max(n, 1)))))

@app.post("/vps/create")
@login_required
@limiter.limit("3/hour")
def vps_create():
    u = me(); kind, image, plan = request.form.get("kind"), request.form.get("image"), request.form.get("plan")
    n = core.valid_invites(u["discord_id"]) if u["discord_id"] else 0
    owned = core.q("SELECT COUNT(*) n FROM vps WHERE user_id=? AND status!='failed'", (u["id"],), one=True)["n"]
    if kind not in ("ct", "vm", "docker") or image not in ("22.04", "24.04") or plan not in core.PLANS: abort(400)
    if not u["discord_id"]: flash("Link your Discord account first.", "err")
    elif core.PLANS[plan]["invites"] > n and not u["is_admin"]: flash("Not enough verified invites for that plan.", "err")
    elif owned >= max(int(core.setting("max_vps")), core.PLANS[core.plan_for(n) or "basic"]["slots"]) and not u["is_admin"]: flash("VPS limit reached.", "err")
    else:
        name = f"anz-{re.sub('[^a-z0-9]', '', u['username'].lower())[:10]}-{secrets.token_hex(2)}"
        vid = core.ex("INSERT INTO vps(user_id,name,plan,kind,image,secret) VALUES(?,?,?,?,?,?)",
                      (u["id"], name, plan, kind, image, core.enc(secrets.token_urlsafe(14))))
        core.ex("INSERT INTO jobs(vps_id) VALUES(?)", (vid,))  # picked up by the Discord bot, which verifies invites
        flash("Request sent to the verification bot. This page shows progress.", "ok")
    return redirect("/servers")

def own_vps(vid):
    v = core.q("SELECT * FROM vps WHERE id=?", (vid,), one=True)
    if not v or (v["user_id"] != me()["id"] and not me()["is_admin"]): abort(404)
    core.set_node(v["node_id"])  # every later container command for this request runs on the right node
    return v

@app.route("/vps/<int:vid>")
@login_required
def vps_page(vid):
    own_vps(vid); return redirect(f"/v/{vid}")  # the full management page lives in features.py

@app.post("/vps/<int:vid>/<action>")
@login_required
@limiter.limit("30/minute")
def vps_action(vid, action):
    v = own_vps(vid)
    if v["suspended"] and not me()["is_admin"]: flash("This server is suspended.", "err"); return redirect(f"/v/{vid}")
    if action == "exec":
        cmd = request.form.get("cmd", "")[:500]
        try: out = core.exec_cmd(v["engine"], v["name"], cmd)[-4000:]
        except Exception as e: out = f"error: {e}"
        return render_template("vps.html", v=v, live=core.state(v["engine"], v["name"]), pw=core.dec(v["secret"]), out=out)
    if action not in ("start", "stop", "restart", "delete"): abort(400)
    try:
        if v["engine"]: core.control(v["engine"], v["name"], action)
        if action == "delete":
            core.ex("DELETE FROM jobs WHERE vps_id=?", (vid,)); core.ex("DELETE FROM vps WHERE id=?", (vid,)); return redirect("/dashboard")
        flash(f"{action} done.", "ok")
    except Exception as e: flash(f"{action} failed: {e}", "err")
    return redirect(f"/v/{vid}")

# ---------------------------------------------------------------- admin
@app.route("/admin")
@admin_required
def admin():
    up = time.time() - psutil.boot_time()
    return render_template("admin.html", cpu=psutil.cpu_percent(interval=0.2), ram=psutil.virtual_memory().percent,
        disk=psutil.disk_usage("/").percent, uptime=fmt_up(up), lxc=core.have_lxc(), docker=core.have_docker(), kvm=core.have_kvm(),
        users=core.q("SELECT * FROM users ORDER BY id DESC LIMIT 200"),
        vps=core.q("SELECT v.*, u.username FROM vps v JOIN users u ON u.id=v.user_id ORDER BY v.id DESC LIMIT 200"),
        alerts=core.q("SELECT * FROM alerts ORDER BY id DESC LIMIT 50"),
        s={k: core.setting(k) for k in core.DEFAULTS})

@app.post("/admin/user/<int:uid>/<act>")
@admin_required
def admin_user(uid, act):
    if uid == me()["id"] or act not in ("ban", "unban", "promote", "demote"): abort(400)
    col, val = {"ban": ("banned", 1), "unban": ("banned", 0), "promote": ("is_admin", 1), "demote": ("is_admin", 0)}[act]
    core.ex(f"UPDATE users SET {col}=? WHERE id=?", (val, uid))  # col comes from a fixed map, never user input
    core.alert("audit", f"{me()['username']} {act} user #{uid}")
    return redirect("/admin")

@app.post("/admin/settings")
@admin_required
def admin_settings():
    for k in ("max_vps", "registration", "mining_autostop"):
        v = request.form.get(k, "")
        if k == "max_vps": v = str(max(1, min(50, int(v)))) if v.isdigit() else "1"
        else: v = "1" if v == "on" else "0"
        core.ex("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (k, v))
    core.ex("INSERT OR REPLACE INTO settings(key,value) VALUES('announcement',?)", (request.form.get("announcement", "")[:200],))
    flash("Settings saved.", "ok"); return redirect("/admin")

@app.post("/admin/alerts/clear")
@admin_required
def admin_clear(): core.ex("DELETE FROM alerts"); return redirect("/admin")

# ---------------------------------------------------------------- templates
T = {}
T["base.html"] = r'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{% block title %}Ariznodes HVM{% endblock %}</title>
<style>
:root{--bg:#0a0f1e;--s1:#101830;--s2:#16203d;--ln:#25325a;--tx:#e8edfb;--mut:#8f9cc0;--pri:#6d7cff;--pri-h:#8591ff;--on:#3ddc97;--wait:#ffb84d;--off:#ff6b81;
--card:var(--s1);--line:var(--ln);--txt:var(--tx);--a:var(--pri);--b:#7dd3fc;--r:var(--off);--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.6 Inter,ui-sans-serif,system-ui,"Segoe UI",Roboto,sans-serif;min-height:100vh;-webkit-font-smoothing:antialiased}
a{color:#9db4ff;text-decoration:none}a:hover{text-decoration:underline}:focus-visible{outline:2px solid var(--pri-h);outline-offset:2px}
.ico{width:18px;height:18px;vertical-align:-4px;flex:none}.mono,code,pre,.big.mono{font-family:var(--mono)}.mut{color:var(--mut)}.inl{display:inline}.grad{color:inherit}.rv{opacity:1}
h1{font-size:clamp(1.9rem,4.4vw,3.1rem);line-height:1.08;letter-spacing:-.025em;font-weight:680;margin:.1em 0 .3em}h2{font-size:1.15rem;font-weight:640;margin:2em 0 .7em;letter-spacing:-.01em}h3{font-size:1rem;margin:1.2em 0 .4em}
.shell{display:grid;grid-template-columns:236px 1fr;min-height:100vh}.side{position:sticky;top:0;height:100vh;padding:18px 12px;background:#0c1328;border-right:1px solid var(--ln);display:flex;flex-direction:column;gap:4px}
.brand{display:flex;align-items:center;gap:10px;color:var(--tx);font-weight:700;padding:4px 10px 18px;letter-spacing:-.01em}.brand:hover{text-decoration:none}.brand .ico{color:var(--pri-h);width:22px;height:22px}.brand sup{font-size:.55em;color:var(--mut)}
.nav a{display:flex;align-items:center;gap:11px;padding:9px 12px;border-radius:7px;color:var(--mut);font-weight:520;position:relative}.nav a:hover{background:var(--s1);color:var(--tx);text-decoration:none}
.nav a.on{background:var(--s2);color:var(--tx)}.nav a.on:before{content:"";position:absolute;left:-12px;top:8px;bottom:8px;width:3px;border-radius:0 3px 3px 0;background:var(--pri-h)}
.me{margin-top:auto;display:flex;align-items:center;gap:10px;padding:10px;border:1px solid var(--ln);border-radius:9px;background:var(--s1)}.me b{flex:1;overflow:hidden;text-overflow:ellipsis;font-weight:600}
.pub{display:flex;align-items:center;gap:20px;padding:14px max(20px,calc(50vw - 560px));border-bottom:1px solid var(--ln);position:sticky;top:0;background:#0a0f1ee6;backdrop-filter:blur(10px);z-index:5}.sp{flex:1}
main{max-width:1060px;margin:0 auto;padding:30px 24px 60px}.pubmain{max-width:1120px}.ph{margin-bottom:22px}.ph p{margin:0;color:var(--mut)}
.card{background:var(--s1);border:1px solid var(--ln);border-radius:10px;padding:20px;transition:border-color .2s}.card:hover{border-color:#34457a}.grid{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.btn,button{background:var(--pri);color:#fff;border:1px solid transparent;padding:8px 15px;border-radius:6px;font:inherit;font-weight:600;cursor:pointer;display:inline-flex;gap:8px;align-items:center;transition:background .15s}
.btn:hover,button:hover{background:var(--pri-h);text-decoration:none}button.ghost,.btn.ghost{background:transparent;border-color:var(--ln);color:var(--tx)}button.ghost:hover,.btn.ghost:hover{background:var(--s2)}
button.red{background:#3a1822;border-color:#7a2b3d;color:#ffb3c0}button.red:hover{background:#51202e}button.lnk{background:none;border:0;color:var(--mut);padding:4px}button.lnk:hover{color:var(--tx);background:none}
input,select,textarea{width:100%;background:var(--s2);border:1px solid var(--ln);color:var(--tx);border-radius:6px;padding:9px 11px;font:inherit;margin:5px 0 13px}input:focus,select:focus,textarea:focus{outline:0;border-color:var(--pri-h);box-shadow:0 0 0 3px #6d7cff30}
label{font-weight:540;font-size:.92rem}input[type=checkbox]{width:auto;margin-right:6px}
table{width:100%;border-collapse:collapse}td,th{padding:10px 8px;border-bottom:1px solid var(--ln);text-align:left;font-size:14px}th{color:var(--mut);font-weight:540}tr:hover td{background:#ffffff05}tr:last-child td{border-bottom:0}
.tag{padding:2px 9px;border-radius:99px;background:var(--s2);border:1px solid var(--ln);font-size:12px;color:var(--mut)}pre{background:#070b17;border:1px solid var(--ln);padding:12px;border-radius:7px;overflow:auto;max-height:280px;font-size:13px}
.big{font-size:1.9rem;font-weight:680;letter-spacing:-.02em;line-height:1.2}.dot,.led{display:inline-block;width:9px;height:9px;border-radius:50%;background:#4a5679;margin-right:7px;box-shadow:inset 0 1px 1px #ffffff40}
.running .dot,.dot.on,.led.g{background:var(--on);box-shadow:0 0 8px var(--on),inset 0 1px 1px #fff7}.pending .dot,.led.a{background:var(--wait);box-shadow:0 0 8px var(--wait)}.failed .dot,.dot.off,.suspended .dot{background:var(--off);box-shadow:0 0 8px var(--off)}
.bar{height:8px;background:var(--s2);border-radius:2px;overflow:hidden;-webkit-mask:repeating-linear-gradient(90deg,#000 0 6px,transparent 6px 8px);mask:repeating-linear-gradient(90deg,#000 0 6px,transparent 6px 8px)}.bar i{display:block;height:100%;background:var(--pri-h);transition:width 1s}
.toasts{position:fixed;top:16px;right:16px;z-index:20;display:grid;gap:8px;max-width:min(380px,calc(100vw - 32px))}.flash{padding:11px 14px;border-radius:8px;background:var(--s2);border:1px solid var(--ln);border-left:3px solid var(--pri-h);box-shadow:0 8px 28px #0008;animation:in .25s both}
.flash.ok{border-left-color:var(--on)}.flash.err{border-left-color:var(--off)}@keyframes in{from{opacity:0;transform:translateX(16px)}}.banner{background:var(--s2);border-bottom:1px solid var(--ln);text-align:center;padding:7px;font-size:14px}
.units{display:grid;gap:8px}.unit{display:grid;grid-template-columns:auto 1fr auto auto;gap:14px;align-items:center;padding:12px 16px;background:var(--s1);border:1px solid var(--ln);border-radius:8px;color:var(--tx)}
.unit:hover{border-color:var(--pri);text-decoration:none;background:var(--s2)}.unit b{font-family:var(--mono);font-weight:600}.unit span,.unit em{color:var(--mut);font-style:normal;font-size:13px}.empty{padding:26px;text-align:center;color:var(--mut);border:1px dashed var(--ln);border-radius:8px}
.hero{display:grid;grid-template-columns:1.1fr .9fr;gap:48px;align-items:center;padding:64px 0 40px}.hero p{font-size:1.1rem;color:var(--mut);max-width:34em}.cta{display:flex;gap:10px;margin-top:24px;flex-wrap:wrap}
.rack{background:#070b17;border:1px solid var(--ln);border-radius:10px;padding:12px;display:grid;gap:8px;box-shadow:0 24px 60px #0007}.rack .u{display:grid;grid-template-columns:auto 1fr 90px;gap:12px;align-items:center;padding:12px 14px;background:linear-gradient(#141d38,#101830);border:1px solid var(--ln);border-radius:5px;font:13px var(--mono)}
.rack .u span{color:var(--mut);margin-left:8px}.rack .led{animation:boot 2.6s both;animation-delay:calc(var(--i)*.55s)}.rack .m{height:7px;background:#0a1226;border-radius:2px;overflow:hidden}.rack .m i{display:block;height:100%;width:var(--w);background:var(--pri-h);animation:fill 1.6s both;animation-delay:calc(var(--i)*.55s + 1s)}
@keyframes boot{0%{background:#2a3352;box-shadow:none}35%{background:var(--wait);box-shadow:0 0 8px var(--wait)}100%{background:var(--on);box-shadow:0 0 8px var(--on)}}@keyframes fill{from{width:0}}
.steps{counter-reset:s;display:grid;grid-template-columns:repeat(3,1fr);gap:0;border:1px solid var(--ln);border-radius:10px;overflow:hidden}.steps li{list-style:none;padding:22px;background:var(--s1);border-right:1px solid var(--ln);counter-increment:s}.steps li:last-child{border:0}
.steps li:before{content:counter(s);display:inline-grid;place-items:center;width:26px;height:26px;border-radius:50%;background:var(--pri);font-weight:700;font-size:13px;margin-bottom:10px}.steps b{display:block;margin-bottom:4px}.steps p{margin:0;color:var(--mut);font-size:14px}
.cmp td:first-child{color:var(--mut)}.cmp th,.cmp td{padding:12px 14px}.cmp .hl{background:#6d7cff14}.faq{display:grid;gap:8px}.faq details{background:var(--s1);border:1px solid var(--ln);border-radius:8px;padding:13px 16px}.faq summary{cursor:pointer;font-weight:600}.faq p{color:var(--mut);margin:.5em 0 0}
.authwrap{display:grid;grid-template-columns:1fr 420px;gap:56px;align-items:center;min-height:calc(100vh - 140px)}.authwrap h1{font-size:2.2rem}.auth{max-width:420px;width:100%}
footer{color:var(--mut);font-size:13px;padding:28px 0;border-top:1px solid var(--ln);margin-top:50px;display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
@media(max-width:900px){.hero,.authwrap{grid-template-columns:1fr;gap:28px}.authside{display:none}.steps{grid-template-columns:1fr}.steps li{border-right:0;border-bottom:1px solid var(--ln)}
.shell{grid-template-columns:1fr}.side{position:fixed;inset:auto 0 0 0;height:auto;flex-direction:row;padding:6px;z-index:9;border-top:1px solid var(--ln);border-right:0}.brand,.me b,.nav a span{display:none}.nav{display:flex;flex:1;justify-content:space-around}.me{margin:0;border:0;padding:0;background:none}main{padding-bottom:90px}}
@media(prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}.rack .led{background:var(--on)}}
</style></head><body>
{% set p = request.path %}{% if me %}<div class="shell"><aside class="side"><a class="brand" href="/">{{ ico('server') }}<span>Ariznodes<sup>&trade;</sup></span></a>
<nav class="nav"><a href="/dashboard" class="{{ 'on' if p == '/dashboard' or p.startswith('/v/') or p.startswith('/vps') }}">{{ ico('grid') }}<span>Servers</span></a>
<a href="/account" class="{{ 'on' if p.startswith('/account') }}">{{ ico('user') }}<span>Account</span></a>
{% if me.is_admin %}<a href="/admin" class="{{ 'on' if p == '/admin' }}">{{ ico('shield') }}<span>Admin</span></a><a href="/admin/more" class="{{ 'on' if p.startswith('/admin/') }}">{{ ico('sliders') }}<span>Admin tools</span></a>{% endif %}</nav>
<div class="me">{{ ico('user') }}<b>{{ me.username }}</b><form method="post" action="/logout" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="lnk" title="Log out" aria-label="Log out">{{ ico('logout') }}</button></form></div></aside><div>
{% else %}<header class="pub"><a class="brand" href="/" style="padding:0">{{ ico('server') }}<span>Ariznodes<sup>&trade;</sup> HVM</span></a><span class="sp"></span><a href="/login">Log in</a><a class="btn" href="/register">Create account</a></header><div>{% endif %}
{% if announce %}<div class="banner">{{ announce }}</div>{% endif %}<div class="toasts">{% for c, m in get_flashed_messages(with_categories=true) %}<div class="flash {{ c }}" role="status">{{ m }}</div>{% endfor %}</div>
<main class="{{ '' if me else 'pubmain' }}">{% block body %}{% endblock %}{% if not me %}<footer><span>Ariznodes&trade; HVM Panel, built by {{ creator }}</span><span>Servers are free; abuse and mining get you banned.</span></footer>{% endif %}</main></div>{% if me %}</div>{% endif %}
<script nonce="{{ nonce }}">document.querySelectorAll('[data-w]').forEach(b=>setTimeout(()=>b.style.width=b.dataset.w+'%',120));setTimeout(()=>document.querySelectorAll('.flash').forEach(f=>{f.style.transition='opacity .4s';f.style.opacity=0}),6500);</script>
{% block scripts %}{% endblock %}</body></html>'''

T["home.html"] = r'''{% extends "base.html" %}{% block body %}
<section class="hero"><div><h1>Invite two friends. Get a server.</h1>
<p>Ariznodes HVM turns real Discord invites into LXC containers and KVM virtual machines. Every server comes with SSH, a browser terminal, snapshots and a control panel.</p>
<div class="cta"><a class="btn" href="/register">Create account</a><a class="btn ghost" href="/login">Log in</a></div></div>
<div class="rack" aria-hidden="true">{% for n, pl, w in [('anz-nova-01', 'basic', '34%'), ('anz-orbit-02', 'medium', '58%'), ('anz-vega-03', 'large', '71%'), ('anz-lyra-04', 'basic', '22%')] %}
<div class="u" style="--i:{{ loop.index0 }};--w:{{ w }}"><span style="margin:0"><i class="led"></i></span><b>{{ n }}<span>{{ pl }}</span></b><div class="m"><i></i></div></div>{% endfor %}</div></section>
<h2>How you get a server</h2><ol class="steps" style="padding:0;margin:0"><li><b>Link your Discord</b><p>Sign in with Discord so we know which invites are yours.</p></li>
<li><b>Invite real members</b><p>Our bot counts only genuine accounts that stay in the server.</p></li><li><b>Deploy and connect</b><p>Pick a container or VM, then connect over SSH or from your browser.</p></li></ol>
<h2>Plans</h2><div class="card" style="padding:6px 8px;overflow:auto"><table class="cmp"><tr><th></th>{% for k in PLANS %}<th class="{{ 'hl' if k == 'medium' }}">{{ k }}</th>{% endfor %}</tr>
<tr><td>Invites needed</td>{% for k, p in PLANS.items() %}<td class="{{ 'hl' if k == 'medium' }}">{{ p.invites }}</td>{% endfor %}</tr><tr><td>vCPU</td>{% for k, p in PLANS.items() %}<td class="{{ 'hl' if k == 'medium' }}">{{ p.cpu }}</td>{% endfor %}</tr>
<tr><td>Memory</td>{% for k, p in PLANS.items() %}<td class="{{ 'hl' if k == 'medium' }}">{{ p.ram // 1024 }} GB</td>{% endfor %}</tr><tr><td>Disk</td>{% for k, p in PLANS.items() %}<td class="{{ 'hl' if k == 'medium' }}">{{ p.disk }} GB</td>{% endfor %}</tr></table></div>
<h2>What is included</h2><div class="grid"><div class="card"><h3 style="margin-top:0">{{ ico('link') }} SSH and browser terminal</h3><p class="mut">Public SSH address or a web terminal, no port forwarding.</p></div>
<div class="card"><h3 style="margin-top:0">{{ ico('refresh') }} Snapshots and reinstall</h3><p class="mut">Save a known-good state and roll back in one click.</p></div>
<div class="card"><h3 style="margin-top:0">{{ ico('lock') }} Two-factor login</h3><p class="mut">Authenticator-app codes, device sign-out and an audit trail.</p></div>
<div class="card"><h3 style="margin-top:0">{{ ico('bolt') }} REST API</h3><p class="mut">Start, stop and monitor servers from your own scripts.</p></div></div>
<h2>Questions</h2><div class="faq"><details><summary>Why do I need Discord?</summary><p>Invites are checked by our bot. Your account must be linked so credit goes to the right person.</p></details>
<details><summary>What counts as a valid invite?</summary><p>An account older than a week that joined through your link and is still in the server.</p></details>
<details><summary>Do servers expire?</summary><p>Depending on the host settings, you may need to renew with one click. Expired servers are paused first and deleted only after a grace period.</p></details></div>{% endblock %}'''

T["auth.html"] = r'''{% extends "base.html" %}{% block body %}<div class="authwrap"><div class="authside"><h1>{{ 'Create your account' if mode == 'register' else 'Sign in to your servers' }}</h1>
<p class="mut" style="max-width:30em">{{ 'Link Discord, invite real members and unlock your first server.' if mode == 'register' else 'Manage servers, open a terminal and check usage.' }}</p>
<div class="rack" style="margin-top:26px;max-width:380px" aria-hidden="true">{% for w in ['40%', '64%', '28%'] %}<div class="u" style="--i:{{ loop.index0 }};--w:{{ w }}"><span style="margin:0"><i class="led"></i></span><b>&nbsp;</b><div class="m"><i></i></div></div>{% endfor %}</div></div>
<div class="card auth"><h2 style="margin-top:0">{{ 'Create account' if mode == 'register' else 'Welcome back' }}</h2><form method="post" autocomplete="on"><input type="hidden" name="csrf" value="{{ csrf }}">
<label>Username</label><input name="username" required minlength="3" maxlength="20" autocomplete="username"><label>Password</label>
<input name="password" type="password" required minlength="{{ 10 if mode == 'register' else 1 }}" autocomplete="{{ 'new-password' if mode == 'register' else 'current-password' }}">{% if mode == 'register' %}<p class="mut" style="margin:-6px 0 12px;font-size:13px">At least 10 characters.</p>{% endif %}
{% if ts_site %}<div class="cf-turnstile" data-sitekey="{{ ts_site }}" data-theme="dark"></div>{% endif %}<button style="width:100%;justify-content:center">{{ 'Create account' if mode == 'register' else 'Log in' }}</button></form>
<p class="mut" style="margin-bottom:0">{% if mode == 'login' %}New here? <a href="/register">Create an account</a>{% else %}Already registered? <a href="/login">Log in</a>{% endif %}</p></div></div>
{% if ts_site %}<script nonce="{{ nonce }}" src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>{% endif %}{% endblock %}'''

T["dash.html"] = r'''{% extends "base.html" %}{% block body %}
<div class="ph"><h1 style="font-size:1.7rem">Hello, {{ me.username }}</h1><p>Deploy, connect and manage your servers.</p></div>
<div class="grid"><div class="card"><span class="mut">Discord</span><div class="big">{% if me.discord_id %}{{ me.discord_name }}{% else %}Not linked{% endif %}</div>
{% if not me.discord_id %}<a class="btn" href="/discord/link">{{ ico('link') }} Authorize Discord</a>{% else %}<span class="tag">verified</span>{% endif %}</div>
<div class="card"><span class="mut">Verified invites</span><div class="big">{{ n }}</div><div class="bar"><i data-w="{{ pct }}" style="width:0"></i></div>
<p class="mut">{% if nxt %}{{ nxt[1].invites - n }} more for <b>{{ nxt[0] }}</b>{% else %}Top tier unlocked{% endif %}</p></div>
<div class="card"><span class="mut">Your plan</span><div class="big">{{ plan or 'none' }}</div><p class="mut">Fake, young or departed accounts do not count.</p></div></div>
<h2>Deploy a server</h2>{% if plan or me.is_admin %}<div class="card"><form method="post" action="/vps/create"><input type="hidden" name="csrf" value="{{ csrf }}">
<div class="grid"><div><label>Type</label><select name="kind"><option value="ct">Container (LXC / Docker fallback)</option><option value="vm">Virtual machine (KVM/QEMU)</option></select></div>
<div><label>OS</label><select name="image"><option>24.04</option><option>22.04</option></select></div>
<div><label>Plan</label><select name="plan">{% for k, p in PLANS.items() %}{% if p.invites <= n or me.is_admin %}<option value="{{ k }}">{{ k }}</option>{% endif %}{% endfor %}</select></div></div>
<button>{{ ico('bolt') }} Request VPS</button> <span class="mut" style="margin-left:10px">Limit: {{ max_vps }} per user</span></form></div>
{% else %}<div class="card mut">{{ ico('lock') }} Link Discord and invite at least 2 real members to unlock deployments.</div>{% endif %}
<h2>Your servers</h2><div class="units">{% for v in vps %}<a class="unit {{ v.status }}" href="/v/{{ v.id }}"><i class="dot"></i><b>{{ v.label or v.name }}</b><span>{{ v.plan }}, {{ 'VM' if v.kind == 'vm' else 'container' }}</span><em>{{ v.status }}</em></a>
{% else %}<div class="empty">No servers yet. Request one above and it appears here.</div>{% endfor %}</div>
{% if vps|selectattr('status', 'equalto', 'pending')|list or vps|selectattr('status', 'equalto', 'running')|list|length == 0 and vps %}<script nonce="{{ nonce }}">setTimeout(()=>location.reload(),6000)</script>{% endif %}{% endblock %}'''

T["vps.html"] = r'''{% extends "base.html" %}{% block body %}<h1 style="font-size:2rem">{{ v.name }}</h1>
<div class="grid"><div class="card {{ live }}"><span class="mut">State</span><div class="big"><span class="dot"></span>{{ live }}</div></div>
<div class="card"><span class="mut">Plan / engine</span><div class="big">{{ v.plan }}</div><span class="tag">{{ v.engine or 'pending' }} &middot; {{ 'VM' if v.kind == 'vm' else 'container' }}</span></div>
<div class="card"><span class="mut">Root password</span><pre>{{ pw }}</pre></div></div>
{% if v.engine %}<h2>Controls</h2><div class="card"><form method="post" class="inl" action="/vps/{{ v.id }}/start"><input type="hidden" name="csrf" value="{{ csrf }}"><button>{{ ico('play') }} Start</button></form>
<form method="post" class="inl" action="/vps/{{ v.id }}/stop"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="ghost">{{ ico('stop') }} Stop</button></form>
<form method="post" class="inl" action="/vps/{{ v.id }}/restart"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="ghost">{{ ico('refresh') }} Restart</button></form>
<form method="post" class="inl" action="/vps/{{ v.id }}/delete"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="red">{{ ico('trash') }} Delete</button></form></div>
<h2>Console</h2><div class="card"><form method="post" action="/vps/{{ v.id }}/exec"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="cmd" placeholder="uname -a" maxlength="500" required><button>Run</button></form>
{% if out is not none %}<pre>{{ out }}</pre>{% endif %}</div>
{% else %}<div class="card"><form method="post" action="/vps/{{ v.id }}/delete"><input type="hidden" name="csrf" value="{{ csrf }}"><p class="mut">Status: {{ v.status }}</p><button class="red">{{ ico('trash') }} Remove</button></form></div>{% endif %}{% endblock %}'''

T["admin.html"] = r'''{% extends "base.html" %}{% block body %}<h1 style="font-size:2rem">{{ ico('shield') }} Admin <span class="grad">control</span></h1><p><a class="btn" href="/admin/more">{{ ico('bolt') }} More tools</a></p>
<div class="grid"><div class="card"><span class="mut">CPU</span><div class="big">{{ cpu }}%</div><div class="bar"><i data-w="{{ cpu }}" style="width:0"></i></div></div>
<div class="card"><span class="mut">RAM</span><div class="big">{{ ram }}%</div><div class="bar"><i data-w="{{ ram }}" style="width:0"></i></div></div>
<div class="card"><span class="mut">Disk</span><div class="big">{{ disk }}%</div><div class="bar"><i data-w="{{ disk }}" style="width:0"></i></div></div>
<div class="card"><span class="mut">Uptime</span><div class="big" style="font-size:1.4rem">{{ uptime }}</div></div></div>
<h2>Nodes</h2><div class="card"><table><tr><th>Node</th><th>Status</th><th>LXC</th><th>Docker</th><th>KVM</th></tr><tr><td>local (this host)</td><td><span class="dot on"></span>online</td>
<td><span class="dot {{ 'on' if lxc else 'off' }}"></span></td><td><span class="dot {{ 'on' if docker else 'off' }}"></span></td><td><span class="dot {{ 'on' if kvm else 'off' }}"></span></td></tr></table></div>
<h2>{{ ico('alert') }} Alerts</h2><div class="card"><table>{% for a in alerts %}<tr><td><span class="tag">{{ a.kind }}</span></td><td>{{ a.detail }}</td><td class="mut">{{ a.created_at|ts }}</td></tr>{% else %}<tr><td class="mut">All quiet.</td></tr>{% endfor %}</table>
<form method="post" action="/admin/alerts/clear"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="ghost">Clear</button></form></div>
<h2>Users</h2><div class="card" style="overflow:auto"><table><tr><th>User</th><th>Discord</th><th>Role</th><th></th></tr>{% for u in users %}<tr><td>{{ u.username }}</td><td>{{ u.discord_name or '-' }}</td>
<td>{{ 'admin' if u.is_admin else 'user' }}{% if u.banned %} <span class="tag">banned</span>{% endif %}</td><td>{% if u.id != me.id %}
{% for act, label in [('unban' if u.banned else 'ban', 'Unban' if u.banned else 'Ban'), ('demote' if u.is_admin else 'promote', 'Remove admin' if u.is_admin else 'Make admin')] %}
<form method="post" class="inl" action="/admin/user/{{ u.id }}/{{ act }}"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="ghost">{{ label }}</button></form> {% endfor %}{% endif %}</td></tr>{% endfor %}</table></div>
<h2>All servers</h2><div class="card" style="overflow:auto"><table><tr><th>Name</th><th>Owner</th><th>Plan</th><th>Engine</th><th>Status</th><th></th></tr>{% for v in vps %}<tr class="{{ v.status }}"><td>{{ v.name }}</td><td>{{ v.username }}</td><td>{{ v.plan }}</td><td>{{ v.engine or '-' }}</td><td><span class="dot"></span>{{ v.status }}</td><td><a href="/v/{{ v.id }}">Open</a></td></tr>{% endfor %}</table></div>
<h2>Settings</h2><div class="card"><form method="post" action="/admin/settings"><input type="hidden" name="csrf" value="{{ csrf }}">
<label>Max servers per user</label><input name="max_vps" value="{{ s.max_vps }}"><label>Announcement banner</label><input name="announcement" value="{{ s.announcement }}" maxlength="200">
<label><input type="checkbox" name="registration" style="width:auto" {{ 'checked' if s.registration == '1' }}> Open registration</label>
<label><input type="checkbox" name="mining_autostop" style="width:auto" {{ 'checked' if s.mining_autostop == '1' }}> Auto-stop servers flagged for crypto mining</label><br><button>Save</button></form></div>{% endblock %}'''
app.jinja_loader = DictLoader(T)

import features  # noqa: E402,F401  (registers the v2.1 routes and templates)

if __name__ == "__main__":
    app.run(os.getenv("BIND_HOST", "127.0.0.1"), int(os.getenv("PORT", 8080)))
PYAPP

# ---------------------------------------------------------------- bot.py
cat > "$APP/bot.py" <<'PYBOT'
"""Verification + provisioning bot: tracks invites, flags raids, processes VPS jobs, watches for mining."""
import asyncio, collections, json, logging, os, time
import discord
from discord import app_commands
import core, ops

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
log = logging.getLogger("ariznodes-bot")
GUILD = int(os.environ["DISCORD_GUILD_ID"])
LOGCH = int(os.getenv("DISCORD_LOG_CHANNEL_ID") or 0)
MIN_AGE = 7 * 86400  # invitee accounts younger than this are treated as fake
core.init_db()

class Bot(discord.Client):
    def __init__(self):
        i = discord.Intents.default(); i.members = True  # needs "Server Members Intent" enabled in the dev portal
        super().__init__(intents=i)
        self.tree = app_commands.CommandTree(self)
        self.cache, self.joins, self.last_raid = {}, collections.deque(), 0.0
        self.hot, self.last_cpu = collections.Counter(), {}

    async def setup_hook(self):
        self.tree.copy_global_to(guild=discord.Object(GUILD)); await self.tree.sync(guild=discord.Object(GUILD))
        self.loop.create_task(self.jobs_loop()); self.loop.create_task(self.monitor_loop())

    async def notify(self, text):
        ch = self.get_channel(LOGCH) if LOGCH else None
        if ch:
            try: await ch.send(text, allowed_mentions=discord.AllowedMentions.none())
            except discord.HTTPException: pass

    async def on_ready(self):
        g = self.get_guild(GUILD)
        try: self.cache = {i.code: i.uses for i in await g.invites()}
        except discord.Forbidden: log.error("Bot needs the Manage Server permission to read invites")
        log.info("ready as %s", self.user)

    async def on_invite_create(self, inv): self.cache[inv.code] = inv.uses
    async def on_invite_delete(self, inv): self.cache.pop(inv.code, None)

    async def on_member_join(self, m):
        if m.guild.id != GUILD or m.bot: return
        now = time.time(); self.joins.append(now)
        while self.joins and now - self.joins[0] > 60: self.joins.popleft()
        if len(self.joins) >= 10 and now - self.last_raid > 300:  # 10+ joins/minute
            self.last_raid = now; core.alert("raid", f"{len(self.joins)} members joined within 60s")
            await self.notify(f"RAID ALERT: {len(self.joins)} joins in 60s")
        try: invs = await m.guild.invites()
        except discord.Forbidden: return
        used = next((i for i in invs if i.uses > self.cache.get(i.code, 0)), None)
        self.cache = {i.code: i.uses for i in invs}
        if not used or not used.inviter or used.inviter.id == m.id: return
        valid = int(now - m.created_at.timestamp() >= MIN_AGE)  # brand-new accounts = fake
        core.ex("INSERT OR IGNORE INTO invites(inviter_id,invitee_id,valid) VALUES(?,?,?)", (str(used.inviter.id), str(m.id), valid))

    async def on_member_remove(self, m):  # leavers no longer count, and re-joining cannot re-credit them
        if m.guild.id == GUILD: core.ex("UPDATE invites SET valid=0 WHERE invitee_id=?", (str(m.id),))

    # ------------------------------------------------------------ VPS jobs
    async def jobs_loop(self):
        await self.wait_until_ready()
        while not self.is_closed():
            try:
                for j in core.q("SELECT * FROM jobs WHERE status='pending' ORDER BY id LIMIT 3"): await self.handle(j)
            except Exception: log.exception("jobs loop")
            await asyncio.sleep(4)

    async def handle(self, j):
        core.ex("UPDATE jobs SET status='running' WHERE id=?", (j["id"],))
        v = core.q("SELECT * FROM vps WHERE id=?", (j["vps_id"],), one=True)
        if not v: return core.ex("UPDATE jobs SET status='failed', message='vps removed' WHERE id=?", (j["id"],))
        u = core.q("SELECT * FROM users WHERE id=?", (v["user_id"],), one=True)
        try:
            if not u["discord_id"]: raise RuntimeError("Discord account not linked")
            guild = self.get_guild(GUILD)
            try: await guild.fetch_member(int(u["discord_id"]))
            except discord.NotFound: raise RuntimeError("User is not in the Discord server")
            n = core.valid_invites(u["discord_id"]); need = core.PLANS[v["plan"]]["invites"]
            if n < need and not u["is_admin"]: raise RuntimeError(f"Needs {need} valid invites, has {n}")
            await self.notify(f"<@{u['discord_id']}> wants a {v['plan']} {v['kind']} - verified ({n} legitimate invites). Provisioning...")
            nid = await asyncio.to_thread(core.pick_node, v["kind"])  # this host first, then the remote node with free slots
            core.ex("UPDATE vps SET node_id=? WHERE id=?", (nid, v["id"]))
            def _prov(): core.set_node(nid); return core.provision(v["name"], v["plan"], v["kind"], v["image"], core.dec(v["secret"]))
            engine = await asyncio.to_thread(_prov)
            core.ex("UPDATE vps SET status='running', engine=? WHERE id=?", (engine, v["id"]))
            ops.set_expiry(v["id"])
            core.ex("UPDATE jobs SET status='done' WHERE id=?", (j["id"],))
            await self.notify(f"<@{u['discord_id']}> your server `{v['name']}` is ready on {engine}.")
            try: await (await self.fetch_user(int(u["discord_id"]))).send(f"Your Ariznodes server `{v['name']}` is ready - manage it in the panel.")
            except discord.HTTPException: pass
        except Exception as e:
            log.warning("job %s failed: %s", j["id"], e)
            core.ex("UPDATE vps SET status='failed' WHERE id=?", (v["id"],))
            core.ex("UPDATE jobs SET status='failed', message=? WHERE id=?", (str(e)[:300], j["id"]))
            await self.notify(f"Provisioning denied/failed for `{v['name']}`: {e}")

    # ------------------------------------------------------------ monitoring
    async def monitor_loop(self):
        await self.wait_until_ready()
        while not self.is_closed():
            try: await asyncio.to_thread(self.scan)
            except Exception: log.exception("monitor")
            await asyncio.sleep(60)

    def cpu_pct(self, v):
        cores = core.PLANS[v["plan"]]["cpu"]
        if v["engine"] == "docker":
            return float(core.run(["docker", "stats", "--no-stream", "--format", "{{.CPUPerc}}", v["name"]], 30).strip().rstrip("%")) / cores
        ns = json.loads(core.run(["lxc", "query", f"/1.0/instances/{v['name']}/state"], 20))["cpu"]["usage"]
        now, prev = time.time(), self.last_cpu.get(v["name"]); self.last_cpu[v["name"]] = (ns, now)
        return None if not prev else (ns - prev[0]) / 1e9 / (now - prev[1]) / cores * 100

    def scan(self):  # sustained >90% CPU for 5 consecutive minutes is treated as likely mining
        for gone in ops.expire_sweep(): log.info("expired server removed: %s", gone)
        for v in core.q("SELECT * FROM vps WHERE engine IS NOT NULL"):
            core.set_node(v["node_id"])
            st = core.state(v["engine"], v["name"])
            if st != v["status"]: core.ex("UPDATE vps SET status=? WHERE id=?", (st, v["id"]))
            if st != "running": self.hot[v["name"]] = 0; continue
            try: ops.keepalive(v)  # restart sshd / reopen dropped tunnels
            except Exception: log.exception("keepalive %s", v["name"])
            try: p = self.cpu_pct(v)
            except Exception: continue  # node offline or instance busy
            if p is None: continue
            self.hot[v["name"]] = self.hot[v["name"]] + 1 if p > 90 else 0
            if self.hot[v["name"]] >= 5:
                self.hot[v["name"]] = 0; core.alert("mining", f"{v['name']} sustained >90% CPU for 5 min")
                if core.setting("mining_autostop") == "1": core.control(v["engine"], v["name"], "stop")

bot = Bot()

@bot.tree.command(name="invites", description="Show your verified invite count and plan")
async def invites(i: discord.Interaction):
    n = core.valid_invites(i.user.id)
    await i.response.send_message(f"You have **{n}** verified invites - plan: **{core.plan_for(n) or 'none yet'}**.", ephemeral=True)

def _mention_safe(): return discord.AllowedMentions.none()

@bot.tree.command(name="help", description="What this bot can do")
async def help_cmd(i: discord.Interaction):
    await i.response.send_message("**Ariznodes HVM**\n`/invites` your verified invites\n`/myservers` your servers\n`/plans` plan sizes\n`/leaderboard` top inviters\n`/status` panel status\n`/nodes` node health (staff)", ephemeral=True)

@bot.tree.command(name="myservers", description="List your servers")
async def myservers(i: discord.Interaction):
    u = core.q("SELECT id FROM users WHERE discord_id=?", (str(i.user.id),), one=True)
    if not u: return await i.response.send_message("Link your Discord account in the panel first.", ephemeral=True)
    rows = core.q("SELECT * FROM vps WHERE user_id=? ORDER BY id DESC", (u["id"],))
    await i.response.send_message("\n".join(f"`{v['name']}` {v['plan']} {v['kind']} - {v['status']}" for v in rows) or "No servers yet. Deploy one in the panel.", ephemeral=True)

@bot.tree.command(name="plans", description="Plan sizes and invites needed")
async def plans(i: discord.Interaction):
    await i.response.send_message("\n".join(f"**{k}**: {p['invites']} invites, {p['cpu']} vCPU, {p['ram'] // 1024} GB RAM, {p['disk']} GB, {p['slots']} server(s)" for k, p in core.PLANS.items()), ephemeral=True)

@bot.tree.command(name="leaderboard", description="Top inviters")
async def leaderboard(i: discord.Interaction):
    rows = core.q("SELECT inviter_id, COUNT(*) n FROM invites WHERE valid=1 GROUP BY inviter_id ORDER BY n DESC LIMIT 10")
    await i.response.send_message("\n".join(f"{k + 1}. <@{r['inviter_id']}> - {r['n']}" for k, r in enumerate(rows)) or "No invites tracked yet.", allowed_mentions=_mention_safe())

@bot.tree.command(name="status", description="Panel status")
async def status(i: discord.Interaction):
    c = lambda s: core.q(s, one=True)["n"]
    await i.response.send_message(f"Users: **{c('SELECT COUNT(*) n FROM users')}**, servers running: **{c(chr(83) + 'ELECT COUNT(*) n FROM vps WHERE status=' + chr(39) + 'running' + chr(39))}**, remote nodes: **{c('SELECT COUNT(*) n FROM nodes WHERE enabled=1')}**.", ephemeral=True)

@bot.tree.command(name="nodes", description="Node health (staff only)")
@app_commands.default_permissions(manage_guild=True)
async def nodes(i: discord.Interaction):
    rows = core.q("SELECT * FROM nodes ORDER BY id")
    used0 = core.q("SELECT COUNT(*) n FROM vps WHERE node_id=0", one=True)["n"]
    lines = [f"local: {used0} servers"] + [f"{n['name']}: {core.q('SELECT COUNT(*) n FROM vps WHERE node_id=?', (n['id'],), one=True)['n']}/{n['slots']} slots, {'on' if n['enabled'] else 'off'}" for n in rows]
    await i.response.send_message("\n".join(lines), ephemeral=True)

bot.run(os.environ["DISCORD_BOT_TOKEN"], log_handler=None)
PYBOT

# ---------------------------------------------------------------- ops.py
cat > "$APP/ops.py" <<'PYOPS'
"""Container operations shared by the web panel and the Discord bot (no Flask imports)."""
import json, re, shlex, time
import core
from core import PLANS, run

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
QUICK = {  # one-click installs shown in the panel
    "update": "apt-get update -qq && apt-get upgrade -y -qq",
    "tools":  "apt-get install -y -qq htop neofetch nano wget unzip zip procps iproute2 net-tools",
    "build":  "apt-get install -y -qq build-essential",
    "python": "apt-get install -y -qq python3 python3-pip python3-venv",
    "node":   "apt-get install -y -qq nodejs npm",
    "git":    "apt-get install -y -qq git",
    "nginx":  "apt-get install -y -qq nginx",
    "docker": "apt-get install -y -qq docker.io",
}

def sh(v, script, timeout=60, inp=None, args=()):
    """Run a bash script inside the instance. Arguments arrive as $1.. (never interpolated)."""
    base = ["lxc", "exec", v["name"], "--"] if v["engine"] == "lxc" else ["docker", "exec", "-i", v["name"]]
    return run(base + ["bash", "-lc", script, "_", *args], timeout, inp)

# ----------------------------------------------------------------- SSH + tools
PREP = ("command -v curl >/dev/null && command -v ssh >/dev/null || { export DEBIAN_FRONTEND=noninteractive; "
        "apt-get update -qq && apt-get install -y -qq curl ca-certificates openssh-client >/dev/null; }\n")
SSH_SCRIPT = r'''set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openssh-server openssh-client curl ca-certificates procps iproute2 nano >/dev/null
mkdir -p /run/sshd /etc/ssh/sshd_config.d
printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/00-ariznodes.conf
if [ -d /run/systemd/system ]; then systemctl enable --now ssh >/dev/null 2>&1 || systemctl restart ssh
else pgrep -x sshd >/dev/null || { setsid nohup /usr/sbin/sshd -D >/dev/null 2>&1 </dev/null & }; fi
sleep 1; pgrep -x sshd >/dev/null'''

def ssh_enable(v):
    core.ex("UPDATE vps SET ssh_state='installing' WHERE id=?", (v["id"],))
    try:
        sh(v, SSH_SCRIPT, 900)
        core.ex("UPDATE vps SET ssh_state='ready' WHERE id=?", (v["id"],))
    except Exception:
        core.ex("UPDATE vps SET ssh_state='failed' WHERE id=?", (v["id"],)); raise

def _start_tunnel(v, kind, token=""):
    if kind == "pinggy":
        user = f"{token}+tcp@pro.pinggy.io" if token else "tcp@free.pinggy.io"
        launch = ("ssh -p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 "
                  f"-o ExitOnForwardFailure=yes -R0:localhost:22 {shlex.quote(user)}")
        pat = r"tcp://[A-Za-z0-9._-]+:[0-9]+"
    else:
        launch = "sshx -q"
        pat = r"https://sshx\.io/s/[^ ]+"
    # PID files, not pkill -f: a pkill pattern would also match this very shell.
    script = PREP + (("command -v sshx >/dev/null || (curl -sSf https://sshx.io/get | sh) >/dev/null 2>&1\n" if kind == "sshx" else "") +
        f"[ -f /tmp/{kind}.pid ] && kill $(cat /tmp/{kind}.pid) 2>/dev/null; rm -f /tmp/{kind}.log\n"
        f"setsid nohup {launch} >/tmp/{kind}.log 2>&1 </dev/null &\necho $! > /tmp/{kind}.pid\n"
        f"for i in $(seq 1 40); do u=$(grep -aoE '{pat}' /tmp/{kind}.log | head -n1); "
        "[ -n \"$u\" ] && { echo \"$u\"; exit 0; }; sleep 1; done; tail -n 5 /tmp/" + kind + ".log >&2; exit 1")
    return sh(v, script, 180).strip().splitlines()[-1]

def _stop_tunnel(v, kind):
    try: sh(v, f"[ -f /tmp/{kind}.pid ] && kill $(cat /tmp/{kind}.pid) 2>/dev/null; rm -f /tmp/{kind}.pid; true", 20)
    except Exception: pass

def pinggy_start(v):
    url = _start_tunnel(v, "pinggy", core.setting("pinggy_token").strip())
    core.ex("UPDATE vps SET pinggy_on=1, pinggy_url=? WHERE id=?", (url, v["id"])); return url
def pinggy_stop(v): _stop_tunnel(v, "pinggy"); core.ex("UPDATE vps SET pinggy_on=0, pinggy_url=NULL WHERE id=?", (v["id"],))
def sshx_start(v):
    url = _start_tunnel(v, "sshx"); core.ex("UPDATE vps SET sshx_url=? WHERE id=?", (url, v["id"])); return url
def sshx_stop(v): _stop_tunnel(v, "sshx"); core.ex("UPDATE vps SET sshx_url=NULL WHERE id=?", (v["id"],))

def tunnel_target(url):
    m = re.match(r"tcp://([^:]+):(\d+)", url or "")
    return (m.group(1), m.group(2)) if m else (None, None)

def keepalive(v):
    """Called by the bot every minute: restart sshd after a Docker restart and re-open dropped pinggy tunnels
    (free pinggy tunnels are time limited and change address on reconnect)."""
    if v["suspended"]: return
    if v["engine"] == "docker" and v["ssh_state"] == "ready":
        sh(v, "pgrep -x sshd >/dev/null || { mkdir -p /run/sshd; setsid nohup /usr/sbin/sshd -D >/dev/null 2>&1 </dev/null & }", 20)
    if v["pinggy_on"] and core.setting("auto_tunnel") == "1":
        try: sh(v, "[ -f /tmp/pinggy.pid ] && kill -0 $(cat /tmp/pinggy.pid) 2>/dev/null", 20)
        except Exception: pinggy_start(v)

# ------------------------------------------------------------------ live data
def _lxc_state(n): return json.loads(run(["lxc", "query", f"/1.0/instances/{n}/state"], 20))

def stats(v):
    n, p = v["name"], PLANS[v["plan"]]
    if v["engine"] == "docker":
        j = json.loads(run(["docker", "stats", "--no-stream", "--format", "{{json .}}", n], 30))
        return dict(cpu=round(min(float(j["CPUPerc"].rstrip("%")) / p["cpu"], 100), 1), mem_pct=float(j["MemPerc"].rstrip("%")),
                    mem=j["MemUsage"], net=j["NetIO"], disk=j["BlockIO"], pids=j["PIDs"])
    a = _lxc_state(n); t0 = time.time(); time.sleep(1); b = _lxc_state(n); dt = max(time.time() - t0, 0.5)
    cpu = (b["cpu"]["usage"] - a["cpu"]["usage"]) / 1e9 / dt / p["cpu"] * 100
    used, limit = b["memory"]["usage"], p["ram"] * 1048576
    net = (b.get("network") or {}).get("eth0", {}).get("counters", {})
    mb = lambda x: f"{x / 1048576:.0f} MiB"
    return dict(cpu=round(max(0, min(cpu, 100)), 1), mem_pct=round(100 * used / limit, 1), mem=f"{mb(used)} / {mb(limit)}",
                net=f"{mb(net.get('bytes_received', 0))} in / {mb(net.get('bytes_sent', 0))} out", disk="-", pids=b.get("processes", 0))

def ip_of(v):
    try:
        if v["engine"] == "docker":
            return run(["docker", "inspect", "-f", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", v["name"]], 15).strip()
        for a in (_lxc_state(v["name"]).get("network") or {}).get("eth0", {}).get("addresses", []):
            if a["family"] == "inet": return a["address"]
    except Exception: pass
    return "-"

NEED = "command -v ps >/dev/null || { echo \"Install the tools first: Access tab > 'Enable SSH & tools'\"; exit 0; }\n"
INFO = {
    "ps":     NEED + "ps aux --sort=-%cpu | head -n 15",
    "disk":   "df -h 2>/dev/null; echo; free -m",
    "net":    "(ip -br a 2>/dev/null || hostname -I); echo; (ss -tlnp 2>/dev/null | head -n 20)",
    "uptime": "uptime -p 2>/dev/null; echo; head -n 3 /etc/os-release; echo; uname -srm",
}
def info(v, what):
    if what == "logs":
        return run(["docker", "logs", "--tail", "150", v["name"]], 20) if v["engine"] == "docker" else run(["lxc", "info", v["name"], "--show-log"], 20)
    if what not in INFO: raise ValueError("unknown view")
    return sh(v, INFO[what], 30)

# ------------------------------------------------------------------ snapshots
def snap_list(v):
    n = v["name"]
    if v["engine"] == "lxc":
        return [dict(tag=s["name"], when=(s.get("created_at") or "")[:16].replace("T", " "), size="")
                for s in json.loads(run(["lxc", "query", f"/1.0/instances/{n}/snapshots?recursion=1"], 20))]
    out = run(["docker", "images", f"anzsnap/{n}", "--format", "{{.Tag}}|{{.CreatedSince}}|{{.Size}}"], 20)
    return [dict(tag=a, when=b, size=c) for a, b, c in (l.split("|") for l in out.splitlines() if l)]

def snap_ok(tag):
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,29}", tag or ""): raise ValueError("Snapshot name: 1-30 chars a-z, 0-9, dash")
    return tag

def snap_create(v, tag):
    snap_ok(tag)
    if len(snap_list(v)) >= 5: raise RuntimeError("Snapshot limit (5) reached - delete one first")
    run(["lxc", "snapshot", v["name"], tag], 300) if v["engine"] == "lxc" else run(["docker", "commit", v["name"], f"anzsnap/{v['name']}:{tag}"], 300)

def snap_delete(v, tag):
    snap_ok(tag)
    run(["lxc", "delete", f"{v['name']}/{tag}"], 120) if v["engine"] == "lxc" else run(["docker", "rmi", f"anzsnap/{v['name']}:{tag}"], 120)

def docker_recreate(v, ref):
    p = PLANS[v["plan"]]
    run(["docker", "rm", "-f", v["name"]], 120)
    run(["docker", "run", "-d", "--name", v["name"], "--restart", "unless-stopped", "--cpus", str(p["cpu"]),
         "--memory", f"{p['ram']}m", ref, "sleep", "infinity"], 900)

def snap_restore(v, tag):
    snap_ok(tag)
    if v["engine"] == "lxc": run(["lxc", "restore", v["name"], tag], 300)
    else:
        docker_recreate(v, f"anzsnap/{v['name']}:{tag}")
        core.ex("UPDATE vps SET pinggy_on=0, pinggy_url=NULL, sshx_url=NULL WHERE id=?", (v["id"],))  # processes died with the old container

# ---------------------------------------------------- lifecycle / admin actions
def reinstall(v, image, password):
    try: core.control(v["engine"], v["name"], "delete")
    except Exception: pass
    engine = core.provision(v["name"], v["plan"], v["kind"], image, password)
    core.ex("UPDATE vps SET engine=?, image=?, status='running', ssh_state=NULL, pinggy_on=0, pinggy_url=NULL, sshx_url=NULL WHERE id=?",
            (engine, image, v["id"]))

def resize(v, plan):
    p = PLANS[plan]
    if v["engine"] == "docker":
        run(["docker", "update", "--cpus", str(p["cpu"]), "--memory", f"{p['ram']}m", "--memory-swap", f"{p['ram']}m", v["name"]], 60)
    else:
        run(["lxc", "config", "set", v["name"], f"limits.cpu={p['cpu']}"], 60)
        run(["lxc", "config", "set", v["name"], f"limits.memory={p['ram']}MiB"], 60)
    core.ex("UPDATE vps SET plan=? WHERE id=?", (plan, v["id"]))

def set_root_password(v, pw): sh(v, "chpasswd", 30, f"root:{pw}\n")

# ------------------------------------------------------------------ file access
def ls(v, path): return sh(v, 'ls -1Ap --group-directories-first -- "$1"', 20, args=[path]).splitlines()
def read_file(v, path, limit=60000):
    return sh(v, 'if [ -f "$1" ]; then head -c %d -- "$1"; else echo "not a regular file" >&2; exit 1; fi' % limit, 20, args=[path])
def write_file(v, path, data):
    if len(data) > 200000: raise ValueError("File too large for the editor (200 KB max)")
    sh(v, 'cat > "$1"', 20, data, args=[path])

# -------------------------------------------------------------------- expiry
def set_expiry(vid):
    d = int(core.setting("vps_days") or 0)
    core.ex("UPDATE vps SET expires_at=? WHERE id=?", (time.time() + d * 86400 if d > 0 else 0, vid))

LXC_KEYS = {
    "nesting":   ("security.nesting", "Nesting (run Docker inside this container)", ["false", "true"], "false"),
    "autostart": ("boot.autostart", "Start automatically when the host boots", ["true", "false"], "false"),
    "swap":      ("limits.memory.swap", "Allow swap", ["true", "false"], "true"),
    "priority":  ("limits.cpu.priority", "CPU priority (0 low, 10 high)", [str(i) for i in range(11)], "5"),
    "procs":     ("limits.processes", "Process limit (0 = unlimited)", ["0", "256", "512", "1024", "4096"], "0"),
    "autosnap":  ("snapshots.schedule", "Automatic daily snapshot (kept 7 days)", ["off", "daily"], "off"),
}
def lxc_fields(v):
    cfg = json.loads(run(["lxc", "query", f"/1.0/instances/{v['name']}"], 20)).get("config", {})
    return [dict(key=k, label=lab, opts=opts, cur=("daily" if cfg.get(key) == "@daily" else "off") if k == "autosnap" else str(cfg.get(key, d)))
            for k, (key, lab, opts, d) in LXC_KEYS.items()]
def lxc_set(v, k, val):
    if k not in LXC_KEYS: raise ValueError("Unknown LXC setting")
    key, _, opts, _d = LXC_KEYS[k]; n = v["name"]
    if val not in opts: raise ValueError("Invalid value")
    if k == "autosnap":
        if val == "daily": run(["lxc", "config", "set", n, "snapshots.schedule", "@daily"], 30); run(["lxc", "config", "set", n, "snapshots.expiry", "7d"], 30)
        else: run(["lxc", "config", "unset", n, "snapshots.schedule"], 30)
    else: run(["lxc", "config", "set", n, key, val], 30)

def expire_sweep():
    """Stop expired servers; delete them after a 3-day grace period."""
    out, now = [], time.time()
    for v in core.q("SELECT * FROM vps WHERE engine IS NOT NULL AND expires_at>0 AND expires_at<?", (now,)):
        core.set_node(v["node_id"])
        if now > v["expires_at"] + 3 * 86400:
            try: core.control(v["engine"], v["name"], "delete")
            except Exception: pass
            core.ex("DELETE FROM jobs WHERE vps_id=?", (v["id"],)); core.ex("DELETE FROM vps WHERE id=?", (v["id"],))
            core.alert("expiry", f"{v['name']} deleted after the 3-day grace period"); out.append(v["name"])
        elif not v["suspended"]:
            try: core.control(v["engine"], v["name"], "stop")
            except Exception: pass
            core.ex("UPDATE vps SET suspended=1, susp_reason='expired' WHERE id=?", (v["id"],))
            core.alert("expiry", f"{v['name']} expired and was stopped")
    return out
PYOPS

# ---------------------------------------------------------------- features.py
cat > "$APP/fun.py" <<'PYFUN'
"""v3.5: themes + particles, XP/levels/badges/daily rewards, leaderboard, API tester, public status, extra login hardening."""
import hashlib, math, re, secrets, time
from flask import abort, flash, redirect, render_template, request, session
from itsdangerous import BadSignature, URLSafeTimedSerializer
from werkzeug.security import check_password_hash
import core
import app as A
import features as F
from app import T, app, limiter, login_required, me, real_ip
from features import act

# ------------------------------------------------------------- bot trap: honeypot + minimum fill time
_ser = URLSafeTimedSerializer(app.secret_key, salt="ft")
def make_ft(): return _ser.dumps(int(time.time()))
app.jinja_env.globals["make_ft"] = make_ft

def ft_ok(tok):
    try: t = _ser.loads(tok, max_age=3600)
    except BadSignature: return False
    return time.time() - t >= 2  # humans need more than 2 seconds to fill a form

@app.before_request
def bot_trap():
    if request.method == "POST" and request.path in ("/login", "/register") and (request.form.get("website") or not ft_ok(request.form.get("ft", ""))):
        flash("That form was sent too fast or looks automated. Wait a moment and try again.", "err"); return redirect(request.path)

@app.before_request
def session_guard():
    """Bind sessions to the browser, and tell admins when an admin signs in from somewhere new."""
    u = me()
    if "uid" in session and session.get("ua") not in (None, A.uahash()):
        session.clear(); flash("Your session ended because the browser changed. Log in again.", "err"); return redirect("/login")
    if not u or session.get("seen"): return
    session["seen"] = 1
    dev = hashlib.sha256((real_ip() + A.uahash()).encode()).hexdigest()[:16]
    known = core.q("SELECT 1 FROM activity WHERE user_id=? AND action='device' AND detail=?", (u["id"], dev), one=True)
    if not known:
        had_any = core.q("SELECT 1 FROM activity WHERE user_id=? AND action='device' LIMIT 1", (u["id"],), one=True)
        act("device", dev)
        if had_any and u["is_admin"]: core.alert("security", f"Admin {u['username']} signed in from a new device or IP ({real_ip()})")

# ---------------------------------------------------------- 2FA recovery codes
def new_codes(uid):
    core.ex("DELETE FROM recovery WHERE user_id=?", (uid,))
    codes = [f"{secrets.token_hex(2)}-{secrets.token_hex(2)}" for _ in range(8)]
    for c in codes: core.ex("INSERT INTO recovery(user_id,hash) VALUES(?,?)", (uid, hashlib.sha256(c.encode()).hexdigest()))
    return codes

def use_code(uid, code):
    c = core.db()
    try:
        cur = c.execute("UPDATE recovery SET used=1 WHERE user_id=? AND hash=? AND used=0", (uid, hashlib.sha256(code.strip().lower().encode()).hexdigest())); c.commit(); return cur.rowcount == 1
    finally: c.close()

_totp_ok = F.totp_ok
def totp_or_code(secret, code):  # the 2FA login also accepts a one-time recovery code
    if _totp_ok(secret, code): return True
    uid = session.get("pre2fa")
    return bool(uid and re.fullmatch(r"[0-9a-f]{4}-[0-9a-f]{4}", (code or "").strip().lower()) and use_code(uid, code))
F.totp_ok = totp_or_code

@app.post("/account/recovery")
@login_required
@limiter.limit("5/hour")
def recovery():
    u = me()
    if not u["totp_on"]: flash("Turn on 2FA first.", "err")
    elif not check_password_hash(u["pw_hash"], request.form.get("password", "")): flash("Password is wrong.", "err")
    else: session["new_codes"] = new_codes(u["id"]); act("2fa", "recovery codes regenerated")
    return redirect("/account")

# ------------------------------------------------------------- XP, levels, badges, rewards
TITLES = ["Rookie", "Builder", "Hoster", "Architect", "Legend"]
def profile(u):
    n = core.valid_invites(u["discord_id"]) if u["discord_id"] else 0
    servers = core.q("SELECT COUNT(*) c FROM vps WHERE user_id=?", (u["id"],), one=True)["c"]
    xp = n * 50 + servers * 30 + (u["streak"] or 0) * 5 + (40 if u["totp_on"] else 0)
    lvl = int(math.sqrt(xp / 25)) + 1; cur, nxt = (lvl - 1) ** 2 * 25, lvl ** 2 * 25
    return dict(xp=xp, lvl=lvl, title=TITLES[min(lvl // 3, 4)], pct=int(100 * (xp - cur) / max(nxt - cur, 1)), nxt=nxt,
                coins=u["coins"] or 0, streak=u["streak"] or 0, invites=n, servers=servers)

def badges(u, p):
    kinds = {r["kind"] for r in core.q("SELECT DISTINCT kind FROM vps WHERE user_id=?", (u["id"],))}
    has = lambda sql: core.q(sql, (u["id"],), one=True) is not None
    return [("First server", "Deploy any server", p["servers"] > 0), ("Recruiter", "Get 2 valid invites", p["invites"] >= 2),
            ("Squad leader", "Get 8 valid invites", p["invites"] >= 8), ("On a roll", "Reach a 7 day streak", p["streak"] >= 7),
            ("Locked down", "Turn on 2FA", bool(u["totp_on"])), ("API pioneer", "Create an API token", has("SELECT 1 FROM tokens WHERE user_id=?")),
            ("Time traveller", "Create a snapshot", has("SELECT 1 FROM activity WHERE user_id=? AND action='snapshot' AND detail='create'")),
            ("Polyglot", "Use two server types", len(kinds) >= 2)]

@app.context_processor
def fun_ctx():
    u = me()
    return dict(lvl=profile(u) if u else None, new_codes=session.pop("new_codes", None) if u else None)

@app.route("/rewards")
@login_required
def rewards():
    u = me(); p = profile(u)
    return render_template("rewards.html", p=p, badges=badges(u, p), can_claim=(u["last_claim"] or 0) != int(time.time() // 86400),
                           vps=core.q("SELECT * FROM vps WHERE user_id=? AND engine IS NOT NULL", (u["id"],)), days=int(core.setting("vps_days") or 0))

@app.post("/rewards/claim")
@login_required
def claim():
    u = me(); today = int(time.time() // 86400); last = u["last_claim"] or 0
    if last == today: flash("Already claimed today. Come back tomorrow.", "err"); return redirect("/rewards")
    streak = (u["streak"] or 0) + 1 if last == today - 1 else 1; gain = 10 + min(streak, 7) * 2
    core.ex("UPDATE users SET coins=coins+?, streak=?, last_claim=? WHERE id=?", (gain, streak, today, u["id"]))
    act("reward", f"+{gain} coins, streak {streak}"); flash(f"+{gain} coins. Streak: {streak} day(s).", "ok"); return redirect("/rewards#confetti")

@app.post("/rewards/spend/<int:vid>")
@login_required
def spend(vid):
    u = me(); v = core.q("SELECT * FROM vps WHERE id=? AND user_id=?", (vid, u["id"]), one=True) or abort(404)
    if int(core.setting("vps_days") or 0) <= 0: flash("Servers do not expire here, so there is nothing to extend.", "err"); return redirect("/rewards")
    c = core.db()
    try: cur = c.execute("UPDATE users SET coins=coins-15 WHERE id=? AND coins>=15", (u["id"],)); c.commit(); paid = cur.rowcount == 1  # atomic: no double spend
    finally: c.close()
    if not paid: flash("You need 15 coins.", "err"); return redirect("/rewards")
    core.ex("UPDATE vps SET expires_at=? WHERE id=?", (max(time.time(), v["expires_at"] or 0) + 3 * 86400, vid))
    if v["suspended"] and v["susp_reason"] == "expired" and v["engine"]:
        try: core.set_node(v["node_id"]); core.control(v["engine"], v["name"], "start")
        except Exception: pass
        core.ex("UPDATE vps SET suspended=0, susp_reason=NULL WHERE id=?", (vid,))
    act("reward", "spent 15 coins: +3 days", vid); flash("Server extended by 3 days.", "ok"); return redirect("/rewards")

@app.route("/leaderboard")
@login_required
def leaderboard():
    names = {r["discord_id"]: r["username"] for r in core.q("SELECT discord_id, username FROM users WHERE discord_id IS NOT NULL")}
    inv = [(names.get(r["inviter_id"], "Discord member"), r["n"]) for r in core.q("SELECT inviter_id, COUNT(*) n FROM invites WHERE valid=1 GROUP BY inviter_id ORDER BY n DESC LIMIT 10")]
    return render_template("leaderboard.html", inv=inv, streaks=core.q("SELECT username, streak FROM users WHERE streak>0 ORDER BY streak DESC LIMIT 10"))

@app.route("/api")
@login_required
def api_page(): return render_template("api.html")

_stat = {"t": 0, "v": None}
@app.route("/status")
@limiter.limit("30/minute")
def public_status():
    if time.time() - _stat["t"] > 30:  # engine probes spawn processes, so cache them
        core.set_node(0); _stat.update(t=time.time(), v=dict(lxc=core.have_lxc(), docker=core.have_docker()))
    c = lambda s: core.q(s, one=True)["n"]
    return render_template("status.html", eng=_stat["v"], users=c("SELECT COUNT(*) n FROM users"), running=c("SELECT COUNT(*) n FROM vps WHERE status='running'"),
                           nodes=core.q("SELECT name, enabled FROM nodes"), maint=core.setting("maintenance") == "1")

# ------------------------------------------------------------------------- theme + templates
A.ICONS["gift"] = '<rect x="3" y="8" width="18" height="4" rx="1"/><path d="M12 8v13M5 12v9h14v-9M12 8c-2 0-4-1-4-3s3-2 4 3c1-5 4-5 4-3s-2 3-4 3"/>'
A.ICONS["trophy"] = '<path d="M8 4h8v6a4 4 0 01-8 0zM8 6H4v2a4 4 0 004 4M16 6h4v2a4 4 0 01-4 4M12 14v4M8 21h8"/>'
A.ICONS["code"] = '<path d="M8 8l-4 4 4 4M16 8l4 4-4 4M14 5l-4 14"/>'

THEME_CSS = """
:root{--pri:#7c5cff;--pri-h:#a78bfa;--b:#22d3ee;--glow:#7c5cff55}
[data-theme=crimson]{--pri:#e5383b;--pri-h:#ff5a5d;--b:#ff9f68;--glow:#e5383b55}[data-theme=matrix]{--pri:#16a34a;--pri-h:#4ade80;--b:#a3e635;--glow:#16a34a55}
[data-theme=sunset]{--pri:#f97316;--pri-h:#fb923c;--b:#f472b6;--glow:#f9731655}[data-theme=ocean]{--pri:#0ea5e9;--pri-h:#38bdf8;--b:#2dd4bf;--glow:#0ea5e955}
#bgfx{position:fixed;inset:0;z-index:0;pointer-events:none}.shell,.pub{position:relative;z-index:1}
.btn:not(.ghost),button:not(.ghost):not(.red):not(.lnk):not(.sw){background:linear-gradient(135deg,var(--pri),var(--pri-h));box-shadow:0 4px 18px -6px var(--glow)}
.card:hover{box-shadow:0 0 0 1px var(--pri),0 14px 44px -12px var(--glow)}.brand .ico{filter:drop-shadow(0 0 8px var(--pri))}.lvl .bar i,.bar i{background:linear-gradient(90deg,var(--pri),var(--b))}
.themes{display:flex;gap:8px;padding:8px 12px;margin-top:auto}.themes+.me{margin-top:0}.sw{width:20px;height:20px;min-height:0;padding:0;border-radius:50%;border:2px solid var(--ln)}.sw:hover{transform:scale(1.2);background:inherit}
.sw[data-t=cyber]{background:#7c5cff}.sw[data-t=crimson]{background:#e5383b}.sw[data-t=matrix]{background:#16a34a}.sw[data-t=sunset]{background:#f97316}.sw[data-t=ocean]{background:#0ea5e9}
.badge.locked{opacity:.4;filter:grayscale(1)}.badge b{display:block}.cf{position:fixed;top:-14px;width:8px;height:14px;z-index:30;animation:cfall linear forwards}@keyframes cfall{to{transform:translateY(106vh) rotate(720deg)}}
a{color:var(--pri-h)}.card:hover,.unit:hover{border-color:var(--pri)}input:focus,select:focus,textarea:focus{border-color:var(--pri-h);box-shadow:0 0 0 3px var(--glow)}.cmp .hl{background:var(--glow)}.pulse{animation-name:pu}
.hp{position:absolute;left:-9999px;width:1px;height:1px;opacity:0}.nav a:hover{transform:translateX(2px)}.nav a{transition:transform .15s,background .15s}
"""
FX_JS = """<script nonce="{{ nonce }}">document.querySelectorAll('.sw').forEach(b=>b.onclick=()=>{localStorage.setItem('az-theme',b.dataset.t);document.documentElement.dataset.theme=b.dataset.t});
(()=>{const c=document.getElementById('bgfx');if(!c||matchMedia('(prefers-reduced-motion:reduce)').matches)return;const x=c.getContext('2d');let w,h,P=[];
function rs(){w=c.width=innerWidth;h=c.height=innerHeight;P=Array.from({length:Math.min(70,w*h/22000|0)},()=>({x:Math.random()*w,y:Math.random()*h,vx:(Math.random()-.5)*.25,vy:(Math.random()-.5)*.25}))}rs();addEventListener('resize',rs);
(function f(){if(!document.hidden){x.clearRect(0,0,w,h);x.fillStyle=x.strokeStyle=getComputedStyle(document.documentElement).getPropertyValue('--pri-h')||'#fff';
for(const p of P){p.x=(p.x+p.vx+w)%w;p.y=(p.y+p.vy+h)%h;x.globalAlpha=.5;x.fillRect(p.x,p.y,2,2)}
for(let i=0;i<P.length;i++)for(let j=i+1;j<P.length;j++){const d=Math.hypot(P[i].x-P[j].x,P[i].y-P[j].y);if(d<120){x.globalAlpha=(1-d/120)*.18;x.beginPath();x.moveTo(P[i].x,P[i].y);x.lineTo(P[j].x,P[j].y);x.stroke()}}}requestAnimationFrame(f)})()})();</script>"""

b = T["base.html"]
b = b.replace("</title>", "</title><script nonce=\"{{ nonce }}\">try{document.documentElement.dataset.theme=localStorage.getItem('az-theme')||'cyber'}catch(e){}</script>", 1)
b = b.replace("</style>", THEME_CSS + "</style>", 1).replace("</head><body>", "</head><body><canvas id=\"bgfx\" aria-hidden=\"true\"></canvas>", 1)
b = b.replace('<div class="me">', '<div class="themes" role="group" aria-label="Theme">{% for t in [\'cyber\', \'crimson\', \'matrix\', \'sunset\', \'ocean\'] %}<button class="sw" data-t="{{ t }}" title="{{ t }} theme" aria-label="{{ t }} theme"></button>{% endfor %}</div><div class="me">', 1)
b = b.replace("<span>Tutorial</span></a>", "<span>Tutorial</span></a><a href=\"/rewards\" class=\"{{ 'on' if p == '/rewards' }}\">{{ ico('gift') }}<span>Rewards</span></a><a href=\"/leaderboard\" class=\"{{ 'on' if p == '/leaderboard' }}\">{{ ico('trophy') }}<span>Leaderboard</span></a><a href=\"/api\" class=\"{{ 'on' if p == '/api' }}\">{{ ico('code') }}<span>API</span></a>", 1)
b = b.replace("{% block scripts %}", FX_JS + "{% block scripts %}", 1)
T["base.html"] = b
T["auth.html"] = T["auth.html"].replace('<input type="hidden" name="csrf" value="{{ csrf }}">', '<input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="ft" value="{{ make_ft() }}"><input class="hp" name="website" tabindex="-1" autocomplete="off" aria-hidden="true">', 1)
T["dash.html"] = T["dash.html"].replace('<div class="acts" style="margin:18px 0">', '''{% if lvl %}<div class="card lvl" style="margin-top:14px"><div class="acts"><b>Level {{ lvl.lvl }} {{ lvl.title }}</b><span class="tag">{{ lvl.xp }} XP</span><span class="tag">{{ lvl.coins }} coins</span><span class="tag">{{ lvl.streak }} day streak</span><a class="btn ghost" href="/rewards" style="margin-left:auto">Daily reward</a></div><div class="bar" style="margin-top:10px"><i data-w="{{ lvl.pct }}" style="width:0"></i></div></div>{% endif %}
<div class="acts" style="margin:18px 0">''', 1)
T["account.html"] = T["account.html"].replace("<h2>API tokens</h2>", '''<h2>Recovery codes</h2><div class="card">{% if new_codes %}<div class="flash ok">Save these now. Each code works once:<pre>{{ new_codes|join('\\n') }}</pre></div>{% endif %}<p class="mut">Use a code if you lose your authenticator. Needs 2FA enabled.</p>
<form method="post" action="/account/recovery" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="password" type="password" placeholder="Your password" required><button class="ghost">Generate new codes</button></form></div><h2>API tokens</h2>''', 1)

T["rewards.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Rewards</h1><p>Level up, collect coins and unlock badges.</p></div>
<div class="grid"><div class="card stat"><span class="mut">Level</span><div class="big">{{ p.lvl }} {{ p.title }}</div><div class="bar"><i data-w="{{ p.pct }}" style="width:0"></i></div><span class="mut">{{ p.xp }} of {{ p.nxt }} XP</span></div>
<div class="card stat"><span class="mut">Coins</span><div class="big">{{ p.coins }}</div><span class="mut">{{ p.streak }} day streak</span></div>
<div class="card stat"><span class="mut">Daily reward</span>{% if can_claim %}<form method="post" action="/rewards/claim"><input type="hidden" name="csrf" value="{{ csrf }}"><button>{{ ico('gift') }} Claim coins</button></form>{% else %}<div class="big" style="font-size:1.2rem">Claimed today</div><span class="mut">Come back tomorrow to keep your streak.</span>{% endif %}</div></div>
<h2>Spend coins</h2><div class="card">{% if days %}<p class="mut">Extend a server by 3 days for 15 coins.</p>{% for v in vps %}<div class="acts" style="margin:8px 0"><b class="mono">{{ v.name }}</b><form method="post" action="/rewards/spend/{{ v.id }}" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="ghost">Extend 3 days</button></form></div>{% else %}<p class="mut">Deploy a server first.</p>{% endfor %}
{% else %}<p class="mut">Servers do not expire on this panel, so coins are just for bragging rights.</p>{% endif %}</div>
<h2>Badges</h2><div class="grid">{% for n, d, got in badges %}<div class="card badge {{ '' if got else 'locked' }}"><b>{{ n }}</b><p class="mut" style="margin:4px 0 8px">{{ d }}</p><span class="tag">{{ 'Unlocked' if got else 'Locked' }}</span></div>{% endfor %}</div>
<script nonce="{{ nonce }}">if(location.hash==='#confetti'){for(let i=0;i<70;i++){const d=document.createElement('i');d.className='cf';d.style.cssText=`left:${Math.random()*100}vw;background:hsl(${Math.random()*360} 90% 60%);animation-delay:${Math.random()*.6}s;animation-duration:${1.6+Math.random()*1.6}s`;document.body.appendChild(d);setTimeout(()=>d.remove(),4000)}}</script>{% endblock %}'''

T["leaderboard.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Leaderboard</h1><p>Top inviters and longest streaks.</p></div>
<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(320px,1fr))"><div class="card"><h3 style="margin-top:0">Top inviters</h3><table>{% for n, c in inv %}<tr><td>{{ loop.index }}</td><td>{{ n }}</td><td class="mono">{{ c }}</td></tr>{% else %}<tr><td class="mut">No invites tracked yet.</td></tr>{% endfor %}</table></div>
<div class="card"><h3 style="margin-top:0">Longest streaks</h3><table>{% for s in streaks %}<tr><td>{{ loop.index }}</td><td>{{ s.username }}</td><td class="mono">{{ s.streak }} days</td></tr>{% else %}<tr><td class="mut">Claim a daily reward to start a streak.</td></tr>{% endfor %}</table></div></div>{% endblock %}'''

T["status.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Status</h1><p>Live panel health.</p></div>{% if maint %}<div class="flash err" style="margin-bottom:14px">Maintenance mode: new deployments are paused.</div>{% endif %}
<div class="grid"><div class="card stat"><span class="mut">Panel</span><div class="big"><i class="dot on"></i>Online</div></div><div class="card stat"><span class="mut">Servers running</span><div class="big">{{ running }}</div></div><div class="card stat"><span class="mut">Users</span><div class="big">{{ users }}</div></div></div>
<h2>Engines and nodes</h2><div class="card"><table><tr><td><i class="dot {{ 'on' if eng.lxc else 'off' }}"></i>LXC on this host</td></tr><tr><td><i class="dot {{ 'on' if eng.docker else 'off' }}"></i>Docker on this host</td></tr>
{% for n in nodes %}<tr><td><i class="dot {{ 'on' if n.enabled else 'off' }}"></i>Node {{ n.name }}</td></tr>{% endfor %}</table></div>{% endblock %}'''

T["api.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">API</h1><p>Control your servers from scripts. <a href="/account">Create a token</a> in Account first.</p></div>
<div class="card"><h3 style="margin-top:0">Try it</h3><label>API token</label><input id="tk" type="password" placeholder="arz-..." autocomplete="off"><div class="acts"><select id="ep" style="width:auto;margin:0"><option>GET /api/v1/ping</option><option>GET /api/v1/vps</option><option>GET /api/v1/vps/{id}/stats</option><option>POST /api/v1/vps/{id}/start</option><option>POST /api/v1/vps/{id}/stop</option><option>POST /api/v1/vps/{id}/restart</option></select>
<input id="vid" placeholder="server id" style="width:130px;margin:0"><button id="go">Send</button></div><pre id="res" style="margin-top:12px">The response appears here.</pre></div>
<h2>Reference</h2><div class="card"><table><tr><td class="mono">GET /api/v1/ping</td><td class="mut">Check a token. Admin tokens also return admin: true (used by node installs).</td></tr><tr><td class="mono">GET /api/v1/vps</td><td class="mut">List your servers.</td></tr>
<tr><td class="mono">GET /api/v1/vps/ID/stats</td><td class="mut">CPU, memory, network.</td></tr><tr><td class="mono">POST /api/v1/vps/ID/start|stop|restart</td><td class="mut">Power control.</td></tr></table>
<pre>curl -H "Authorization: Bearer YOUR_TOKEN" https://{{ request.host }}/api/v1/vps</pre></div>
<script nonce="{{ nonce }}">document.getElementById('go').onclick=async()=>{const [m,p]=document.getElementById('ep').value.split(' ');const r=document.getElementById('res');r.textContent='Sending...';
try{const x=await fetch(p.replace('{id}',encodeURIComponent(document.getElementById('vid').value||'0')),{method:m,headers:{Authorization:'Bearer '+document.getElementById('tk').value}});let t=await x.text();try{t=JSON.stringify(JSON.parse(t),null,2)}catch(e){}r.textContent='HTTP '+x.status+'\n'+t}catch(e){r.textContent='Request failed: '+e}}</script>{% endblock %}'''
PYFUN

cat > "$APP/v3.py" <<'PYV3'
"""Ariznodes HVM v3: multi-page UI, nodes + API portal, tighter security, LXC advanced, red theme."""
import hashlib, hmac, ipaddress, json, os, re, time
from datetime import timedelta
import requests
from flask import abort, flash, jsonify, redirect, render_template, request, session
import core, ops
import app as A
from app import T, admin_required, app, limiter, login_required, me, real_ip
from features import MACRO, act, api_user, mine

KIND = {"ct": "LXC container", "vm": "KVM virtual machine", "docker": "Docker container"}
app.jinja_env.globals["kind_label"] = lambda k: KIND.get(k, k)
A.ICONS["book"] = '<path d="M4 5a2 2 0 012-2h13v16H6a2 2 0 00-2 2zM4 19V5M8 7h7"/>'
A.ICONS["node"] = '<circle cx="12" cy="5" r="2.5"/><circle cx="5" cy="19" r="2.5"/><circle cx="19" cy="19" r="2.5"/><path d="M12 7.5v4M12 11.5l-6 5M12 11.5l6 5"/>'

# ------------------------------------------------------------------ security gate
def ip_in(ip, rules):
    try: a = ipaddress.ip_address(ip)
    except ValueError: return False
    for r in rules:
        try:
            if a in ipaddress.ip_network(r.strip(), strict=False): return True
        except ValueError: pass
    return False

@app.before_request
def security_gate():
    core.set_node(0)  # worker threads are reused; never inherit another request's node
    app.permanent_session_lifetime = timedelta(hours=max(1, int(core.setting("sess_hours") or 12)))
    ip = real_ip()
    if core.q("SELECT 1 FROM ip_bans WHERE ip=?", (ip,), one=True): abort(403)
    rules = [x for x in core.setting("admin_ips").split(",") if x.strip()]
    if request.path.startswith("/admin") and rules and not ip_in(ip, rules): abort(404)
    u = me()
    if u and not u["totp_on"] and not request.path.startswith(("/account", "/logout")):
        if (u["is_admin"] and core.setting("force_admin_2fa") == "1") or core.setting("force_all_2fa") == "1":
            flash("Two-factor authentication is required on this panel. Set it up to continue.", "err"); return redirect("/account")

# ------------------------------------------------------------------- user pages
@app.route("/deploy")
@login_required
def deploy():
    u = me(); n = core.valid_invites(u["discord_id"]) if u["discord_id"] else 0; plan = core.plan_for(n)
    owned = core.q("SELECT COUNT(*) n FROM vps WHERE user_id=? AND status!='failed'", (u["id"],), one=True)["n"]
    allowed = max(int(core.setting("max_vps")), core.PLANS[plan]["slots"]) if plan else 0
    return render_template("deploy.html", n=n, plan=plan, owned=owned, allowed=allowed)

@app.route("/servers")
@login_required
def servers():
    kind = request.args.get("kind", ""); rows = core.q("SELECT * FROM vps WHERE user_id=? ORDER BY id DESC", (me()["id"],))
    return render_template("servers.html", vps=[v for v in rows if not kind or v["kind"] == kind], kind=kind, total=len(rows),
                           counts={k: sum(1 for v in rows if v["kind"] == k) for k in KIND})

@app.route("/tutorial")
@login_required
def tutorial(): return render_template("tutorial.html")

@app.post("/v/<int:vid>/lxc/<key>")
@login_required
@limiter.limit("20/minute")
def v_lxc(vid, key):
    v = mine(vid)
    try:
        if v["engine"] != "lxc": abort(404)
        ops.lxc_set(v, key, request.form.get("val", "")); act("lxc", f"{key}={request.form.get('val')}", vid); flash("LXC setting applied.", "ok")
    except (ValueError, RuntimeError) as e: flash(str(e)[:200], "err")
    return redirect(f"/v/{vid}#t-lxc")

# ----------------------------------------------------------------- nodes + API portal
def agent_call(url, key, path, payload=None, timeout=15):
    body = json.dumps(payload or {}); ts = str(int(time.time()))
    sig = hmac.new(key.encode(), (ts + body).encode(), hashlib.sha256).hexdigest()
    r = requests.post(url.rstrip("/") + path, data=body, timeout=timeout, headers={"X-Ts": ts, "X-Sig": sig, "Content-Type": "application/json", "User-Agent": "Ariznodes-Panel/3.5"})
    try: return r.json()
    except ValueError: raise ValueError(f"HTTP {r.status_code} from the node, and it is not the agent. Cloudflare or a proxy may be answering: {r.text[:70]!r}")

def add_node(name, url, key, slots):
    if not re.fullmatch(r"[\w .-]{2,40}", name or "") or not re.match(r"^https?://[\w.:-]+$", (url or "").rstrip("/")): raise ValueError("Invalid node name or URL")
    try: caps = agent_call(url, key, "/agent/caps")
    except requests.RequestException as e: raise ValueError(f"Could not reach the node agent ({type(e).__name__}). Point the tunnel hostname at http://localhost:8081 and make sure Cloudflare is not challenging the request.")
    if not caps.get("ok"): raise ValueError("The node rejected the key")
    core.ex("""INSERT INTO nodes(name,url,key,caps,slots,last_ok) VALUES(?,?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET
               url=excluded.url, key=excluded.key, caps=excluded.caps, slots=excluded.slots, last_ok=excluded.last_ok""",
            (name, url.rstrip("/"), core.enc(key), json.dumps(caps), max(1, min(500, int(slots))), time.time()))

@app.get("/api/v1/ping")
@limiter.limit("30/minute")
def api_ping():
    u = api_user()
    if not u: return jsonify(ok=False, error="unauthorized"), 401
    ver = open("/opt/ariznodes/VERSION").read().strip() if os.path.exists("/opt/ariznodes/VERSION") else "3"
    return jsonify(ok=True, panel="Ariznodes HVM", version=ver, admin=bool(u["is_admin"]), user=u["username"])

@app.post("/api/v1/nodes/register")
@limiter.limit("10/minute")
def api_register():
    u = api_user()
    if not u or not u["is_admin"]: return jsonify(ok=False, error="an admin API key is required"), 401
    d = request.get_json(silent=True) or {}
    try: add_node(str(d.get("name", "")), str(d.get("url", "")), str(d.get("agent_key", "")), d.get("slots", 10))
    except (ValueError, TypeError) as e: return jsonify(ok=False, error=str(e)), 400
    core.ex("INSERT INTO activity(user_id,action,detail) VALUES(?,?,?)", (u["id"], "node", "registered " + str(d.get("name"))[:40])); return jsonify(ok=True)

def node_rows():
    out = []
    for n in core.q("SELECT * FROM nodes ORDER BY id"):
        used = core.q("SELECT COUNT(*) c FROM vps WHERE node_id=? AND status!='failed'", (n["id"],), one=True)["c"]
        out.append(dict(n=n, caps=json.loads(n["caps"] or "{}"), used=used))
    return out

@app.route("/admin/nodes")
@admin_required
def admin_nodes():
    core.set_node(0)
    used = core.q("SELECT COUNT(*) c FROM vps WHERE node_id=0 AND status!='failed'", one=True)["c"]
    return render_template("admin_nodes.html", nodes=node_rows(), used=used, lslots=core.setting("local_slots"), fallback=core.setting("docker_fallback"),
                           local=dict(lxc=core.have_lxc(), docker=core.have_docker(), kvm=core.have_kvm()))

@app.post("/admin/nodes/<op>")
@admin_required
def admin_nodes_op(op):
    f = request.form
    try:
        if op == "add": add_node(f.get("name", ""), f.get("url", ""), f.get("key", ""), f.get("slots", "10") or 10); flash("Node added.", "ok")
        elif op == "local":
            core.ex("INSERT OR REPLACE INTO settings VALUES('local_slots',?)", (str(max(0, min(500, int(f.get("slots", "0") or 0)))),))
            core.ex("INSERT OR REPLACE INTO settings VALUES('docker_fallback',?)", ("1" if f.get("fallback") else "0",)); flash("Local node settings saved.", "ok")
        else:
            n = core.q("SELECT * FROM nodes WHERE id=?", (int(f.get("id", "0")),), one=True) or abort(404)
            if op == "toggle": core.ex("UPDATE nodes SET enabled=1-enabled WHERE id=?", (n["id"],))
            elif op == "slots": core.ex("UPDATE nodes SET slots=? WHERE id=?", (max(1, min(500, int(f.get("slots", "10")))), n["id"]))
            elif op == "ping":
                caps = agent_call(n["url"], core.dec(n["key"]), "/agent/caps")
                if not caps.get("ok"): raise ValueError("Node rejected the key")
                core.ex("UPDATE nodes SET caps=?, last_ok=? WHERE id=?", (json.dumps(caps), time.time(), n["id"])); flash("Node is online.", "ok")
            elif op == "remove":
                if core.q("SELECT 1 FROM vps WHERE node_id=?", (n["id"],), one=True): raise ValueError("Move or delete the servers on this node first")
                core.ex("DELETE FROM nodes WHERE id=?", (n["id"],)); flash("Node removed.", "ok")
            else: abort(404)
        act("admin", f"nodes {op}")
    except (ValueError, requests.RequestException) as e: flash(str(e)[:200] or "Node request failed", "err")
    return redirect("/admin/nodes")

# --------------------------------------------------------------------- security admin
@app.route("/admin/security")
@admin_required
def admin_security():
    return render_template("admin_security.html", s={k: core.setting(k) for k in core.DEFAULTS}, my_ip=real_ip(),
        bans=core.q("SELECT * FROM ip_bans ORDER BY created_at DESC LIMIT 100"),
        fails=core.q("SELECT * FROM activity WHERE action='login_fail' ORDER BY id DESC LIMIT 30"))

def _int(v, lo, hi, d):
    return str(max(lo, min(hi, int(v)))) if str(v).isdigit() else d

@app.post("/admin/security/<op>")
@admin_required
def admin_security_op(op):
    f = request.form
    if op == "save":
        rules = [x.strip() for x in f.get("admin_ips", "").split(",") if x.strip()]
        try:
            for r in rules: ipaddress.ip_network(r, strict=False)
        except ValueError: flash("Admin IP list must be IPs or CIDR ranges separated by commas.", "err"); return redirect("/admin/security")
        if rules and not ip_in(real_ip(), rules): flash("Your current IP is not in that list - refusing, you would lock yourself out.", "err"); return redirect("/admin/security")
        vals = {"min_pw": _int(f.get("min_pw"), 8, 64, "10"), "max_fails": _int(f.get("max_fails"), 3, 20, "5"), "lock_min": _int(f.get("lock_min"), 1, 1440, "15"),
                "sess_hours": _int(f.get("sess_hours"), 1, 168, "12"), "ip_ban_after": _int(f.get("ip_ban_after"), 5, 200, "20"), "admin_ips": ",".join(rules),
                "force_admin_2fa": "1" if f.get("force_admin_2fa") else "0", "force_all_2fa": "1" if f.get("force_all_2fa") else "0", "registration": "1" if f.get("registration") else "0"}
        for k, v in vals.items(): core.ex("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (k, v))
        flash("Security settings saved.", "ok")
    elif op == "ban":
        try: ip = str(ipaddress.ip_address(f.get("ip", "").strip()))
        except ValueError: flash("Enter a valid IP address.", "err"); return redirect("/admin/security")
        if ip == real_ip(): flash("You cannot ban your own IP.", "err")
        else: core.ex("INSERT OR REPLACE INTO ip_bans(ip,reason) VALUES(?,?)", (ip, f.get("reason", "manual")[:100] or "manual")); flash("IP banned.", "ok")
    elif op == "unban": core.ex("DELETE FROM ip_bans WHERE ip=?", (f.get("ip", ""),)); flash("IP unbanned.", "ok")
    elif op == "signout-all": core.ex("UPDATE users SET sv=sv+1"); session["sv"] = (me()["sv"] or 0) + 1; flash("Every user was signed out.", "ok")
    else: abort(404)
    act("admin", f"security {op}"); return redirect("/admin/security")

# ----------------------------------------------------------------- theme + templates
for old, new in [("#0a0f1e", "#0b0a0d"), ("#101830", "#141117"), ("#16203d", "#1c1820"), ("#25325a", "#2e2731"), ("#0c1328", "#0e0c11"), ("#070b17", "#08070a"),
                 ("#141d38", "#1a161e"), ("#0a1226", "#0e0c11"), ("#6d7cff", "#e5383b"), ("#8591ff", "#ff5a5d"), ("#34457a", "#5a2f35"), ("#9db4ff", "#ff8a8c"),
                 ("#8f9cc0", "#a39aa8"), ("#e8edfb", "#f3eef0"), ("#4a5679", "#4d4552"), ("#2a3352", "#2f2833")]:
    for k in ("base.html", "vps2.html"): T[k] = T[k].replace(old, new)
T["base.html"] = re.sub(r'<nav class="nav">.*?</nav>', lambda m: '''<nav class="nav">{% if p.startswith('/admin') %}<div class="tag" style="margin:0 10px 8px;color:var(--pri-h)">Admin console</div>
<a href="/admin" class="{{ 'on' if p == '/admin' }}">{{ ico('grid') }}<span>Overview</span></a><a href="/admin/nodes" class="{{ 'on' if p.startswith('/admin/nodes') }}">{{ ico('node') }}<span>Nodes</span></a>
<a href="/admin/more" class="{{ 'on' if p.startswith('/admin/more') or p.startswith('/admin/user') }}">{{ ico('server') }}<span>Servers and users</span></a><a href="/admin/security" class="{{ 'on' if p.startswith('/admin/security') }}">{{ ico('lock') }}<span>Security</span></a>
<a href="/dashboard">{{ ico('logout') }}<span>Back to panel</span></a>{% else %}<a href="/dashboard" class="{{ 'on' if p == '/dashboard' }}">{{ ico('grid') }}<span>Dashboard</span></a>
<a href="/servers" class="{{ 'on' if p.startswith('/servers') or p.startswith('/v/') or p.startswith('/vps') }}">{{ ico('server') }}<span>Servers</span></a><a href="/deploy" class="{{ 'on' if p == '/deploy' }}">{{ ico('bolt') }}<span>Deploy</span></a>
<a href="/tutorial" class="{{ 'on' if p == '/tutorial' }}">{{ ico('book') }}<span>Tutorial</span></a><a href="/account" class="{{ 'on' if p.startswith('/account') }}">{{ ico('user') }}<span>Account</span></a>
{% if me.is_admin %}<a href="/admin">{{ ico('shield') }}<span>Admin</span></a>{% endif %}{% endif %}</nav>''', T["base.html"], count=1, flags=re.S)
T["base.html"] = re.sub(r'\{% if not me %\}<footer>.*?</footer>\{% endif %\}', lambda m: '<footer><span>&copy; 2026 Ariznodes&trade; HVM Panel v3. All rights reserved.</span><span>Built by {{ creator }}</span></footer>', T["base.html"], count=1, flags=re.S)
T["base.html"] = T["base.html"].replace("</style>", """.inl{display:inline-flex;align-items:center;gap:8px;vertical-align:middle;flex-wrap:wrap}.inl input,.inl select{margin:0;width:auto}.acts{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
button,.btn{min-height:36px;justify-content:center;line-height:1.2;white-space:nowrap}td form.inl{margin:2px 4px 2px 0}.type{position:relative;cursor:pointer;display:block}.type input{position:absolute;opacity:0}
.type:has(input:checked){border-color:var(--pri);background:var(--s2)}.type b{display:block;margin-bottom:4px}.type p{margin:0;color:var(--mut);font-size:14px}.type.off{opacity:.45;cursor:not-allowed}
.nav .tag{display:inline-block}.stat{display:flex;flex-direction:column;gap:2px}</style>""", 1)
T["vps2.html"] = T["vps2.html"].replace("{{ 'VM' if v.kind == 'vm' else 'container' }}", "{{ kind_label(v.kind) }}")
T["vps2.html"] = T["vps2.html"].replace('<button class="ghost" data-tab="t-tools">Tools</button>', '{% if lxc %}<button class="ghost" data-tab="t-lxc">LXC advanced</button>{% endif %}<button class="ghost" data-tab="t-tools">Tools</button>')
T["vps2.html"] = T["vps2.html"].replace('<section class="tab" id="t-tools">', '''{% if lxc %}<section class="tab" id="t-lxc"><div class="card"><h3 style="margin-top:0">LXC advanced</h3><table>{% for f in lxc %}<tr><td>{{ f.label }}</td><td>
<form method="post" action="/v/{{ v.id }}/lxc/{{ f.key }}" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><select name="val">{% for o in f.opts %}<option {{ 'selected' if o == f.cur }}>{{ o }}</option>{% endfor %}</select><button class="ghost">Apply</button></form></td></tr>{% endfor %}</table></div></section>{% endif %}
<section class="tab" id="t-tools">''', 1)

T["dash.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Hello, {{ me.username }}</h1><p>Your account at a glance.</p></div>
<div class="grid"><div class="card stat"><span class="mut">Discord</span><div class="big">{% if me.discord_id %}{{ me.discord_name }}{% else %}Not linked{% endif %}</div>{% if not me.discord_id %}<div><a class="btn" href="/discord/link">{{ ico('link') }} Authorize Discord</a></div>{% else %}<div><span class="tag">verified</span></div>{% endif %}</div>
<div class="card stat"><span class="mut">Verified invites</span><div class="big">{{ n }}</div><div class="bar"><i data-w="{{ pct }}" style="width:0"></i></div><span class="mut">{% if nxt %}{{ nxt[1].invites - n }} more for {{ nxt[0] }}{% else %}Top tier unlocked{% endif %}</span></div>
<div class="card stat"><span class="mut">Your plan</span><div class="big">{{ plan or 'none' }}</div><span class="mut">{% if plan %}{{ PLANS[plan].cpu }} vCPU, {{ PLANS[plan].ram // 1024 }} GB RAM, {{ PLANS[plan].disk }} GB, {{ PLANS[plan].slots }} server(s){% else %}Invite 2 members to unlock basic{% endif %}</span></div></div>
<div class="acts" style="margin:18px 0"><a class="btn" href="/deploy">{{ ico('bolt') }} Deploy a server</a><a class="btn ghost" href="/servers">{{ ico('server') }} All servers</a><a class="btn ghost" href="/tutorial">{{ ico('book') }} Tutorial</a></div>
<h2>Recent servers</h2><div class="units">{% for v in vps[:4] %}<a class="unit {{ v.status }}" href="/v/{{ v.id }}"><i class="dot"></i><b>{{ v.label or v.name }}</b><span>{{ v.plan }}, {{ kind_label(v.kind) }}</span><em>{{ v.status }}</em></a>
{% else %}<div class="empty">No servers yet. Open Deploy to create your first one.</div>{% endfor %}</div>
<h2>What each plan includes</h2><div class="card" style="overflow:auto"><table><tr><th>Plan</th><th>Invites</th><th>vCPU</th><th>RAM</th><th>Disk</th><th>Servers</th></tr>{% for k, p in PLANS.items() %}<tr><td>{{ k }}{% if k == plan %} <span class="tag">yours</span>{% endif %}</td><td>{{ p.invites }}</td><td>{{ p.cpu }}</td><td>{{ p.ram // 1024 }} GB</td><td>{{ p.disk }} GB</td><td>{{ p.slots }}</td></tr>{% endfor %}</table></div>{% endblock %}'''

T["deploy.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Deploy a server</h1><p>Servers used: {{ owned }} of {{ 'unlimited' if me.is_admin else allowed }}. Choose a type, an OS and a plan.</p></div>
{% if not plan and not me.is_admin %}<div class="empty">{{ ico('lock') }} Link Discord and invite 2 real members to unlock your first server.</div>{% else %}
<form method="post" action="/vps/create"><input type="hidden" name="csrf" value="{{ csrf }}"><h2 style="margin-top:0">1. Type</h2><div class="grid">
<label class="type card"><input type="radio" name="kind" value="ct" checked><b>LXC container</b><p>Fast Linux system container. Supports nesting, scheduled snapshots and fine-grained limits.</p></label>
<label class="type card"><input type="radio" name="kind" value="vm"><b>KVM virtual machine</b><p>Full VM with its own kernel. Needs a node with KVM.</p></label>
<label class="type card"><input type="radio" name="kind" value="docker"><b>Docker container</b><p>Runs on Docker, fully separate from LXC. Good for single apps.</p></label></div>
<h2>2. Operating system</h2><select name="image" style="max-width:260px"><option>24.04</option><option>22.04</option></select>
<h2>3. Plan</h2><div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(165px,1fr))">{% for k, p in PLANS.items() %}{% set ok = p.invites <= n or me.is_admin %}<label class="type card {{ '' if ok else 'off' }}"><input type="radio" name="plan" value="{{ k }}" {{ 'checked' if k == (plan or 'basic') else '' }} {{ '' if ok else 'disabled' }}>
<b>{{ k }}</b><p>{{ p.cpu }} vCPU, {{ p.ram // 1024 }} GB RAM, {{ p.disk }} GB disk, {{ p.slots }} server(s)</p><p>{{ 'Unlocked' if ok else 'Needs ' ~ p.invites ~ ' invites' }}</p></label>{% endfor %}</div>
<div class="acts" style="margin-top:20px"><button>{{ ico('bolt') }} Request server</button><span class="mut">The verification bot checks your invites, then builds it.</span></div></form>{% endif %}{% endblock %}'''

T["servers.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Servers</h1><p>{{ total }} total.</p></div>
<div class="acts" style="margin-bottom:16px"><a class="btn {{ '' if not kind else 'ghost' }}" href="/servers">All</a>{% for k, l in [('ct', 'LXC'), ('vm', 'KVM VMs'), ('docker', 'Docker')] %}<a class="btn {{ '' if kind == k else 'ghost' }}" href="/servers?kind={{ k }}">{{ l }} ({{ counts[k] }})</a>{% endfor %}
<a class="btn ghost" href="/deploy" style="margin-left:auto">{{ ico('bolt') }} Deploy</a></div>
<div class="units">{% for v in vps %}<a class="unit {{ v.status }}" href="/v/{{ v.id }}"><i class="dot"></i><b>{{ v.label or v.name }}</b><span>{{ v.plan }}, {{ kind_label(v.kind) }}</span><em>{{ v.status }}</em></a>{% else %}<div class="empty">Nothing here yet.</div>{% endfor %}</div>{% endblock %}'''

T["tutorial.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Getting started</h1><p>Five steps from sign-up to your first SSH session.</p></div>
<style>.tut{max-width:760px;overflow:hidden}.prog{display:flex;gap:6px;margin-bottom:18px}.prog i{flex:1;height:4px;border-radius:2px;background:var(--s2);overflow:hidden}.prog i b{display:block;height:100%;width:0;background:var(--pri-h)}.prog i.done b{width:100%}
.prog i.run b{animation:pg 6s linear forwards}@keyframes pg{to{width:100%}}.st{display:none}.st.on{display:block}.st.on .vis{animation:rise .5s both}@keyframes rise{from{opacity:0;transform:translateY(10px)}}
.vis{margin:16px 0;padding:18px;background:var(--s2);border:1px solid var(--ln);border-radius:8px;min-height:130px;font:13px var(--mono)}.cur:after{content:"";display:inline-block;width:8px;height:14px;background:var(--pri-h);margin-left:3px;vertical-align:-2px;animation:bl 1s steps(1) infinite}@keyframes bl{50%{opacity:0}}
.typed{display:inline-block;overflow:hidden;white-space:nowrap;vertical-align:bottom;width:0}.st.on .typed{animation:ty 3s steps(34) .4s forwards}@keyframes ty{to{width:34ch}}.pulse{animation:pu 1.4s infinite}@keyframes pu{50%{box-shadow:0 0 0 8px #e5383b22}}
.av{display:inline-grid;place-items:center;width:34px;height:34px;border-radius:50%;background:var(--ln);margin-right:6px;opacity:0}.st.on .av{animation:pop .4s forwards}.st.on .av:nth-child(2){animation-delay:.8s}@keyframes pop{from{transform:scale(.4)}to{opacity:1;transform:none}}
.fill{height:8px;background:var(--bg);border-radius:2px;overflow:hidden;margin:10px 0}.fill i{display:block;height:100%;width:0;background:var(--pri-h)}.st.on .fill i{animation:fl 3.5s ease-out forwards}@keyframes fl{to{width:100%}}</style>
<div class="card tut" id="tut"><div class="prog"><i></i><i></i><i></i><i></i><i></i></div>
<div class="st"><h3 style="margin-top:0">1. Create your account</h3><p class="mut">Pick a username and a strong password. Turn on two-factor login later in Account.</p><div class="vis">username: <span class="cur">arizfan</span><br>password: ************</div></div>
<div class="st"><h3 style="margin-top:0">2. Link your Discord</h3><p class="mut">Authorize Discord on the dashboard so the bot knows which invites belong to you.</p><div class="vis"><a class="btn pulse" href="/discord/link">{{ ico('link') }} Authorize Discord</a></div></div>
<div class="st"><h3 style="margin-top:0">3. Invite real members</h3><p class="mut">Each genuine account that joins from your invite counts. Fake or brand-new accounts do not.</p><div class="vis"><span class="av">+1</span><span class="av">+1</span><br><br>2 valid invites: basic plan unlocked</div></div>
<div class="st"><h3 style="margin-top:0">4. Deploy</h3><p class="mut">Open Deploy, choose LXC, KVM or Docker, pick your plan and request it. The bot builds it in about a minute.</p><div class="vis">anz-you-4f2a<div class="fill"><i></i></div><i class="dot on"></i>running</div></div>
<div class="st"><h3 style="margin-top:0">5. Connect</h3><p class="mut">Open your server, go to Access, enable SSH, then start a Pinggy tunnel or the sshx browser terminal.</p><div class="vis">$ <span class="typed">ssh -p 40527 root@abc.pinggy.online</span></div></div>
<div class="acts" style="margin-top:14px"><button class="ghost" id="pv">Back</button><button id="nx">Next</button><button class="ghost" id="pl">Pause</button></div></div>
<script nonce="{{ nonce }}">const st=[...document.querySelectorAll('.st')],pg=[...document.querySelectorAll('.prog i')];let i=0,t,paused=false;
function go(n){i=(n+st.length)%st.length;st.forEach((s,k)=>s.classList.toggle('on',k===i));pg.forEach((p,k)=>{p.className=k<i?'done':k===i?'run':'';p.firstChild||p.insertAdjacentHTML('afterbegin','<b></b>')});clearTimeout(t);if(!paused)t=setTimeout(()=>go(i+1),6000)}
document.getElementById('nx').onclick=()=>go(i+1);document.getElementById('pv').onclick=()=>go(i-1);document.getElementById('pl').onclick=e=>{paused=!paused;e.target.textContent=paused?'Play':'Pause';go(i)};go(0);</script>{% endblock %}'''

T["admin_nodes.html"] = MACRO + r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Nodes</h1><p>Servers go to this host first. When it is full, the panel uses the next node with a free slot.</p></div>
<div class="card" style="overflow:auto"><table><tr><th>Node</th><th>LXC</th><th>Docker</th><th>KVM</th><th>Slots</th><th>Actions</th></tr>
<tr><td><i class="dot on"></i>local (this host)</td><td><i class="dot {{ 'on' if local.lxc else 'off' }}"></i></td><td><i class="dot {{ 'on' if local.docker else 'off' }}"></i></td><td><i class="dot {{ 'on' if local.kvm else 'off' }}"></i></td><td>{{ used }} / {{ lslots if lslots != '0' else 'unlimited' }}</td>
<td><form method="post" action="/admin/nodes/local" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="slots" value="{{ lslots }}" style="width:70px" title="0 = unlimited"><label><input type="checkbox" name="fallback" {{ 'checked' if fallback == '1' }}> Docker fallback for LXC</label><button class="ghost">Save</button></form></td></tr>
{% for r in nodes %}<tr><td><i class="dot {{ 'on' if r.n.enabled else 'off' }}"></i>{{ r.n.name }}<br><span class="mut mono" style="font-size:12px">{{ r.n.url }}</span></td><td><i class="dot {{ 'on' if r.caps.lxc else 'off' }}"></i></td><td><i class="dot {{ 'on' if r.caps.docker else 'off' }}"></i></td><td><i class="dot {{ 'on' if r.caps.kvm else 'off' }}"></i></td>
<td>{{ r.used }} / {{ r.n.slots }}</td><td><form method="post" action="/admin/nodes/slots" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="id" value="{{ r.n.id }}"><input name="slots" value="{{ r.n.slots }}" style="width:70px"><button class="ghost">Set slots</button></form>
<form method="post" action="/admin/nodes/ping" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="id" value="{{ r.n.id }}"><button class="ghost">Test</button></form>
<form method="post" action="/admin/nodes/toggle" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="id" value="{{ r.n.id }}"><button class="ghost">{{ 'Disable' if r.n.enabled else 'Enable' }}</button></form>
<form method="post" action="/admin/nodes/remove" class="inl" data-confirm="Remove this node?"><input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="id" value="{{ r.n.id }}"><button class="red">Remove</button></form></td></tr>{% endfor %}</table></div>
<h2>Add a node</h2><div class="card"><p class="mut">Easiest: on the other server run <code>sudo bash install.sh</code>, choose "API node", and paste an admin API key from Account. It registers itself. To add one by hand:</p>
<form method="post" action="/admin/nodes/add"><input type="hidden" name="csrf" value="{{ csrf }}"><div class="grid"><div><label>Name</label><input name="name" required></div><div><label>Node URL</label><input name="url" placeholder="https://node1.example.com" required></div>
<div><label>Node key</label><input name="key" type="password" required></div><div><label>Slots</label><input name="slots" value="10"></div></div><button>Add node</button></form></div>
<script nonce="{{ nonce }}">document.querySelectorAll('form[data-confirm]').forEach(f=>f.addEventListener('submit',e=>{if(!confirm(f.dataset.confirm))e.preventDefault()}));</script>{% endblock %}'''

T["admin_security.html"] = r'''{% extends "base.html" %}{% block body %}<div class="ph"><h1 style="font-size:1.7rem">Security</h1><p>Login rules, 2FA enforcement and access control. Your IP: <code>{{ my_ip }}</code></p></div>
<div class="card"><form method="post" action="/admin/security/save"><input type="hidden" name="csrf" value="{{ csrf }}"><div class="grid">
<div><label>Minimum password length</label><input name="min_pw" value="{{ s.min_pw }}"></div><div><label>Failed logins before lockout</label><input name="max_fails" value="{{ s.max_fails }}"></div>
<div><label>Lockout minutes</label><input name="lock_min" value="{{ s.lock_min }}"></div><div><label>Session lifetime (hours)</label><input name="sess_hours" value="{{ s.sess_hours }}"></div>
<div><label>Auto-ban IP after N failed logins in 10 min</label><input name="ip_ban_after" value="{{ s.ip_ban_after }}"></div><div><label>Admin area IP allowlist (comma separated, empty = anywhere)</label><input name="admin_ips" value="{{ s.admin_ips }}" placeholder="203.0.113.5, 198.51.100.0/24"></div></div>
<label><input type="checkbox" name="force_admin_2fa" {{ 'checked' if s.force_admin_2fa == '1' }}> Require 2FA for admins</label><br><label><input type="checkbox" name="force_all_2fa" {{ 'checked' if s.force_all_2fa == '1' }}> Require 2FA for everyone</label><br>
<label><input type="checkbox" name="registration" {{ 'checked' if s.registration == '1' }}> Open registration</label><br><div class="acts" style="margin-top:12px"><button>Save security settings</button></div></form></div>
<h2>Banned IPs</h2><div class="card"><form method="post" action="/admin/security/ban" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="ip" placeholder="IP address" required><input name="reason" placeholder="Reason"><button>Ban IP</button></form>
<table>{% for b in bans %}<tr><td class="mono">{{ b.ip }}</td><td class="mut">{{ b.reason }}</td><td class="mut">{{ b.created_at|ts }}</td><td><form method="post" action="/admin/security/unban" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="ip" value="{{ b.ip }}"><button class="ghost">Unban</button></form></td></tr>{% else %}<tr><td class="mut">No banned IPs.</td></tr>{% endfor %}</table></div>
<h2>Sessions</h2><div class="card"><form method="post" action="/admin/security/signout-all" class="inl" data-confirm="Sign out every user?"><input type="hidden" name="csrf" value="{{ csrf }}"><button class="red">Sign out all users</button></form></div>
<h2>Recent failed logins</h2><div class="card" style="overflow:auto"><table>{% for a in fails %}<tr><td class="mono">{{ a.detail }}</td><td class="mut">{{ a.ip }}</td><td class="mut">{{ a.created_at|ts }}</td></tr>{% else %}<tr><td class="mut">None.</td></tr>{% endfor %}</table></div>
<script nonce="{{ nonce }}">document.querySelectorAll('form[data-confirm]').forEach(f=>f.addEventListener('submit',e=>{if(!confirm(f.dataset.confirm))e.preventDefault()}));</script>{% endblock %}'''

import fun  # noqa: E402,F401  (themes, rewards, status page, login hardening)
PYV3

cat > "$APP/features.py" <<'PYFEAT'
"""Extra panel features (v2.1): SSH/tunnels, VPS management, 2FA, API tokens, admin tools."""
import base64, csv, hashlib, hmac, io, re, secrets, struct, threading, time
from flask import Response, abort, flash, jsonify, redirect, render_template, request, session
from werkzeug.security import check_password_hash, generate_password_hash
import core, ops
from app import T, admin_required, app, limiter, login_required, me, own_vps, uahash

PLAN_NAMES = list(core.PLANS)

def act(action, detail="", vid=None, uid=None):
    u = me(); uid = uid or (u["id"] if u else None)
    ip = request.headers.get("CF-Connecting-IP") or request.remote_addr
    core.ex("INSERT INTO activity(user_id,vps_id,action,detail,ip) VALUES(?,?,?,?,?)", (uid, vid, action, (detail or "")[:300], ip))

def bg(label, v, fn, *a):
    """Run a slow container job without blocking the request; outcome goes to the activity log."""
    def job():
        try: fn(v, *a); core.ex("INSERT INTO activity(user_id,vps_id,action,detail) VALUES(?,?,?,?)", (v["user_id"], v["id"], label, "done"))
        except Exception as e: core.ex("INSERT INTO activity(user_id,vps_id,action,detail) VALUES(?,?,?,?)", (v["user_id"], v["id"], label + " failed", str(e)[:300]))
    threading.Thread(target=job, daemon=True).start()

def mine(vid):
    """Ownership check + must be deployed and not suspended (admins bypass suspension)."""
    v = own_vps(vid)
    if not v["engine"]: abort(redirect(f"/v/{vid}"))
    if v["suspended"] and not me()["is_admin"]:
        flash("This server is suspended.", "err"); abort(redirect(f"/v/{vid}"))
    return v

def fresh(vid): return core.q("SELECT * FROM vps WHERE id=?", (vid,), one=True)

# --------------------------------------------------------------------- TOTP (RFC 6238)
def totp(secret, t=None, step=30):
    key = base64.b32decode(secret + "=" * (-len(secret) % 8))
    h = hmac.new(key, struct.pack(">Q", int((t or time.time()) // step)), "sha1").digest()
    o = h[-1] & 15
    return f"{(struct.unpack('>I', h[o:o + 4])[0] & 0x7fffffff) % 10**6:06d}"
def totp_ok(secret, code):
    code = re.sub(r"\D", "", code or "")
    return len(code) == 6 and any(hmac.compare_digest(totp(secret, time.time() + d * 30), code) for d in (-1, 0, 1))

@app.route("/login/2fa", methods=["GET", "POST"])
@limiter.limit("10/minute", methods=["POST"])
def login_2fa():
    uid = session.get("pre2fa")
    if not uid: return redirect("/login")
    if request.method == "POST":
        session["t2"] = session.get("t2", 0) + 1
        if session["t2"] > 6: session.clear(); flash("Too many wrong codes. Log in again.", "err"); return redirect("/login")
        u = core.q("SELECT * FROM users WHERE id=?", (uid,), one=True)
        if u and u["totp_on"] and not u["banned"] and totp_ok(u["totp_secret"], request.form.get("code")):
            session.clear(); session.update(uid=u["id"], sv=u["sv"], ua=uahash(), csrf=secrets.token_urlsafe(32)); session.permanent = True
            act("login", "2FA verified", uid=u["id"]); return redirect("/dashboard")
        flash("Invalid code.", "err")
    return render_template("login2fa.html")

# --------------------------------------------------------------------------- account
@app.route("/account")
@login_required
def account():
    u = me(); uri = None
    if u["totp_secret"] and not u["totp_on"]:
        uri = f"otpauth://totp/Ariznodes:{u['username']}?secret={u['totp_secret']}&issuer=Ariznodes"
    return render_template("account.html", u=u, uri=uri, new_token=session.pop("new_token", None),
        tokens=core.q("SELECT id,name,created_at FROM tokens WHERE user_id=?", (u["id"],)),
        acts=core.q("SELECT * FROM activity WHERE user_id=? ORDER BY id DESC LIMIT 30", (u["id"],)))

@app.post("/account/password")
@login_required
def acc_password():
    u, f = me(), request.form
    if not check_password_hash(u["pw_hash"], f.get("current", "")): flash("Current password is wrong.", "err")
    elif f.get("new") != f.get("confirm") or not core.pw_ok(f.get("new", "")): flash("New passwords must match and meet the password rules (length, letters and numbers).", "err")
    else:
        core.ex("UPDATE users SET pw_hash=?, sv=sv+1 WHERE id=?", (generate_password_hash(f["new"]), u["id"]))
        session["sv"] = u["sv"] + 1; act("password", "changed (other sessions signed out)"); flash("Password changed. Other devices were signed out.", "ok")
    return redirect("/account")

@app.post("/account/2fa/<step>")
@login_required
@limiter.limit("10/minute")
def acc_2fa(step):
    u = me()
    if step == "start" and not u["totp_on"]:
        core.ex("UPDATE users SET totp_secret=? WHERE id=?", (base64.b32encode(secrets.token_bytes(20)).decode().rstrip("="), u["id"]))
    elif step == "enable" and u["totp_secret"] and totp_ok(u["totp_secret"], request.form.get("code")):
        core.ex("UPDATE users SET totp_on=1 WHERE id=?", (u["id"],)); act("2fa", "enabled"); flash("Two-factor authentication enabled.", "ok")
    elif step == "enable": flash("That code is not valid - check your authenticator's clock.", "err")
    elif step == "disable" and check_password_hash(u["pw_hash"], request.form.get("password", "")):
        core.ex("UPDATE users SET totp_on=0, totp_secret=NULL WHERE id=?", (u["id"],)); act("2fa", "disabled"); flash("Two-factor authentication disabled.", "ok")
    elif step == "disable": flash("Password is wrong.", "err")
    return redirect("/account")

@app.post("/account/token/new")
@login_required
def acc_token_new():
    if core.q("SELECT COUNT(*) n FROM tokens WHERE user_id=?", (me()["id"],), one=True)["n"] >= 5: flash("Token limit (5) reached.", "err")
    else:
        tok = "arz-" + secrets.token_urlsafe(30)
        core.ex("INSERT INTO tokens(user_id,name,hash) VALUES(?,?,?)", (me()["id"], request.form.get("name", "token")[:40] or "token", hashlib.sha256(tok.encode()).hexdigest()))
        session["new_token"] = tok; act("token", "created")
    return redirect("/account")

@app.post("/account/token/<int:tid>/revoke")
@login_required
def acc_token_revoke(tid):
    core.ex("DELETE FROM tokens WHERE id=? AND user_id=?", (tid, me()["id"])); act("token", "revoked"); return redirect("/account")

@app.post("/account/logout-all")
@login_required
def acc_logout_all():
    core.ex("UPDATE users SET sv=sv+1 WHERE id=?", (me()["id"],)); session["sv"] = me()["sv"] + 1
    act("sessions", "all other sessions signed out"); flash("Signed out everywhere else.", "ok"); return redirect("/account")

# ------------------------------------------------------------------------ VPS page
def render_vps(v, out=None, cmd=""):
    lxc = None
    if v["engine"] == "lxc":
        try: lxc = ops.lxc_fields(v)
        except Exception: pass
    live = core.state(v["engine"], v["name"]) if v["engine"] else v["status"]
    snaps = []
    if v["engine"]:
        try: snaps = ops.snap_list(v)
        except Exception: pass
    host, port = ops.tunnel_target(v["pinggy_url"])
    left = (v["expires_at"] - time.time()) / 86400 if v["expires_at"] else None
    return render_template("vps2.html", v=v, live=live, pw=core.dec(v["secret"]), snaps=snaps, host=host, port=port,
        ip=ops.ip_of(v) if live == "running" else "-", quick=list(ops.QUICK), lxc=lxc, out=out, cmd=cmd, left=left, plan_names=PLAN_NAMES,
        hist=core.q("SELECT detail,created_at FROM activity WHERE vps_id=? AND action='exec' ORDER BY id DESC LIMIT 8", (v["id"],)),
        busy=any(core.q("SELECT 1 FROM vps WHERE id=? AND ssh_state='installing'", (v["id"],))))

@app.route("/v/<int:vid>")
@login_required
def v_page(vid): return render_vps(own_vps(vid))

@app.route("/v/<int:vid>/stats.json")
@login_required
@limiter.limit("60/minute")
def v_stats(vid):
    v = mine(vid)
    try: return jsonify(ok=True, state=core.state(v["engine"], v["name"]), **ops.stats(v))
    except Exception as e: return jsonify(ok=False, error=str(e)[:200])

@app.route("/v/<int:vid>/info/<what>")
@login_required
@limiter.limit("30/minute")
def v_info(vid, what):
    v = mine(vid)
    try: return jsonify(out=ops.info(v, what)[-6000:])
    except Exception as e: return jsonify(out=f"error: {e}")

@app.post("/v/<int:vid>/exec")
@login_required
@limiter.limit("30/minute")
def v_exec(vid):
    v, cmd = mine(vid), request.form.get("cmd", "")[:500]
    act("exec", cmd, vid)
    try: out = ops.sh(v, cmd, 60)[-6000:] or "(no output)"
    except Exception as e: out = f"error: {e}"
    return render_vps(v, out, cmd)

@app.post("/v/<int:vid>/<path:op>")
@login_required
@limiter.limit("20/minute")
def v_op(vid, op):
    v = own_vps(vid); parts = op.split("/"); a = parts[0]
    back = redirect(f"/v/{vid}")
    if a == "rename":
        core.ex("UPDATE vps SET label=? WHERE id=?", (re.sub(r"[^\w .-]", "", request.form.get("label", ""))[:40], vid)); return back
    if a == "renew":
        d = int(core.setting("vps_days") or 0)
        if d <= 0: flash("Servers do not expire on this panel.", "err"); return back
        core.ex("UPDATE vps SET expires_at=? WHERE id=?", (time.time() + d * 86400, vid))
        if v["suspended"] and v["susp_reason"] == "expired" and v["engine"]:
            try: core.control(v["engine"], v["name"], "start")
            except Exception: pass
            core.ex("UPDATE vps SET suspended=0, susp_reason=NULL WHERE id=?", (vid,))
        act("renew", f"+{d} days", vid); flash(f"Renewed for {d} days.", "ok"); return back
    v = mine(vid)
    try:
        if a == "ssh": bg("ssh setup", v, ops.ssh_enable); flash("Installing SSH and tools - this takes about a minute. The page refreshes by itself.", "ok")
        elif a == "tunnel" and parts[1:] in (["pinggy", "start"], ["pinggy", "stop"], ["sshx", "start"], ["sshx", "stop"]):
            if parts[1:] == ["pinggy", "start"] and v["ssh_state"] != "ready": flash("Enable SSH first.", "err"); return back
            {"pinggy start": ops.pinggy_start, "pinggy stop": ops.pinggy_stop, "sshx start": ops.sshx_start, "sshx stop": ops.sshx_stop}[" ".join(parts[1:])](v)
            act("tunnel", " ".join(parts[1:]), vid); flash("Done.", "ok")
        elif a == "passwd":
            pw = secrets.token_urlsafe(14); ops.set_root_password(v, pw)
            core.ex("UPDATE vps SET secret=? WHERE id=?", (core.enc(pw), vid)); act("passwd", "root password reset", vid); flash("Root password reset.", "ok")
        elif a == "snap" and parts[1] == "create": ops.snap_create(v, request.form.get("tag", "").lower().strip()); act("snapshot", "create", vid); flash("Snapshot created.", "ok")
        elif a == "snap" and parts[1] == "restore": ops.snap_restore(v, parts[2]); act("snapshot", "restore " + parts[2], vid); flash("Snapshot restored.", "ok")
        elif a == "snap" and parts[1] == "delete": ops.snap_delete(v, parts[2]); act("snapshot", "delete " + parts[2], vid); flash("Snapshot deleted.", "ok")
        elif a == "quick" and parts[1] in ops.QUICK:
            bg("install " + parts[1], v, lambda vv: ops.sh(vv, "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; " + ops.QUICK[parts[1]], 900))
            flash(f"Installing '{parts[1]}' in the background - see Activity for the result.", "ok")
        elif a == "reinstall":
            if request.form.get("confirm") != "yes" or request.form.get("image") not in ("22.04", "24.04"): flash("Tick the confirmation box.", "err"); return back
            pw = secrets.token_urlsafe(14); core.ex("UPDATE vps SET secret=?, status='pending' WHERE id=?", (core.enc(pw), vid))
            bg("reinstall", v, lambda vv: ops.reinstall(vv, request.form["image"], pw)); act("reinstall", request.form["image"], vid)
            flash("Reinstalling - all data on this server is being erased.", "ok")
        else: abort(404)
    except (ValueError, RuntimeError) as e: flash(str(e)[:250], "err")
    return back

@app.route("/v/<int:vid>/files")
@login_required
def v_files(vid):
    v, path = mine(vid), request.args.get("path", "/root")
    if not path.startswith("/") or "\0" in path: abort(400)
    try:
        if path.endswith("/") or request.args.get("dir"): return render_template("files.html", v=v, path=path.rstrip("/") or "/", entries=ops.ls(v, path), text=None)
        try: return render_template("files.html", v=v, path=path, entries=None, text=ops.read_file(v, path))
        except RuntimeError: return render_template("files.html", v=v, path=path.rstrip("/") or "/", entries=ops.ls(v, path), text=None)
    except RuntimeError as e: flash(str(e)[:200], "err"); return redirect(f"/v/{vid}")

@app.post("/v/<int:vid>/files/save")
@login_required
@limiter.limit("30/minute")
def v_save(vid):
    v, path = mine(vid), request.form.get("path", "")
    if not path.startswith("/") or "\0" in path: abort(400)
    try: ops.write_file(v, path, request.form.get("text", "").replace("\r\n", "\n")); act("file", "saved " + path, vid); flash("Saved.", "ok")
    except (RuntimeError, ValueError) as e: flash(str(e)[:200], "err")
    return redirect(f"/v/{vid}/files?path={path}")

# ------------------------------------------------------------------ REST API (Bearer)
def api_user():
    h = request.headers.get("Authorization", "")
    if not h.startswith("Bearer "): return None
    return core.q("SELECT u.* FROM tokens t JOIN users u ON u.id=t.user_id WHERE t.hash=? AND u.banned=0",
                  (hashlib.sha256(h[7:].strip().encode()).hexdigest(),), one=True)

def api_vps(u, vid):
    v = fresh(vid)
    if not v or (v["user_id"] != u["id"] and not u["is_admin"]): return None
    return v

@app.get("/api/v1/vps")
@limiter.limit("60/minute")
def api_list():
    u = api_user()
    if not u: return jsonify(error="unauthorized"), 401
    return jsonify([dict(id=v["id"], name=v["name"], plan=v["plan"], kind=v["kind"], status=v["status"], engine=v["engine"])
                    for v in core.q("SELECT * FROM vps WHERE user_id=?", (u["id"],))])

@app.post("/api/v1/vps/<int:vid>/<action>")
@limiter.limit("30/minute")
def api_action(vid, action):
    u = api_user()
    if not u: return jsonify(error="unauthorized"), 401
    v = api_vps(u, vid)
    if not v or not v["engine"]: return jsonify(error="not found"), 404
    if v["suspended"] and not u["is_admin"]: return jsonify(error="suspended"), 403
    if action not in ("start", "stop", "restart"): return jsonify(error="action must be start, stop or restart"), 400
    try: core.control(v["engine"], v["name"], action)
    except Exception as e: return jsonify(error=str(e)[:200]), 500
    core.ex("INSERT INTO activity(user_id,vps_id,action,detail) VALUES(?,?,?,?)", (u["id"], vid, "api", action)); return jsonify(ok=True)

@app.get("/api/v1/vps/<int:vid>/stats")
@limiter.limit("30/minute")
def api_stats(vid):
    u = api_user(); v = api_vps(u, vid) if u else None
    if not u: return jsonify(error="unauthorized"), 401
    if not v or not v["engine"]: return jsonify(error="not found"), 404
    try: return jsonify(ops.stats(v))
    except Exception as e: return jsonify(error=str(e)[:200]), 500

# ------------------------------------------------------------------------- admin tools
@app.before_request
def maintenance_gate():
    if request.path == "/vps/create" and request.method == "POST" and core.setting("maintenance") == "1":
        u = me()
        if not (u and u["is_admin"]): flash("Deployments are paused for maintenance.", "err"); return redirect("/dashboard")

@app.route("/admin/more")
@admin_required
def admin_more():
    return render_template("admin_more.html", plans=PLAN_NAMES, s={k: core.setting(k) for k in core.DEFAULTS},
        users=core.q("SELECT * FROM users ORDER BY id DESC LIMIT 200"),
        vps=core.q("SELECT v.*, u.username FROM vps v JOIN users u ON u.id=v.user_id ORDER BY v.id DESC LIMIT 200"),
        acts=core.q("SELECT a.*, u.username FROM activity a LEFT JOIN users u ON u.id=a.user_id ORDER BY a.id DESC LIMIT 80"))

@app.route("/admin/user/<int:uid>")
@admin_required
def admin_user_page(uid):
    u = core.q("SELECT * FROM users WHERE id=?", (uid,), one=True) or abort(404)
    return render_template("admin_user.html", u=u, n=core.valid_invites(u["discord_id"]) if u["discord_id"] else 0,
        vps=core.q("SELECT * FROM vps WHERE user_id=?", (uid,)),
        acts=core.q("SELECT * FROM activity WHERE user_id=? ORDER BY id DESC LIMIT 40", (uid,)))

@app.post("/admin/bonus/<int:uid>")
@admin_required
def admin_bonus(uid):
    try: n = max(-50, min(50, int(request.form.get("n", "0"))))
    except ValueError: n = 0
    core.ex("UPDATE users SET bonus_invites=? WHERE id=?", (n, uid)); act("admin", f"bonus invites user#{uid} = {n}"); return redirect(f"/admin/user/{uid}")

@app.post("/admin/vps/<int:vid>/<op>")
@admin_required
@limiter.limit("30/minute")
def admin_vps_op(vid, op):
    v = fresh(vid) or abort(404)
    try:
        if op == "suspend" and v["engine"]:
            core.control(v["engine"], v["name"], "stop"); core.ex("UPDATE vps SET suspended=1, susp_reason='admin' WHERE id=?", (vid,))
        elif op == "unsuspend" and v["engine"]:
            core.control(v["engine"], v["name"], "start"); core.ex("UPDATE vps SET suspended=0, susp_reason=NULL WHERE id=?", (vid,))
        elif op == "resize" and request.form.get("plan") in core.PLANS and v["engine"]: ops.resize(v, request.form["plan"])
        elif op == "transfer":
            t = core.q("SELECT id FROM users WHERE username=? COLLATE NOCASE", (request.form.get("to", ""),), one=True)
            if not t: flash("No such user.", "err"); return redirect("/admin/more")
            core.ex("UPDATE vps SET user_id=? WHERE id=?", (t["id"], vid))
        elif op == "renew":
            d = max(1, min(365, int(request.form.get("days", "7") or 7)))
            core.ex("UPDATE vps SET expires_at=?, suspended=0, susp_reason=NULL WHERE id=?", (time.time() + d * 86400, vid))
            if v["suspended"] and v["engine"]: core.control(v["engine"], v["name"], "start")
        else: abort(400)
        act("admin", f"{op} {v['name']}"); flash(f"{op}: done.", "ok")
    except (RuntimeError, ValueError) as e: flash(str(e)[:250], "err")
    return redirect("/admin/more")

@app.post("/admin/more/settings")
@admin_required
def admin_more_settings():
    f = request.form
    hook = f.get("alert_webhook", "").strip()
    if hook and not re.match(r"^https://(discord|discordapp)\.com/api/webhooks/\d+/[\w-]+$", hook): flash("Webhook must be a Discord webhook URL.", "err"); return redirect("/admin/more")
    vals = {"maintenance": "1" if f.get("maintenance") else "0", "auto_tunnel": "1" if f.get("auto_tunnel") else "0",
            "vps_days": str(max(0, min(365, int(f.get("vps_days", "0") or 0)))) if f.get("vps_days", "0").isdigit() else "0",
            "alert_webhook": hook, "pinggy_token": re.sub(r"[^\w-]", "", f.get("pinggy_token", ""))[:64]}
    for k, v in vals.items(): core.ex("INSERT OR REPLACE INTO settings(key,value) VALUES(?,?)", (k, v))
    act("admin", "settings updated"); flash("Settings saved.", "ok"); return redirect("/admin/more")

@app.route("/admin/export/<what>.csv")
@admin_required
def admin_export(what):
    sql = {"users": "SELECT id,username,discord_id,discord_name,is_admin,banned,bonus_invites,totp_on,created_at FROM users",
           "vps": "SELECT id,user_id,name,label,plan,kind,image,engine,status,suspended,expires_at,created_at FROM vps",
           "activity": "SELECT id,user_id,vps_id,action,detail,ip,created_at FROM activity ORDER BY id DESC LIMIT 5000"}.get(what) or abort(404)
    rows = core.q(sql); buf = io.StringIO(); w = csv.writer(buf)
    if rows: w.writerow(rows[0].keys())
    for r in rows: w.writerow([("'" + c) if isinstance(c, str) and c[:1] in "=+-@" else c for c in tuple(r)])  # blocks CSV formula injection
    act("admin", f"export {what}")
    return Response(buf.getvalue(), mimetype="text/csv", headers={"Content-Disposition": f"attachment; filename={what}.csv"})

# --------------------------------------------------------------------------- templates
MACRO = '''{% macro pb(url, label, cls='ghost', confirm='') %}<form method="post" action="{{ url }}" class="inl"{% if confirm %} data-confirm="{{ confirm }}"{% endif %}><input type="hidden" name="csrf" value="{{ csrf }}"><button class="{{ cls }}">{{ label }}</button></form>{% endmacro %}'''
T["login2fa.html"] = r'''{% extends "base.html" %}{% block body %}<div class="card auth"><h2 style="margin-top:0">{{ ico('shield') }} Two-factor code</h2>
<form method="post"><input type="hidden" name="csrf" value="{{ csrf }}"><p class="mut">Enter the 6-digit code from your authenticator app.</p>
<input name="code" inputmode="numeric" autocomplete="one-time-code" maxlength="8" required autofocus><button style="width:100%;justify-content:center">Verify</button></form></div>{% endblock %}'''

T["account.html"] = MACRO + r'''{% extends "base.html" %}{% block body %}<h1 style="font-size:2rem">{{ ico('user') }} Account <span class="grad">security</span></h1>
<div class="grid"><div class="card"><h3>Change password</h3><form method="post" action="/account/password"><input type="hidden" name="csrf" value="{{ csrf }}">
<input name="current" type="password" placeholder="Current password" required autocomplete="current-password"><input name="new" type="password" placeholder="New password (10+)" required minlength="10" autocomplete="new-password">
<input name="confirm" type="password" placeholder="Repeat new password" required autocomplete="new-password"><button>Update</button></form></div>
<div class="card"><h3>Two-factor (TOTP)</h3>{% if u.totp_on %}<p><span class="tag">enabled</span></p><form method="post" action="/account/2fa/disable"><input type="hidden" name="csrf" value="{{ csrf }}">
<input name="password" type="password" placeholder="Password to disable" required><button class="red">Disable</button></form>
{% elif uri %}<p class="mut">Add this key to Google Authenticator, Authy, 1Password, etc. (manual entry, time-based):</p><pre>{{ u.totp_secret }}</pre><p class="mut" style="word-break:break-all">{{ uri }}</p>
<form method="post" action="/account/2fa/enable"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="code" placeholder="6-digit code" inputmode="numeric" required><button>Confirm &amp; enable</button></form>
{% else %}<p class="mut">Protect logins with a one-time code.</p>{{ pb('/account/2fa/start', 'Set up 2FA', '') }}{% endif %}</div>
<div class="card"><h3>Sessions</h3><p class="mut">Sign out every other browser/device.</p>{{ pb('/account/logout-all', 'Sign out everywhere else') }}</div></div>
<h2>API tokens</h2><div class="card">{% if new_token %}<div class="flash ok">Copy your token now, it is shown only once:<pre>{{ new_token }}</pre></div>{% endif %}
<form method="post" action="/account/token/new" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="name" placeholder="Token name" maxlength="40" style="width:220px;display:inline-block"> <button>Create token</button></form>
<table>{% for t in tokens %}<tr><td>{{ t.name }}</td><td class="mut">{{ t.created_at|ts }}</td><td>{{ pb('/account/token/%d/revoke' % t.id, 'Revoke', 'red') }}</td></tr>{% endfor %}</table>
<p class="mut">Use: <code>curl -H "Authorization: Bearer TOKEN" https://{{ request.host }}/api/v1/vps</code> &middot; POST <code>/api/v1/vps/ID/start|stop|restart</code> &middot; GET <code>/api/v1/vps/ID/stats</code></p></div>
<h2>Recent activity</h2><div class="card" style="overflow:auto"><table>{% for a in acts %}<tr><td><span class="tag">{{ a.action }}</span></td><td>{{ a.detail }}</td><td class="mut">{{ a.ip or '' }}</td><td class="mut">{{ a.created_at|ts }}</td></tr>{% else %}<tr><td class="mut">Nothing yet.</td></tr>{% endfor %}</table></div>{% endblock %}'''

T["files.html"] = MACRO + r'''{% extends "base.html" %}{% block body %}<h1 style="font-size:1.6rem">Files &middot; {{ v.label or v.name }}</h1><p><a href="/v/{{ v.id }}">&larr; back to server</a> &nbsp; <code>{{ path }}</code></p>
{% if entries is not none %}<div class="card"><table>{% if path != '/' %}<tr><td><a href="/v/{{ v.id }}/files?dir=1&path={{ (path.rsplit('/', 1)[0] or '/')|urlencode }}">../</a></td></tr>{% endif %}
{% for e in entries %}<tr><td><a href="/v/{{ v.id }}/files?{{ 'dir=1&' if e.endswith('/') }}path={{ ((path.rstrip('/') + '/' + e.rstrip('/'))|urlencode) }}">{{ e }}</a></td></tr>{% else %}<tr><td class="mut">Empty.</td></tr>{% endfor %}</table></div>
{% else %}<div class="card"><form method="post" action="/v/{{ v.id }}/files/save"><input type="hidden" name="csrf" value="{{ csrf }}"><input type="hidden" name="path" value="{{ path }}">
<textarea name="text" rows="22" style="width:100%;background:#05060a;color:var(--txt);border:1px solid var(--line);border-radius:10px;padding:12px;font:13px/1.5 monospace">{{ text }}</textarea><br><button>Save file</button></form></div>{% endif %}{% endblock %}'''

T["vps2.html"] = MACRO + r'''{% extends "base.html" %}{% block body %}
<h1 style="font-size:2rem;margin-bottom:4px">{{ v.label or v.name }} <span class="tag">{{ v.name }}</span></h1>
{% if v.suspended %}<div class="flash err">{{ ico('ban') }} Suspended ({{ v.susp_reason or 'admin' }}).{% if v.susp_reason == 'expired' %} Renew in Settings to restore it.{% endif %}</div>{% endif %}
<div class="grid"><div class="card {{ live }}"><span class="mut">State</span><div class="big"><span class="dot"></span><span id="st">{{ live }}</span></div></div>
<div class="card"><span class="mut">Plan / engine</span><div class="big">{{ v.plan }}</div><span class="tag">{{ v.engine or 'pending' }} &middot; {{ 'VM' if v.kind == 'vm' else 'container' }}</span></div>
<div class="card"><span class="mut">Internal IP</span><div class="big" style="font-size:1.3rem">{{ ip }}</div>{% if left is not none %}<span class="tag">{{ 'expires in %.1f days' % left if left > 0 else 'expired' }}</span>{% endif %}</div>
<div class="card"><span class="mut">Root password</span><pre style="margin:8px 0 0">{{ pw }}</pre></div></div>
{% if not v.engine %}<div class="card"><p class="mut">Status: {{ v.status }}</p>{{ pb('/vps/%d/delete' % v.id, 'Remove', 'red') }}</div>{% else %}
<div class="tabs"><button class="ghost" data-tab="t-over">Overview</button><button class="ghost" data-tab="t-acc">Access</button><button class="ghost" data-tab="t-con">Console</button>
<button class="ghost" data-tab="t-snap">Snapshots</button><button class="ghost" data-tab="t-tools">Tools</button><button class="ghost" data-tab="t-set">Settings</button></div>
<section class="tab" id="t-over"><div class="card"><div class="grid">
<div><span class="mut">CPU</span><div class="bar"><i id="b-cpu" style="width:0"></i></div><small id="x-cpu" class="mut">-</small></div>
<div><span class="mut">Memory</span><div class="bar"><i id="b-mem" style="width:0"></i></div><small id="x-mem" class="mut">-</small></div>
<div><span class="mut">Network</span><div id="x-net" class="mut">-</div></div><div><span class="mut">Processes</span><div id="x-pids" class="mut">-</div></div></div>
<p>{{ pb('/vps/%d/start' % v.id, 'Start', '') }} {{ pb('/vps/%d/stop' % v.id, 'Stop') }} {{ pb('/vps/%d/restart' % v.id, 'Restart') }} {{ pb('/vps/%d/delete' % v.id, 'Delete', 'red', 'Delete this server permanently?') }}</p>
<p><button class="ghost" data-info="ps">Processes</button> <button class="ghost" data-info="disk">Disk &amp; RAM</button> <button class="ghost" data-info="net">Network</button> <button class="ghost" data-info="uptime">System</button> <button class="ghost" data-info="logs">Logs</button></p>
<pre id="info" style="display:none"></pre></div></section>
<section class="tab" id="t-acc"><div class="card"><h3>SSH {% if v.ssh_state == 'ready' %}<span class="tag">ready</span>{% elif v.ssh_state == 'installing' %}<span class="tag">installing...</span>{% elif v.ssh_state == 'failed' %}<span class="tag">failed</span>{% endif %}</h3>
<p class="mut">Installs OpenSSH plus basic tools (ps, ip, curl, nano) and enables root login with the password above.</p>{{ pb('/v/%d/ssh' % v.id, 'Enable SSH & tools', '') }}
<h3>Pinggy SSH tunnel</h3>{% if v.pinggy_url %}<pre>ssh -p {{ port }} root@{{ host }}</pre><p class="mut">Live tunnel: {{ v.pinggy_url }} &middot; free tunnels change address on reconnect; the panel re-opens dropped tunnels automatically.</p>{{ pb('/v/%d/tunnel/pinggy/start' % v.id, 'Refresh tunnel') }} {{ pb('/v/%d/tunnel/pinggy/stop' % v.id, 'Stop', 'red') }}
{% else %}<p class="mut">Public SSH address with no port forwarding (needs SSH enabled first).</p>{{ pb('/v/%d/tunnel/pinggy/start' % v.id, 'Start pinggy tunnel', '') }}{% endif %}
<h3>sshx web terminal</h3>{% if v.sshx_url %}<p><a href="{{ v.sshx_url }}" target="_blank" rel="noopener noreferrer">{{ v.sshx_url }}</a></p><p class="mut">Anyone with this link gets a shell. Treat it like a password.</p>{{ pb('/v/%d/tunnel/sshx/stop' % v.id, 'Stop sshx', 'red') }}
{% else %}<p class="mut">Instant browser terminal, no SSH client needed.</p>{{ pb('/v/%d/tunnel/sshx/start' % v.id, 'Start sshx terminal', '') }}{% endif %}</div></section>
<section class="tab" id="t-con"><div class="card"><form method="post" action="/v/{{ v.id }}/exec"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="cmd" value="{{ cmd }}" placeholder="uname -a" maxlength="500" required><button>Run</button>
 &nbsp; <a href="/v/{{ v.id }}/files?dir=1&path=/root">Open file manager</a></form>{% if out is not none %}<pre>{{ out }}</pre>{% endif %}
{% if hist %}<p class="mut">Recent:</p>{% for h in hist %}<div class="mut"><code>{{ h.detail }}</code></div>{% endfor %}{% endif %}</div></section>
<section class="tab" id="t-snap"><div class="card"><form method="post" action="/v/{{ v.id }}/snap/create" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="tag" placeholder="snapshot-name" pattern="[a-z0-9][a-z0-9-]{0,29}" required style="width:220px;display:inline-block"> <button>Create snapshot</button></form>
<table>{% for s in snaps %}<tr><td>{{ s.tag }}</td><td class="mut">{{ s.when }} {{ s.size }}</td><td>{{ pb('/v/%d/snap/restore/%s' % (v.id, s.tag), 'Restore', '', 'Restore this snapshot? Current data will be replaced.') }} {{ pb('/v/%d/snap/delete/%s' % (v.id, s.tag), 'Delete', 'red') }}</td></tr>{% else %}<tr><td class="mut">No snapshots (max 5).</td></tr>{% endfor %}</table></div></section>
<section class="tab" id="t-tools"><div class="card"><p class="mut">One-click installs (run in the background; result appears in Activity on your account page).</p>{% for q in quick %}{{ pb('/v/%d/quick/%s' % (v.id, q), q) }} {% endfor %}</div></section>
<section class="tab" id="t-set"><div class="card"><form method="post" action="/v/{{ v.id }}/rename" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="label" value="{{ v.label or '' }}" placeholder="Display name" maxlength="40" style="width:220px;display:inline-block"> <button>Rename</button></form>
<p>{{ pb('/v/%d/passwd' % v.id, 'Reset root password', '', 'Generate a new root password?') }} {{ pb('/v/%d/renew' % v.id, 'Renew expiry', '') }}</p>
<h3>Reinstall OS</h3><form method="post" action="/v/{{ v.id }}/reinstall" data-confirm="This erases ALL data on the server. Continue?"><input type="hidden" name="csrf" value="{{ csrf }}"><select name="image" style="width:160px"><option>24.04</option><option>22.04</option></select>
<label><input type="checkbox" name="confirm" value="yes" style="width:auto"> I understand all data will be erased</label><br><button class="red">Reinstall</button></form></div></section>{% endif %}{% endblock %}
{% block scripts %}<style>.tabs{margin:18px 0 10px;display:flex;gap:8px;flex-wrap:wrap}.tab{display:none}.tab.on{display:block;animation:up .4s both}.tabs .on{background:var(--pri);border-color:var(--pri)}</style>
<script nonce="{{ nonce }}">
const tabs=[...document.querySelectorAll('[data-tab]')];function show(id){document.querySelectorAll('.tab').forEach(s=>s.classList.toggle('on',s.id===id));tabs.forEach(b=>b.classList.toggle('on',b.dataset.tab===id));history.replaceState(null,'','#'+id)}
tabs.forEach(b=>b.onclick=()=>show(b.dataset.tab));show((location.hash||'#{{ 't-con' if out is not none else 't-over' }}').slice(1));
document.querySelectorAll('form[data-confirm]').forEach(f=>f.addEventListener('submit',e=>{if(!confirm(f.dataset.confirm))e.preventDefault()}));
{% if v.engine %}const base='/v/{{ v.id }}';
document.querySelectorAll('[data-info]').forEach(b=>b.onclick=async()=>{const p=document.getElementById('info');p.style.display='block';p.textContent='Loading...';p.textContent=(await (await fetch(base+'/info/'+b.dataset.info)).json()).out||'(empty)'});
async function tick(){try{const j=await (await fetch(base+'/stats.json')).json();if(!j.ok)return;document.getElementById('st').textContent=j.state;
document.getElementById('b-cpu').style.width=j.cpu+'%';document.getElementById('x-cpu').textContent=j.cpu+'%';document.getElementById('b-mem').style.width=j.mem_pct+'%';
document.getElementById('x-mem').textContent=j.mem+' ('+j.mem_pct+'%)';document.getElementById('x-net').textContent=j.net;document.getElementById('x-pids').textContent=j.pids}catch(e){}}
if('{{ live }}'==='running'){tick();setInterval(()=>{if(!document.hidden)tick()},4000)}
{% if busy %}setTimeout(()=>location.reload(),8000);{% endif %}{% endif %}</script>{% endblock %}'''

T["admin_user.html"] = r'''{% extends "base.html" %}{% block body %}<p><a href="/admin/more">&larr; Admin tools</a></p><h1 style="font-size:1.8rem">{{ u.username }} {% if u.is_admin %}<span class="tag">admin</span>{% endif %}{% if u.banned %}<span class="tag">banned</span>{% endif %}</h1>
<div class="grid"><div class="card"><span class="mut">Discord</span><div class="big" style="font-size:1.3rem">{{ u.discord_name or 'not linked' }}</div></div><div class="card"><span class="mut">Valid invites</span><div class="big">{{ n }}</div><span class="tag">includes {{ u.bonus_invites }} bonus</span></div>
<div class="card"><span class="mut">2FA</span><div class="big" style="font-size:1.3rem">{{ 'on' if u.totp_on else 'off' }}</div></div></div>
<div class="card"><form method="post" action="/admin/bonus/{{ u.id }}"><input type="hidden" name="csrf" value="{{ csrf }}"><label>Bonus invites (-50..50)</label><input name="n" value="{{ u.bonus_invites }}" style="width:120px"><button>Save</button></form></div>
<h2>Servers</h2><div class="card"><table>{% for v in vps %}<tr><td>{{ v.name }}</td><td>{{ v.plan }}</td><td>{{ v.status }}</td><td><a href="/v/{{ v.id }}">Open</a></td></tr>{% else %}<tr><td class="mut">None.</td></tr>{% endfor %}</table></div>
<h2>Activity</h2><div class="card" style="overflow:auto"><table>{% for a in acts %}<tr><td><span class="tag">{{ a.action }}</span></td><td>{{ a.detail }}</td><td class="mut">{{ a.ip or '' }}</td><td class="mut">{{ a.created_at|ts }}</td></tr>{% endfor %}</table></div>{% endblock %}'''

T["admin_more.html"] = MACRO + r'''{% extends "base.html" %}{% block body %}<p><a href="/admin">&larr; Admin</a></p><h1 style="font-size:2rem">Admin <span class="grad">tools</span></h1>
<div class="card"><form method="post" action="/admin/more/settings"><input type="hidden" name="csrf" value="{{ csrf }}"><div class="grid">
<div><label>Server lifetime in days (0 = never expires)</label><input name="vps_days" value="{{ s.vps_days }}"></div>
<div><label>Discord alert webhook URL</label><input name="alert_webhook" value="{{ s.alert_webhook }}" placeholder="https://discord.com/api/webhooks/..."></div>
<div><label>Pinggy access token (optional, stable addresses)</label><input name="pinggy_token" value="{{ s.pinggy_token }}"></div></div>
<label><input type="checkbox" name="maintenance" style="width:auto" {{ 'checked' if s.maintenance == '1' }}> Maintenance mode (pause new deployments)</label>
<label><input type="checkbox" name="auto_tunnel" style="width:auto" {{ 'checked' if s.auto_tunnel == '1' }}> Keep pinggy tunnels alive (auto-reconnect)</label><br><button>Save</button>
&nbsp; Export: <a href="/admin/export/users.csv">users</a> &middot; <a href="/admin/export/vps.csv">servers</a> &middot; <a href="/admin/export/activity.csv">activity</a></form></div>
<h2>Servers</h2><div class="card" style="overflow:auto"><table><tr><th>Name</th><th>Owner</th><th>Plan</th><th>Status</th><th>Actions</th></tr>{% for v in vps %}<tr><td><a href="/v/{{ v.id }}">{{ v.name }}</a></td><td>{{ v.username }}</td><td>{{ v.plan }}</td><td>{{ v.status }}{% if v.suspended %} <span class="tag">suspended</span>{% endif %}</td><td>
{% if v.engine %}{% if v.suspended %}{{ pb('/admin/vps/%d/unsuspend' % v.id, 'Unsuspend', '') }}{% else %}{{ pb('/admin/vps/%d/suspend' % v.id, 'Suspend', '', 'Stop and lock this server?') }}{% endif %}{% endif %}
<form method="post" action="/admin/vps/{{ v.id }}/resize" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><select name="plan" style="width:100px;display:inline-block;margin:0">{% for p in plans %}<option {{ 'selected' if p == v.plan }}>{{ p }}</option>{% endfor %}</select><button class="ghost">Resize</button></form>
<form method="post" action="/admin/vps/{{ v.id }}/transfer" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="to" placeholder="new owner" style="width:110px;display:inline-block;margin:0"><button class="ghost">Transfer</button></form>
<form method="post" action="/admin/vps/{{ v.id }}/renew" class="inl"><input type="hidden" name="csrf" value="{{ csrf }}"><input name="days" value="7" style="width:60px;display:inline-block;margin:0"><button class="ghost">Renew</button></form></td></tr>{% endfor %}</table></div>
<h2>Users</h2><div class="card" style="overflow:auto"><table>{% for u in users %}<tr><td><a href="/admin/user/{{ u.id }}">{{ u.username }}</a></td><td>{{ u.discord_name or '-' }}</td><td class="mut">+{{ u.bonus_invites }} bonus</td><td>{{ '2FA' if u.totp_on }}</td></tr>{% endfor %}</table></div>
<h2>Activity log</h2><div class="card" style="overflow:auto"><table>{% for a in acts %}<tr><td class="mut">{{ a.username or '-' }}</td><td><span class="tag">{{ a.action }}</span></td><td>{{ a.detail }}</td><td class="mut">{{ a.ip or '' }}</td><td class="mut">{{ a.created_at|ts }}</td></tr>{% endfor %}</table></div>
<script nonce="{{ nonce }}">document.querySelectorAll('form[data-confirm]').forEach(f=>f.addEventListener('submit',e=>{if(!confirm(f.dataset.confirm))e.preventDefault()}));</script>{% endblock %}'''

import v3  # noqa: E402,F401  (v3 pages, nodes, security)
PYFEAT

  chmod 640 "$APP/core.py" "$APP/app.py" "$APP/bot.py" "$APP/ops.py" "$APP/features.py" "$APP/v3.py" "$APP/fun.py"
  echo "$VERSION" >"$APP/VERSION"
  ok "Application files deployed (v${VERSION})"
}

# ============================================================================
#  Install steps (each one is idempotent and safe to re-run)
# ============================================================================
step_swap() { # swap first: apt, pip and snap all spike memory
  local ram need=0; ram="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  if [ "$ram" -lt 1024 ]; then need=3072; elif [ "$ram" -lt 2048 ]; then need=2048; elif [ "$ram" -lt 4096 ]; then need=1024; fi
  [ "$need" -eq 0 ] && { ok "Memory looks fine (${ram} MB)"; return 0; }
  info "Low memory (${ram} MB): adding swap so the install does not get killed"; ensure_swap "$need"; mem_guard
}

step_sysctl() {
  # Raised inotify limits are LXD's own recommendation once you run many instances.
  cat >/etc/sysctl.d/99-ariznodes.conf <<'EOF'
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
kernel.keys.maxkeys = 2000
EOF
  soft "Applying kernel settings" 60 sysctl --system
}

step_packages() {
  if done_step packages && have_cmd python3 && have_cmd openssl; then ok "Base packages already installed"; return 0; fi
  wait_apt_idle
  soft "Refreshing package index" 600 apt-get update -o Acquire::Retries=3
  apt_install python3 python3-venv python3-pip curl ca-certificates openssl tar gzip iproute2 procps psmisc
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || die "Python 3.9+ is required"
  mark_step packages
}

step_docker() {
  if have_cmd docker && docker info >/dev/null 2>&1; then
    ok "Docker already running"; DOCKER_OK=1
  else
    apt_install docker.io
    soft "Enabling Docker" 120 systemctl enable --now docker
    local i; for i in $(seq 1 20); do docker info >/dev/null 2>&1 && { DOCKER_OK=1; break; }; sleep 2; done
    [ "$DOCKER_OK" -eq 1 ] && ok "Docker is up" || warn "Docker did not start (see: journalctl -u docker)"
  fi
  # Pre-pull the base image so the first user deployment is fast.
  [ "$DOCKER_OK" -eq 1 ] && soft "Pre-pulling ubuntu:24.04 for the Docker fallback" 900 docker pull ubuntu:24.04
  return 0
}

step_lxd() {
  if [ "${DOCKER_ONLY:-0}" = 1 ]; then info "Docker-only mode: skipping LXD"; return 0; fi
  if ! have_cmd lxc; then
    apt_install snapd
    soft "Loading kernel modules" 30 modprobe -a kvm vhost_vsock vhost_net
    soft "Waiting for snapd to finish seeding" 300 snap wait system seed.loaded
    if ! retry 3 "Installing LXD via snap (this can take several minutes)" 900 snap install lxd; then
      warn "LXD could not be installed - continuing with Docker only (no VMs)."; return 0
    fi
  fi
  soft "Waiting for the LXD daemon" 200 lxd waitready --timeout 180
  if ! lxc profile show default 2>/dev/null | grep -q 'root:'; then
    soft "Initialising LXD (dir storage, lxdbr0 network)" 300 lxd init --auto --storage-backend=dir
  else
    ok "LXD already initialised"
  fi
  if lxc info >/dev/null 2>&1; then LXD_OK=1; ok "LXD is ready (containers$( [ -e /dev/kvm ] && echo ' + KVM VMs' ))"
  else warn "LXD is installed but not responding - the panel will use Docker."; fi
}

step_backend_check() {
  if [ "$LXD_OK" -eq 0 ] && [ "$DOCKER_OK" -eq 0 ]; then
    err "Neither LXD nor Docker is working - the panel could not deploy anything."
    err "Check:  journalctl -u docker   |   snap services lxd   |   $LOG"
    exit 1
  fi
  [ "$LXD_OK" -eq 1 ] && info "Deployment engine: LXD$([ "$DOCKER_OK" -eq 1 ] && echo ' (Docker as fallback)')" || info "Deployment engine: Docker (containers only)"
}

step_python() {
  mkdir -p "$APP/data"; chmod 700 "$APP"
  [ -x "$APP/venv/bin/python" ] || must "Creating Python virtualenv" 300 python3 -m venv "$APP/venv"
  soft "Upgrading pip" 300 "$APP/venv/bin/pip" install --no-cache-dir --upgrade pip wheel
  local pkgs=("flask>=3.0" "gunicorn>=21.2" "requests>=2.31" "discord.py>=2.3" "flask-limiter>=3.5"
              "python-dotenv>=1.0" "psutil>=5.9" "cryptography>=42")
  # Prefer wheels only: avoids a long (and often failing) compile of psutil/cryptography.
  if ! retry 3 "Installing Python dependencies" 1200 "$APP/venv/bin/pip" install --no-cache-dir --only-binary=:all: "${pkgs[@]}"; then
    warn "Binary wheels unavailable - installing a compiler toolchain and building from source"
    apt_install build-essential python3-dev libffi-dev libssl-dev
    must "Installing Python dependencies (source build)" 2400 "$APP/venv/bin/pip" install --no-cache-dir "${pkgs[@]}"
  fi
  "$APP/venv/bin/python" -c 'import flask, discord, psutil, cryptography, flask_limiter, dotenv' \
    || die "Python dependencies installed but cannot be imported - see $LOG"
}

env_val() { [ -f "$APP/.env" ] || return 0; grep -m1 "^$1=" "$APP/.env" | cut -d= -f2- || true; }

step_env() {
  # Keep existing keys on re-runs: regenerating FERNET_KEY would make every stored
  # VPS root password undecryptable and SECRET_KEY would log everyone out.
  local sk fk creator
  sk="$(env_val SECRET_KEY)"; fk="$(env_val FERNET_KEY)"
  [ -n "$sk" ] || sk="$(openssl rand -hex 32)"
  [ -n "$fk" ] || fk="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n')"
  creator="$(printf '%s' "${CREATOR:-ArizNodes Labs}" | tr -cd 'A-Za-z0-9 ._-')"
  [ -f "$APP/.env" ] && { cp -p "$APP/.env" "$APP/.env.bak.$(date +%s)"; ls -1t "$APP"/.env.bak.* | tail -n +4 | xargs -r rm -f; }
  (
    umask 077
    cat >"$APP/.env.new" <<EOF
DOMAIN=${DOMAIN}
SECRET_KEY=${sk}
FERNET_KEY=${fk}
BIND_HOST=127.0.0.1
PORT=${PORT}
COOKIE_SECURE=1
CREATOR="${creator}"
DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}
DISCORD_CLIENT_ID=${DISCORD_CLIENT_ID}
DISCORD_CLIENT_SECRET=${DISCORD_CLIENT_SECRET}
DISCORD_GUILD_ID=${DISCORD_GUILD_ID}
DISCORD_LOG_CHANNEL_ID=${DISCORD_LOG_CHANNEL_ID:-}
TURNSTILE_SITE=${TURNSTILE_SITE:-}
TURNSTILE_SECRET=${TURNSTILE_SECRET:-}
EOF
  )
  mv "$APP/.env.new" "$APP/.env"; chmod 600 "$APP/.env"
  ok "Wrote $APP/.env (mode 600)"
}

step_bootstrap_admin() {
  local out
  out="$(cd "$APP" && ADMIN_PASS="$ADMIN_PASS" "$APP/venv/bin/python" core.py bootstrap admin 2>>"$LOG")" \
    || die "Could not initialise the database - see $LOG"
  if [ "$out" = "admin created" ]; then ADMIN_CREATED=1; ok "Database initialised, admin account created"
  else ADMIN_CREATED=0; ok "Database ready (admin account already existed)"; fi
  chmod 600 "$APP/data/panel.db"* 2>/dev/null || true
}

step_services() {
  cat >/etc/systemd/system/ariznodes-web.service <<EOF
[Unit]
Description=Ariznodes HVM web panel
After=network-online.target docker.service
Wants=network-online.target

[Service]
WorkingDirectory=${APP}
EnvironmentFile=${APP}/.env
Environment=HOME=/root
Environment=PATH=/snap/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${APP}/venv/bin/gunicorn --workers 1 --threads 8 --timeout 90 --bind 127.0.0.1:${PORT} --access-logfile - --error-logfile - app:app
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/ariznodes-bot.service <<EOF
[Unit]
Description=Ariznodes HVM Discord verification bot
After=network-online.target docker.service ariznodes-web.service
Wants=network-online.target

[Service]
WorkingDirectory=${APP}
EnvironmentFile=${APP}/.env
Environment=HOME=/root
Environment=PATH=/snap/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${APP}/venv/bin/python bot.py
Restart=always
RestartSec=10
StartLimitIntervalSec=0
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  must "Enabling services" 60 systemctl enable ariznodes-web ariznodes-bot
  BOT_START="$(date '+%F %T')"
  must "Starting web panel" 60 systemctl restart ariznodes-web
  must "Starting Discord bot" 60 systemctl restart ariznodes-bot
}

step_backup() {
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  cat >/usr/local/sbin/ariznodes-backup <<'EOF'
#!/usr/bin/env bash
# Consistent SQLite snapshot + secrets -> /var/backups/ariznodes (14 newest kept).
set -euo pipefail
APP=/opt/ariznodes; DEST=/var/backups/ariznodes; STAMP="$(date +%Y%m%d-%H%M%S)"; TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077; mkdir -p "$DEST"
"$APP/venv/bin/python" - "$APP/data/panel.db" "$TMP/panel.db" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
cp -p "$APP/.env" "$TMP/env"
tar -C "$TMP" -czf "$DEST/ariznodes-$STAMP.tar.gz" panel.db env
ls -1t "$DEST"/ariznodes-*.tar.gz | tail -n +15 | xargs -r rm -f
echo "$DEST/ariznodes-$STAMP.tar.gz"
EOF
  chmod 750 /usr/local/sbin/ariznodes-backup
  cat >/etc/systemd/system/ariznodes-backup.service <<'EOF'
[Unit]
Description=Ariznodes panel backup
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ariznodes-backup
EOF
  cat >/etc/systemd/system/ariznodes-backup.timer <<'EOF'
[Unit]
Description=Daily Ariznodes panel backup
[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=900
Persistent=true
[Install]
WantedBy=timers.target
EOF
  cat >/etc/logrotate.d/ariznodes <<EOF
${LOG} {
    monthly
    rotate 6
    compress
    missingok
    notifempty
    create 600 root root
}
EOF
  systemctl daemon-reload
  soft "Enabling daily backups" 30 systemctl enable --now ariznodes-backup.timer
}

step_harden() {
  [ "${HARDEN:-0}" = 1 ] || { info "Skipping firewall/fail2ban (use --harden to enable)"; return 0; }
  local ports p
  ports="$(ss -ltnpH 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}' | sort -u | tr '\n' ' ')"
  [ -n "${ports// /}" ] || ports="22"
  apt_install ufw fail2ban python3-systemd
  ufw default deny incoming  >>"$LOG" 2>&1
  ufw default allow outgoing >>"$LOG" 2>&1
  for p in $ports; do ufw allow "${p}/tcp" >>"$LOG" 2>&1; ok "Firewall: SSH port ${p}/tcp stays open"; done
  # Without these rules UFW blocks DHCP/DNS/forwarding for LXD and Docker guests.
  if [ "$LXD_OK" -eq 1 ]; then
    ufw allow in on lxdbr0 >>"$LOG" 2>&1; ufw route allow in on lxdbr0 >>"$LOG" 2>&1; ufw route allow out on lxdbr0 >>"$LOG" 2>&1
  fi
  if [ "$DOCKER_OK" -eq 1 ]; then ufw route allow in on docker0 >>"$LOG" 2>&1; ufw route allow out on docker0 >>"$LOG" 2>&1; fi
  ufw --force enable >>"$LOG" 2>&1 && ok "UFW enabled (panel itself is loopback-only, reachable through the tunnel)"
  cat >/etc/fail2ban/jail.d/ariznodes.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF
  soft "Enabling fail2ban" 60 systemctl enable --now fail2ban
  soft "Reloading fail2ban" 60 systemctl restart fail2ban
}

step_cloudflared() {
  if [ "$NO_TUNNEL" -eq 1 ] || [ -z "${CF_TUNNEL_TOKEN:-}" ]; then
    info "No tunnel token given - point your own reverse proxy at http://127.0.0.1:${PORT}"; return 0
  fi
  if ! have_cmd cloudflared; then
    local arch deb=/tmp/cloudflared.deb; arch="$(dpkg --print-architecture)"
    must "Downloading cloudflared" 300 curl -fL --retry 4 --retry-delay 3 -o "$deb" \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    apt_install "$deb"; rm -f "$deb"
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^cloudflared.service'; then
    soft "Removing previous tunnel service" 60 cloudflared service uninstall
  fi
  if run_step "Registering Cloudflare Tunnel" 90 cloudflared service install "$CF_TUNNEL_TOKEN"; then
    soft "Starting tunnel" 30 systemctl restart cloudflared
  else
    warn "Tunnel registration failed - check the token, then run: cloudflared service install <token>"
  fi
}

step_selftest() {
  info "Post-install checks"
  local i code="" body="" hints=0
  for i in $(seq 1 40); do
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/healthz" 2>/dev/null || true)"
    [ "$code" = 200 ] && break; sleep 1
  done
  if [ "$code" = 200 ]; then ok "Web panel answers on 127.0.0.1:${PORT}"
  else warn "Web panel is not answering (HTTP ${code:-none})"; journalctl -u ariznodes-web -n 15 --no-pager 2>/dev/null | sed 's/^/    /'; SELFTEST_FAIL=1; fi

  curl -sI -m 3 "http://127.0.0.1:${PORT}/" 2>/dev/null | grep -qi '^content-security-policy' \
    && ok "Security headers (CSP, HSTS, frame protection) active" || warn "Security headers missing"

  for i in $(seq 1 45); do
    body="$(journalctl -u ariznodes-bot --since "${BOT_START:-1 minute ago}" --no-pager 2>/dev/null || true)"
    grep -q 'ready as' <<<"$body" && break
    grep -qE 'LoginFailure|Improper token|PrivilegedIntentsRequired' <<<"$body" && break
    sleep 1
  done
  if   grep -q 'ready as' <<<"$body"; then ok "Discord bot is online and tracking invites"
  elif grep -q 'PrivilegedIntentsRequired' <<<"$body"; then
    warn "Bot needs the 'Server Members Intent' - Developer Portal > Bot > Privileged Gateway Intents, then: systemctl restart ariznodes-bot"; hints=1
  elif grep -qE 'LoginFailure|Improper token' <<<"$body"; then
    warn "Discord rejected the bot token - fix DISCORD_BOT_TOKEN in ${APP}/.env then: systemctl restart ariznodes-bot"; hints=1
  else warn "Bot has not reported ready yet - check: journalctl -u ariznodes-bot -n 30"; hints=1; fi
  [ "$hints" -eq 0 ] || SELFTEST_FAIL=1
  systemctl is-active --quiet ariznodes-backup.timer && ok "Daily backups scheduled (03:30, kept 14 days)" || true
}

print_summary() {
  celebrate
  echo
  echo "${C_BLD}${C_GRN}==================================================================${C_RST}"
  echo "${C_BLD} Ariznodes(TM) HVM Panel ${VERSION} installed${C_RST}$([ "$SELFTEST_FAIL" -eq 1 ] && echo "  ${C_YLW}(with warnings above)${C_RST}")"
  echo "${C_BLD}${C_GRN}==================================================================${C_RST}"
  echo "  Public URL   : https://${DOMAIN}"
  echo "  Local URL    : http://127.0.0.1:${PORT}"
  if [ "${ADMIN_CREATED:-0}" = 1 ]; then
    echo "  Admin login  : admin"
    echo "  Password     : ${C_BLD}${ADMIN_PASS}${C_RST}   <-- shown once, save it now"
  else
    echo "  Admin login  : existing account kept (forgot it? sudo bash ${SCRIPT_NAME} reset-admin)"
  fi
  echo "  Engine       : $([ "$LXD_OK" -eq 1 ] && echo "LXD$([ -e /dev/kvm ] && echo ' + KVM VMs')" || echo 'Docker (containers only)')"
  echo
  echo "  ${C_BLD}Finish setup${C_RST}"
  echo "   1. Cloudflare Zero Trust > Networks > Tunnels > Public hostname:"
  echo "        ${DOMAIN}  ->  HTTP  localhost:${PORT}"
  echo "   2. Discord Developer Portal > OAuth2 > Redirects, add:"
  echo "        https://${DOMAIN}/discord/callback"
  echo "   3. Bot > Privileged Gateway Intents: enable 'Server Members Intent';"
  echo "      invite the bot with the 'Manage Server' permission."
  echo
  echo "  ${C_BLD}Manage${C_RST}   sudo bash ${SCRIPT_NAME} status | doctor | logs | backup | upgrade"
  echo "  ${C_BLD}Log file${C_RST} ${LOG}"
  echo
}

# ============================================================================
#  Commands
# ============================================================================
v_url()       { [[ "$1" =~ ^https?://[A-Za-z0-9._:-]+$ ]] || { warn "Enter a URL like https://panel.example.com (no path)."; return 1; }; }
norm_url()    { local u="${1%/}"; printf '%s' "$u"; }
v_node_name() { [[ "$1" =~ ^[A-Za-z0-9._-]{2,40}$ ]] || { warn "2-40 characters: letters, digits, dot, dash, underscore."; return 1; }; }

choose_mode() {
  [ -n "${INSTALL_MODE:-}" ] && return 0
  local a=""
  if interactive; then
    echo "  Installation type:"; echo "    1) Normal installation  (web panel + Discord bot + API portal)"
    echo "    2) API node installation  (adds capacity to an existing panel)"
    read -rp "  Select [1/2]: " a </dev/tty || a=1
  fi
  [ "$a" = 2 ] && INSTALL_MODE=node || INSTALL_MODE=panel
}

verify_panel() { # the API key must be valid AND belong to an admin
  local tries=0 raw code resp
  while :; do
    raw="$(curl -sS -m 15 -w '\n%{http_code}' -A 'Ariznodes-Node/3.5' -H "Authorization: Bearer ${PANEL_KEY}" "${PANEL_URL%/}/api/v1/ping" 2>>"$LOG" || true)"
    code="${raw##*$'\n'}"; resp="${raw%$'\n'*}"
    if grep -q '"ok": *true' <<<"$resp" && grep -q '"admin": *true' <<<"$resp"; then ok "Panel API key verified"; return 0; fi
    warn "Panel answered HTTP ${code:-none}: ${resp:0:120}"
    case "$code" in 401) warn "The key was rejected. Use an ADMIN API token from the panel (Account > API tokens).";; 403|503) warn "Cloudflare may be challenging this request (WAF / Bot Fight Mode). Allow this server's IP or the path /api/*.";; ""|000) warn "Could not connect. Check the URL and that the panel is online.";; esac
    tries=$((tries + 1)); if ! interactive || [ "$tries" -ge 4 ]; then die "Panel API key could not be verified"; fi
    unset PANEL_URL PANEL_KEY
    prompt PANEL_URL "Panel URL (e.g. https://hvm.example.com)" "" "" v_url norm_url
    prompt PANEL_KEY "Panel admin API key" "" secret v_nonempty
  done
}

write_agent_files() {
  info "Deploying node agent"
  mkdir -p "$APP"
cat > "$APP/agent.py" <<'PYAGENT'
"""Ariznodes node agent: executes signed lxc/docker commands for the main panel. Nothing else."""
import hashlib, hmac, os, subprocess, time
from dotenv import load_dotenv
load_dotenv("/opt/ariznodes/.env")
from flask import Flask, jsonify, request

app = Flask(__name__)
KEY = os.environ["AGENT_KEY"].encode()
SEEN = {}  # signature -> expiry, blocks replays inside the 2-minute window

def authed():
    ts, sig = request.headers.get("X-Ts", ""), request.headers.get("X-Sig", "")
    if not ts.isdigit() or abs(time.time() - int(ts)) > 120: return False
    good = hmac.new(KEY, ts.encode() + request.get_data(), hashlib.sha256).hexdigest()
    now = time.time()
    for s in [s for s, e in SEEN.items() if e < now]: SEEN.pop(s, None)
    if not hmac.compare_digest(good, sig) or sig in SEEN: return False
    SEEN[sig] = now + 130; return True

def ok(cmd):
    try: return subprocess.run(cmd, capture_output=True, timeout=30).returncode == 0
    except Exception: return False

@app.get("/agent/ping")
def ping(): return jsonify(ok=True, agent="ariznodes")

@app.post("/agent/caps")
def caps():
    if not authed(): return jsonify(ok=False, error="bad signature"), 403
    return jsonify(ok=True, lxc=ok(["lxc", "info"]), docker=ok(["docker", "info"]), kvm=os.path.exists("/dev/kvm"))

@app.post("/agent/run")
def run():
    if not authed(): return jsonify(ok=False, error="bad signature"), 403
    d = request.get_json(silent=True) or {}
    cmd, timeout = d.get("cmd"), min(int(d.get("timeout") or 60), 1800)
    if not isinstance(cmd, list) or not cmd or not all(isinstance(c, str) for c in cmd) or cmd[0] not in ("lxc", "docker"):
        return jsonify(ok=False, error="only lxc and docker commands are allowed"), 400
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=d.get("inp"),
                           env={**os.environ, "PATH": "/snap/bin:/usr/local/bin:/usr/bin:/bin"})
    except subprocess.TimeoutExpired: return jsonify(ok=False, error="command timed out")
    if r.returncode: return jsonify(ok=False, error=((r.stderr or r.stdout) or "command failed").strip()[-400:])
    return jsonify(ok=True, out=r.stdout)
PYAGENT
  chmod 640 "$APP/agent.py"; echo "$VERSION" >"$APP/VERSION"
}

step_python_node() {
  mkdir -p "$APP"; chmod 700 "$APP"
  [ -x "$APP/venv/bin/python" ] || must "Creating Python virtualenv" 300 python3 -m venv "$APP/venv"
  retry 3 "Installing agent dependencies" 900 "$APP/venv/bin/pip" install --no-cache-dir --upgrade pip "flask>=3.0" "gunicorn>=21.2" "python-dotenv>=1.0"
}

step_node_env_services() {
  local key; key="$(env_val AGENT_KEY)"; [ -n "$key" ] || key="$(openssl rand -hex 32)"; AGENT_KEY="$key"
  ( umask 077; printf 'AGENT_KEY=%s\nPORT=%s\n' "$key" "$PORT" >"$APP/.env" )
  cat >/etc/systemd/system/ariznodes-agent.service <<EOF
[Unit]
Description=Ariznodes node agent
After=network-online.target docker.service

[Service]
WorkingDirectory=${APP}
EnvironmentFile=${APP}/.env
Environment=HOME=/root
Environment=PATH=/snap/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${APP}/venv/bin/gunicorn --workers 1 --threads 8 --timeout 1900 --bind 127.0.0.1:${PORT} agent:app
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  must "Starting node agent" 60 systemctl enable --now ariznodes-agent
  must "Restarting node agent" 60 systemctl restart ariznodes-agent
}

register_node() {
  local i body raw code="" resp=""
  body="$(printf '{"name":"%s","url":"%s","agent_key":"%s","slots":%s}' "$NODE_NAME" "${NODE_URL%/}" "$AGENT_KEY" "${NODE_SLOTS:-10}")"
  for i in $(seq 1 12); do
    raw="$(curl -sS -m 30 -w '\n%{http_code}' -A 'Ariznodes-Node/3.5' -X POST -H "Authorization: Bearer ${PANEL_KEY}" -H 'Content-Type: application/json' -d "$body" "${PANEL_URL%/}/api/v1/nodes/register" 2>>"$LOG" || true)"
    code="${raw##*$'\n'}"; resp="${raw%$'\n'*}"
    if grep -q '"ok": *true' <<<"$resp"; then ok "Node '${NODE_NAME}' registered with the panel"; return 0; fi
    [ "$i" -eq 1 ] && warn "Waiting for ${NODE_URL} to become reachable from the panel (tunnel hostname -> http://localhost:${PORT})..."
    sleep 5
  done
  warn "Registration failed. Last answer: HTTP ${code:-none} ${resp:0:200}"
  warn "Check: 1) tunnel hostname ${NODE_URL} -> http://localhost:${PORT}   2) Cloudflare WAF / Bot Fight Mode   3) run: sudo bash ${SCRIPT_NAME} node-test"
  warn "Or add it by hand in the panel (Admin > Nodes): URL ${NODE_URL}, key ${AGENT_KEY}"
}

cmd_install_node() {
  info "API node installation"; PORT=8081
  prompt PANEL_URL "Panel URL (e.g. https://hvm.example.com)" "" "" v_url norm_url
  prompt PANEL_KEY "Panel admin API key" "" secret v_nonempty
  verify_panel
  prompt NODE_NAME "Name for this node" "$(hostname -s)" "" v_node_name
  prompt NODE_URL "Public URL of THIS node (tunnel hostname, e.g. https://node1.example.com)" "" "" v_url norm_url
  if [ "$NO_TUNNEL" -eq 1 ]; then CF_TUNNEL_TOKEN=""; fi
  prompt CF_TUNNEL_TOKEN "Cloudflare Tunnel token for this node (optional)" "" secret v_cf_token
  [ -n "${DOCKER_ONLY:-}" ] || DOCKER_ONLY=0
  save_config
  STEP_TOTAL=9; stop_auto_updates
  phase "Memory and swap"; step_swap
  phase "Kernel settings"; step_sysctl
  phase "System packages"; step_packages
  phase "Docker"; step_docker
  phase "LXD containers and KVM VMs"; step_lxd; step_backend_check
  phase "Node agent"; mem_guard; step_python_node; write_agent_files; step_node_env_services
  phase "Cloudflare tunnel"; step_cloudflared
  phase "Registering with the panel"; register_node
  mark_step installed; save_self_copy
  echo; echo "${C_BLD}${C_GRN}Node '${NODE_NAME}' is installed.${C_RST}"
  echo "  Agent    : 127.0.0.1:${PORT}  (Cloudflare tunnel hostname must point to http://localhost:${PORT})"
  echo "  Panel    : ${PANEL_URL}  (Admin > Nodes shows this node)"
  echo "  Logs     : journalctl -u ariznodes-agent -f"; echo
}

cmd_install() {
  preflight
  load_config
  choose_mode
  if [ "$INSTALL_MODE" = node ]; then cmd_install_node; return 0; fi
  collect_inputs
  save_config
  verify_discord
  STEP_TOTAL=14; stop_auto_updates
  phase "Memory and swap"; step_swap
  phase "Kernel settings"; step_sysctl
  phase "System packages"; step_packages
  phase "Docker"; step_docker
  phase "LXD containers and KVM VMs"; step_lxd; step_backend_check
  phase "Python environment"; mem_guard; step_python
  phase "Panel code"; write_app_files
  phase "Secrets and configuration"; step_env
  phase "Database and admin account"; step_bootstrap_admin
  phase "Services"; step_services
  phase "Backups"; step_backup
  phase "Security hardening"; step_harden
  phase "Cloudflare tunnel"; step_cloudflared
  phase "Final checks"; step_selftest
  mark_step installed; save_self_copy
  print_summary
  scrub_conf_secret
}

cmd_upgrade() {
  [ -d "$APP" ] || die "Not installed yet - run: sudo bash ${SCRIPT_NAME} install"
  if [ ! -f "$APP/app.py" ] && [ -f "$APP/agent.py" ]; then  # API node
    write_agent_files; must "Restarting node agent" 60 systemctl restart ariznodes-agent; ok "Node agent upgraded to v${VERSION}"; return 0
  fi
  load_config
  if [ -f /usr/local/sbin/ariznodes-backup ]; then soft "Backing up before upgrade" 120 /usr/local/sbin/ariznodes-backup; fi
  step_python
  write_app_files
  BOT_START="$(date '+%F %T')"
  must "Restarting web panel" 60 systemctl restart ariznodes-web
  must "Restarting Discord bot" 60 systemctl restart ariznodes-bot
  PORT="$(env_val PORT)"; PORT="${PORT:-8080}"
  step_selftest
  ok "Upgrade to v${VERSION} complete (data and secrets untouched)"
}

cmd_status() {
  local s
  for s in ariznodes-web ariznodes-bot cloudflared docker snap.lxd.daemon; do
    systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "$s" || continue
    if systemctl is-active --quiet "$s"; then ok "$s: active"; else warn "$s: $(systemctl is-active "$s" 2>/dev/null || true)"; fi
  done
  local code; code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/healthz" 2>/dev/null || true)"
  [ "$code" = 200 ] && ok "Panel healthy on 127.0.0.1:${PORT}" || warn "Panel health check failed (HTTP ${code:-none})"
  if [ -x "$APP/venv/bin/python" ]; then
    (cd "$APP" && "$APP/venv/bin/python" - <<'PY'
import core
print("   users: %d   vps: %d   open alerts: %d" % tuple(core.q(f"SELECT COUNT(*) n FROM {t}", one=True)["n"] for t in ("users", "vps", "alerts")))
PY
    ) 2>/dev/null || true
  fi
}

cmd_doctor() {
  local fails=0 f
  chk() { # chk "description" command...
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$d"; else err "$d"; fails=$((fails + 1)); fi
  }
  info "Diagnostics for Ariznodes ${VERSION}"
  chk "App directory present ($APP)"                  test -d "$APP"
  chk ".env exists and is mode 600"                   test "$(stat -c %a "$APP/.env" 2>/dev/null)" = 600
  chk "Database present"                              test -f "$APP/data/panel.db"
  chk "ariznodes-web service active"                  systemctl is-active --quiet ariznodes-web
  chk "ariznodes-bot service active"                  systemctl is-active --quiet ariznodes-bot
  chk "Panel answers /healthz on port ${PORT}"        curl -fsS -m 4 "http://127.0.0.1:${PORT}/healthz"
  chk "Panel bound to loopback only"                  bash -c "ss -ltnH 'sport = :${PORT}' | grep -q '127.0.0.1'"
  chk "Docker engine responding"                      docker info
  chk "LXD responding"                                lxc info
  [ -e /dev/kvm ] && ok "/dev/kvm present" || warn "/dev/kvm missing - VMs unavailable"
  if systemctl list-unit-files cloudflared.service 2>/dev/null | grep -q cloudflared; then
    chk "cloudflared tunnel service active"           systemctl is-active --quiet cloudflared
  else warn "cloudflared not installed (fine if you use your own proxy)"; fi
  local d; d="$(env_val DOMAIN)"
  if [ -n "$d" ]; then
    getent hosts "$d" >/dev/null 2>&1 && ok "DNS resolves for $d" || warn "$d does not resolve yet (add the tunnel hostname in Cloudflare)"
  fi
  f="$(df -Pm / | awk 'NR==2 {print $4}')"; [ "$f" -gt 2000 ] && ok "Disk space OK (${f} MB free)" || { err "Low disk space (${f} MB)"; fails=$((fails + 1)); }
  echo; info "Recent errors"
  journalctl -u ariznodes-web -u ariznodes-bot -p err -n 8 --no-pager 2>/dev/null | sed 's/^/    /' || true
  [ "$fails" -eq 0 ] && ok "All checks passed" || { err "${fails} check(s) failed"; return 1; }
}

cmd_logs()   { exec journalctl -u ariznodes-web -u ariznodes-bot -f -n 50; }
cmd_backup() { [ -x /usr/local/sbin/ariznodes-backup ] || die "Backup tool not installed"; ok "Backup written: $(/usr/local/sbin/ariznodes-backup)"; }

cmd_restore() {
  local f="${EXTRA_ARGS[0]:-}"
  [ -n "$f" ] && [ -f "$f" ] || die "Usage: sudo bash ${SCRIPT_NAME} restore /var/backups/ariznodes/ariznodes-<stamp>.tar.gz"
  confirm "Replace the CURRENT database and secrets with this backup?" n || die "Cancelled"
  local tmp; tmp="$(mktemp -d)"; tar -xzf "$f" -C "$tmp" || die "Not a valid backup archive"
  [ -f "$tmp/panel.db" ] && [ -f "$tmp/env" ] || die "Archive is missing panel.db or env"
  /usr/local/sbin/ariznodes-backup >/dev/null 2>&1 || true   # safety copy of what we are about to overwrite
  systemctl stop ariznodes-web ariznodes-bot
  rm -f "$APP/data/panel.db-wal" "$APP/data/panel.db-shm"
  install -m 600 "$tmp/panel.db" "$APP/data/panel.db"; install -m 600 "$tmp/env" "$APP/.env"
  rm -rf "$tmp"
  systemctl start ariznodes-web ariznodes-bot
  ok "Restored from $f"
}

cmd_reset_admin() {
  local user="${EXTRA_ARGS[0]:-admin}" pw; pw="$(gen_pass)"
  [ -x "$APP/venv/bin/python" ] || die "Panel is not installed"
  (cd "$APP" && NEWPW="$pw" TARGET="$user" "$APP/venv/bin/python" - <<'PY'
import os, core
from werkzeug.security import generate_password_hash
r = core.q("SELECT id FROM users WHERE username=? COLLATE NOCASE", (os.environ["TARGET"],), one=True)
if not r:
    raise SystemExit("no such user: " + os.environ["TARGET"])
core.ex("UPDATE users SET pw_hash=?, fails=0, locked_until=0, banned=0 WHERE id=?",
        (generate_password_hash(os.environ["NEWPW"]), r["id"]))
PY
  ) || die "Could not reset the password for '${user}'"
  ok "New password for '${user}': ${C_BLD}${pw}${C_RST}"
}

cmd_uninstall() {
  [ -d "$APP" ] || warn "$APP not found - cleaning up anything left over"
  warn "This removes the Ariznodes panel and bot services."
  confirm "Continue with uninstall?" n || die "Cancelled"
  local inst=""
  have_cmd lxc    && inst="$(lxc list 'anz-' -c n --format csv 2>/dev/null || true)"
  have_cmd docker && inst="${inst}"$'\n'"$(docker ps -a --filter 'name=anz-' --format '{{.Names}}' 2>/dev/null || true)"
  inst="$(printf '%s' "$inst" | sed '/^$/d')"
  if [ -n "$inst" ]; then
    warn "VPS instances created by the panel:"; printf '    %s\n' $inst
    if confirm "DELETE these instances and their data permanently?" n; then
      local n
      for n in $inst; do
        lxc delete --force "$n" >>"$LOG" 2>&1 || docker rm -f "$n" >>"$LOG" 2>&1 || warn "Could not delete $n"
      done
      ok "Instances deleted"
    else info "Instances left running"; fi
  fi
  if [ -x /usr/local/sbin/ariznodes-backup ] && confirm "Take a final backup first?" y; then /usr/local/sbin/ariznodes-backup || true; fi
  systemctl disable --now ariznodes-web ariznodes-bot ariznodes-backup.timer >>"$LOG" 2>&1 || true
  rm -f /etc/systemd/system/ariznodes-{web,bot,backup}.service /etc/systemd/system/ariznodes-backup.timer \
        /usr/local/sbin/ariznodes-backup /etc/logrotate.d/ariznodes /etc/sysctl.d/99-ariznodes.conf \
        /etc/fail2ban/jail.d/ariznodes.local
  systemctl daemon-reload
  if confirm "Delete panel data and secrets ($APP)?  Backups in $BACKUP_DIR are kept." n; then rm -rf "$APP"; ok "$APP removed"; fi
  if have_cmd cloudflared && confirm "Also remove the Cloudflare Tunnel service?" n; then cloudflared service uninstall >>"$LOG" 2>&1 || true; fi
  rm -rf "$STATE_DIR"; confirm "Remove saved install answers ($CONF)?" y && rm -f "$CONF"
  ok "Uninstalled. Docker, LXD and UFW were left as they are."
}

# ============================================================================
save_self_copy() { # lets you run:  sudo ariznodes status|doctor|upgrade|self-update
  if [ -f "${BASH_SOURCE[0]:-}" ]; then install -m 755 "${BASH_SOURCE[0]}" /usr/local/sbin/ariznodes-installer 2>/dev/null && ln -sf /usr/local/sbin/ariznodes-installer /usr/local/bin/ariznodes || true; fi
  return 0
}

cmd_self_update() {
  case "$UPDATE_URL" in *YOUR-GITHUB-USER*) die "Set your GitHub raw URL first: UPDATE_URL=https://raw.githubusercontent.com/you/repo/main/install.sh sudo -E bash ${SCRIPT_NAME} self-update" ;; esac
  local tmp nv; tmp="$(mktemp)"
  must "Downloading the latest installer" 120 curl -fsSL --retry 3 -o "$tmp" "$UPDATE_URL"
  bash -n "$tmp" || die "The downloaded file is not a valid script - not applying it"
  grep -q 'Ariznodes(TM) HVM Panel' "$tmp" || die "The downloaded file does not look like the Ariznodes installer"
  nv="$(sed -n 's/^VERSION="\(.*\)"/\1/p' "$tmp" | head -n1)"; info "Installed script v${VERSION}, latest v${nv:-?}"
  install -m 755 "$tmp" /usr/local/sbin/ariznodes-installer && ln -sf /usr/local/sbin/ariznodes-installer /usr/local/bin/ariznodes; rm -f "$tmp"
  ok "Installer updated (run it any time with: sudo ariznodes <command>)"
  if [ -d "$APP" ]; then exec bash /usr/local/sbin/ariznodes-installer upgrade; fi
}

cmd_diag() { # support bundle with no secrets in it
  local f="/root/ariznodes-diag-$(date +%Y%m%d-%H%M%S).txt"
  { echo "== ariznodes ${VERSION} $(date)"; . /etc/os-release; echo "$PRETTY_NAME"; uname -a; echo; free -m; swapon --show; df -h /; echo
    systemd-detect-virt || true; ls -l /dev/kvm 2>&1 || true; echo
    for s in ariznodes-web ariznodes-bot ariznodes-agent cloudflared docker; do echo "-- $s: $(systemctl is-active $s 2>&1)"; done
    echo; ss -ltnp 2>/dev/null | head -n 20; echo; docker info 2>&1 | head -n 12; echo; lxc info 2>&1 | head -n 12
    for u in ariznodes-web ariznodes-bot ariznodes-agent; do echo; echo "-- journal $u"; journalctl -u $u -n 60 --no-pager 2>&1 | sed -E 's/(token|key|secret|password)=[^ ]+/\1=REDACTED/Ig'; done
    echo; echo "-- install log tail"; tail -n 60 "$LOG" | sed -E 's/(token|key|secret|password)=[^ ]+/\1=REDACTED/Ig'
  } >"$f" 2>&1; chmod 600 "$f"; ok "Support bundle written: $f (contains no secrets)"
}

cmd_node_test() { # why does my API node not connect?
  load_config; [ -f "$APP/agent.py" ] || die "This server is not an API node."
  local port; port="$(env_val PORT)"; port="${port:-8081}"
  if systemctl is-active --quiet ariznodes-agent; then ok "Agent service is running"; else err "Agent service is NOT running (journalctl -u ariznodes-agent -n 30)"; fi
  if curl -fsS -m 5 "http://127.0.0.1:${port}/agent/ping" 2>/dev/null | grep -q ariznodes; then ok "Agent answers locally on 127.0.0.1:${port}"; else err "Agent does not answer on 127.0.0.1:${port}"; fi
  if [ -n "${NODE_URL:-}" ]; then
    if curl -sS -m 12 -A 'Ariznodes-Test' "${NODE_URL%/}/agent/ping" 2>/dev/null | grep -q ariznodes; then ok "${NODE_URL} reaches the agent (tunnel OK)"
    else err "${NODE_URL} does NOT reach the agent. In Cloudflare Zero Trust set the public hostname to HTTP localhost:${port}, and check WAF / Bot Fight Mode."; fi
  fi
  if [ -n "${PANEL_URL:-}" ] && [ -n "${PANEL_KEY:-}" ]; then verify_panel; fi
  if lxc info >/dev/null 2>&1; then ok "LXD works"; else warn "LXD not available"; fi
  if docker info >/dev/null 2>&1; then ok "Docker works"; else warn "Docker not available"; fi
}

main() {
  parse_args "$@"
  need_root
  init_log
  case "$CMD" in
    install|upgrade|status|doctor|logs|backup|restore|reset-admin|uninstall|self-update|diag|node-test) ;;
    *) usage; die "Unknown command: $CMD" ;;
  esac
  if [ "$CMD" = install ]; then splash; elif [ "$CMD" != logs ]; then banner; fi
  if [ "$CMD" != install ] && [ "${PORT_FLAG:-0}" -eq 0 ]; then  # reuse the port the panel was installed with
    local p; p="$(env_val PORT)"
    if [ -n "$p" ]; then PORT="$p"; fi
  fi
  case "$CMD" in
    install)      cmd_install ;;
    upgrade)      cmd_upgrade ;;
    status)       cmd_status ;;
    doctor)       cmd_doctor ;;
    logs)         cmd_logs ;;
    backup)       cmd_backup ;;
    restore)      cmd_restore ;;
    reset-admin)  cmd_reset_admin ;;
    uninstall)    cmd_uninstall ;;
    self-update)  cmd_self_update ;;
    diag)         cmd_diag ;;
    node-test)    cmd_node_test ;;
  esac
}

# Allow `source install.sh` for testing without running anything.
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]:-}" ] || [ "$0" = "bash" ] || [ "$0" = "-bash" ]; then
  main "$@"
fi
