# Exact-object Sections reader preparation

This isolated experiment is not part of Arx's package, Xcode target, UI, API or
permission flow. Keep it unmerged. It is preparation, not qualified Sections
support. No native reader is executed by this workflow.

## Change from the earlier guard scaffold

The earlier candidate constructed a private object ID from a supplied UUID and
checked the fetched object's identity and parent. Those checks did not prove
EventKit/private namespace equivalence or account identity.

This candidate does not convert EventKit IDs into private IDs. It takes the exact
selected EventKit calendar and reminder, checks their exact identifiers and
source against a one-object read grant, then extracts each object's private
backing object. The ephemeral binding consists of:

- the selected EventKit source, list and reminder IDs;
- the private list and reminder obtained from those exact objects, not fetched by
  a guessed identifier or name;
- the private account obtained from that selected list;
- the independently checked private reminder parent and account.

The binding must pass before constructing a Sections view or reading membership.
The binding is constructed by the reader, never supplied as a caller-asserted
`verified` flag. Names and titles do not establish identity. No list/account
search, enumeration, database access or fallback route exists here.

The native adapter guards method signatures, object ivar encodings and expected
backing classes. It uses the store belonging to the exact reminder, not a new
private default store. It checks the returned section's entity, list and account,
and checks provenance again around the membership call. Nil/error/exception or
missing metadata is `unknown`, never `none`. Fixed output contains only state,
a fixed reason and, for a candidate positive result, the section ID.

## Evidence and limits

[go-eventkit's bridge](https://raw.githubusercontent.com/BRO3886/go-eventkit/main/reminders/bridge_darwin.m)
contains exact `EKReminder` and `EKCalendar` extraction through
`backingObject._remObject`, class checks, and the reminder's `_store`/`store`
route. This is implementation evidence for a candidate, not Apple's guarantee
of stable object layout or proof on another Mac.

[RemCTL's EventKit bridge](https://raw.githubusercontent.com/viticci/remctl/main/remctl-bridge.swift)
explicitly notes EventKit/ReminderKit list-ID divergence and uses a name fallback.
This experiment deliberately does not use that fallback. A separate
[SQLite schema note](https://github.com/rex/mcp-apple-reminders/blob/main/docs/SQLITE_SCHEMA.md)
reports UUID equivalence on one machine; that narrower observation does not
establish a general mapping contract.

[Apple's sourceIdentifier](https://developer.apple.com/documentation/eventkit/eksource/sourceidentifier)
identifies an EventKit source, not a documented private account ID.
[calendarIdentifier](https://developer.apple.com/documentation/eventkit/ekcalendar/calendaridentifier)
is local and can be lost after a full sync.
[calendarItemExternalIdentifier](https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier)
can have duplicates and is not a substitute for exact account/list binding.

Published iOS runtime headers provide secondary structural evidence for
[REMReminder.list/account/remObjectID](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMReminder.h),
[REMList.account/remObjectID](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMList.h),
[REMAccount.remObjectID](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMAccount.h),
[REMListSection.list](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMListSection.h)
and its inherited
[REMBaseSection.remObjectID](https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMBaseSection.h).
They are not evidence that the same classes, selectors or semantics work on the
target macOS. The earlier metadata investigation in
[PR9](https://github.com/soliskit/Arx/pull/9) motivated the candidate membership
selector; this adapter refuses it when its method signature is unavailable.

Compilation and synthetic tests cannot prove the backing-object provenance,
account semantics, private call behavior, freshness, sandbox/TCC access or real
section membership. Re-reading properties is not transaction isolation. These
remain separately scoped runtime gates. A missing route or any uncertainty must
block the result, not trigger UUID guessing, broad search or more permissions.
There is no native `none` result and no assignment/write API.

## Bounded runner

`BoundedReader.m` prepares one process for one exact source/list/reminder read.
It accepts at most 4096 bytes of JSON on stdin, refuses missing or mismatched
scope before constructing an EventKit store, verifies the selected calendar's
source before fetching the requested reminder, and never requests permission.
It resolves only the exact selected IDs with EventKit lookup methods. Output is
at most 2048 bytes. A process-wide 10-second deadline includes stdin and native
calls. Exit 0 means a candidate section result; 69 means unknown; 64 malformed
input; 77 scope/permission refusal; 70/74 internal/output failure; 124 timeout.
Any crash, signal or nonzero exit means unknown, not no section. The deadline does
not make undocumented native code safe or establish membership semantics.

The stdin `grant` is a local experiment scope record, NOT authenticated Arx
client authorization. The runner is not a network service. It must not be wired
into Arx or run based on untrusted JSON. A future run needs separate exact-object
selection, owner authority, output/time limits and a trusted launch path. Merely
possessing this source or a compiled binary authorizes nothing.

The workflow compiles/signs the native binary with the current Arx entitlements
and verifies their exact equality, including app sandbox. It NEVER launches that
binary. Identical entitlements are preparation, not proof of equivalent app
identity, TCC permission, helper inheritance or successful sandbox access. No
entitlement is added. No dependency is added.

## Safe checks

The executable fixture builds define `ARX_SECTION_READER_FIXTURES`. They link
Foundation only. The exact-object fixture seam replaces private extraction and
store/view access with in-memory objects. The transport fixture replaces the
entire native EventKit/provider path with a fixed unknown result. Neither can
construct a real EventKit/private store or request permission.

Fixtures cover distinct EventKit/private namespaces, exact grants, wrong source,
wrong parent/account/entity, absent backing/store, changing provenance, missing
selector/wrong ABI, section outside the bound list/account, nil/error/exception,
sanitized output and recovery. Transport tests cover malformed/oversized input,
scope refusal, output bounds and a blocked-stdin timeout. These test the guards,
not Apple's implementation.

The native compile/sign step and synthetic executable steps must remain separate.
Do not turn a compile check into a real-store test, even on a fresh hosted Mac.
