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
its own 10-second deadline. The membership deadline starts on Run, not during
interactive setup. There are no worker retries. Input is limited to 4096 bytes;
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
6. Return only the copyable sanitized report: OS/build, status, requested step, fixed reason and whether
   the expected section matched. No IDs, titles, account labels, raw worker output,
   private logs or unrelated screenshots. A match is candidate positive evidence
   on this machine/build, not proof of transaction isolation or shipping quality.
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
The returned report contains only sanitized status fields and a match boolean,
never the section ID/name. The requested step is labels, selection or read. It
identifies the operation requested by the UI, NOT proof a membership call began.
The copyable report and status line use a closed reason vocabulary. Unknown
worker reasons are never displayed. The worker preserves only allowlisted native
refusals and distinguishes a validated section-name mismatch from unavailable
membership. A timeout, crash or malformed result means read invocation is unknown;
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
oversized output, the 10-second parent deadline and single-launch behavior, plus
one same-app fixture-worker smoke. A child that exits at its own deadline (124)
is reported with the fixed `timeout` reason instead of generic
`worker_unavailable`. The special workflow compiles
ExactReader/Worker with `ARX_SECTION_READER_FIXTURES=1`, links Foundation only and
runs synthetic identity and transport tests. That macro compiles out all native
EventKit/provider paths. No hosted step invokes a real Sections provider.

The portable C gates are inherited synthetic helpers; name/title Boolean helpers
are not used by the native ExactReader. No successful fixture result establishes
native membership, sandbox access or unsectioned semantics.
