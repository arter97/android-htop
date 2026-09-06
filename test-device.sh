#!/usr/bin/env bash
#
# Push a built htop to the connected device and verify it actually renders.
#
# Runs htop under a real pty for each TERM we compiled in, then checks the
# screen for the header htop always draws. An unknown TERM is expected to fail
# cleanly rather than hang.
#
#   ./test-device.sh [path-to-htop]
#
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:-$TOP/dist/arm64-v8a/htop}"
REMOTE="${REMOTE:-/data/local/tmp/htop}"
TERMS="${TERMS:-xterm-256color screen tmux-256color linux vt100}"

[ -f "$BIN" ] || { echo "no binary at $BIN (run ./build.sh first)" >&2; exit 1; }

abi="$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
echo "device abi: $abi"

adb push "$BIN" "$REMOTE" >/dev/null
adb shell chmod 755 "$REMOTE"

echo "--- $REMOTE --version"
adb shell "$REMOTE --version"

drive() { # drive <TERM> -- run htop in a pty, send q, print the screen
  python3 - "$1" "$REMOTE" <<'PY'
import fcntl, os, pty, select, struct, sys, termios, time
term, remote = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("adb", ["adb", "shell", "-t", "-t",
                      f"TERM={term} HOME=/data/local/tmp {remote}"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
buf, t0, sent = b"", time.time(), False
while time.time() - t0 < 10:
    if select.select([fd], [], [], 0.5)[0]:
        try:
            d = os.read(fd, 65536)
        except OSError:
            break
        if not d:
            break
        buf += d
    if not sent and time.time() - t0 > 3:
        os.write(fd, b"q")
        sent = True
os.waitpid(pid, os.WNOHANG)
sys.stdout.buffer.write(buf)
PY
}

fail=0
for t in $TERMS; do
  out="$(drive "$t" | tr -d '\r')"
  if grep -q 'Load average' <<<"$out" && grep -q 'F10' <<<"$out"; then
    echo "ok    TERM=$t ($(wc -c <<<"$out") bytes drawn)"
  else
    echo "FAIL  TERM=$t"
    sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' <<<"$out" | head -5
    fail=1
  fi
done

# "dumb" has no cursor addressing, so the screen comes out scrambled; all we
# want to know is that ncurses came up and htop drew its function-key bar.
out="$(drive dumb | tr -d '\r')"
if grep -q 'F10' <<<"$out"; then
  echo "ok    TERM=dumb (initialized)"
else
  echo "FAIL  TERM=dumb"
  fail=1
fi

# A terminal we did not compile in must fail fast, not hang.
out="$(adb shell -t -t "TERM=no-such-term timeout 5 $REMOTE" 2>&1 || true)"
if grep -q 'cannot initialize terminal' <<<"$out"; then
  echo "ok    TERM=no-such-term rejected cleanly"
else
  echo "FAIL  TERM=no-such-term did not fail cleanly"
  fail=1
fi

exit "$fail"
