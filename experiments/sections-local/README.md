# Local Sections read proof

An isolated, unmerged experiment. This does not ship Sections or qualify private
API behavior. The normal Arx interface is unchanged unless an experiment launch
argument is present. No entitlement, signing identity, bundle identifier,
dependency, account, tunnel or permission setting is changed.

## Modes and safety boundaries

- `--sections-local-experiment`: local selection UI. It does NOT construct the
  normal BridgeViewModel, SharingController, listener or pairing UI. Sharing and
  the tunnel must remain off. It never requests Reminders permission.
- `--sections-local-worker`: bounded child entry point in the SAME app executable,
  before SwiftUI or normal model construction. It receives local JSON over a
  pipe, not a network request. It refuses missing existing full Reminders access.
  It never requests permission, starts a server, writes reminders or constructs
  a new private default store. An independently launched worker is NOT Arx client
  authorization; this experiment must never become a network endpoint. Combined
  with `--sections-local-fixtures`, it instead refuses with `fixture_no_provider`
  before any EventKit store, existing permission state or private provider is
  touched; hosted same-app smoke checks use only that mode.
- `--sections-local-fixtures`: visibly labeled synthetic UI. All results come
  from fixed model fixtures, with no child launch, EventKit store or private
  provider. `--sections-local-fixture-result` additionally previews the final
  sanitized result. Hosted screenshots use only these modes.

Each child has a process-wide 10-second alarm, and the parent kills its child at
its own 10-second deadline. That one parent deadline bounds everything that
waits on the child: the nonblocking input write, the run and the output drain;
launch itself is a single spawn call that refuses fast on a missing child. The
parent drains output while the child runs, so a full pipe can never stall the
writer into the deadline; bytes past the output bound are counted and
discarded. The worker emits fixed operation markers as complete raw lines
(`stage=<operation>.<before|after>`) in program order, always before the result
JSON. A marker proves only that execution REACHED that point, never that an
operation entered a private call or completed one. The parent validates the
lines as an in-order subsequence of the expected per-action sequence, strips
them, and composes a bounded interval phrase from the last complete line
(`during <phrase>` or `after <phrase>, before <next phrase>`); a partial line
at the end is treated as absent. Byte bounds fail closed: non-marker bytes are
limited to 16384, complete marker lines to 512, and the aggregate buffered
output to 16896 at all times; any excess is `output_too_large`, and an
out-of-order, duplicated or misplaced marker sequence is `output_undecodable`.
The exchange completes only when the output stream has closed and
the child has finished, so a descendant holding the child's output pipe open
ends the wait at the same deadline instead of blocking the parent. The
membership deadline starts on Run, not during interactive setup. There are no
worker retries. Input is limited to 4096 bytes;
section-read output to 2048 bytes. Local account/list labels have a separate
16384-byte/100-list bound and are never included in the copyable report. Timeout,
crash, permission refusal, mismatch, missing metadata or unknown ends the
experiment. No fallback to another identity, API, privilege or list occurs.

The child may be refused by the sandbox or TCC even with the same signed app
identity. That is a blocked experiment result, not permission to change signing,
reset TCC, add entitlements or launch an unsandboxed helper. Hosted compilation
and identical signing settings cannot prove that this path works on another Mac.

## Local selection and the one read

The owner prepares only disposable objects in Apple Reminders:

1. Keep browser access revoked, sharing stopped and the tunnel stopped. Close the
   normal Arx app. Use the existing signed Xcode project and current permissions;
   add only `--sections-local-experiment` to launch this experiment branch.
2. Ensure `Arx Test A` contains no real reminders. Create one temporary section
   with a unique name and one disposable reminder inside it. Do not recreate,
   edit or move any unrelated object. No test code writes these objects.
3. Load account/list labels, select the exact `Arx Test A`, and confirm it contains
   only this one temporary reminder. If duplicate Arx Test A list names exist,
   selection cannot proceed. No guess based on account or list names is allowed.
4. Locate fetches reminders from ONLY that selected exact EventKit calendar.
   Zero, multiple, wrong-parent or wrong-source results stop. It inspects and
   shows a reminder's ID/title only after exactly one row is present. Other lists'
   reminders are never fetched. Confirm that exact displayed reminder locally.
5. Enter the expected unique section name from Apple Reminders. Run ONE section
   read. The Run button is permanently disabled before launch. Do not relaunch
   the mode to retry a real read without a separate decision.
6. Return only the copyable sanitized report: OS/build, status, requested step,
   fixed reason with its bounded interval phrase, permission status token, the
   disposable test list/reminder names, the expected section name, the returned
   section name (verified in the selected test list and account; it may be a
   pre-existing section in that list), any allowlisted error domain/code or
   exception token, and whether the expected section matched. List names are
   read locally for the picker; reminders are fetched only from the selected
   test list. No unrelated reminder contents, raw Console logs, library
   statistics, saved log files or automatic clipboard copying. No IDs outside
   the disposable scope, unrelated names, raw worker output or unrelated
   screenshots. A match is candidate positive evidence on this machine/build,
   not proof of transaction isolation or shipping quality.
7. Delete only the owner-created reminder and temporary section in Apple
   Reminders, close the experiment, remove its launch argument and leave sharing
   and the tunnel stopped. The experiment PR closes unmerged.

A new permission prompt, unexpected object, wrong identity, zero/multiple rows,
unknown or mismatch stops the attempt. Do not change settings or broaden access.
This proof does not repeat CRUD, movement, completion, browser or layout tests.

## Identity and output

Exact EventKit source/list/reminder IDs come from local selection. The reader
extracts each exact EventKit object's `backingObject._remObject`, checks private
list/reminder entities, the reminder's parent and all account identities, and
uses the store associated with that exact reminder. It does not construct a
private UUID from an EventKit identifier or search by title. The list title is
only an additional scratch-scope restriction, not an identity mapping.

The private membership selector is guarded by argument/return ABI metadata.
After the read, provenance and parent/account identity are checked again. The
returned section must have a valid section ID and the exact bound parent/account.
Only then is its display name compared locally with the expected unique name.
The returned report contains sanitized status fields, the match boolean and,
under the owner's explicit approval for this diagnostic, the disposable-scope
names: the expected section name and the returned section name (verified in the
selected test list and account; it may be a pre-existing section in that list).
The section ID is never included. The requested step is labels, selection or read. It
identifies the operation requested by the UI, NOT proof a membership call began.
The copyable report and status line use a closed reason vocabulary. Unknown
worker reasons are never displayed. The worker preserves only allowlisted native
refusals and distinguishes a validated section-name mismatch from unavailable
membership. A failed identity check names its own fixed sub-reason (list,
account or title). Permission refusal carries a fixed status token; provider
errors carry an allowlisted domain token (or the fixed token `other`) with an
integer code; exceptions carry an allowlisted name token (or `other`). No raw
domain, exception text or free-text error crosses the stream. A timeout, crash
or malformed result means read invocation is unknown;
there is no checkpoint file, persistent log, extra provider call or retry.
Object binding refusals can occur before or after membership, and the fixed
reason does not distinguish those points. Membership-unverified includes nil,
provider error and invalid section metadata. API-unavailable includes missing
exact store or guarded view/selector. These are diagnostics, not new capability
claims. Synthetic checks cannot establish which failure occurs on an owner's Mac.

This diagnostic revision has no authority to run a second local experiment.
A separate owner decision is required before any further real step.
Nil is unknown, never unsectioned. There is no native `none` result and no write
or assignment path. Re-reading properties does not establish atomic freshness.

The exact-object backing route is secondary implementation evidence, not an
Apple stability contract:

- https://raw.githubusercontent.com/BRO3886/go-eventkit/main/reminders/bridge_darwin.m
- https://raw.githubusercontent.com/viticci/remctl/main/remctl-bridge.swift
- https://raw.githubusercontent.com/viticci/remctl/main/remctl-private.m
- https://developer.apple.com/documentation/eventkit/eksource/sourceidentifier
- https://developer.apple.com/documentation/eventkit/ekcalendar/calendaridentifier
- https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier
- https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMReminder.h
- https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMList.h
- https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMAccount.h
- https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMListSection.h
- https://raw.githubusercontent.com/MTACS/iOS-17-Runtime-Headers/main/PrivateFrameworks/ReminderKit.framework/REMBaseSection.h

RemCTL documents identifier divergence and a name fallback that this experiment
rejects. Published iOS headers are structural clues, not macOS qualification.
Private getters/layout/selectors/account semantics, sandbox/TCC and actual
membership still require the separately bounded real read. Absence of metadata
must remain unknown rather than prompting a guessed selector or broader access.

## Checks

Normal CI compiles the app and runs the existing package/native/browser checks.
The added model tests instantiate only fixture models. Hosted screenshots launch
only fixture UI, not the real experiment or worker. Hosted ArxTests also drive
the actual Swift parent transport against synthetic script children: input
delivery, accepted and refused exit statuses, signal death, malformed and
oversized output, launch failure, early stdin close, a large valid reply across
pipe capacity, a descendant holding the output pipe, the 10-second parent
deadline and single-launch behavior, the fixed marker protocol (interval
phrasing after a signal, in-order subsequence validation, marker-byte and
non-marker bounds, partial-line handling) plus
one same-app fixture-worker smoke. Every fixture script, directory and counter
file a test creates is removed when that test finishes. A child that exits at its own deadline (124)
is reported with the fixed `timeout` reason instead of generic
`worker_unavailable`. The special workflow compiles
ExactReader/Worker with `ARX_SECTION_READER_FIXTURES=1`, links Foundation only and
runs synthetic identity and transport tests. That macro compiles out all native
EventKit/provider paths. No hosted step invokes a real Sections provider.

The portable C gates are inherited synthetic helpers; name/title Boolean helpers
are not used by the native ExactReader. No successful fixture result establishes
native membership, sandbox access or unsectioned semantics.
