#!/usr/bin/env bash
#
# Cross-compile htop (with a self-contained ncurses) for Android.
#
# ncurses is built with --disable-database and a compiled-in fallback terminfo
# set, because Android ships no terminfo database at all.
#
# Environment:
#   ABIS             space separated ABI list (default: "arm64-v8a armeabi-v7a")
#   API              minimum Android API level (default: 26, nl_langinfo)
#   ANDROID_NDK_HOME pre-existing NDK; downloaded if unset
#   NCURSES_VERSION  pinned ncurses version (default: latest release)
#   HTOP_VERSION     pinned htop version (default: latest release)
#   JOBS             parallel make jobs (default: nproc)
#
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$TOP/build}"
DIST="${DIST:-$TOP/dist}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a}"
API="${API:-26}"
JOBS="${JOBS:-$(nproc)}"

# Terminals worth carrying around on a phone. Anything unknown degrades to
# "dumb", which is also compiled in.
FALLBACKS="${FALLBACKS:-dumb,linux,linux-16color,vt100,vt220,ansi,xterm,xterm-color,xterm-16color,xterm-256color,screen,screen-256color,tmux,tmux-256color,rxvt,rxvt-256color,putty,putty-256color,alacritty,foot,ghostty,wezterm,st-256color,vte-256color,konsole-256color,Eterm}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

fetch() { # fetch <url> <output>
  curl --retry 3 --retry-delay 2 -fsSL "$1" -o "$2"
}

resolve_versions() {
  if [ -z "${NCURSES_VERSION:-}" ]; then
    NCURSES_VERSION="$(curl -fsSL https://ftp.gnu.org/gnu/ncurses/ \
      | grep -o 'ncurses-[0-9][0-9.]*\.tar\.gz' \
      | sed 's/^ncurses-//; s/\.tar\.gz$//' \
      | sort -V | tail -1)"
  fi
  if [ -z "${HTOP_VERSION:-}" ]; then
    HTOP_VERSION="$(curl -fsSL https://api.github.com/repos/htop-dev/htop/releases/latest \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')"
  fi
  [ -n "$NCURSES_VERSION" ] || { echo "cannot resolve ncurses version" >&2; exit 1; }
  [ -n "$HTOP_VERSION" ]    || { echo "cannot resolve htop version" >&2; exit 1; }
  log "ncurses $NCURSES_VERSION, htop $HTOP_VERSION"
}

install_ndk() {
  if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    log "using NDK at $ANDROID_NDK_HOME"
    return
  fi
  log "resolving latest Android NDK"
  local xml="$WORK/repository2-3.xml" zip name
  fetch https://dl.google.com/android/repository/repository2-3.xml "$xml"
  # Newest linux archive that is not a beta/rc/canary drop.
  name="$(grep -o 'android-ndk-r[0-9]\+[a-z]*-linux\.zip' "$xml" | sort -uV | tail -1)"
  [ -n "$name" ] || { echo "cannot resolve NDK release" >&2; exit 1; }
  zip="$WORK/$name"
  log "downloading $name"
  fetch "https://dl.google.com/android/repository/$name" "$zip"
  rm -rf "$WORK/ndk" && mkdir -p "$WORK/ndk"
  unzip -q "$zip" -d "$WORK/ndk"
  ANDROID_NDK_HOME="$(echo "$WORK/ndk"/android-ndk-*)"
  export ANDROID_NDK_HOME
}

abi_triple() {
  case "$1" in
    arm64-v8a)   echo aarch64-linux-android ;;
    armeabi-v7a) echo armv7a-linux-androideabi ;;
    x86_64)      echo x86_64-linux-android ;;
    x86)         echo i686-linux-android ;;
    *) echo "unknown ABI: $1" >&2; exit 1 ;;
  esac
}

# The configure --host name differs from the clang target for 32-bit ARM.
abi_host() {
  case "$1" in
    armeabi-v7a) echo arm-linux-androideabi ;;
    *)           abi_triple "$1" ;;
  esac
}

# Only names present in this ncurses release's own terminfo.src can be compiled
# in, so drop anything else instead of failing the whole build.
validate_fallbacks() {
  local db="$WORK/terminfo-check" keep="" drop="" t
  rm -rf "$db" && mkdir -p "$db"
  tic -o "$db" -x "$WORK/ncurses-$NCURSES_VERSION/misc/terminfo.src" >/dev/null 2>&1 || true
  for t in ${FALLBACKS//,/ }; do
    if infocmp -A "$db" -1 "$t" >/dev/null 2>&1; then
      keep="${keep:+$keep,}$t"
    else
      drop="${drop:+$drop }$t"
    fi
  done
  [ -n "$keep" ] || { echo "no usable terminfo fallbacks" >&2; exit 1; }
  [ -z "$drop" ] || log "skipping unknown terminfo entries: $drop"
  FALLBACKS="$keep"
  log "compiled-in terminfo: $FALLBACKS"
}

build_abi() {
  local abi="$1"
  local triple host prefix
  triple="$(abi_triple "$abi")"
  host="$(abi_host "$abi")"
  prefix="$WORK/$abi/prefix"

  local tc="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
  export CC="$tc/${triple}${API}-clang"
  export AR="$tc/llvm-ar" RANLIB="$tc/llvm-ranlib" STRIP="$tc/llvm-strip"
  export CFLAGS="-Os -fPIC -fdata-sections -ffunction-sections"
  export LDFLAGS="-Wl,--gc-sections"
  [ -x "$CC" ] || { echo "no compiler: $CC" >&2; exit 1; }

  mkdir -p "$prefix"

  log "[$abi] building ncurses $NCURSES_VERSION"
  local nsrc="$WORK/ncurses-$NCURSES_VERSION"
  local nbuild="$WORK/$abi/ncurses"
  rm -rf "$nbuild" && mkdir -p "$nbuild"
  ( cd "$nbuild" && "$nsrc/configure" \
      --host="$host" --prefix="$prefix" \
      --with-build-cc="${BUILD_CC:-cc}" \
      --with-tic-path="$(command -v tic)" \
      --with-infocmp-path="$(command -v infocmp)" \
      --disable-database --with-fallbacks="$FALLBACKS" \
      --enable-widec --enable-pc-files \
      --with-pkg-config-libdir="$prefix/lib/pkgconfig" \
      --without-shared --with-normal --without-debug --without-cxx \
      --without-cxx-binding --without-ada --without-manpages \
      --without-progs --without-tests --without-tack \
      --disable-home-terminfo --disable-rpath-hack --disable-stripping \
      --enable-const --enable-ext-colors --enable-ext-mouse \
      --disable-mixed-case --disable-termcap \
      >/dev/null
    make -j"$JOBS" >/dev/null
    make install.libs install.includes >/dev/null )

  # htop looks for plain -lncurses / ncurses.h too; alias the wide build.
  ln -sf libncursesw.a "$prefix/lib/libncurses.a"
  ln -sf ncursesw "$prefix/include/ncurses"

  log "[$abi] building htop $HTOP_VERSION"
  local hsrc="$WORK/htop-${HTOP_VERSION#v}"
  local hbuild="$WORK/$abi/htop"
  rm -rf "$hbuild" && mkdir -p "$hbuild"
  ( cd "$hbuild"
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export PKG_CONFIG_SYSROOT_DIR=""
    export CPPFLAGS="-I$prefix/include -I$prefix/include/ncursesw"
    export LDFLAGS="$LDFLAGS -L$prefix/lib -static-libgcc"
    "$hsrc/configure" \
      --host="$host" --prefix=/data/local/tmp/htop \
      --enable-unicode \
      --disable-hwloc --disable-sensors --disable-capabilities \
      --disable-delayacct --disable-affinity \
      >/dev/null
    make -j"$JOBS" >/dev/null )

  mkdir -p "$DIST/$abi"
  "$STRIP" -o "$DIST/$abi/htop" "$hbuild/htop"
  log "[$abi] $(file "$DIST/$abi/htop" | cut -d: -f2-)"
}

main() {
  mkdir -p "$WORK" "$DIST"
  resolve_versions
  install_ndk

  log "fetching sources"
  local nt="$WORK/ncurses-$NCURSES_VERSION.tar.gz"
  local ht="$WORK/htop-$HTOP_VERSION.tar.xz"
  [ -f "$nt" ] || fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz" "$nt"
  [ -f "$ht" ] || fetch "https://github.com/htop-dev/htop/releases/download/$HTOP_VERSION/htop-${HTOP_VERSION#v}.tar.xz" "$ht"
  [ -d "$WORK/ncurses-$NCURSES_VERSION" ] || tar -C "$WORK" -xf "$nt"
  [ -d "$WORK/htop-${HTOP_VERSION#v}" ]   || tar -C "$WORK" -xf "$ht"

  validate_fallbacks

  for abi in $ABIS; do
    build_abi "$abi"
  done

  {
    echo "ndk=$(basename "$ANDROID_NDK_HOME")"
    echo "ncurses=$NCURSES_VERSION"
    echo "htop=$HTOP_VERSION"
    echo "api=$API"
  } | tee "$DIST/versions.txt"
}

main "$@"
