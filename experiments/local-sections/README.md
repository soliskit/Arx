# Account-free local Sections experiment

Test-only branch; close PR unmerged. No production Arx change. Scope: one free hosted Mac run, normal Reminders/UI access, source types/counts, at most one temporary list and empty section, exact-object cleanup. No account sign-in, owner device/data, private SQLite, unrelated list search, reminder reads or moves, permission bypass, paid use or automatic repeat.

The experiment uses GitHub's documented fresh xcode-27 VM, not a claimed private store path. It opens the DEFAULT EventKit store. Public EKSource types are the account gate: zero sources, nonlocal/unknown sources, denied or unanswered normal permission requests all stop. Only source counts and boolean outcomes leave the process. It does not prove the default store is empty. Unknown account semantics must be treated as a blocker during review, not silently relaxed.

A new list uses a random synthetic marker and the returned EventKit calendar ID. The private fetch requires that exact returned ID already be a complete x-apple-reminderkit REMCDList URL. No UUID/string conversion, broad search or database lookup is attempted. The actual private object's ID and name must both match before creating one empty section. If EventKit does not return this form, the experiment will stop at mapping, clean the new list and report that Sections support remains unanswered.

Section save is attempted once. A fresh REMStore fetch checks its returned ID and synthetic name. Apple UI is launched only after the local-source gate, but no source-backed exact private-section UI route is currently known, so the code explicitly reports UI unverified rather than capturing unrelated sidebar content. Cleanup removes the verified empty section, verifies removal, then deletes the exact generated list and verifies absence. An uncertain write or exception stops without blind cleanup/retry; report unresolved cleanup. No persistence result implies iCloud sync or reminder membership support.

The regular build/browser/Mac-fixture workflow skips this experimental branch to avoid extra hosted runs. One separate PR job compiles gate tests and the probe, runs once, uploads only bounded structured evidence. No manual dispatch/retry or owner credentials. Failure comes back for review. No branch push occurs until independent exact review. All authored changes and before-push lint/hooks are checked locally; macOS compilation is necessarily part of the single hosted run and may be its stopping failure.

Sources:

- https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/use-github-hosted-runners
- https://support.apple.com/guide/reminders/manage-sections-in-reminder-lists-remn14bf0e77/mac
- https://raw.githubusercontent.com/viticci/remctl/main/remctl-private.m

The gate test exhaustively exercises all 64 creation/cleanup boolean combinations plus empty/oversized/mixed local-source arrays. It proves gating logic only, not macOS permissions or private framework behavior.
