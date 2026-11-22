"""Proposed hosted compile receipt checks. Never launches app or helper."""
from pathlib import Path
import json
import re
import subprocess
import sys


def emit_observation(label, record):
    try:
        print(label + json.dumps(record, sort_keys=True), flush=True)
    except OSError:
        # New diagnostic output cannot replace the original verification result.
        pass


mode, derived = sys.argv[1:]
if mode not in ("attributed", "ordinary"):
    raise ValueError("unknown qualification mode")
headers = list(Path(derived).glob("**/ArxSectionsBuildStamp.h"))
emit_observation("Sections stamp header scan: ", {"mode": mode, "count": len(headers)})
if len(headers) != 2:
    raise ValueError("expected exactly app and helper generated headers")
expected_revision = subprocess.run(
    ["/usr/bin/git", "rev-parse", "--verify", "HEAD"],
    check=True, capture_output=True, timeout=5,
).stdout.decode().strip()
observed = []
for header in headers:
    if header.stat().st_size > 4096:
        raise ValueError("stamp header exceeds bound")
    text = header.read_text()
    revision = re.search(r'^#define ARX_SECTIONS_SOURCE_REVISION @"([a-f0-9]*)"$', text, re.M)
    manifest = re.search(r'^#define ARX_SECTIONS_SOURCE_MANIFEST @"([a-f0-9]*)"$', text, re.M)
    required = re.search(r'^#define ARX_SECTIONS_REQUIRES_ATTRIBUTION ([01])$', text, re.M)
    # Only bounded hex/bit fields, never the header body or path.
    receipt = {"slot": len(observed) + 1,
               "target": {"Arx.build": "app", "ArxSectionsWorker.build": "helper"}.get(
                   header.parent.parent.name, "other"),
               "expected_revision": expected_revision if re.fullmatch(
                   r"[a-f0-9]{40}", expected_revision) else "invalid",
               "revision": revision[1] if revision and len(revision[1]) <= 40 else None,
               "revision_length": len(revision[1]) if revision else None,
               "manifest": manifest[1] if manifest and len(manifest[1]) <= 64 else None,
               "manifest_length": len(manifest[1]) if manifest else None,
               "required": required[1] if required else None}
    emit_observation("Sections stamp header observation: ", receipt)
    if not all((revision, manifest, required)):
        raise ValueError("missing generated stamp field")
    values = (revision[1], manifest[1], required[1])
    if mode == "attributed":
        if values[0] != expected_revision or len(values[1]) != 64 or values[2] != "1":
            raise ValueError("attributed build did not produce expected source stamp")
    elif values != ("", "", "0"):
        raise ValueError("ordinary build unexpectedly requires attribution")
    observed.append(values)
if observed[0] != observed[1]:
    raise ValueError("app and helper compiled-source headers differ")
print("Generated-header compile receipt:", mode, "two matching headers", observed[0])
print("No app/helper execution or native membership assertion")
