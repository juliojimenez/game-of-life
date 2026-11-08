#!/usr/bin/env python3
"""Interactive smoke test for bin/life through a pseudo-terminal (DESIGN.md §5.10).

The suite cannot see a terminal, so this script gives the executable one: a pty of 80 columns by
24 rows that is the child's controlling terminal, so `stty size`, `stty -g` and the raw keyboard
work exactly as they do for a user. It checks the escape sequences the terminal UI must emit and
their order, the summary line printed after the alternate screen is left, that keys reach the
program (q quits an unbounded run, space pauses), and that the terminal is back in canonical,
echoing mode afterwards.

Usage: python3 tests/pty-smoke.py bin/life
Exit status 0 when every check passes, 1 otherwise. No dependencies beyond the standard library.
"""
import fcntl
import os
import select
import struct
import subprocess
import sys
import termios
import time

ESC = "\x1b"
ALT_ON, HIDE, HOME, SHOW, ALT_OFF = (ESC + "[?1049h", ESC + "[?25l", ESC + "[H",
                                     ESC + "[?25h", ESC + "[?1049l")

failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (("  " + detail) if detail and not ok else ""))
    if not ok:
        failures.append(label)


MARK = "@@pty-smoke stty -a@@"


def canonical_echo(stty_a):
    """True when the `stty -a` text shows icanon and echo on (no leading -). `stty -g` strings are
    not compared: on macOS the kernel sets the transient pendin flag when ICANON is turned back on,
    so they differ although every setting was restored (DESIGN.md §5.10)."""
    tokens = stty_a.replace(";", " ").split()
    return ("icanon" in tokens and "-icanon" not in tokens
            and "echo" in tokens and "-echo" not in tokens)


WRAPPER = 'exec 2>&1; "$0" "$@"; rc=$?; echo; echo "' + MARK + '"; stty -a; exit $rc'


def run(cmd, keys=(), timeout=60.0, rows=24, cols=80):
    """Run CMD under a fresh pty that is the child's controlling terminal. KEYS is a sequence of
    (delay_seconds, bytes) sent after the program has started. Returns (exit_code, output_text,
    stty_a_text): the last is `stty -a` run on the pty right after the program exits, from inside
    the session (macOS revokes the pty once the session leader is gone, so the parent cannot ask)."""
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def make_controlling():
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)   # fd 0 is the slave in the child

    proc = subprocess.Popen(["sh", "-c", WRAPPER] + list(cmd), stdin=slave, stdout=slave,
                            stderr=slave, start_new_session=True, preexec_fn=make_controlling,
                            close_fds=True)
    out = bytearray()
    start = time.time()
    pending = sorted(keys)
    deadline = start + timeout
    while True:
        now = time.time()
        while pending and now - start >= pending[0][0]:
            os.write(master, pending.pop(0)[1])
        ready, _, _ = select.select([master], [], [], 0.05)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                out += data
        if proc.poll() is not None:
            for _ in range(20):                      # drain what the child wrote last
                ready, _, _ = select.select([master], [], [], 0.1)
                if not ready:
                    break
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                out += data
            break
        if now > deadline:
            proc.kill()
            proc.wait()
            out += b"\n[pty-smoke: timeout]\n"
            break
    os.close(master)
    os.close(slave)
    text = out.decode("utf-8", "replace")
    program_output, found, stty_a = text.rpartition(MARK)
    if not found:
        program_output, stty_a = text, ""
    return proc.returncode, program_output, stty_a


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    life = sys.argv[1]

    # 1. A bounded run: every sequence, in order, then the summary after the alternate screen is left.
    rc, out, stty_a = run([life, "glider", "-g", "30", "-f", "200"])
    check("bounded run exits 0", rc == 0, f"rc={rc}")
    for name, seq in (("alt-screen on", ALT_ON), ("hide cursor", HIDE), ("home", HOME),
                      ("show cursor", SHOW), ("alt-screen off", ALT_OFF)):
        check(f"bounded run emits {name}", seq in out)
    if ALT_ON in out and ALT_OFF in out:
        check("alt-screen on comes before off", out.find(ALT_ON) < out.rfind(ALT_OFF))
        tail = out[out.rfind(ALT_OFF) + len(ALT_OFF):]
        check("summary printed after leaving the alternate screen",
              "Glider: generation 30, population 5" in tail, repr(tail[-200:]))
    check("status line shows the generation", "gen 30" in out)
    check("terminal back in canonical echoing mode (bounded run)", canonical_echo(stty_a),
          stty_a.strip()[:200])

    # 2. An unbounded run ends on q.
    rc, out, stty_a = run([life, "gosper-glider-gun", "-f", "30"], keys=[(1.5, b"q")], timeout=30)
    check("q quits an unbounded run (exit 0)", rc == 0, f"rc={rc}")
    check("quit summary", "(quit)" in out and "Gosper glider gun: generation" in out, repr(out[-300:]))
    check("terminal back in canonical echoing mode (after q)", canonical_echo(stty_a),
          stty_a.strip()[:200])

    # 3. Space pauses, then q quits.
    rc, out, stty_a = run([life, "blinker", "-f", "30"], keys=[(1.0, b" "), (2.0, b"q")], timeout=30)
    check("space pauses", "PAUSED" in out)
    check("q after pause exits 0", rc == 0, f"rc={rc}")

    # 4. A soup sized from the terminal: 80 columns, (24 - 1) * 2 rows in block style.
    rc, out, stty_a = run([life, "-s", "7", "-g", "5", "-f", "200"])
    check("soup run exits 0", rc == 0, f"rc={rc}")
    check("soup sized from the terminal", "soup 80x46 density 0.30 seed 7:" in out, repr(out[-300:]))

    # 5. ASCII style on request.
    rc, out, stty_a = run([life, "blinker", "--ascii", "-g", "1", "-f", "200"])
    check("--ascii draws with #", "###" in out and "█" not in out)

    print()
    if failures:
        print(f"{len(failures)} check(s) failed: " + ", ".join(failures))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
