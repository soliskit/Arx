"""Transport checks against the Foundation-only worker fixture, never native app."""
import json
import subprocess
import sys
import time

binary = sys.argv[1]
assert binary.endswith("/local-worker-fixture")
count = 0

# The worker now emits fixed stage markers as raw lines before the result JSON.
# A marker proves only that execution REACHED that point.
INPUT_BEFORE = b"stage=input.read.before\n"
INPUT_AFTER = b"stage=input.read.after\n"
ENCODE_BEFORE = b"stage=reply.encode.before\n"
ENCODE_AFTER = b"stage=reply.encode.after\n"


def check(data, code):
    global count
    result = subprocess.run([binary], input=data, capture_output=True, timeout=15)
    assert result.returncode == code, (result.returncode, code, result.stderr)
    assert len(result.stdout) <= 2048 and not result.stderr
    count += 1
    return result


# Malformed or refused input dies after only the input.read.before marker.
for data in [b"", b"{", b"[]", b"x" * 4097, b'{"action":"wrong"}']:
    result = check(data, 64)
    assert result.stdout == INPUT_BEFORE, result.stdout
scope = {"action": "read", "scratchConfirmed": "yes", "sourceID": "fixture-source", "listID": "fixture-list", "reminderID": "fixture-item", "expectedSection": "Fixture section"}
for key in scope:
    for bad in [None, "", [], 42, "x" * 257]:
        result = check(json.dumps({**scope, key: bad}).encode(), 64)
        assert result.stdout == INPUT_BEFORE, result.stdout
# A complete run of the fixture emits the reached markers then the result JSON.
expected_prefix = INPUT_BEFORE + INPUT_AFTER + ENCODE_BEFORE + ENCODE_AFTER
fixture_reply = b'{"reason":"fixture_no_provider","state":"unknown"}'
result = check(b'{"action":"labels"}', 69)
assert result.stdout == expected_prefix + fixture_reply, result.stdout
result = check(json.dumps(scope).encode(), 69)
assert result.stdout == expected_prefix + fixture_reply, result.stdout
assert json.loads(result.stdout[len(expected_prefix):]) == {"state": "unknown", "reason": "fixture_no_provider"}
locate = {key: value for key, value in scope.items() if key not in ["reminderID", "expectedSection"]}
locate["action"] = "locate"
result = check(json.dumps(locate).encode(), 69)
assert result.stdout.startswith(expected_prefix), result.stdout
# Optional on the wire for fixture compatibility; production parent requires it.
nonce = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
for action in ["labels", "locate", "read"]:
    request = {**scope, "action": action, "requestNonce": nonce}
    result = check(json.dumps(request).encode(), 69)
    reply = json.loads(result.stdout[len(expected_prefix):])
    assert reply["requestNonce"] == nonce
for invalid in [42, "", "not-a-uuid", nonce.lower()]:
    result = check(json.dumps({**scope, "requestNonce": invalid}).encode(), 64)
    assert result.stdout == INPUT_BEFORE
started = time.monotonic()
process = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    process.wait(timeout=15)
    assert process.returncode == 124 and 8 <= time.monotonic() - started <= 14
    # The child dies at its own alarm after emitting only the first marker.
    assert process.stdout.read() == INPUT_BEFORE and process.stderr.read() == b""
    count += 1
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    process.stdin.close()
print(f"Local worker fixture transport checks: {count} PASS")
