# Sections reader preparation

An isolated, test-only candidate for reading one reminder's section membership.
It is not part of Arx's package, Xcode target, UI, API or permission flow. This
experiment must remain unmerged. It adds no dependency, entitlement or write API.

## What the preparation checks

- Exact selected-list grant and read permission before a provider session opens.
- Strict UUID or exact `x-apple-reminderkit://<entity>/<UUID>` identifiers. No name
  search, enumeration, query/fragment aliases or unrelated-list fallback.
- List ID and name, reminder ID and title, reminder parent list, and section
  parent list. Matching names alone never establish identity.
- A fresh read session per request, fixed output fields and an Objective-C
  exception boundary. Exceptions return `unknown`; private exception text is not
  included in output. This cannot recover native crashes, hangs or process aborts.
- Runtime method existence, argument count, object-return and object/error-pointer
  argument types before invoking each candidate selector.

The injected provider contract can represent `section`, `none` and `unknown`.
Only a provider with independently proved semantics may assert `none`. The native
candidate **never returns `none`**: a nil membership, including nil without an
error, remains `unknown`. No fixture proves that a real reminder is unsectioned.

## Safe tests

The workflow compiles the native candidate to an object file but never executes
it. A second build defines `ARX_SECTION_READER_FIXTURES`, which disables the native
store factory. The executable uses only in-memory synthetic objects, including
objects that mimic the guarded Objective-C selectors. It neither loads ReminderKit
nor opens a Reminders store or asks for permission. The fixture executable has no
code path that constructs a real store.

Run the portable guards on Linux or macOS:

```sh
cc -std=c11 -Wall -Wextra -Werror experiments/sections-reader/gates-test.c -o /tmp/section-gates
/tmp/section-gates
```

On a Mac, the workflow's two compilation steps check the native source and run
synthetic fixtures. Do not add a real-store runner or invoke
`ARXPrivateSectionReadProvider.newReadSession` as part of preparation.

Fixtures cover denied/malformed requests before provider access, exact grant
strings, wrong IDs/names/titles/parents, fresh sessions, positive section and
synthetic-only none, nil/error/exception results, absent selectors and an invalid
Objective-C return ABI. The C test exhausts the boolean gate combinations.

## What remains unproved

Compilation and synthetic tests do not establish availability, data semantics,
permissions, sandbox behavior, stable IDs, real section membership or persistence
on any Mac. The native candidate's factory would open the default private store
if deliberately invoked outside the fixture build. No executable entry point is
provided for doing that, and preparation does not authorize doing it.

EventKit and ReminderKit IDs may differ. The roundtrip ID/name/parent checks are
fail-closed guards, not proof that the two namespaces identify the same objects.
A future real-provider test must separately bind the selected list and reminder
(including account consistency), qualify the returned section's entity/parent,
and establish nil/unsectioned semantics. Account identity is not asserted here.
The selected-list grant is supplied by a synthetic caller, not integrated with
Arx's actual authorization system. Passing these tests cannot qualify a feature
for shipping. A sandboxed, scoped, separately approved native read and stronger
identity evidence remain gates. Any write or assignment needs separate evidence
and authorization. This candidate cannot assign, rename, delete or move anything.

## Candidate sources

- [RemCTL private bridge](https://raw.githubusercontent.com/viticci/remctl/main/remctl-private.m): `REMObjectID.objectIDWithURL:` and exact store fetch route; not proof of ID equivalence.
- [RemCTL EventKit bridge](https://raw.githubusercontent.com/viticci/remctl/main/remctl-bridge.swift): ID divergence and a name fallback this candidate deliberately does not use.
- [Existing metadata investigation](https://github.com/soliskit/Arx/pull/9): membership selector metadata was present on the inspected Mac. Metadata alone does not establish safe invocation or semantics.

No application behavior changes in this experiment.
