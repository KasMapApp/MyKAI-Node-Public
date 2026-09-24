#!/bin/sh
# MyKAI Node — one-line installer for Docker hosts (NAS, VPS, home server).
#
# Usage:
#   curl -fsSL https://mykai.dev/install.sh | bash
#
# Or with a specific account key (unify stats with an existing desktop install):
#   curl -fsSL https://mykai.dev/install.sh | MYKAI_ACCOUNT_KEY=acc_<32hex> bash
#
# The older form keeps working:
#   bash <(curl -fsSL https://mykai.dev/install.sh)
#
# No sudo needed in front. When this user can't use Docker, the script asks
# for admin rights itself, once, and says why. Putting sudo in front of the
# `bash <(...)` form breaks it outright: sudo closes the /dev/fd pipe that
# <(...) hands to bash, so bash stops with "/dev/fd/63: No such file or
# directory" before a single line of this file runs. Nothing in here can catch
# that, which is why the pipe form above is the one we show. `curl ... | sudo
# bash` works too. A key that has to pass through sudo goes as an argument,
# because sudo drops environment variables set in front of it:
#   curl -fsSL https://mykai.dev/install.sh | sudo bash -s -- --key acc_<32hex>
#
# What this script does:
#   1. Refuses 32-bit and unknown CPUs before it touches anything
#   2. Makes sure Docker works: installs it with Docker's own installer when
#      it is missing (plain Linux only -- a NAS gets pointed at its app store),
#      starts it when it is stopped, adds the compose plugin when that is
#      missing, and goes through sudo when this user can't reach the socket
#   3. Warns when the disk is on the small side
#   4. Creates ~/.mykai-node/ with a docker-compose.yml describing two services:
#        kaspad           — the actual Kaspa node (image depends on arch, below)
#        mykai-monitor    — kasmap/mykai-headless (MyKAI's telemetry monitor)
#   5. Pulls both images up front, with a plain-English message if one fails
#      instead of a cryptic docker error
#   6. Brings the stack up with `docker compose up -d`
#   7. Prints the final account key + container status
#
# Architectures:
#   x86_64 / amd64   — kasmap/kaspad, our own Toccata-ready build
#   aarch64 / arm64  — supertypo/rusty-kaspad. Community-built from the same
#                      rusty-kaspa source and published multi-arch. We don't
#                      ship an ARM kaspad of our own yet, and cross-building
#                      Rust for ARM isn't worth duplicating a maintained image
#                      for. Covers Raspberry Pi 5, ARM NAS, Ampere/Graviton.
#   Anything else (32-bit ARM, i386) is refused with an explanation.
#
# Idempotent: safe to re-run. Re-running upgrades both images to the versions
# pinned in this script and restarts the stack. The persisted accountKey + chain data survive the upgrade
# (both stored in named docker volumes).
#
# Uninstall:
#   cd ~/.mykai-node && docker compose down -v   # removes containers + data
#   rm -rf ~/.mykai-node
#
# Everything below is functions, and only the last line runs anything. A
# download cut off halfway through `curl | bash` therefore runs nothing at all
# instead of half an install.

set -eu

INSTALL_DIR="${MYKAI_INSTALL_DIR:-${HOME:-/root}/.mykai-node}"
NODE_NAME="${MYKAI_NODE_NAME:-MyKAI Cloud Node}"
ACCOUNT_KEY="${MYKAI_ACCOUNT_KEY:-}"
HELP_URL="https://mykai.dev/linux/setup"

# ─── Image pins ─────────────────────────────────────────────────────────────
# One place to bump. MONITOR_IMAGE must exist on Docker Hub as a multi-arch
# (amd64 + arm64) manifest — build it with:
#
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -f Dockerfile.headless -t kasmap/mykai-headless:<tag> --push .
#
# A plain `docker build` publishes only the builder's own architecture, which
# is what left ARM hosts with "no matching manifest for linux/arm64/v8". If the
# pinned tag is amd64-only, the preflight below stops ARM hosts with that
# explanation instead of letting compose fail halfway through.
#
# kaspad 2.1.0 (2026-09-23). Upstream asked every node, mining and
# infrastructure operator to move: chunked IBD under P2P protocol 11, stricter
# wire limits, and a stratum-bridge socket-leak fix. Protocol 11 negotiates
# down to 10, so a stale pin is compatible rather than broken -- but amd64 sat
# on 2.0.0 for three months, a release behind even what the Windows app shipped
# before 2.1.0, because nothing here bumps itself.
#
# The amd64 image is OURS and its build context is cloud-monitor/kaspad/
# (recreated 2026-09-23 -- the original went missing). Rebuild and push BEFORE
# moving the pin below, or every new install fails on a tag that is not there:
#
#   docker build --platform linux/amd64 #     --build-arg KASPAD_VERSION=<v> --build-arg KASPAD_SHA256=<sha of the zip> #     -t kasmap/kaspad:<v> cloud-monitor/kaspad && docker push kasmap/kaspad:<v>
#
# ARM stays on supertypo's community image; v2.1.0 was verified to keep the
# same entrypoint wrapper, RUSTY_HOME=/app/data and uid, so the branch below
# still holds.
MONITOR_IMAGE="kasmap/mykai-headless:0.5.1"
KASPAD_IMAGE_AMD64="kasmap/kaspad:2.1.0"
KASPAD_IMAGE_ARM64="supertypo/rusty-kaspad:v2.1.0"

# Disk sizing. A synced node's data is normally 50-65 GB, but it swells when
# the network is busy: Seb's node went to almost 120 GB during the TPS
# world-record attempt (the one that worked). 200 GB free leaves room for the
# next one.
DISK_PEAK_GB=120
DISK_SAFE_GB=200

say() { printf '\033[1;36m[MyKAI]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[MyKAI] %s\033[0m\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USAGE_EOF'
MyKAI Node installer for Linux servers, NAS and VPS hosts.

  curl -fsSL https://mykai.dev/install.sh | bash

Options:
  --key acc_<32 hex>   add this machine to an existing MyKAI account
  -h, --help           show this help

Environment: MYKAI_ACCOUNT_KEY, MYKAI_NODE_NAME, MYKAI_INSTALL_DIR
Help page:   https://mykai.dev/linux/setup
USAGE_EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key)
        [ "$#" -ge 2 ] || fail "--key needs a value: --key acc_<32 hex chars>"
        ACCOUNT_KEY="$2"
        shift 2
        ;;
      --key=*)
        ACCOUNT_KEY="${1#--key=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1 (see --help)"
        ;;
    esac
  done
}

WORK_DIR=""
cleanup() {
  if [ -n "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
}

# Download $1 to $2 with whichever of curl or wget is there.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    return 1
  fi
}

# ─── Admin rights ───────────────────────────────────────────────────────────
#
# Root runs everything directly. Anyone else goes through sudo, for the steps
# that need it only, and the password is asked once (sudo -v) right after a
# sentence that says why.

IS_ROOT=0
SUDO_READY=0

as_root() {
  if [ "$IS_ROOT" = 1 ]; then "$@"; else sudo "$@"; fi
}

get_sudo() {
  if [ "$IS_ROOT" = 1 ] || [ "$SUDO_READY" = 1 ]; then return 0; fi
  if ! command -v sudo >/dev/null 2>&1; then
    fail "$1 This user can't get them here (there's no sudo).
       Log in as root and run the install command again."
  fi
  if ! sudo -n true 2>/dev/null; then
    say "$1 You may be asked for your password."
    if ! sudo -v; then
      fail "Couldn't get admin rights with sudo.
       Run the install command as root, or from an account that's allowed
       to use sudo (or is in the docker group)."
    fi
  fi
  SUDO_READY=1
}

# Write stdin to file $1. That's normally this user's own home; admin rights
# only come in when an earlier run as root left the files owned by root.
put_file() {
  dir=$(dirname "$1")
  if [ ! -d "$dir" ]; then
    if ! mkdir -p "$dir" 2>/dev/null; then
      get_sudo "Creating $dir needs admin rights."
      as_root mkdir -p "$dir"
    fi
  fi
  if { [ -e "$1" ] && [ -w "$1" ]; } || { [ ! -e "$1" ] && [ -w "$dir" ]; }; then
    cat > "$1"
  else
    get_sudo "Updating $1 needs admin rights."
    as_root tee "$1" >/dev/null
  fi
}

# ─── Architecture ───────────────────────────────────────────────────────────

detect_arch() {
  MACHINE=$(uname -m 2>/dev/null || echo unknown)
  case "$MACHINE" in
    x86_64|amd64)
      DOCKER_ARCH="amd64"
      KASPAD_IMAGE="$KASPAD_IMAGE_AMD64"
      # Our own image: the entrypoint IS the kaspad binary, appdir at /data.
      KASPAD_APPDIR="/data"
      ;;
    aarch64|arm64)
      DOCKER_ARCH="arm64"
      KASPAD_IMAGE="$KASPAD_IMAGE_ARM64"
      # supertypo's image runs kaspad as uid 50051 via su-exec and chowns
      # $RUSTY_HOME (/app/data) on start, so the appdir has to be that path —
      # a volume at /data would stay root-owned and kaspad could not write it.
      KASPAD_APPDIR="/app/data"
      ;;
    armv7l|armv6l|arm)
      fail "This is a 32-bit ARM system ($MACHINE). Kaspa needs a 64-bit OS.
       On a Raspberry Pi: reinstall with the 64-bit Raspberry Pi OS image
       (or any arm64 Debian/Ubuntu) and run this installer again."
      ;;
    *)
      fail "Unsupported CPU architecture: $MACHINE.
       MyKAI Node ships images for x86_64 (Intel/AMD) and aarch64 (ARM64)."
      ;;
  esac
}

# ─── Docker: installed ──────────────────────────────────────────────────────

# A WSL distro has WSL_DISTRO_NAME and /run/WSL (the variable doesn't survive
# sudo, the folder does). The kernel name isn't enough: every container on
# Docker Desktop for Windows runs on that same "microsoft" WSL2 kernel, and
# those are ordinary Linux boxes as far as this script is concerned.
is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] || [ -d /run/WSL ]
}

# Docker can be installed and still missing from this shell's PATH:
# /usr/local/bin, where a Synology and plenty of manual installs keep it, is
# left out of some PATHs (non-interactive ssh, `su -` on busybox). Look in the
# usual places before deciding it's not there, because the fallback --
# Docker's own installer -- must never run over a Docker that exists.
find_docker() {
  if command -v docker >/dev/null 2>&1; then return 0; fi
  for d in /usr/local/bin /usr/bin /snap/bin /usr/local/sbin /usr/sbin; do
    if [ -x "$d/docker" ]; then
      PATH="$d:$PATH"
      export PATH
      return 0
    fi
  done
  return 1
}

# A NAS ships Docker as an app of its own. Docker's Linux installer would
# refuse it or fight the vendor's package, so these get pointed at the app.
nas_hint() {
  if [ -f /etc/synoinfo.conf ]; then
    echo "On a Synology NAS: install Container Manager from Package Center."
  elif [ -f /etc/config/qpkg.conf ]; then
    echo "On a QNAP NAS: install Container Station from App Center."
  elif [ -f /etc/unraid-version ]; then
    echo "On Unraid: turn Docker on under Settings > Docker."
  elif command -v midclt >/dev/null 2>&1; then
    echo "On TrueNAS: set up Apps in the web interface, that turns Docker on."
  fi
}

install_docker() {
  case "$(uname -s)" in
    Linux) ;;
    Darwin)
      fail "Docker isn't installed. On a Mac, install Docker Desktop first:
       https://docs.docker.com/desktop/setup/install/mac-install/
       then run the install command again."
      ;;
    *)
      fail "Docker isn't installed, and this installer can only set it up on Linux.
       Install Docker for this system, then run the install command again."
      ;;
  esac
  if is_wsl; then
    fail "This is Windows (WSL). Use the MyKAI Windows app instead: https://mykai.dev"
  fi
  hint=$(nas_hint)
  if [ -n "$hint" ]; then
    fail "Docker isn't installed yet. $hint
       Then run the install command again."
  fi

  get_sudo "Installing Docker needs admin rights."
  # Last look, through root's PATH, before installing anything.
  root_docker=$(as_root sh -c 'command -v docker' 2>/dev/null) || root_docker=""
  if [ -n "$root_docker" ]; then
    PATH="$(dirname "$root_docker"):$PATH"
    export PATH
    return 0
  fi
  say "Docker isn't installed yet. Installing it with Docker's own installer"
  say "(get.docker.com, always the newest release). This takes a few minutes…"
  if ! fetch https://get.docker.com "$WORK_DIR/get-docker.sh"; then
    fail "Couldn't download Docker's installer.
       Check that this machine can reach the internet, then run the install command again."
  fi
  if ! as_root sh "$WORK_DIR/get-docker.sh" </dev/null >"$WORK_DIR/get-docker.log" 2>&1; then
    fail "Docker couldn't be installed automatically on this system.
       Install it yourself (pick your Linux version):
       https://docs.docker.com/engine/install/
       then run the install command again.

       Docker's installer said:
       $(tail -n 4 "$WORK_DIR/get-docker.log")"
  fi
  hash -r 2>/dev/null || true
  if ! command -v docker >/dev/null 2>&1; then
    fail "Docker's installer finished, but there's no docker command afterwards.
       Install Docker yourself: https://docs.docker.com/engine/install/
       then run the install command again."
  fi
  say "Docker installed."
}

# ─── Docker: running, and reachable by us ───────────────────────────────────
#
# Three things stand between an installed Docker and a working one: the
# daemon can be stopped, this user can lack access to its socket, or both.
# Before this, a socket "permission denied" fell into the pull step's
# "not on Docker Hub, that's a bug in this installer" branch -- the wrong
# message for the most common non-root setup.

DOCKER_BIN=""
DOCKER=""
DOCKER_SHOW="docker"
DOCKER_VIA_SUDO=0

docker_info_ok() {
  "$@" info >"$WORK_DIR/docker-info.out" 2>&1
}

# Newer Docker CLIs word it as "failed to connect to the docker API ... check
# if the daemon is running", older ones as "Cannot connect to the Docker
# daemon ... Is the docker daemon running?". Both mean the same here.
daemon_down() {
  grep -qiE "cannot connect to the docker daemon|is the docker daemon running|failed to connect to the docker api|daemon is running" "$WORK_DIR/docker-info.out"
}

no_permission() {
  grep -qi "permission denied" "$WORK_DIR/docker-info.out"
}

start_docker_daemon() {
  # Only Linux has a service we can start. Elsewhere (Docker Desktop) the
  # message at the end of setup_docker_access says to open the app.
  [ "$(uname -s)" = "Linux" ] || return 0
  get_sudo "Starting Docker needs admin rights."
  say "Docker isn't running. Starting it…"
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || as_root systemctl start docker >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    as_root rc-service docker start >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    as_root service docker start >/dev/null 2>&1 || true
  fi
  # Give it a moment to open its socket.
  n=0
  while [ "$n" -lt 20 ]; do
    if as_root "$DOCKER_BIN" info >/dev/null 2>&1; then return 0; fi
    sleep 1
    n=$((n + 1))
  done
}

use_sudo_docker() {
  DOCKER="sudo $DOCKER_BIN"
  DOCKER_SHOW="sudo docker"
  DOCKER_VIA_SUDO=1
}

setup_docker_access() {
  DOCKER_BIN=$(command -v docker)

  if docker_info_ok "$DOCKER_BIN"; then DOCKER="$DOCKER_BIN"; return 0; fi

  if daemon_down; then
    start_docker_daemon
    if docker_info_ok "$DOCKER_BIN"; then DOCKER="$DOCKER_BIN"; return 0; fi
  fi

  if [ "$IS_ROOT" != 1 ] && no_permission; then
    get_sudo "Docker needs admin rights on this machine."
    if docker_info_ok sudo "$DOCKER_BIN"; then use_sudo_docker; return 0; fi
    if daemon_down; then
      start_docker_daemon
      if docker_info_ok sudo "$DOCKER_BIN"; then use_sudo_docker; return 0; fi
    fi
  fi

  detail=$(tail -n 3 "$WORK_DIR/docker-info.out" 2>/dev/null || true)
  if daemon_down; then
    fail "Docker is installed but isn't running, and it wouldn't start.
       Start it (sudo systemctl start docker, open Docker Desktop, or turn
       Docker on in your NAS's app center) and run the install command again.

       Docker said:
       $detail"
  fi
  if no_permission; then
    fail "This user isn't allowed to use Docker.
       Log in as root, or ask your admin to add you to the docker group,
       then run the install command again.

       Docker said:
       $detail"
  fi
  fail "Docker isn't working on this machine yet.

       Docker said:
       $detail

       Help: $HELP_URL"
}

# ─── Docker: compose ────────────────────────────────────────────────────────
#
# Docker from a distro's own packages (Ubuntu's docker.io, say) often comes
# without compose. Docker's installer always includes it, so this mostly
# catches those hosts. The plugin goes in the system-wide plugin folder so it
# also works through sudo.

COMPOSE=""
COMPOSE_SHOW="docker compose"

install_compose_plugin() {
  [ "$(uname -s)" = "Linux" ] || return 0
  case "$MACHINE" in
    x86_64|amd64) compose_arch="x86_64" ;;
    *) compose_arch="aarch64" ;;
  esac
  get_sudo "Adding Docker Compose needs admin rights."
  say "Docker Compose is missing. Adding it from Docker's own releases…"
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$compose_arch"
  if ! fetch "$url" "$WORK_DIR/docker-compose"; then
    fail "Couldn't download Docker Compose.
       Check that this machine can reach github.com, then run the install command again."
  fi
  # Docker publishes a checksum next to every binary. Checking it catches a
  # download that got cut off; skipped only when there's no sha256sum.
  if command -v sha256sum >/dev/null 2>&1 && fetch "$url.sha256" "$WORK_DIR/docker-compose.sha256"; then
    want=$(cut -d ' ' -f 1 "$WORK_DIR/docker-compose.sha256")
    have=$(sha256sum "$WORK_DIR/docker-compose" | cut -d ' ' -f 1)
    if [ "$want" != "$have" ]; then
      fail "The Docker Compose download came out damaged. Run the install command again."
    fi
  fi
  as_root mkdir -p /usr/local/lib/docker/cli-plugins
  as_root cp "$WORK_DIR/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
  as_root chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
}

setup_compose() {
  if $DOCKER compose version >/dev/null 2>&1; then
    COMPOSE="$DOCKER compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    if [ "$DOCKER_VIA_SUDO" = 1 ]; then
      COMPOSE="sudo $(command -v docker-compose)"
    else
      COMPOSE="$(command -v docker-compose)"
    fi
    COMPOSE_SHOW="docker-compose"
  else
    install_compose_plugin
    if ! $DOCKER compose version >/dev/null 2>&1; then
      fail "docker compose is not installed. On Linux: apt install docker-compose-plugin
       On Mac: it comes with Docker Desktop, so check your install."
    fi
    COMPOSE="$DOCKER compose"
  fi
  # Commands printed at the end have to work for the person reading them.
  # Through sudo, or when this whole script was started with sudo, that means
  # sudo in front.
  if [ "$DOCKER_VIA_SUDO" = 1 ] || { [ "$IS_ROOT" = 1 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != "root" ]; }; then
    DOCKER_SHOW="sudo docker"
    COMPOSE_SHOW="sudo $COMPOSE_SHOW"
  fi
}

# ─── Disk ───────────────────────────────────────────────────────────────────

check_disk() {
  # An existing install already has its chain data on this disk, so the free
  # number says little about it. Only fresh machines get sized up.
  if $DOCKER inspect mykai-kaspad >/dev/null 2>&1; then return 0; fi
  root_dir=$($DOCKER info -f '{{.DockerRootDir}}' 2>/dev/null) || root_dir=""
  [ -n "$root_dir" ] || root_dir="/var/lib/docker"
  avail_kb=$(df -Pk "$root_dir" 2>/dev/null | awk 'NR==2 {print $4}') || avail_kb=""
  case "$avail_kb" in
    ''|*[!0-9]*) return 0 ;;
  esac
  avail_gb=$((avail_kb / 1048576))
  if [ "$avail_gb" -ge "$DISK_SAFE_GB" ]; then return 0; fi
  say "Heads-up: $avail_gb GB free on the disk Docker uses ($root_dir)."
  say "A Kaspa node grows to about $DISK_PEAK_GB GB when the network is busy."
  say "$DISK_SAFE_GB GB free is the safe size."
  if [ "$avail_gb" -lt "$DISK_PEAK_GB" ]; then
    say "It will run, but it can stop when the disk fills up."
  fi
}

# ─── Account key ────────────────────────────────────────────────────────────

resolve_account_key() {
  if [ -n "$ACCOUNT_KEY" ]; then return 0; fi

  # Try to reuse a previously-installed key.
  if [ -f "$INSTALL_DIR/.mykai-account-key" ]; then
    ACCOUNT_KEY=$(cat "$INSTALL_DIR/.mykai-account-key" 2>/dev/null || true)
    if [ -n "$ACCOUNT_KEY" ]; then
      say "Reusing existing account key: ${ACCOUNT_KEY%????????????????????????}…"
      return 0
    fi
  fi

  # The key file sits in the home of whoever ran the last install, so one run
  # with sudo and one without look in different places. The monitor that's
  # already running knows the key either way, and asking it keeps this
  # machine on the same account instead of quietly starting a new one.
  running=$($DOCKER inspect -f '{{range .Config.Env}}{{println .}}{{end}}' mykai-monitor 2>/dev/null \
    | sed -n 's/^MYKAI_ACCOUNT_KEY=//p' | head -n 1) || running=""
  if printf '%s' "$running" | grep -Eq '^acc_[0-9a-f]{32}$'; then
    ACCOUNT_KEY="$running"
    say "Reusing the account key of the node already running here: ${ACCOUNT_KEY%????????????????????????}…"
    return 0
  fi

  # Auto-mint a fresh one. Format matches desktop's electron-store output:
  # acc_<32 hex chars>.
  if command -v openssl >/dev/null 2>&1; then
    HEX=$(openssl rand -hex 16)
  elif [ -r /dev/urandom ]; then
    HEX=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  else
    fail "Can't generate a random key — no openssl, no /dev/urandom. Set
         MYKAI_ACCOUNT_KEY=acc_<32hex> manually and re-run."
  fi
  ACCOUNT_KEY="acc_${HEX}"
  say "Generated new account key: ${ACCOUNT_KEY%????????????????????????}…"
  say "To unify with a desktop MyKAI install later, set MYKAI_ACCOUNT_KEY"
  say "to your desktop's key and re-run this script."
}

# ─── Pull the images first, and explain any failure in English ──────────────
#
# Doing this before compose runs means a missing or wrong-architecture image
# produces one clear sentence instead of a half-created stack and a raw
# registry error. Both failure modes below have actually happened: a stale
# image name that wasn't on Hub, and an amd64-only manifest on a Pi 5.
#
# The "not on Hub" branch matches registry wording only. It used to match a
# bare "denied", which also caught the socket's "permission denied" and told
# people the installer had a bug when their user just couldn't reach Docker.

pull_image() {
  image="$1"
  role="$2"
  say "Pulling $image ($role)…"
  if $DOCKER pull "$image" >"$WORK_DIR/pull.log" 2>&1; then
    return 0
  fi
  detail=$(tail -n 3 "$WORK_DIR/pull.log" 2>/dev/null || true)
  case "$detail" in
    *"no matching manifest"*|*"no match for platform"*|*"cannot be used on this platform"*)
      fail "$image has no linux/$DOCKER_ARCH build on Docker Hub yet.
       Your hardware is fine — the image just isn't published for it.
       Please report it at https://github.com/KasMapApp/MyKAI-Node-Public/issues
       and mention $MACHINE.

       Docker said:
       $detail"
      ;;
    *"toomanyrequests"*|*"rate limit"*)
      fail "Docker Hub is limiting downloads from this internet address right now.
       Wait an hour or so, then run the install command again.

       Docker said:
       $detail"
      ;;
    *"no space left on device"*)
      fail "The disk is full. Free up space ($DISK_SAFE_GB GB free is the safe size)
       and run the install command again.

       Docker said:
       $detail"
      ;;
    *"permission denied while trying to connect"*|*"Cannot connect to the Docker daemon"*|*"failed to connect to the docker API"*)
      fail "Lost contact with Docker while downloading.
       Run the install command again. If it keeps happening: $HELP_URL

       Docker said:
       $detail"
      ;;
    *"pull access denied"*|*"requested access to the resource is denied"*|*"manifest unknown"*|*"not found"*)
      fail "$image could not be found on Docker Hub.
       That's a bug in this installer, not something you did wrong.
       Please report it at https://github.com/KasMapApp/MyKAI-Node-Public/issues

       Docker said:
       $detail"
      ;;
    *)
      fail "Could not pull $image.
       Check that this machine has internet access and can reach Docker Hub.

       Docker said:
       $detail"
      ;;
  esac
}

# ─── Write docker-compose.yml ───────────────────────────────────────────────

write_files() {
  put_file "$INSTALL_DIR/.mykai-account-key" <<KEY_EOF
$ACCOUNT_KEY
KEY_EOF
  chmod 600 "$INSTALL_DIR/.mykai-account-key" 2>/dev/null || as_root chmod 600 "$INSTALL_DIR/.mykai-account-key"

  # kaspad's command list differs by image. supertypo's entrypoint is a wrapper
  # script that expects the binary name as its first argument (it matches on
  # ^kaspad to decide whether to resolve and inject --externalip), so on ARM the
  # list starts with a bare `kaspad`. Our own image's entrypoint IS the binary,
  # so its list starts at the first flag. Everything after that is identical.
  if [ "$DOCKER_ARCH" = "arm64" ]; then
    KASPAD_ENTRY_ARG="      - kaspad
"
  else
    KASPAD_ENTRY_ARG=""
  fi

  put_file "$INSTALL_DIR/docker-compose.yml" <<COMPOSE_EOF
# MyKAI Node — generated by https://mykai.dev/install.sh
# Built for linux/$DOCKER_ARCH on $MACHINE.
# Edit MYKAI_NODE_NAME below if you want a custom label.
# To reset everything: docker compose down -v && rm -rf $INSTALL_DIR

services:
  kaspad:
    image: $KASPAD_IMAGE
    container_name: mykai-kaspad
    restart: unless-stopped
    ports:
      - "16111:16111"     # P2P inbound. Forward this in your router too.
    volumes:
      - kaspad-data:$KASPAD_APPDIR
    command:
$KASPAD_ENTRY_ARG      # --yes auto-confirms kaspad's y/n prompts (the one-way DB schema
      # upgrade when coming from a pre-Toccata version). Without it the
      # prompt reads EOF in Docker and the container crash-loops.
      - --yes
      - --utxoindex
      - --appdir=$KASPAD_APPDIR
      - --listen=0.0.0.0:16111
      - --rpclisten-borsh=0.0.0.0:17110
      - --rpclisten-json=0.0.0.0:18110
      # Outbound peer count — matches MyKAI Node desktop default (v0.4.3+)
      # for a consistent network-load profile across the MyKAI fleet.
      # NAS / VPS operators who want more (mining, observatory) can edit
      # this line in ~/.mykai-node/docker-compose.yml and run
      # \`docker compose up -d\` to apply.
      - --outpeers=12
      # Link every docker node to MyKAI's own always-on hub — same role as
      # the desktop app's seed peers: your address lands in a well-connected
      # addrman immediately instead of waiting on the gossip random walk.
      - --addpeer=167.233.105.217:16111

  mykai-monitor:
    image: $MONITOR_IMAGE
    container_name: mykai-monitor
    restart: unless-stopped
    depends_on:
      - kaspad
    environment:
      - MYKAI_KASPAD_HOST=kaspad
      - MYKAI_BORSH_PORT=17110
      - MYKAI_JSON_PORT=18110
      - MYKAI_NETWORK=mainnet
      - MYKAI_IS_PUBLIC=true
      - MYKAI_NODE_NAME=${NODE_NAME}
      - MYKAI_ACCOUNT_KEY=${ACCOUNT_KEY}
      # Lets the monitor report chain-storage size (read-only mount).
      - MYKAI_DATA_DIR=/kaspad-data
    volumes:
      - mykai-data:/app/data
      - kaspad-data:/kaspad-data:ro

volumes:
  kaspad-data:
  mykai-data:
COMPOSE_EOF

  say "Wrote $INSTALL_DIR/docker-compose.yml"
}

# ─── Start ──────────────────────────────────────────────────────────────────
#
# Same idea as the pulls: one sentence instead of a raw daemon error. The
# likeliest failure for Kaspa people is a kaspad they already run on 16111.

start_stack() {
  say "Starting containers…"
  if $COMPOSE -f "$COMPOSE_FILE_PATH" up -d >"$WORK_DIR/up.log" 2>&1; then
    return 0
  fi
  detail=$(tail -n 3 "$WORK_DIR/up.log" 2>/dev/null || true)
  case "$detail" in
    *"port is already allocated"*|*"address already in use"*)
      fail "Port 16111 is already in use on this machine, most likely by a Kaspa
       node that's already running. MyKAI brings its own, so stop that one
       first, then run the install command again.

       Docker said:
       $detail"
      ;;
    *"no space left on device"*)
      fail "The disk is full. Free up space ($DISK_SAFE_GB GB free is the safe size)
       and run the install command again.

       Docker said:
       $detail"
      ;;
    *)
      fail "The containers wouldn't start.

       Docker said:
       $detail

       Help: $HELP_URL"
      ;;
  esac
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t mykai)
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  if [ "$(id -u)" = "0" ]; then IS_ROOT=1; fi

  say "MyKAI Node installer"

  # Architecture first: refusing a 32-bit Pi is better done before Docker
  # gets installed on it.
  detect_arch

  if ! find_docker; then
    install_docker
  fi
  setup_docker_access
  setup_compose
  say "Docker found: $($DOCKER --version | head -1)"
  say "Compose found: $COMPOSE_SHOW"
  say "Architecture: $MACHINE (docker platform linux/$DOCKER_ARCH)"

  check_disk

  resolve_account_key
  # Validate format defensively.
  if ! printf '%s' "$ACCOUNT_KEY" | grep -Eq '^acc_[0-9a-f]{32}$'; then
    fail "That account key isn't valid. Expected: acc_<32 hex chars>.
       Got: $ACCOUNT_KEY"
  fi

  pull_image "$KASPAD_IMAGE" "Kaspa node"
  pull_image "$MONITOR_IMAGE" "MyKAI monitor"

  write_files

  # -f instead of cd: works the same when the folder belongs to root and
  # only sudo can read it. The project name still comes from the folder.
  COMPOSE_FILE_PATH="$INSTALL_DIR/docker-compose.yml"
  start_stack

  sleep 2
  say ""
  say "✓ MyKAI Node is running."
  say ""
  say "Account key:  $ACCOUNT_KEY"
  say "Node name:    $NODE_NAME"
  say "Install dir:  $INSTALL_DIR"
  say ""
  say "Container status:"
  $COMPOSE -f "$COMPOSE_FILE_PATH" ps
  say ""
  say "Next steps:"
  say "  • Forward TCP port 16111 in your router (or open it in your VPS"
  say "    firewall) to make this node reachable"
  say "  • View logs:           $DOCKER_SHOW logs -f mykai-monitor"
  say "  • Stop everything:     $COMPOSE_SHOW -f $COMPOSE_FILE_PATH down"
  say "  • Stop + wipe data:    $COMPOSE_SHOW -f $COMPOSE_FILE_PATH down -v"
  say "  • Update later:        run the install command again"
  say ""
  # "My Nodes" is a list in the Windows app, not a page on mykai.dev. This
  # used to send people looking for it on the website.
  say "Within a few minutes your node counts in the live total on https://mykai.dev"
  say "Also run the MyKAI Windows app? Install with its account key and this"
  say "server shows up under My Nodes in the app."
  say "Something not working? $HELP_URL"
}

main "$@"
