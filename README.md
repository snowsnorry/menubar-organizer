# Menubar Organizer

Menubar Organizer is a native macOS menu bar utility for arranging status items and temporarily revealing hidden items. It provides a settings window in English and Russian, stores the layout locally, and includes a configurable reveal timer and login option.

The app currently targets macOS 27.0 and requires Xcode 27.0 with Command Line Tools to build. It has no network dependencies. Menu bar visibility uses a private system interface tested on build 26A428, so behavior on other builds is not established.

## Build and run

To build an application bundle without installing it:

```sh
./script/build_and_run.sh --app-build
```

To build, install in `/Applications`, and launch the app:

```sh
./script/build_and_run.sh --app
```

The install command replaces only an existing app with the same bundle ID. If you want to inspect the settings without reading or changing the actual menu bar or saved layout, build first and then run:

```sh
open -n dist/MenubarOrganizer.app --args --preview
```

To read and rearrange menu bar items, grant Menubar Organizer access in **System Settings → Privacy & Security → Accessibility**. Rebuilding with an ad hoc signature may require you to renew that permission. Set `SIGN_IDENTITY` to an available signing identity if you need a stable signature.

## Behavior and current limits

The settings window groups items as visible or hidden. Edits remain a draft until you press **OK**; **Cancel** or closing the window discards them. Reordering edits the system menu bar position table after **OK** or while restoring a saved layout at launch. Items can also be moved with the inspector controls. Missing apps keep their saved positions, while newly discovered apps remain visible.

At launch, the app restores the saved order before hiding saved hidden items. If access to the system position table is unavailable, it applies hiding and keeps the saved order for a later retry without opening a permission dialog during startup.

Clicking the `…` status item or pressing Command-Shift-H reveals hidden items; clicking it again hides them. The default inactivity interval is five seconds. Moving the pointer in the menu bar restarts the interval, while an open menu pauses it. Some menus do not send reliable accessibility notifications, so dismissal with Escape can leave items visible until the next click outside the menu bar.

After wake, an accepted visibility filter survives errors in subsequent discovery or ordering checks. These errors are reported without issuing a reveal command, and successful hiding completes automatic visibility recovery even when the diagnostic inventory is stale.

The private visibility interface is limited to the tested OS build. Some system items have only partial support: the Focus icon may disappear while a visibility filter is active, while VPN and Time Machine use a separate experimental backend. Their exact legacy bundle IDs are resolved through dynamically loaded `CoreMenuExtra` functions in ApplicationServices, and restored from matching `.menu` bundles in `/System/Library/CoreServices/Menu Extras`. SystemUIServer is never excluded from the assessment allow-list. Missing APIs, recovery bundles, or ambiguous AX identities prevent removal; remove errors or failed disappearance checks trigger restoration. A legacy-extra failure is reported separately and preserves assessment filtering for other apps and system-item IDs. Passive refresh does not retry a failed legacy target; the next reveal/collapse or explicit apply can retry it. The `legacyExtras` unified-log category records get/remove/add statuses and bounded AX verification attempts. Every successful remove/add also requires a fresh AX inventory check. Transient ambiguous AX snapshots after removal are retried within a bounded verification window; persistent ambiguity still restores the extra. Discovery excludes backend-owned unloaded extras from the configured-extra inference, so a stale VPN preference cannot prevent identifying a remaining unlabelled Time Machine icon. Failed restoration retains a receipt for retry and reports an error; recovery cannot be guaranteed if the system refuses `add`, or after a forced process kill. Reordering is deferred when an item is overflowing, its coordinates cannot be verified, or a protected item blocks the path. A global visibility filter may also affect menu bar icons whose processes have no bundle ID.

End-to-end system acceptance is still in progress. In particular, direct status-item clicking, login behavior, two-display changes, and recovery from every interruption need further manual verification. A successful build or unit test does not establish those behaviors.

## Avoiding conflicts with other menu bar managers

Before enabling visibility filtering, the app checks running applications against known menu bar manager names and bundle identifiers, including Bartender. It refuses to activate the filter when it finds one. This check prevents two applications from changing menu bar visibility at the same time. It covers the known identifiers in the source code; close any other menu bar manager before enabling filtering.

## Tests

```sh
swift test --disable-sandbox
```

The `Sources/MenubarOrganizer` target contains the app and its system adapter. `Sources/OrganizerCore` contains the layout model and rules. The tests in `Tests/OrganizerCoreTests` cover those rules. `Tests/MenubarOrganizerTests` verifies the legacy backend with an injected API and inventory, without altering the menu bar.

For the first manual legacy-extra experiment, enable both VPN and Time Machine in macOS and keep other menu bar managers closed. Hide only Time Machine and confirm VPN remains visible; reveal it and confirm it returns. Repeat with only VPN hidden and Time Machine visible. Both extras must have unique, directly accessible AX identities and matching restoration bundles. These unit tests do not establish acceptance on the live menu bar.
