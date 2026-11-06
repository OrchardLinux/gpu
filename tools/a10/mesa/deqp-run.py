#!/usr/bin/env python3
"""Run a dEQP suite on the device from the Mac, one result line at a time.

    mesa/deqp-run.py run gles2 RESULTS.csv            # continues if RESULTS.csv exists
    mesa/deqp-run.py run gles3 RESULTS.csv --gles-override 3.0
    mesa/deqp-run.py run gles31 RESULTS.csv --gles-override 3.1 --filter functional.compute
    mesa/deqp-run.py summary RESULTS.csv [--depth 3]

Results live on the Mac, written and flushed per test, because a wedged GPU or
a panic takes the device's RAM with it. A test that crashes or stops producing
output is recorded and never run again, so a rerun after a reboot continues
behind it. A run checks the renderer at its start and the render node before every batch,
and stops with status 3 without them: Mesa would silently fall back to
software rendering, and the results would not be the GPU's. After a hang the GPU is probed (--health); if it does not answer the
run stops with exit status 3 and says a reboot is needed.

Exit status: 0 suite finished, 2 usage or setup problem, 3 reboot needed.

--gles-override: Zink only offers what the driver's features allow (ES 2.0 on
the A10 today). The override makes the context anyway, so the suite measures
what is missing. A result under an override is a gap list, not a conformance
result.

--device-cmd replaces how commands reach the device, to test this script
against another GL stack, e.g. --device-cmd 'podman exec -i NAME' (it must pass stdin).
"""

import argparse
import collections
import csv
import fnmatch
import os
import re
import selectors
import shlex
import signal
import subprocess
import sys
import time

SUITES = {
    # suite: (working directory, binary, case list)
    "gles2": ("gles2", "./deqp-gles2", "gles2-main.txt"),
    "gles3": ("gles3", "./deqp-gles3", "gles3-main.txt"),
    "gles31": ("gles31", "./deqp-gles31", "gles31-main.txt"),
    "khr-gles2": ("glcts", "./glcts", "gles2-khr-main.txt"),
    "khr-gles3": ("glcts", "./glcts", "gles3-khr-main.txt"),
    "khr-gles31": ("glcts", "./glcts", "gles31-khr-main.txt"),
}

DEQP_ARGS = [
    "--deqp-surface-width=256",
    "--deqp-surface-height=256",
    "--deqp-surface-type=pbuffer",
    "--deqp-visibility=hidden",
    "--deqp-log-images=disable",
    "--deqp-log-shader-sources=disable",
    "--deqp-log-filename=/dev/null",
    "--deqp-shadercache=disable",
]

DEVICE_LIST = "/tmp/deqp-batch.txt"
CASE_RE = re.compile(r"^Test case '([^']+)'\.\.")
# EGL surfaceless silently falls back to llvmpipe without a render node
NO_GPU = "deqp-run: no GPU render node"
GPU_CHECK = f"[ -e /dev/dri/renderD128 ] || {{ echo '{NO_GPU}'; exit 9; }}; "
RENDERER_CASES = {"gles2": "dEQP-GLES2.info.renderer", "gles3": "dEQP-GLES3.info.renderer",
                  "gles31": "dEQP-GLES31.info.renderer"}
# dEQP's status line: two spaces, the status, its description in parentheses
STATUS_RE = re.compile(
    r"^\s+(Pass|Fail|NotSupported|QualityWarning|CompatibilityWarning|"
    r"InternalError|ResourceError|Crash|Timeout|Waiver|Pending)\s*\((.*)\)\s*$"
)


def read_done(path):
    done = {}
    if os.path.exists(path):
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                done[row["test"]] = row["status"]
    return done


def read_patterns(path):
    if not path:
        return []
    with open(path) as f:
        return [l.strip() for l in f if l.strip() and not l.startswith("#")]


class Device:
    def __init__(self, prefix):
        self.prefix = shlex.split(prefix)

    def argv(self, script):
        return self.prefix + ["sh", "-c", script]

    def run(self, script, timeout):
        """Output and exit status of a short command; None status if it did not answer."""
        try:
            p = subprocess.run(
                self.argv(script),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                timeout=timeout,
            )
            return p.stdout, p.returncode
        except subprocess.TimeoutExpired:
            return "", None

    def write(self, path, text, timeout):
        """Whether text arrived in the file at path."""
        try:
            p = subprocess.run(
                self.argv(f"cat > {path}"),
                input=text.encode(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=timeout,
            )
            return p.returncode == 0
        except subprocess.TimeoutExpired:
            return False


def chroot_script(device_root, workdir, command, env, chroot):
    exports = " ".join(f"{k}={shlex.quote(v)}" for k, v in env.items())
    inner = f"export {exports}; cd {shlex.quote(os.path.join(device_root, workdir))} && {command}"
    if chroot:
        return f"chroot {shlex.quote(chroot)} sh -c {shlex.quote(inner)}"
    return inner


def run_batch(device, args, env, suite, batch, out, deadline_per_test):
    """Run the cases of batch. Returns (finished names, why it stopped, the test in flight)."""
    workdir, binary, _ = SUITES[suite]
    # The list goes over stdin: the device's SSH server resets the connection on
    # a long command. The device's timeout is only a last resort for a lost
    # connection: it covers the whole batch.
    path = shlex.quote(args.chroot + DEVICE_LIST)
    if not device.write(path, "\n".join(batch) + "\n", 60):
        return [], "exit", None, ["could not write the case list to the device"]
    deqp = " ".join(
        ["timeout -k 5", str(int(deadline_per_test * len(batch) + 60)), binary]
        + DEQP_ARGS
        + [f"--deqp-gl-config-name={args.gl_config}", f"--deqp-caselist-file={DEVICE_LIST}"]
    )
    script = chroot_script(
        args.device_root, workdir, ("" if args.software else GPU_CHECK) + deqp + " 2>&1", env, args.chroot
    )

    proc = subprocess.Popen(
        device.argv(script),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
        start_new_session=True,
    )
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)

    finished, current, started, buf = [], None, time.monotonic(), b""
    last_output = time.monotonic()
    why = "exit"
    tail = collections.deque(maxlen=30)

    def line(text):
        nonlocal current, started
        tail.append(text)
        m = CASE_RE.match(text)
        if m:
            current, started = m.group(1), time.monotonic()
            return
        m = STATUS_RE.match(text)
        if m and current:
            out(current, m.group(1), m.group(2), time.monotonic() - started)
            finished.append(current)
            current = None
            return
        if args.verbose:
            print("  " + text, flush=True)

    while True:
        events = sel.select(timeout=1.0)
        if events:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            last_output = time.monotonic()
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for raw in lines:
                text = raw.decode("utf-8", "replace").rstrip("\r")
                line(text)
                # The context is gone: every later test of this process would fail
                if "VK_ERROR_DEVICE_LOST" in text:
                    why = "hang"
                # EGL's silent fallback: results from here on would be llvmpipe's
                if NO_GPU in text:
                    why = "software"
            if why in ("hang", "software"):
                break
        elif time.monotonic() - last_output > deadline_per_test:
            why = "hang"
            break

    if why in ("hang", "software"):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        # Killing our end leaves dEQP alive on the device, holding its GPU
        # memory: about 40 MB per hang until the device ran out (2026-11-05)
        device.run(f"pkill -9 {shlex.quote(os.path.basename(binary)[:15])}", 30)
    try:
        code = proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        code = None
    if why == "exit" and code not in (0, None) and len(finished) < len(batch):
        why = f"exit {code}"
    return finished, why, current, tail


def cmd_run(args):
    caselist = SUITES[args.suite][2]
    list_file = os.path.join(args.deqp_dir, "mustpass", caselist)
    if not os.path.exists(list_file):
        print(f"no case list {list_file}: run mesa/build-deqp.sh first", file=sys.stderr)
        return 2
    with open(list_file) as f:
        cases = [l.strip() for l in f if l.strip() and not l.startswith("#")]
    if args.filter:
        rx = re.compile(args.filter)
        cases = [c for c in cases if rx.search(c)]
    skips = read_patterns(args.skip_file)
    done = read_done(args.results)
    todo = [
        c for c in cases if c not in done and not any(fnmatch.fnmatchcase(c, p) for p in skips)
    ]
    print(
        f"{args.suite}: {len(cases)} cases, {len(done)} already in {args.results}, "
        f"{len(todo)} to run",
        flush=True,
    )
    if not todo:
        return 0

    env = {
        "PVR_I_WANT_A_BROKEN_VULKAN_DRIVER": "1",
        "EGL_PLATFORM": "surfaceless",
        "MESA_SHADER_CACHE_DISABLE": "true",
        "HOME": "/root",
    }
    if not args.software:
        env["MESA_LOADER_DRIVER_OVERRIDE"] = "zink"
        # Zink's render pass tracking for tilers: without it, split renders
        # reload depth and stencil, which is broken on the A10 (2026-11-05)
        env["ZINK_DEBUG"] = "rp"
    else:
        env["LIBGL_ALWAYS_SOFTWARE"] = "1"
    if args.gles_override:
        env["MESA_GLES_VERSION_OVERRIDE"] = args.gles_override

    device = Device(args.device_cmd)
    if not args.software and args.suite in RENDERER_CASES:
        workdir, binary, _ = SUITES[args.suite]
        qpa = "/tmp/deqp-renderer.qpa"
        probe = chroot_script(
            args.device_root,
            workdir,
            f"{binary} --deqp-case={RENDERER_CASES[args.suite]} --deqp-surface-type=pbuffer "
            f"--deqp-surface-width=64 --deqp-surface-height=64 --deqp-log-filename={qpa} "
            f"--deqp-gl-config-name={args.gl_config} >/dev/null 2>&1; grep -a 'zink\\|llvmpipe' {qpa}",
            env,
            args.chroot,
        )
        text, _ = device.run(probe, 60)
        if "llvmpipe" in text or "PowerVR" not in text:
            print(f"Not rendering on the GPU: {text.strip() or 'no renderer reported'}", flush=True)
            return 3
    new = not os.path.exists(args.results)
    results = open(args.results, "a", newline="")
    writer = csv.writer(results)
    if new:
        writer.writerow(["test", "status", "detail", "seconds", "gles_override", "time"])

    stats = collections.Counter()

    def out(test, status, detail, secs):
        writer.writerow(
            [test, status, detail[:200], f"{secs:.2f}", args.gles_override or "",
             time.strftime("%H:%M:%S")]
        )
        results.flush()
        os.fsync(results.fileno())
        stats[status] += 1
        n = sum(stats.values())
        if status not in ("Pass", "NotSupported") and not args.quiet:
            print(f"  {status}: {test}", flush=True)
        if n % 200 == 0:
            print(f"[{n}/{total}] {dict(stats)}", flush=True)

    i = 0
    stalled = 0
    total = len(todo)  # stopped batches take their finished cases out of todo
    while i < len(todo):
        batch = todo[i : i + args.batch]
        finished, why, current, tail = run_batch(device, args, env, args.suite, batch, out, args.timeout)
        finished_set = set(finished)
        remaining = [c for c in batch if c not in finished_set]

        if why == "software":
            print(
                "No GPU render node: Mesa would fall back to software rendering, and the "
                "results would not be the GPU's. Load the GPU driver "
                "(modprobe powervr exp_hw_support=1) and rerun the same command.",
                flush=True,
            )
            results.close()
            return 3

        if why == "exit" and not remaining:
            i += len(batch)
            stalled = 0
            continue

        # A device that no longer answers: only a test in flight is to blame
        answered = device.run("true", 30)[1] == 0
        if not answered:
            if current:
                out(current, "DeviceLost", why, 0.0)
            print(
                f"The device does not answer (in {current or 'no test'}). Reboot, set up the "
                "device again and rerun the same command: it continues behind this test.",
                flush=True,
            )
            results.close()
            return 3

        # Never ran a single case, batch after batch: the suite cannot start at all
        stalled = 0 if finished or current else stalled + 1
        if stalled >= 3:
            print("dEQP does not start a test. Its last output:", flush=True)
            print("\n".join(tail), flush=True)
            results.close()
            return 2

        # The batch stopped early. What it stopped in gets a result of its own.
        # If dEQP died before printing a case name, the next unrun case is it.
        if not remaining:
            # All of the batch ran; dEQP itself did not end. No test to blame.
            print(f"dEQP did not exit cleanly after its batch: {why}", flush=True)
            i += len(batch)
            stalled = 0
            continue
        culprit = current or remaining[0]
        if stalled:
            pass  # retried: may be the setup rather than this case
        elif why == "exit" and not current:
            out(culprit, "NotRun", "dEQP exited without running this case", 0.0)
            remaining.remove(culprit)
        else:
            out(culprit, "Hang" if why == "hang" else "Crash", why,
                args.timeout if why == "hang" else 0.0)
            remaining.remove(culprit)
        todo[i : i + len(batch)] = remaining

        if why == "hang" or args.health_always:
            text, code = device.run(args.health, 90)
            print(f"health after {culprit}: status {code}", flush=True)
            if code != 0:
                print(text[-2000:], flush=True)
                print(
                    f"The GPU does not answer after {culprit}. Reboot, set up the device again "
                    "and rerun the same command: it continues behind this test.",
                    flush=True,
                )
                results.close()
                return 3

    results.close()
    print(f"done: {dict(stats)}", flush=True)
    return 0


def cmd_summary(args):
    rows = list(csv.DictReader(open(args.results, newline="")))
    total = collections.Counter(r["status"] for r in rows)
    print(f"{len(rows)} results: " + ", ".join(f"{k} {v}" for k, v in total.most_common()))
    overrides = {r.get("gles_override") for r in rows} - {"", None}
    if overrides:
        print(f"Under a version override ({', '.join(sorted(overrides))}): a gap list, not conformance.")
    groups = collections.defaultdict(collections.Counter)
    for r in rows:
        groups[".".join(r["test"].split(".")[: args.depth])][r["status"]] += 1
    print(f"{'group':<58} {'pass':>6} {'fail':>6} {'hang':>5} {'crash':>5} {'n/s':>6}")
    for g in sorted(groups):
        c = groups[g]
        bad = sum(v for k, v in c.items() if k not in ("Pass", "NotSupported", "Hang", "Crash"))
        print(f"{g:<58} {c['Pass']:>6} {bad:>6} {c['Hang']:>5} {c['Crash']:>5} {c['NotSupported']:>6}")
    details = collections.Counter(
        r["detail"] for r in rows if r["status"] not in ("Pass", "NotSupported")
    )
    if details:
        print("\nMost common failure reasons:")
        for d, n in details.most_common(args.reasons):
            print(f"{n:>7}  {d}")
    return 0


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("suite", choices=sorted(SUITES))
    r.add_argument("results")
    r.add_argument("--deqp-dir", default=os.path.join(here, "..", "out", "deqp"))
    r.add_argument("--device-cmd", default="orchard exec --")
    r.add_argument("--device-root", default="/home/tablet/deqp", help="the suites' directory, seen from the chroot if there is one")
    r.add_argument("--chroot", default="", help="run inside this chroot; default: the installed system directly")
    r.add_argument(
        "--gl-config",
        default="rgba8888d24s8ms0",
        help="the EGL config dEQP renders to",
    )
    r.add_argument("--filter", help="regular expression on the case name")
    r.add_argument("--skip-file", help="file of fnmatch patterns to leave out")
    r.add_argument("--gles-override", choices=["3.0", "3.1"])
    r.add_argument("--batch", type=int, default=500)
    r.add_argument("--timeout", type=float, default=60.0, help="seconds without output that count as a hang")
    r.add_argument(
        "--health",
        default="PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 timeout -k 5 30 /home/tablet/deqp/vk-tri",
        help="command that exits 0 when the GPU still renders",
    )
    r.add_argument("--health-always", action="store_true", help="also probe after a crash")
    r.add_argument("--software", action="store_true", help="llvmpipe, to test this script")
    r.add_argument("--quiet", action="store_true", help="no line per failure")
    r.add_argument("--verbose", action="store_true", help="print dEQP's other output")
    r.set_defaults(func=cmd_run)
    s = sub.add_parser("summary")
    s.add_argument("results")
    s.add_argument("--depth", type=int, default=3)
    s.add_argument("--reasons", type=int, default=20)
    s.set_defaults(func=cmd_summary)
    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
