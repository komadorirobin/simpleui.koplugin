# SimpleUI – KOReader Patches

This directory contains two Lua patch files that implement personal
customisations on top of the [SimpleUI plugin](https://github.com/doctorhetfield-cmd/simpleui.koplugin).

Because the patches live outside the plugin itself and are applied at
KOReader startup via monkey-patching, they survive upstream plugin updates.
You can pull the latest version of the plugin without losing your changes.

---

## Installation

1. Copy the **two `.lua` files** from this directory into your device's
   `koreader/patches/` folder
   (e.g. `/mnt/us/koreader/patches/` on Kindle, `/mnt/onboard/.adds/koreader/patches/` on Kobo).
   The `README.md` file is only for reference and does **not** need to be copied.
2. Restart KOReader.

The patches are loaded automatically on every KOReader startup.

---

## What each patch does

### `2-simpleui-hardcover.lua`

Registers the **Hardcover** module (`desktop_modules/module_hardcover.lua`)
in SimpleUI's module registry, making it available on the Homescreen just
like any other built-in module.

*The module file (`module_hardcover.lua`) must be present in the plugin's
`desktop_modules/` folder.  It is bundled with this fork and does not need
to be moved.*

### `2-simpleui-stats-gray.lua`

Changes the background colour of individual stat cards in the
**Reading Stats** module from white to a light gray (`gray(0.88)`) when
the "Cards" display mode is active.

To adjust the shade, open the patch file and change `_GRAY_LEVEL`:

```lua
local _GRAY_LEVEL = 0.88   -- 0.0 = black … 1.0 = white
```

---

## How it works (technical)

KOReader loads every `*.lua` file found in `koreader/patches/` during
startup, before any plugin is initialised.  Files are loaded in
alphanumeric order, so prefix numbers control priority.

Each patch uses Lua's `package.preload` mechanism to intercept the target
module the first time it is `require()`d.  The wrapper:

1. Loads the original module normally.
2. Monkey-patches the returned table (wrapping `M.build()` or
   `Registry.list()` / `Registry.get()`).
3. Re-registers itself as the preload hook so the patch survives
   plugin hot-reload cycles (where SimpleUI evicts `package.loaded` entries
   on teardown).

If the target module is already in `package.loaded` when the patch file
runs, the live object is patched directly as well.

---

## Updating the plugin

1. Pull (or re-install) the latest version of the plugin.
2. The patch files in `koreader/patches/` are untouched.
3. Restart KOReader — patches are reapplied automatically.
