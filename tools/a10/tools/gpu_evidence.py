#!/usr/bin/env python3
"""Offline decoding/checking of gpu-001 fault, trace and serial captures.

These checks establish only the recorded terminate-only milestone, not shaders
or acceleration. No serial port, device access, or third-party modules are used.
"""

import argparse
import json
from pathlib import Path
import re
import struct


def decode_fault(value):
    if not 0 <= value < 1 << 64:
        raise ValueError("fault status must be an unsigned 64-bit value")
    return {
        "status": f"0x{value:016x}",
        "valid": bool(value & 1),
        "address": f"0x{(value >> 28) << 4:x}",
        "context": (value >> 20) & 0xff,
        "subblock": (value >> 12) & 0xff,
        "requestor": (value >> 6) & 0x3f,
        "level": (value >> 4) & 3,
        "access": "read" if value & 8 else "write",
        "type": (value >> 1) & 3,
    }


def read_trace(data):
    """Read the nonwrapped prefix of the 512 x 36-byte SKU debug ring.

    Current captures contain five pages: records plus unused padding. A wrapped
    ring needs its producer index, which these captures do not contain; reject
    it instead of guessing chronological order.
    """
    if len(data) < 512 * 36:
        raise ValueError("truncated trace: need at least 512 x 36 bytes")
    records = []
    saw_empty = False
    for slot in range(512):
        words = struct.unpack_from("<9I", data, slot * 36)
        if not any(words):
            saw_empty = True
            continue
        if saw_empty:
            raise ValueError("gapped or wrapped ring: producer-index capture required")
        if words[0] != 5:
            raise ValueError(f"unexpected record kind {words[0]} in slot {slot}")
        records.append({
            "slot": slot,
            "timestamp": words[1] | words[2] << 32,
            "event": words[7] & 0xffffff,
            "thread": words[7] >> 24,
            "args": list(words[3:7]),  # r2, r3, stack argument 0, stack argument 1
        })
    if not saw_empty:
        raise ValueError("full ring: producer-index capture required")
    if any(b["timestamp"] < a["timestamp"] for a, b in zip(records, records[1:])):
        raise ValueError("trace timestamps are not chronological")
    return records


def check_trace(records):
    """Find Start -> actual compute IRQ -> Finalize -> IRQ cleared -> host event."""
    cursor = 0
    matched = {}
    checks = [
        ("start", lambda r: r["event"] == 7),
        ("compute_irq", lambda r: r["event"] == 0x102
         and r["args"][0] == 3 and r["args"][1] & 0x80000000
         and r["args"][2] != 0xffffffff and r["args"][2] & 4),
        ("finalize", lambda r: r["event"] == 8),
        ("irq_cleared", lambda r: r["event"] == 0x103
         and r["args"][0] == 3 and r["args"][1] & 0x80000000
         and r["args"][2] == 0),
        ("host_completion", lambda r: r["event"] == 0xe and r["args"][0] == 1),
    ]
    for name, predicate in checks:
        for index in range(cursor, len(records)):
            if predicate(records[index]):
                matched[name] = records[index]["slot"]
                cursor = index + 1
                break
        else:
            raise ValueError(f"missing ordered trace milestone: {name}")
    return matched


def read_dump(log, heading, count):
    _, found, rest = log.partition(heading + "\n")
    if not found:
        raise ValueError(f"missing dump heading: {heading}")
    data = bytearray()
    for line in rest.splitlines():
        match = re.fullmatch(r"[0-9a-fA-F]{8}\s+(.*?)\s+\|.*\|", line)
        if not match:
            break
        data.extend(int(x, 16) for x in match[1].split() if re.fullmatch(r"[0-9a-fA-F]{2}", x))
        if len(data) >= count:
            return bytes(data[:count])
    raise ValueError(f"truncated dump after {heading}")


def validate(log, trace):
    log = log.replace("\r", "")
    exits = re.findall(r"^RUN_EXIT=(\d+)\s*$", log, re.MULTILINE)
    if exits != ["0"]:
        raise ValueError("expected exactly one successful RUN_EXIT=0")
    if not re.search(r"^0 /sys/kernel/debug/apple_gpu_iop/crashlog\s*$", log, re.MULTILINE):
        raise ValueError("missing zero crashlog size")
    stamps = struct.unpack("<2I", read_dump(log, "MODE=real, completion stamps:", 8))
    if stamps != (1, 1):
        raise ValueError(f"completion stamps are not both 1: {stamps}")
    queue = read_dump(log, "Compute scheduling entry:", 44)
    state = struct.unpack_from("<I", queue)[0]
    ip = struct.unpack_from("<I", queue, 28)[0]
    if state != 3 or ip != 0x144080:
        raise ValueError(f"queue not retired at expected End: state={state}, IP={ip:#x}")
    full_faults = re.findall(r"^0x([0-9a-fA-F]{16})\s*$", log, re.MULTILINE)
    if not full_faults or any(int(v, 16) for v in full_faults):
        raise ValueError("missing zero 64-bit fault readback, or a nonzero fault was captured")
    milestones = check_trace(read_trace(trace))
    return {
        "scope": "recorded terminate-only GPU completion; NOT USC shader execution or acceleration",
        "stamps": list(stamps),
        "queue_state": state,
        "microsequence_end": hex(ip),
        "mmu_fault": 0,
        "trace_slots": milestones,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    fault = sub.add_parser("fault", help="decode a complete 64-bit RGX+0xe150 value")
    fault.add_argument("value", type=lambda v: int(v, 0))
    trace = sub.add_parser("trace", help="decode a saved, nonwrapped SKU debug ring")
    trace.add_argument("path", type=Path)
    check = sub.add_parser("validate", help="check a serial log and its corresponding debug capture")
    check.add_argument("log", type=Path)
    check.add_argument("trace", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "fault":
            result = decode_fault(args.value)
        elif args.command == "trace":
            result = read_trace(args.path.read_bytes())
        else:
            result = validate(args.log.read_text(), args.trace.read_bytes())
    except (OSError, ValueError) as error:
        parser.exit(1, f"FAIL: {error}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
