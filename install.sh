#!/bin/sh
# MyKAI Node — one-line installer for Docker hosts (NAS, VPS, home server).
#
# Usage:
#   bash <(curl -fsSL https://mykai.dev/install.sh)
#
# Or with a specific account key (unify stats with an existing desktop install):
#   MYKAI_ACCOUNT_KEY=acc_<32hex> bash <(curl -fsSL https://mykai.dev/install.sh)
#
# What this script does:
#   1. Verifies docker + docker compose are installed, and detects the CPU arch
#   2. Creates ~/.mykai-node/ with a docker-compose.yml describing two services:
#        kaspad           — the actual Kaspa node (image depends on arch, below)
#        mykai-monitor    — kasmap/mykai-headless (MyKAI's telemetry monitor)
#   3. Pulls both images up front, with a plain-English message if one is
#      missing for this architecture instead of a cryptic docker error
#   4. Brings the stack up with `docker compose up -d`
#   5. Prints the final account key + container status
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

set -eu

INSTALL_DIR="${MYKAI_INSTALL_DIR:-$HOME/.mykai-node}"
NODE_NAME="${MYKAI_NODE_NAME:-MyKAI Cloud Node}"
ACCOUNT_KEY="${MYKAI_ACCOUNT_KEY:-}"

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
MONITOR_IMAGE="kasmap/mykai-headless:0.5.1"
KASPAD_IMAGE_AMD64="kasmap/kaspad:2.0.0"
KASPAD_IMAGE_ARM64="supertypo/rusty-kaspad:v2.0.1"

say() { printf '\033[1;36m[MyKAI]\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m[MyKAI] %s\033[0m\n' "$1" >&2; exit 1; }

# ─── Prerequisite checks ────────────────────────────────────────────────────

say "MyKAI Node installer"

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed. Install Docker first:
       https://docs.docker.com/engine/install/   (Linux)
       https://docs.docker.com/desktop/install/  (Mac, Windows)
       Or use your NAS's App Central (Asustor / Synology have 1-click Docker)."
fi

# Compose can be docker-compose (legacy) or `docker compose` (plugin).
COMPOSE=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  fail "docker compose is not installed. On Linux: apt install docker-compose-plugin
       On Mac/Windows: comes with Docker Desktop, so check your install."
fi
say "Docker found: $(docker --version | head -1)"
say "Compose found: $COMPOSE"

# ─── Architecture ───────────────────────────────────────────────────────────

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
say "Architecture: $MACHINE (docker platform linux/$DOCKER_ARCH)"

# ─── Generate or reuse accountKey ───────────────────────────────────────────

if [ -z "$ACCOUNT_KEY" ]; then
  # Try to reuse a previously-installed key.
  if [ -f "$INSTALL_DIR/.mykai-account-key" ]; then
    ACCOUNT_KEY=$(cat "$INSTALL_DIR/.mykai-account-key" 2>/dev/null || true)
    say "Reusing existing account key: ${ACCOUNT_KEY%????????????????????????}…"
  fi
fi

if [ -z "$ACCOUNT_KEY" ]; then
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
fi

# Validate format defensively.
if ! printf '%s' "$ACCOUNT_KEY" | grep -Eq '^acc_[0-9a-f]{32}$'; then
  fail "MYKAI_ACCOUNT_KEY format is invalid. Expected: acc_<32 hex chars>.
       Got: $ACCOUNT_KEY"
fi

# ─── Pull the images first, and explain any failure in English ──────────────
#
# Doing this before compose runs means a missing or wrong-architecture image
# produces one clear sentence instead of a half-created stack and a raw
# registry error. Both failure modes below have actually happened: a stale
# image name that wasn't on Hub, and an amd64-only manifest on a Pi 5.

PULL_LOG="${TMPDIR:-/tmp}/mykai-pull.$$"
trap 'rm -f "$PULL_LOG"' EXIT

pull_image() {
  image="$1"
  role="$2"
  say "Pulling $image ($role)…"
  if docker pull "$image" >"$PULL_LOG" 2>&1; then
    return 0
  fi
  detail=$(tail -n 3 "$PULL_LOG" 2>/dev/null || true)
  case "$detail" in
    *"no matching manifest"*|*"no match for platform"*|*"cannot be used on this platform"*)
      fail "$image has no linux/$DOCKER_ARCH build on Docker Hub yet.
       Your hardware is fine — the image just isn't published for it.
       Please report it at https://github.com/KasMapApp/MyKAI-Node-Public/issues
       and mention $MACHINE.

       Docker said:
       $detail"
      ;;
    *"does not exist"*|*"denied"*|*"not found"*|*"manifest unknown"*)
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

pull_image "$KASPAD_IMAGE" "Kaspa node"
pull_image "$MONITOR_IMAGE" "MyKAI monitor"

# ─── Write docker-compose.yml ───────────────────────────────────────────────

mkdir -p "$INSTALL_DIR"
echo "$ACCOUNT_KEY" > "$INSTALL_DIR/.mykai-account-key"
chmod 600 "$INSTALL_DIR/.mykai-account-key"

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

cat > "$INSTALL_DIR/docker-compose.yml" <<COMPOSE_EOF
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

# ─── Start ──────────────────────────────────────────────────────────────────

cd "$INSTALL_DIR"

say "Starting containers…"
$COMPOSE up -d

# ─── Output ─────────────────────────────────────────────────────────────────

sleep 2
say ""
say "✓ MyKAI Node is running."
say ""
say "Account key:  $ACCOUNT_KEY"
say "Node name:    $NODE_NAME"
say "Install dir:  $INSTALL_DIR"
say ""
say "Container status:"
$COMPOSE ps
say ""
say "Next steps:"
say "  • Forward TCP port 16111 in your router to make this node reachable"
say "  • View logs:           cd $INSTALL_DIR && $COMPOSE logs -f mykai-monitor"
say "  • Stop everything:     cd $INSTALL_DIR && $COMPOSE down"
say "  • Stop + wipe data:    cd $INSTALL_DIR && $COMPOSE down -v"
say ""
say "Your node will show up at https://mykai.dev under \"My Nodes\""
say "within a few minutes (first heartbeat fires at ~15min cadence)."
