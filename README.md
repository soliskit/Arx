# Arx

A Mac control panel for sharing selected Apple Reminders lists and actions with a paired browser. The HTML, CSS and JavaScript are bundled with the app. There is no separate hosted frontend.

## Status and boundaries

Automated qualification and acceptance on the owner's Mac and remote connection are still pending. Install by building in Xcode; no signed installer or App Store release is provided.

Apple grants full Reminders access. Arx's server enforces the selected-list and action grants. Each client starts with no grants; revoke and pair again to change an existing client's access. Moves need both lists granted and writable. Deletion needs its own grant and exact-title confirmation.

Reads show up to 100 reminders per page, with Previous/Next controls and no total list-size cap. EventKit fetches the selected list natively because it has no paged API; Arx retains identifiers and converts only one page to response snapshots. At most four reads run concurrently, one per client. Every page rechecks the session, grant and current list membership. External changes can shift pages; Refresh restarts from the beginning.

The listener binds to `127.0.0.1`. The HTTPS connector makes it remotely reachable; pairing authenticates clients. Cloudflare can process the proxied reminder traffic. An optional Cloudflare Access login is not configured by Arx. Verify the connector and authentication before enabling remote access.

Pairing secrets are single-use and expire after two minutes. Enter them privately in the browser, never a URL, chat, log or screenshot. Cookies are Secure, HttpOnly and SameSite=Strict. Sessions expire after 24 hours or 30 idle minutes; background checks count as activity. Stop or restart clears all grants and sessions. Revocation blocks new requests, not copies already seen or changes already saved.

The app requests Reminders only. It does not manage lists, install a service or prevent sleep. Tags, subtasks, attachments, assignments and Smart Lists are outside the supported interface. Email and file/URL-opening alarm actions are excluded.

## Build and local checks

Use the project's Xcode toolchain with Swift 6.2 or later. The app's deployment minimum remains macOS 27.2. The package's lower macOS library floor does not lower the app requirement. CI's explicit macOS 27.0 test override is for runner evidence only, not supported-OS certification.

Open `Arx.xcodeproj`, select the Mac scheme, and build/run on a supported Mac. Choose your own development signing identity if Xcode requires it. Do not disable App Sandbox or add capabilities to work around a permission error.

Hummingbird is pinned to 2.28.1 in `Package.swift`; commit the resolved graph. macOS uses system CryptoKit. Linux fixture qualification references the same resolved swift-crypto 5.1.1 package.

Node 26.13.0 is used only for development checks and browser tests. The Mac app runs a Swift/Hummingbird server that serves its bundled HTML, CSS and JavaScript; it does not need a Node server or separately hosted website.

Install the pinned checks and hooks in each checkout:

```sh
npm ci --ignore-scripts
bash scripts/install-linters.sh
swift package --disable-sandbox lefthook install
swift package --disable-sandbox lefthook validate
npm run lint
swift format lint --strict --recursive BridgeCore BridgeCoreTests BridgeFixtureServer Arx ArxTests ArxUITests Package.swift
swift test
```

The shell installer verifies pinned release hashes and keeps ShellCheck/actionlint in the ignored `.tools/bin` directory. No system install is needed. Hooks and the existing CI build job check authored browser files, scripts and workflow with the same rules. Dependencies, generated proof output and Xcode-managed files are excluded.

The fixture app mode is explicit and never constructs the EventKit adapter:

```sh
/path/to/Arx.app/Contents/MacOS/Arx --bridge-fixtures
```

`BridgeFixtureServer` and `scripts/browser-proof.mjs` exercise a loopback fixture through a temporary self-signed HTTPS proxy and a disposable browser profile. The certificate exceptions are confined to that proof process, not deployment instructions. No real Reminders or tunnel account is used. Native fixture screenshots cover wide, narrow, minimum-window and sidebar states. Inspect the actual images as well as check results.

## Owner setup

1. Run the native app. Read the permission explanation, then use **Connect Reminders**. The list inventory stays in the native app; it includes source labels and writability so you can choose deliberately.
2. For first acceptance, create two new empty scratch lists in Apple Reminders. Select only those lists in Arx. Do not select existing lists for the acceptance test.
3. Prepare a stable HTTPS connector you control. For Cloudflare, verify the actual account/domain, free configuration and an unused hostname. Do not overwrite DNS, repoint an existing site, change nameservers or buy anything as part of this setup. No temporary Quick Tunnel is the delivery route.
4. Install the standalone `cloudflared` executable matching the Mac architecture using Cloudflare's official download. Homebrew, sudo and background-service installation are not required for a foreground connector. Protect the tunnel token: anyone holding it can run a connector for that tunnel. Use a private prompt rather than placing the token in shell history or command arguments. Consult current Cloudflare instructions for token handling. Do not paste tokens into chat.
5. Enter the exact HTTPS origin and local port in Arx. Start the bridge and wait for **Listener running**. That confirms the local listener only, not remote connectivity.
6. Only after the app and configuration are qualified, map the intended hostname to the app's loopback HTTP port in the connector. Do not create SSH, SMB, RDP, bastion or private-network routes for this app. Verify the hostname is unused before creating DNS. Consider a separate Cloudflare Access identity gate before publishing, and verify any chosen gate with the intended client rather than assuming compatibility.
7. Choose the client's lists/actions, create a pairing secret and enter it privately on the HTTPS browser page. Never publish that secret in evidence. Read-only provider lists remain read-only even with a change grant.

The Mac must stay awake, online, with Arx and the foreground connector running. Sleep, quitting or losing connectivity interrupts access. There is no automatic sleep change or background service.

## Scratch-list acceptance

Using only the two new empty lists, create **Arx connection test** through the bridge; edit its supported fields; move it to the other granted list; complete and reopen it; and delete only test reminders created by the bridge and clearly identifiable recurrence instances they generated. Verify cleanup, then revoke the client. Do not delete either list or inspect unrelated reminder contents. Do not test notification/geofence delivery or open URLs/files. An ambiguous result stops the test, not wider cleanup.

Check unshared identifiers, read-only lists, grant removal/revocation, refresh after external edits, permission loss and stop-sharing behavior. Actual alarm delivery, recurrence-provider behavior and account limits must be recorded separately if not verified.

## Conflicts and uncertain results

Before saving, Arx compares the client's displayed original values with a fresh store snapshot. A detected mismatch requires refresh and review. EventKit has no atomic compare-and-swap for these saves: iCloud or another app can still change an item after comparison. Review changes in Reminders when a concurrent edit is possible.

Missing/stale identifiers fail closed. The app never reconnects an old grant or pending edit by a matching name. Unchanged unsupported recurrence/alarm state is preserved rather than silently simplified. Unsupported edits fail with an error.

Mutation operation IDs limit duplicate application within a session. Do not blindly repeat an uncertain create/delete with a new ID. Refresh and inspect the actual result in Reminders first.

## Stop and revoke

- **Revoke** removes one client's grant/session.
- **Stop all sharing** immediately clears all grants/sessions and begins listener shutdown. Start stays disabled as **Stopping listener** until teardown finishes. The next start uses the same loopback port without restoring old clients. A second active listener must still be refused.
- Control-C stops the foreground connector. That does not revoke the app's macOS permission.
- Remove a route separately if you no longer want that hostname mapped. Stopping the connector does not delete DNS.
- Revoke Reminders access separately in macOS privacy settings if desired.
- For a compromised tunnel token, Cloudflare requires token rotation and disconnection of existing connectors; rotation alone leaves already connected replicas active. Do not rotate or disconnect unrelated connectors without checking their use.

## Sources

- [Apple EventKit access](https://developer.apple.com/documentation/eventkit/accessing-the-event-store.md)
- [Cloudflare Tunnel setup](https://developers.cloudflare.com/tunnel/get-started/)
- [Cloudflare token handling](https://developers.cloudflare.com/tunnel/reference/tunnel-tokens/)
- [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/self-hosted-public-app/)
- [Cloudflare HTTP privacy](https://developers.cloudflare.com/data-localization/regional-services/http-requests/)
