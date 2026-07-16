#!/usr/bin/env bash
set -euo pipefail

VHTTPD_REPO="${VHTTPD_REPO:-https://github.com/guweigang/vhttpd.git}"
VHTTPD_BRANCH="${VHTTPD_BRANCH:-refactor/v2}"
VHTTPD_SOURCE_DIR="${VHTTPD_SOURCE_DIR:-}"
V_REPO="${V_REPO:-https://github.com/guweigang/vlang.git}"
V_BRANCH="${V_BRANCH:-local-dev}"
V_ROOT="${V_ROOT:-$HOME/v}"
VHTTPD_WORKDIR="${VHTTPD_WORKDIR:-$HOME/vhttpd-src}"
VHTTPD_PREFIX="${VHTTPD_PREFIX:-$HOME/.local}"
VHTTPD_VJSX_ROOT="${VHTTPD_VJSX_ROOT:-/usr/local/share/vhttpd/vjsx}"
VHTTPD_QUICKJS_WORK_ROOT="${VHTTPD_QUICKJS_WORK_ROOT:-$HOME/vhttpd-linux-deps}"
V_CC="${V_CC:-gcc}"
VPHP_V_GC="${VPHP_V_GC:-boehm}"
WITH_DB="${WITH_DB:-1}"
RUN_TESTS="${RUN_TESTS:-0}"

log() {
  printf '[vhttpd-install] %s\n' "$*"
}

fail() {
  printf '[vhttpd-install] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

apt_install() {
  if [ "$(id -u)" -eq 0 ]; then
    apt-get update
    apt-get install -y --no-install-recommends "$@"
  else
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends "$@"
  fi
}

clone_or_update() {
  local repo="$1"
  local branch="$2"
  local dir="$3"
  if [ -d "$dir/.git" ]; then
    log "using existing checkout: $dir"
    (
      cd "$dir"
      git fetch --prune origin
      if git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
        git checkout "$branch"
        git pull --ff-only origin "$branch"
      fi
    )
    return
  fi
  rm -rf "$dir"
  log "cloning $repo into $dir"
  if git ls-remote --exit-code --heads "$repo" "$branch" >/dev/null 2>&1; then
    git clone --branch "$branch" "$repo" "$dir"
  else
    git clone "$repo" "$dir"
  fi
}

prepare_apt_deps() {
  log "installing Ubuntu build dependencies"
  apt_install \
    build-essential \
    ca-certificates \
    curl \
    default-libmysqlclient-dev \
    git \
    libgc-dev \
    libpq-dev \
    libsqlite3-dev \
    libssl-dev \
    patchelf \
    pkg-config \
    sqlite3 \
    unzip
}

prepare_v() {
  need_cmd git
  clone_or_update "$V_REPO" "$V_BRANCH" "$V_ROOT"
  log "building V compiler at $V_ROOT"
  (
    cd "$V_ROOT"
    git log -1 --oneline
    make CC="$V_CC"
    ./v version
  )
}

prepare_vjsx() {
  need_cmd git
  log "preparing vjsx at $VHTTPD_VJSX_ROOT"
  if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$(dirname "$VHTTPD_VJSX_ROOT")"
  else
    sudo mkdir -p "$(dirname "$VHTTPD_VJSX_ROOT")"
    sudo chown "$USER" "$(dirname "$VHTTPD_VJSX_ROOT")"
  fi
  clone_or_update "https://github.com/guweigang/vjsx.git" "main" "$VHTTPD_VJSX_ROOT"
  mkdir -p "$HOME/.vmodules" "$VHTTPD_QUICKJS_WORK_ROOT"
  rm -rf "$HOME/.vmodules/vjsx"
  ln -s "$VHTTPD_VJSX_ROOT" "$HOME/.vmodules/vjsx"
  [ -x "$VHTTPD_VJSX_ROOT/scripts/ensure-quickjs.sh" ] || fail "missing vjsx QuickJS helper"
  quickjs_path="$(VJS_QUICKJS_WORK_ROOT="$VHTTPD_QUICKJS_WORK_ROOT" "$VHTTPD_VJSX_ROOT/scripts/ensure-quickjs.sh")"
  export VJS_QUICKJS_PATH="$quickjs_path"
  log "using QuickJS source at $VJS_QUICKJS_PATH"
}

prepare_vhttpd_source() {
  if [ -n "$VHTTPD_SOURCE_DIR" ]; then
    [ -d "$VHTTPD_SOURCE_DIR" ] || fail "VHTTPD_SOURCE_DIR does not exist: $VHTTPD_SOURCE_DIR"
    VHTTPD_WORKDIR="$VHTTPD_SOURCE_DIR"
    log "using vhttpd source: $VHTTPD_WORKDIR"
    return
  fi
  clone_or_update "$VHTTPD_REPO" "$VHTTPD_BRANCH" "$VHTTPD_WORKDIR"
}

build_and_install_vhttpd() {
  export PATH="$V_ROOT:$PATH"
  export V_CC VPHP_V_GC WITH_DB
  need_cmd v
  log "building vhttpd: branch/source=$VHTTPD_WORKDIR WITH_DB=$WITH_DB VPHP_V_GC=$VPHP_V_GC"
  (
    cd "$VHTTPD_WORKDIR"
    if [ "$RUN_TESTS" = "1" ]; then
      make test-fast V_CC="$V_CC" VPHP_V_GC="$VPHP_V_GC"
    fi
    make prod V_CC="$V_CC" VPHP_V_GC="$VPHP_V_GC" WITH_DB="$WITH_DB"
    mkdir -p "$VHTTPD_PREFIX/bin"
    install -m 0755 ./vhttpd "$VHTTPD_PREFIX/bin/vhttpd"
    "$VHTTPD_PREFIX/bin/vhttpd" --help >/dev/null
  )
  log "installed $VHTTPD_PREFIX/bin/vhttpd"
}

main() {
  case "$(uname -s)" in
    Linux) ;;
    *) fail "this installer is intended for Ubuntu/Linux" ;;
  esac
  if command -v lsb_release >/dev/null 2>&1; then
    log "system: $(lsb_release -ds)"
  fi
  prepare_apt_deps
  prepare_v
  prepare_vjsx
  prepare_vhttpd_source
  build_and_install_vhttpd
  log "done"
  log "add to PATH if needed: export PATH=\"$VHTTPD_PREFIX/bin:\$PATH\""
}

main "$@"
