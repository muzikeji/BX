# AltList (vendored)

Vendored from https://github.com/opa334/AltList (upstream 1.0.11, MIT License,
© Lars Fröder — see LICENSE.md) and compiled directly into the MUBXPrefs
bundle instead of linking a runtime AltList.framework. The app-list pages
(生效应用 multi-select, 打开应用 single-select picker) are AltList controllers.

## Files included

ATLApplicationListControllerBase, ATLApplicationListSelectionController,
ATLApplicationListMultiSelectionController, ATLApplicationSection,
ATLApplicationSubtitleCell, ATLApplicationSubtitleSwitchCell,
LSApplicationProxy+AltList, PSSpecifier+AltList, plus the CoreServices.h
declaration shim. Not included: AltList.x (Logos %ctor display-name preheat),
the subcontroller pair, ATLApplicationSelectionCell (unused link-cell preview),
test preference projects.

## MUBX modifications (kept minimal, marked `MUBX vendor` in code)

1. `CoreServices.h` — rewritten as a self-contained declaration shim; the theos
   SDKs used here do not ship the private
   `<MobileCoreServices/LSApplicationProxy.h>` / `LSApplicationWorkspace.h`
   headers upstream imports. `LSApplicationProxy+AltList.h` imports the shim
   instead.
2. `safe_getExecutablePath` — definition moved from AltList.x (the Logos %ctor
   preheat file, not vendored) into `LSApplicationProxy+AltList.m`, its only
   remaining caller.
3. `-[LSApplicationWorkspace atl_allInstalledApplications]` — primary
   acquisition now follows the PullOver-X QSFavoritesPickerController method
   (single `allApplications` pass). Classification itself always happens per
   proxy via the `applicationType` string in the ATLApplicationSection
   predicates (never from enumeration rounds) — that is what fixes MUBX's
   swapped User/System sections. Upstream typed passes stay as fallback.
4. `ATLApplicationListSelectionController` — added a public
   `selectedApplicationID` accessor so the programmatic picker can seed/read
   the selection (upstream only touches the private ivar internally).

When re-syncing upstream, re-apply these three changes.
