# Shared App and Quick Look Appearance

## Goal

Use the existing **View → Appearance** choice as the only user-facing appearance setting for both the main app and Finder Quick Look. Remove the separate Quick Look Appearance menu introduced by PR #265.

## Design

- Keep the existing `MarkdownPreview.appearance` preference key and its `automatic`, `light`, and `dark` values.
- Store the preference in the app group already shared by the app and Quick Look extension.
- On app launch, migrate an existing value from `UserDefaults.standard` into the shared store only when the shared store has no value. This preserves upgrades without overwriting a newer shared choice.
- Read and write the shared value from both processes through one Foundation-only `AppearanceMode` type.
- Keep `automatic` as the default, matching the existing app behavior. In Automatic mode, Quick Look resolves the Quick Look host's effective appearance at render time.
- Continue forcing the renderer's explicit light or dark color scheme for fixed modes so page, code highlighting, math, and Mermaid stay consistent.

## Failure Behavior

If the app group cannot be opened or contains an invalid value, both processes fall back to `automatic`. The main app retains its legacy standard-default value until it can migrate it successfully.

## Scope

Remove the independent Quick Look menu, localization strings, preference key, and tests. Keep the App Group entitlements and the forced-rendering CSS/HTML work because they are still required to apply the shared fixed appearance in Quick Look.

## Verification

- Unit-test missing, invalid, round-trip, migration, and automatic-resolution behavior.
- Build the app and embedded Quick Look extension.
- Install the side-by-side preview build and verify View → Appearance Light, Dark, and Automatic each produce the matching Finder Quick Look result.
