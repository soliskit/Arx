"""Transport checks against the Foundation-only worker fixture, never native app."""
import json
import subprocess
import sys
import time

binary = sys.argv[1]
assert binary.endswith("/local-worker-fixture")
count = 0


def check(data, code):
    global count
    result = subprocess.run([binary], input=data, capture_output=True, timeout=15)
    assert result.returncode == code, (result.returncode, code, result.stderr)
    assert len(result.stdout) <= 2048 and not result.stderr
    count += 1
    return result


for data in [b"", b"{", b"[]", b"x" * 4097, b'{"action":"wrong"}']:
    check(data, 64)
check(b'{"action":"labels"}', 69)
scope = {"action": "read", "scratchConfirmed": "yes", "sourceID": "fixture-source", "listID": "fixture-list", "reminderID": "fixture-item", "expectedSection": "Fixture section"}
for key in scope:
    for bad in [None, "", [], 42, "x" * 257]:
        check(json.dumps({**scope, key: bad}).encode(), 64)
result = check(json.dumps(scope).encode(), 69)
assert json.loads(result.stdout) == {"state": "unknown", "reason": "fixture_no_provider"}
locate = {key: value for key, value in scope.items() if key not in ["reminderID", "expectedSection"]}
locate["action"] = "locate"
check(json.dumps(locate).encode(), 69)
started = time.monotonic()
process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    process.wait(timeout=15)
    assert process.returncode == 124 and 8 <= time.monotonic() - started <= 14
    assert process.stdout.read() == b"" and process.stderr.read() == b""
    count += 1
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    process.stdin.close()
print(f"Local worker fixture transport checks: {count} PASS")
