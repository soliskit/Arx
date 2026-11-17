"""Foundation-only runner transport tests. Never point at the native executable."""
import json
import subprocess
import sys
import time

binary = sys.argv[1]
assert binary.endswith("/exact-runner-fixture"), "refuse native runner"
scope = {"sourceID": "fixture-source", "listID": "fixture-list", "reminderID": "fixture-item"}
payload = {"request": scope, "grant": {**scope, "read": True}}
count = 0


def check(data, code):
    global count
    result = subprocess.run([binary], input=data, capture_output=True, timeout=15)
    assert result.returncode == code, (result.returncode, code, result.stderr)
    assert len(result.stdout) <= 2048 and not result.stderr, result
    count += 1
    return result


check(b"", 64)
check(b"{", 64)
check(b"[]", 64)
check(b"x" * 4097, 64)
check(json.dumps({"request": scope, "grant": {**scope, "read": False}}).encode(), 77)
for key in scope:
    for invalid in [None, [], 7, "", "x" * 257, "wrong"]:
        altered = {**scope, key: invalid}
        check(json.dumps({"request": altered, "grant": {**scope, "read": True}}).encode(), 77)
result = check(json.dumps(payload).encode(), 69)
assert json.loads(result.stdout) == {"state": "unknown", "reason": "fixture_no_provider"}
# Keep stdin open: the process-wide limit must bound reads as well as the provider.
started = time.monotonic()
process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    process.wait(timeout=15)
    assert process.returncode == 124, process.returncode
    assert 8 <= time.monotonic() - started <= 14
    assert process.stdout.read() == b"" and process.stderr.read() == b""
    count += 1
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    process.stdin.close()
print(f"Bounded fixture runner checks: {count} PASS")
