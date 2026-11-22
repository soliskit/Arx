"""Proposed hosted compile receipt checks. Never launches app or helper."""
from pathlib import Path
import re
import subprocess
import sys

mode, derived = sys.argv[1:]
if mode not in ("attributed", "ordinary"):
    raise ValueError("unknown qualification mode")
headers = list(Path(derived).glob("**/ArxSectionsBuildStamp.h"))
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
