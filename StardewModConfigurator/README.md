# Stardew Mod Configurator

Convert **Content Patcher (CP)** or **Alternative Textures (AT)** Stardew Valley mods into versions configurable via **Generic Mod Config Menu (GMCM)** — all without touching a single line of JSON manually.

---

## Features

- 🔍 **Auto-detection** of mod type (Content Patcher or Alternative Textures) via `manifest.json` and heuristics
- 🎚️ **Three levels of toggle granularity** — Low (categories), Medium (groups), High (individual items)
- 💾 **Automatic full backup** of the mod folder before any changes
- 🖼️ **Stardew Valley-themed GUI** (warm browns, golden accents, parchment log)
- 📄 Generates `config.json`, `i18n/default.json`, and updates `content.json`
- 🖥️ **CLI mode** for scripting and automation
- 📦 Portable standalone `.exe` via PyInstaller

---

## Requirements

- **Python 3.8 or newer** (for running from source)
  - `tkinter` (included in the standard library on most platforms)
- **OR** the standalone `.exe` (no Python needed)

---

## Installation

### Option A — Run from source

```bash
cd StardewModConfigurator
python stardew_mod_configurator.py
```

### Option B — Standalone executable

Download the pre-built `StardewModConfigurator.exe` from the Releases page, or build it yourself (see below).

---

## Usage

### GUI mode

1. Launch `stardew_mod_configurator.py` (or the `.exe`)
2. **Step 1** — click **Browse…** and select your mod folder.  
   The detected mod type is shown automatically.
3. **Step 2** — choose a toggle granularity level (see table below).
4. **Step 3** — click **🌟 Convert Mod**.

A backup is created automatically before any files are modified.  
The output log shows every action taken, colour-coded by severity.

### CLI mode

```bash
python stardew_mod_configurator.py --cli <path/to/mod> [--granularity low|medium|high]
```

Examples:

```bash
# Medium granularity (default)
python stardew_mod_configurator.py --cli "C:/Mods/MyCharacterMod"

# Low granularity — just category toggles
python stardew_mod_configurator.py --cli "C:/Mods/MyCharacterMod" --granularity low

# High granularity — one toggle per patch
python stardew_mod_configurator.py --cli "C:/Mods/MyCharacterMod" --granularity high
```

---

## Toggle Granularity

| Level | Label | CP Behaviour | AT Behaviour |
|-------|-------|-------------|-------------|
| **Low** 🟢 | Category toggles only | One toggle per category (Characters, Animals, World, UI, Data, Other) | One toggle per AT category (Nature, Crops, Buildings & Decor, Characters, Craftables, Other) |
| **Medium** 🟡 | Categories + groups | Per-group toggles (e.g. per texture type) plus categories | Per-texture-type group toggles plus categories |
| **High** 🔴 | Every individual item | Every single patch gets its own boolean toggle | Every individual texture item gets its own toggle |

All levels always include a master **Enable Mod** toggle.

---

## How It Works

### Content Patcher mods

1. Parses `content.json`, tolerating `//` comments, `/* */` block comments, and trailing commas.
2. Analyses each entry in `Changes[]` to assign it a category and optional item name.
3. Injects `When` conditions referencing config tokens into every patch.
4. Adds a `ConfigSchema` section so Content Patcher registers the keys with GMCM.
5. Generates `config.json` (all keys default to `"true"`) and `i18n/default.json`.

**Example `When` injection:**

```json
"When": {
    "GMCM_EnableMod": "true",
    "GMCM_Cat_Characters": "true",
    "GMCM_Item_Characters_Alex": "true"
}
```

### Alternative Textures mods

1. Walks the `Textures/` directory tree, parsing every `texture.json`.
2. Maps each `Type` field to a friendly category (Nature, Crops, Buildings & Decor, etc.).
3. Creates a lightweight Content Patcher wrapper `content.json` that provides the GMCM config page.
4. Adds an optional Content Patcher dependency to `manifest.json`.
5. Generates `config.json` and `i18n/default.json`.

---

## Backup System

Before every conversion, the entire mod folder is copied to a sibling directory:

```
MyMod/                       ← original (modified)
MyMod_BACKUP_20240315_143022/ ← timestamped backup (untouched)
```

---

## Building a Standalone .exe

```bash
pip install pyinstaller
python build_exe.py
```

Output: `dist/StardewModConfigurator.exe` (Windows) or `dist/StardewModConfigurator` (macOS/Linux).

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `tkinter` not found | Install `python3-tk` (Linux) or use the pre-built `.exe` |
| "Could not detect mod type" | Ensure `manifest.json` exists and has `ContentPackFor.UniqueID` set |
| Conversion fails with JSON parse error | The mod's JSON may have non-standard syntax; open an issue with the error log |
| GMCM doesn't show my new toggles | Make sure Content Patcher is installed and the mod is loaded after CP |
| AT mod doesn't respond to toggles | AT still loads all textures; the CP wrapper only controls GMCM visibility — full AT integration requires AT's own config system |

---

## Acknowledgements

- [Content Patcher](https://github.com/Pathoschild/StardewMods/tree/stable/ContentPatcher) by Pathoschild
- [Alternative Textures](https://github.com/Floogen/AlternativeTextures) by Floogen
- [Generic Mod Config Menu](https://github.com/spacechase0/StardewValleyMods/tree/develop/GenericModConfigMenu) by spacechase0
