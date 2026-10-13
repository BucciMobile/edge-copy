#!/usr/bin/env python3
"""Fails if pubspec.lock changed a version or removed a package vs. a base."""
import re, subprocess, sys

BASE = sys.argv[1] if len(sys.argv) > 1 else "origin/main"
# Only entries that integration_test legitimately adds.
ALLOWED_NEW = {"integration_test", "flutter_driver",
               "fuchsia_remote_debug_protocol", "process",
               "sync_http", "webdriver"}

def parse(text):
    pk, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^  ([A-Za-z0-9_.\-]+):\s*$", line)
        if m:
            cur = m.group(1)
            pk[cur] = None
            continue
        m = re.match(r'^    version: "?([^"\s]+)"?\s*$', line)
        if m and cur:
            pk[cur] = m.group(1)
    return pk

base = parse(subprocess.check_output(
    ["git", "show", f"{BASE}:pubspec.lock"], text=True))
head = parse(open("pubspec.lock").read())
changed = {k: (base[k], head[k]) for k in base
           if k in head and base[k] != head[k]}
removed = sorted(set(base) - set(head))
added = sorted(set(head) - set(base))
unexpected_added = sorted(set(added) - ALLOWED_NEW)
print("changed:", changed)
print("removed:", removed)
print("added:", added)
print("unexpected_added:", unexpected_added)
sys.exit(1 if (changed or removed or unexpected_added) else 0)
