"""
Stardew Mod Configurator
========================
Converts Content Patcher (CP) or Alternative Textures (AT) Stardew Valley mods
into versions configurable via Generic Mod Config Menu (GMCM).

Usage:
    python stardew_mod_configurator.py          # Launch GUI
    python stardew_mod_configurator.py --cli    # CLI mode
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

APP_NAME = "Stardew Mod Configurator"
APP_VERSION = "1.0.0"

KNOWN_NPCS: set[str] = {
    "Abigail", "Alex", "Caroline", "Clint", "Demetrius", "Dwarf", "Elliott",
    "Emily", "Evelyn", "George", "Gus", "Haley", "Harvey", "Jas", "Jodi",
    "Kent", "Krobus", "Leah", "Leo", "Lewis", "Linus", "Marnie", "Maru",
    "Pam", "Penny", "Pierre", "Robin", "Sam", "Sandy", "Sebastian", "Shane",
    "Vincent", "Willy", "Wizard",
    # SVE additions
    "Sophia", "Victor", "Olivia", "Andy", "Susan", "Morris", "Gunther",
    "Marlon", "Claire", "Lance", "Apples", "Scarlett",
}

CP_UNIQUE_ID = "Pathoschild.ContentPatcher"
AT_UNIQUE_IDS = {"PeaceBringer.AlternativeTextures", "Floogen.AlternativeTextures"}

# AT TextureType → friendly category
AT_CATEGORY_MAP: dict[str, str] = {
    "Craftable": "Craftables",
    "Grass": "Nature",
    "Tree": "Nature",
    "FruitTree": "Nature",
    "ResourceClump": "Nature",
    "Bush": "Nature",
    "ArtifactSpot": "Nature",
    "Crop": "Crops",
    "GiantCrop": "Crops",
    "Flooring": "Buildings & Decor",
    "Furniture": "Buildings & Decor",
    "Building": "Buildings & Decor",
    "Decoration": "Buildings & Decor",
    "Character": "Characters",
    "Unknown": "Other",
}

# CP target prefixes → friendly category
CP_CATEGORY_RULES: list[tuple[list[str], str]] = [
    (["Characters/Farmer", "Characters/Farmer/"], "Player"),
    (["Characters/", "Portraits/"], "Characters"),
    (["Animals/"], "Animals"),
    (["Maps/", "TerrainFeatures/", "TileSheets/", "Minigames/"], "World"),
    (["LooseSprites/", "Fonts/", "UI/"], "UI"),
    (["Data/"], "Data"),
]

# ---------------------------------------------------------------------------
# JSON Utilities
# ---------------------------------------------------------------------------


def strip_json_comments(text: str) -> str:
    """Remove // line comments and /* */ block comments from JSON-like text,
    while respecting quoted strings."""
    result: list[str] = []
    i = 0
    in_string = False
    while i < len(text):
        c = text[i]
        if in_string:
            result.append(c)
            if c == "\\" and i + 1 < len(text):
                i += 1
                result.append(text[i])
            elif c == '"':
                in_string = False
        else:
            if c == '"':
                in_string = True
                result.append(c)
            elif text[i : i + 2] == "//":
                # Skip to end of line
                while i < len(text) and text[i] != "\n":
                    i += 1
                continue
            elif text[i : i + 2] == "/*":
                # Skip to end of block comment
                i += 2
                while i < len(text) and text[i : i + 2] != "*/":
                    i += 1
                i += 2
                continue
            else:
                result.append(c)
        i += 1
    return "".join(result)


def strip_trailing_commas(text: str) -> str:
    """Remove trailing commas before } or ] in JSON-like text,
    while respecting quoted strings."""
    # Pass 1: collect spans of quoted strings so we can skip them
    result: list[str] = []
    i = 0
    in_string = False
    while i < len(text):
        c = text[i]
        if in_string:
            result.append(c)
            if c == "\\" and i + 1 < len(text):
                i += 1
                result.append(text[i])
            elif c == '"':
                in_string = False
        else:
            if c == '"':
                in_string = True
                result.append(c)
            else:
                result.append(c)
        i += 1
    joined = "".join(result)
    # Remove trailing commas before } or ]
    return re.sub(r",(\s*[}\]])", r"\1", joined)


def load_json_lenient(path: Path) -> Any:
    """Load JSON file tolerating // comments, /* */ block comments, and trailing commas."""
    raw = path.read_text(encoding="utf-8-sig")
    cleaned = strip_trailing_commas(strip_json_comments(raw))
    return json.loads(cleaned)


def save_json(path: Path, data: Any) -> None:
    """Save data as pretty-printed JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# String Utilities
# ---------------------------------------------------------------------------


def slugify(name: str) -> str:
    """Convert a string to a safe config-key suffix (alphanumeric + underscore)."""
    name = unicodedata.normalize("NFKD", name)
    name = name.encode("ascii", "ignore").decode("ascii")
    name = re.sub(r"[^\w\s-]", "", name)
    name = re.sub(r"[\s\-]+", "_", name)
    name = name.strip("_")
    return name[:64]  # cap length


def humanize(raw: str) -> str:
    """Convert slug/path/token to a human-readable title."""
    # Strip CP {{placeholder}} tokens
    raw = re.sub(r"\{\{[^}]*\}\}", "", raw)
    # Strip UniqueID prefix like "FlashShifter.SVE_"
    raw = re.sub(r"^[A-Za-z0-9]+\.[A-Za-z0-9]+_", "", raw)
    # Take the last path segment and strip extension
    raw = Path(raw).stem
    # Replace underscores/hyphens with spaces
    raw = raw.replace("_", " ").replace("-", " ")
    # Split camelCase
    raw = re.sub(r"([a-z])([A-Z])", r"\1 \2", raw)
    raw = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", raw)
    # Collapse multiple spaces
    raw = re.sub(r"\s+", " ", raw).strip()
    # Title-case
    return raw.title()


# ---------------------------------------------------------------------------
# Backup System
# ---------------------------------------------------------------------------


def create_backup(mod_dir: Path, log_fn=None) -> Path:
    """Create a full backup of mod_dir as a sibling directory with timestamp."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_name = f"{mod_dir.name}_BACKUP_{timestamp}"
    backup_path = mod_dir.parent / backup_name

    if log_fn:
        log_fn(f"Creating backup: {backup_path}", "info")

    shutil.copytree(str(mod_dir), str(backup_path))

    if log_fn:
        log_fn(f"Backup created successfully at: {backup_path}", "success")

    return backup_path


# ---------------------------------------------------------------------------
# Mod Type Detection
# ---------------------------------------------------------------------------


class ModType:
    CP = "ContentPatcher"
    AT = "AlternativeTextures"
    UNKNOWN = "Unknown"


def detect_mod_type(mod_dir: Path) -> tuple[str, str]:
    """Detect whether mod_dir is a CP or AT mod.

    Returns (ModType, reason_string).
    """
    manifest_path = mod_dir / "manifest.json"
    if manifest_path.exists():
        try:
            manifest = load_json_lenient(manifest_path)
            cpf = manifest.get("ContentPackFor", {})
            if isinstance(cpf, dict):
                uid = cpf.get("UniqueID", "")
            else:
                uid = ""
            if uid == CP_UNIQUE_ID:
                return ModType.CP, f"manifest.json ContentPackFor={uid}"
            if uid in AT_UNIQUE_IDS:
                return ModType.AT, f"manifest.json ContentPackFor={uid}"
        except Exception:
            pass

    # Heuristic fallbacks
    if (mod_dir / "Textures").is_dir():
        return ModType.AT, "Textures/ subfolder found (AT heuristic)"

    content_path = mod_dir / "content.json"
    if content_path.exists():
        try:
            content = load_json_lenient(content_path)
            if isinstance(content, dict) and isinstance(content.get("Changes"), list):
                return ModType.CP, "content.json with Changes array found (CP heuristic)"
        except Exception:
            pass

    return ModType.UNKNOWN, "Could not detect mod type"


# ---------------------------------------------------------------------------
# CP Conversion — Categorisation
# ---------------------------------------------------------------------------


def _cp_category_for_patch(patch: dict) -> tuple[str, str | None]:
    """Return (category, item_name_or_None) for a CP patch entry."""
    target: str = patch.get("Target", patch.get("target", ""))
    from_file: str = patch.get("FromFile", patch.get("fromFile", ""))

    # Check target + fromFile combined for NPC names
    combined = (target + " " + from_file).lower()

    # Characters
    for npc in KNOWN_NPCS:
        if npc.lower() in combined:
            return "Characters", npc

    for prefixes, category in CP_CATEGORY_RULES:
        for pfx in prefixes:
            if target.lower().startswith(pfx.lower()):
                # Try to extract a name from the target path
                parts = target.split("/")
                item = parts[-1] if len(parts) > 1 else None
                if item:
                    item = humanize(item)
                return category, item

    return "Other", None


def _cp_collect_patches(changes: list[dict], granularity: str) -> dict:
    """Analyse patches and return structured info for config key generation.

    Returns {
        "categories": {cat: set_of_items},
        "patch_keys": [(patch_index, [key, ...])]  — keys that apply to this patch
    }
    """
    categories: dict[str, set[str]] = {}
    patch_keys: list[tuple[int, list[str]]] = []

    for idx, patch in enumerate(changes):
        cat, item = _cp_category_for_patch(patch)
        if cat not in categories:
            categories[cat] = set()
        if item:
            categories[cat].add(item)

        keys: list[str] = ["GMCM_EnableMod", f"GMCM_Cat_{slugify(cat)}"]

        if granularity == "high" and item:
            keys.append(f"GMCM_Item_{slugify(cat)}_{slugify(item)}")
        elif granularity == "medium" and item:
            # Group level only — use category toggle, no individual item toggle
            pass

        patch_keys.append((idx, keys))

    return {"categories": categories, "patch_keys": patch_keys}


# ---------------------------------------------------------------------------
# CP Conversion — Main
# ---------------------------------------------------------------------------


def convert_cp_mod(
    mod_dir: Path,
    granularity: str,
    log_fn=None,
) -> None:
    """Convert a Content Patcher mod to have GMCM ConfigSchema toggles."""

    def log(msg: str, level: str = "info") -> None:
        if log_fn:
            log_fn(msg, level)

    content_path = mod_dir / "content.json"
    log(f"Parsing {content_path}", "file")
    content = load_json_lenient(content_path)

    changes: list[dict] = content.get("Changes", [])
    log(f"Found {len(changes)} patch entries in Changes[]", "info")

    # Analyse patches
    analysis = _cp_collect_patches(changes, granularity)
    categories: dict[str, set[str]] = analysis["categories"]
    patch_keys: list[tuple[int, list[str]]] = analysis["patch_keys"]

    # Build ConfigSchema
    existing_schema: dict = content.get("ConfigSchema", {})
    schema: dict = {}

    # Master toggle
    schema["GMCM_EnableMod"] = {
        "AllowValues": "true, false",
        "Default": "true",
        "Description": "{{i18n:GMCM_EnableMod.Description}}",
        "Section": "General",
    }

    # Category toggles
    for cat in sorted(categories.keys()):
        key = f"GMCM_Cat_{slugify(cat)}"
        schema[key] = {
            "AllowValues": "true, false",
            "Default": "true",
            "Description": f"{{{{i18n:{key}.Description}}}}",
            "Section": cat,
        }

    # Item-level toggles (high granularity only)
    if granularity == "high":
        for cat, items in sorted(categories.items()):
            for item in sorted(items):
                key = f"GMCM_Item_{slugify(cat)}_{slugify(item)}"
                schema[key] = {
                    "AllowValues": "true, false",
                    "Default": "true",
                    "Description": f"{{{{i18n:{key}.Description}}}}",
                    "Section": cat,
                }

    # Preserve any existing non-auto-generated entries
    for k, v in existing_schema.items():
        if not k.startswith("GMCM_"):
            schema[k] = v

    log(f"Generated {len(schema)} ConfigSchema entries", "info")

    # Inject When conditions into patches
    for idx, keys in patch_keys:
        patch = changes[idx]
        existing_when: dict = patch.get("When", {})
        for key in keys:
            if key not in existing_when:
                existing_when[key] = "true"
        patch["When"] = existing_when

    log("Injected When conditions into all patches", "success")

    # Update content.json
    content["ConfigSchema"] = schema
    content["Changes"] = changes
    save_json(content_path, content)
    log(f"Saved updated content.json → {content_path}", "file")

    # Generate config.json
    config_data = {k: "true" for k in schema}
    save_json(mod_dir / "config.json", config_data)
    log("Generated config.json with all toggles defaulting to true", "file")

    # Generate i18n/default.json
    i18n: dict = {}
    i18n["GMCM_EnableMod.Description"] = "Enable or disable this entire mod"
    for cat in sorted(categories.keys()):
        key = f"GMCM_Cat_{slugify(cat)}"
        i18n[f"{key}.Description"] = f"Enable or disable all {cat} content"

    if granularity == "high":
        for cat, items in sorted(categories.items()):
            for item in sorted(items):
                key = f"GMCM_Item_{slugify(cat)}_{slugify(item)}"
                i18n[f"{key}.Description"] = f"Enable or disable {item}"

    i18n_path = mod_dir / "i18n" / "default.json"
    existing_i18n: dict = {}
    if i18n_path.exists():
        try:
            existing_i18n = load_json_lenient(i18n_path)
        except Exception:
            pass
    existing_i18n.update(i18n)
    save_json(i18n_path, existing_i18n)
    log(f"Generated i18n/default.json → {i18n_path}", "file")

    log("Content Patcher conversion complete!", "success")


# ---------------------------------------------------------------------------
# AT Conversion — Main
# ---------------------------------------------------------------------------


def _at_category(texture_type: str) -> str:
    return AT_CATEGORY_MAP.get(texture_type, "Other")


def convert_at_mod(
    mod_dir: Path,
    granularity: str,
    log_fn=None,
) -> None:
    """Convert an Alternative Textures mod to have a CP wrapper with GMCM toggles."""

    def log(msg: str, level: str = "info") -> None:
        if log_fn:
            log_fn(msg, level)

    textures_dir = mod_dir / "Textures"
    if not textures_dir.is_dir():
        raise ValueError(f"No Textures/ directory found in {mod_dir}")

    # Walk texture subfolders
    textures: list[dict] = []
    for sub in sorted(textures_dir.iterdir()):
        if not sub.is_dir():
            continue
        tj = sub / "texture.json"
        if not tj.exists():
            continue
        try:
            tdata = load_json_lenient(tj)
            tdata["_folder"] = sub.name
            textures.append(tdata)
            log(f"  Found texture: {sub.name}", "info")
        except Exception as exc:
            log(f"  Warning: could not parse {tj}: {exc}", "warning")

    log(f"Found {len(textures)} texture definitions", "info")

    # Group by category
    categories: dict[str, list[dict]] = {}
    for t in textures:
        cat = _at_category(t.get("Type", "Unknown"))
        categories.setdefault(cat, []).append(t)

    # Build ConfigSchema
    schema: dict = {}
    schema["GMCM_EnableMod"] = {
        "AllowValues": "true, false",
        "Default": "true",
        "Description": "{{i18n:GMCM_EnableMod.Description}}",
        "Section": "General",
    }

    for cat in sorted(categories.keys()):
        key = f"GMCM_Cat_{slugify(cat)}"
        schema[key] = {
            "AllowValues": "true, false",
            "Default": "true",
            "Description": f"{{{{i18n:{key}.Description}}}}",
            "Section": cat,
        }

    type_groups: dict[str, set[str]] = {}
    if granularity in ("medium", "high"):
        # Medium: per-texture-type group toggles
        for t in textures:
            ttype = t.get("Type", "Unknown")
            type_groups.setdefault(ttype, set())
            type_groups[ttype].add(t.get("_folder", "unknown"))
        for ttype in sorted(type_groups.keys()):
            key = f"GMCM_Type_{slugify(ttype)}"
            cat = _at_category(ttype)
            schema[key] = {
                "AllowValues": "true, false",
                "Default": "true",
                "Description": f"{{{{i18n:{key}.Description}}}}",
                "Section": cat,
            }

    if granularity == "high":
        for t in textures:
            name = t.get("ItemName") or t.get("ItemId") or t.get("_folder", "unknown")
            cat = _at_category(t.get("Type", "Unknown"))
            key = f"GMCM_Texture_{slugify(cat)}_{slugify(humanize(str(name)))}"
            schema[key] = {
                "AllowValues": "true, false",
                "Default": "true",
                "Description": f"{{{{i18n:{key}.Description}}}}",
                "Section": cat,
            }

    log(f"Generated {len(schema)} ConfigSchema entries", "info")

    # Build CP wrapper content.json
    # We create a minimal CP patch that uses the config tokens
    # The actual AT textures are still loaded by the AT framework;
    # this wrapper simply provides the GMCM config page.
    changes: list[dict] = []

    # For AT mods the wrapper doesn't need real patches — but we add a
    # placeholder so CP registers the config schema properly.
    placeholder_patch: dict = {
        "Action": "EditData",
        "Target": "Data/mail",
        "Entries": {},
        "When": {k: "true" for k in schema},
    }
    changes.append(placeholder_patch)

    wrapper_content: dict = {
        "Format": "2.0.0",
        "ConfigSchema": schema,
        "Changes": changes,
    }

    content_path = mod_dir / "content.json"
    save_json(content_path, wrapper_content)
    log(f"Created CP wrapper content.json → {content_path}", "file")

    # Generate config.json
    config_data = {k: "true" for k in schema}
    save_json(mod_dir / "config.json", config_data)
    log("Generated config.json", "file")

    # Generate i18n/default.json
    i18n: dict = {}
    i18n["GMCM_EnableMod.Description"] = "Enable or disable this entire mod"
    for cat in sorted(categories.keys()):
        key = f"GMCM_Cat_{slugify(cat)}"
        i18n[f"{key}.Description"] = f"Enable or disable all {cat} content"

    if granularity in ("medium", "high"):
        for ttype in sorted(type_groups.keys()):
            key = f"GMCM_Type_{slugify(ttype)}"
            i18n[f"{key}.Description"] = f"Enable or disable all {ttype} textures"

    if granularity == "high":
        for t in textures:
            name = t.get("ItemName") or t.get("ItemId") or t.get("_folder", "unknown")
            cat = _at_category(t.get("Type", "Unknown"))
            key = f"GMCM_Texture_{slugify(cat)}_{slugify(humanize(str(name)))}"
            i18n[f"{key}.Description"] = f"Enable or disable {humanize(str(name))}"

    i18n_path = mod_dir / "i18n" / "default.json"
    existing_i18n: dict = {}
    if i18n_path.exists():
        try:
            existing_i18n = load_json_lenient(i18n_path)
        except Exception:
            pass
    existing_i18n.update(i18n)
    save_json(i18n_path, existing_i18n)
    log(f"Generated i18n/default.json → {i18n_path}", "file")

    # Update manifest.json to add CP dependency
    manifest_path = mod_dir / "manifest.json"
    if manifest_path.exists():
        try:
            manifest = load_json_lenient(manifest_path)
            deps: list[dict] = manifest.get("Dependencies", [])
            cp_dep_exists = any(
                d.get("UniqueID") == CP_UNIQUE_ID for d in deps if isinstance(d, dict)
            )
            if not cp_dep_exists:
                deps.append(
                    {
                        "UniqueID": CP_UNIQUE_ID,
                        "IsRequired": False,
                    }
                )
                manifest["Dependencies"] = deps
                save_json(manifest_path, manifest)
                log("Added optional Content Patcher dependency to manifest.json", "file")
        except Exception as exc:
            log(f"Warning: could not update manifest.json: {exc}", "warning")

    log("Alternative Textures conversion complete!", "success")


# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------


def run_conversion(
    mod_dir_str: str,
    granularity: str = "medium",
    log_fn=None,
) -> bool:
    """Main entry point for conversion.  Returns True on success."""

    def log(msg: str, level: str = "info") -> None:
        if log_fn:
            log_fn(msg, level)
        else:
            print(f"[{level.upper()}] {msg}")

    mod_dir = Path(mod_dir_str).resolve()

    if not mod_dir.is_dir():
        log(f"Error: {mod_dir} is not a directory", "error")
        return False

    log(f"Processing mod folder: {mod_dir}", "info")

    # Detect mod type
    mod_type, reason = detect_mod_type(mod_dir)
    log(f"Detected mod type: {mod_type} ({reason})", "info")

    if mod_type == ModType.UNKNOWN:
        log(
            "Could not detect mod type. "
            "Ensure the folder contains manifest.json, content.json, or Textures/",
            "error",
        )
        return False

    # Backup
    try:
        backup_path = create_backup(mod_dir, log_fn=log_fn)
        log(f"Backup: {backup_path}", "success")
    except Exception as exc:
        log(f"Backup failed: {exc}", "error")
        return False

    # Convert
    try:
        if mod_type == ModType.CP:
            convert_cp_mod(mod_dir, granularity, log_fn=log)
        elif mod_type == ModType.AT:
            convert_at_mod(mod_dir, granularity, log_fn=log)
        return True
    except Exception as exc:
        import traceback

        log(f"Conversion failed: {exc}", "error")
        log(traceback.format_exc(), "error")
        return False


# ---------------------------------------------------------------------------
# CLI Mode
# ---------------------------------------------------------------------------


def cli_main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a CP/AT Stardew Valley mod to support GMCM toggles."
    )
    parser.add_argument("mod_dir", help="Path to the mod folder")
    parser.add_argument(
        "--granularity",
        choices=["low", "medium", "high"],
        default="medium",
        help="Toggle granularity: low=categories only, medium=categories+groups, high=individual items",
    )
    args = parser.parse_args()

    def cli_log(msg: str, level: str = "info") -> None:
        prefix = {"info": "ℹ", "success": "✓", "error": "✗", "file": "📄", "warning": "⚠"}.get(
            level, "·"
        )
        print(f"{prefix} {msg}")

    success = run_conversion(args.mod_dir, args.granularity, log_fn=cli_log)
    sys.exit(0 if success else 1)


# ---------------------------------------------------------------------------
# GUI Mode (tkinter)
# ---------------------------------------------------------------------------

try:
    import tkinter as tk
    from tkinter import filedialog, messagebox, scrolledtext, ttk

    HAS_TKINTER = True
except ImportError:
    HAS_TKINTER = False

# Stardew Valley colour palette
COLORS = {
    "bg_dark": "#4a2e1a",
    "bg_mid": "#6b4226",
    "bg_light": "#f5e6c8",
    "bg_cream": "#faf0d7",
    "gold": "#ffd700",
    "gold_dark": "#8b6914",
    "green": "#4a7c3f",
    "green_light": "#6aaf50",
    "text_light": "#faf0d7",
    "text_dark": "#2a1a0e",
    "log_bg": "#fdf5e6",
    "log_success": "#2d6a2d",
    "log_error": "#8b1a1a",
    "log_info": "#1a4a7a",
    "log_file": "#7a5a00",
    "log_warning": "#8b4513",
}


class StardewModConfiguratorApp:
    """Stardew Valley-themed tkinter GUI for the mod configurator."""

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.mod_dir_var = tk.StringVar()
        self.granularity_var = tk.StringVar(value="medium")
        self.mod_type_var = tk.StringVar(value="— not detected —")
        self._setup_window()
        self._apply_style()
        self._build_ui()

    # ------------------------------------------------------------------
    # Window / style setup
    # ------------------------------------------------------------------

    def _setup_window(self) -> None:
        self.root.title(f"★ {APP_NAME} ★")
        self.root.resizable(True, True)
        self.root.minsize(640, 560)
        self.root.configure(bg=COLORS["bg_dark"])
        # Centre on screen
        self.root.update_idletasks()
        w, h = 760, 680
        x = (self.root.winfo_screenwidth() - w) // 2
        y = (self.root.winfo_screenheight() - h) // 2
        self.root.geometry(f"{w}x{h}+{x}+{y}")

    def _apply_style(self) -> None:
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except Exception:
            pass

        style.configure(
            "TFrame",
            background=COLORS["bg_light"],
        )
        style.configure(
            "Dark.TFrame",
            background=COLORS["bg_dark"],
        )
        style.configure(
            "TLabel",
            background=COLORS["bg_light"],
            foreground=COLORS["text_dark"],
            font=("Georgia", 10),
        )
        style.configure(
            "Title.TLabel",
            background=COLORS["bg_dark"],
            foreground=COLORS["gold"],
            font=("Georgia", 18, "bold"),
        )
        style.configure(
            "Subtitle.TLabel",
            background=COLORS["bg_dark"],
            foreground=COLORS["bg_light"],
            font=("Georgia", 9, "italic"),
        )
        style.configure(
            "Detection.TLabel",
            background=COLORS["bg_cream"],
            foreground=COLORS["bg_mid"],
            font=("Consolas", 9),
        )
        style.configure(
            "TLabelframe",
            background=COLORS["bg_light"],
            foreground=COLORS["bg_dark"],
            font=("Georgia", 10, "bold"),
        )
        style.configure(
            "TLabelframe.Label",
            background=COLORS["bg_light"],
            foreground=COLORS["bg_mid"],
            font=("Georgia", 10, "bold"),
        )
        style.configure(
            "TRadiobutton",
            background=COLORS["bg_light"],
            foreground=COLORS["text_dark"],
            font=("Georgia", 10),
        )
        style.map(
            "TRadiobutton",
            background=[("active", COLORS["bg_cream"])],
        )
        style.configure(
            "Brown.TButton",
            background=COLORS["bg_mid"],
            foreground=COLORS["text_light"],
            font=("Georgia", 9, "bold"),
            borderwidth=2,
            relief="raised",
        )
        style.map(
            "Brown.TButton",
            background=[("active", COLORS["bg_dark"]), ("pressed", COLORS["bg_dark"])],
            foreground=[("active", COLORS["gold"])],
        )
        style.configure(
            "Convert.TButton",
            background=COLORS["green"],
            foreground=COLORS["text_light"],
            font=("Georgia", 13, "bold"),
            borderwidth=3,
            relief="raised",
            padding=(16, 8),
        )
        style.map(
            "Convert.TButton",
            background=[("active", COLORS["green_light"]), ("pressed", COLORS["green"])],
            foreground=[("active", COLORS["gold"])],
        )
        style.configure(
            "Exit.TButton",
            background=COLORS["bg_mid"],
            foreground=COLORS["text_light"],
            font=("Georgia", 10),
            borderwidth=2,
        )
        style.map(
            "Exit.TButton",
            background=[("active", COLORS["bg_dark"])],
        )

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------

    def _build_ui(self) -> None:
        root = self.root

        # ---- Title bar ----
        title_frame = tk.Frame(root, bg=COLORS["bg_dark"], pady=10)
        title_frame.pack(fill="x")

        tk.Label(
            title_frame,
            text=f"★  {APP_NAME}  ★",
            bg=COLORS["bg_dark"],
            fg=COLORS["gold"],
            font=("Georgia", 18, "bold"),
        ).pack()
        tk.Label(
            title_frame,
            text="Convert CP / AT mods to support Generic Mod Config Menu toggles",
            bg=COLORS["bg_dark"],
            fg=COLORS["bg_light"],
            font=("Georgia", 9, "italic"),
        ).pack()

        # ---- Golden separator ----
        tk.Frame(root, bg=COLORS["gold"], height=2).pack(fill="x")

        # ---- Content area ----
        content = tk.Frame(root, bg=COLORS["bg_light"], padx=16, pady=12)
        content.pack(fill="both", expand=True)

        # ---- Step 1: Select Mod Folder ----
        step1 = ttk.LabelFrame(content, text="📁  Step 1: Select Mod Folder", padding=10)
        step1.pack(fill="x", pady=(0, 8))

        folder_row = tk.Frame(step1, bg=COLORS["bg_light"])
        folder_row.pack(fill="x")

        self.folder_entry = tk.Entry(
            folder_row,
            textvariable=self.mod_dir_var,
            bg=COLORS["bg_cream"],
            fg=COLORS["text_dark"],
            font=("Consolas", 9),
            relief="sunken",
            bd=2,
        )
        self.folder_entry.pack(side="left", fill="x", expand=True, padx=(0, 6))

        ttk.Button(
            folder_row,
            text="Browse…",
            style="Brown.TButton",
            command=self._browse_folder,
        ).pack(side="left")

        detect_row = tk.Frame(step1, bg=COLORS["bg_light"])
        detect_row.pack(fill="x", pady=(6, 0))

        tk.Label(
            detect_row,
            text="Detected type: ",
            bg=COLORS["bg_light"],
            fg=COLORS["text_dark"],
            font=("Georgia", 9),
        ).pack(side="left")

        self.detect_label = tk.Label(
            detect_row,
            textvariable=self.mod_type_var,
            bg=COLORS["bg_cream"],
            fg=COLORS["bg_mid"],
            font=("Consolas", 9),
            padx=6,
            pady=2,
            relief="sunken",
        )
        self.detect_label.pack(side="left")

        # ---- Step 2: Toggle Granularity ----
        step2 = ttk.LabelFrame(content, text="🎚️  Step 2: Choose Toggle Granularity", padding=10)
        step2.pack(fill="x", pady=(0, 8))

        radio_opts = [
            (
                "low",
                "🟢 Low — Category toggles only",
                "One toggle per category (Characters, Animals, World, UI, Data, Other)",
            ),
            (
                "medium",
                "🟡 Medium — Categories + grouped items",
                "Category toggles plus per-texture-type / per-NPC-group toggles",
            ),
            (
                "high",
                "🔴 High — Every individual item",
                "A separate toggle for every single patch / texture item",
            ),
        ]

        for val, label, desc in radio_opts:
            row = tk.Frame(step2, bg=COLORS["bg_light"])
            row.pack(fill="x", pady=2)
            ttk.Radiobutton(
                row,
                text=label,
                variable=self.granularity_var,
                value=val,
            ).pack(side="left")
            tk.Label(
                row,
                text=f"  {desc}",
                bg=COLORS["bg_light"],
                fg=COLORS["gold_dark"],
                font=("Georgia", 8, "italic"),
            ).pack(side="left")

        # ---- Step 3: Convert ----
        step3_frame = tk.Frame(content, bg=COLORS["bg_light"])
        step3_frame.pack(fill="x", pady=(0, 8))

        ttk.Button(
            step3_frame,
            text="🌟  Convert Mod",
            style="Convert.TButton",
            command=self._run_conversion,
        ).pack(side="left", padx=(0, 10))

        ttk.Button(
            step3_frame,
            text="Exit",
            style="Exit.TButton",
            command=self.root.destroy,
        ).pack(side="left")

        # ---- Output Log ----
        log_frame = ttk.LabelFrame(content, text="📋  Output Log", padding=6)
        log_frame.pack(fill="both", expand=True)

        self.log_text = scrolledtext.ScrolledText(
            log_frame,
            bg=COLORS["log_bg"],
            fg=COLORS["text_dark"],
            font=("Consolas", 9),
            relief="sunken",
            bd=2,
            state="disabled",
            wrap="word",
            height=10,
        )
        self.log_text.pack(fill="both", expand=True)

        # Configure text tags for colour-coded log messages
        self.log_text.tag_configure("success", foreground=COLORS["log_success"])
        self.log_text.tag_configure("error", foreground=COLORS["log_error"])
        self.log_text.tag_configure("info", foreground=COLORS["log_info"])
        self.log_text.tag_configure("file", foreground=COLORS["log_file"])
        self.log_text.tag_configure("warning", foreground=COLORS["log_warning"])

        # ---- Status bar ----
        tk.Frame(root, bg=COLORS["gold"], height=1).pack(fill="x")
        status_bar = tk.Frame(root, bg=COLORS["bg_dark"], pady=3)
        status_bar.pack(fill="x")
        tk.Label(
            status_bar,
            text=f"v{APP_VERSION}  ★  A backup is always created before changes  ★",
            bg=COLORS["bg_dark"],
            fg=COLORS["green_light"],
            font=("Georgia", 8),
        ).pack()

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def _browse_folder(self) -> None:
        folder = filedialog.askdirectory(title="Select Mod Folder")
        if folder:
            self.mod_dir_var.set(folder)
            self._auto_detect(folder)

    def _auto_detect(self, folder: str) -> None:
        mod_type, reason = detect_mod_type(Path(folder))
        self.mod_type_var.set(f"{mod_type}  ({reason})")
        if mod_type == ModType.UNKNOWN:
            self.detect_label.configure(fg=COLORS["log_error"])
        elif mod_type == ModType.CP:
            self.detect_label.configure(fg=COLORS["log_info"])
        else:
            self.detect_label.configure(fg=COLORS["green"])

    def _log(self, msg: str, level: str = "info") -> None:
        self.log_text.configure(state="normal")
        prefix = {
            "info": "ℹ",
            "success": "✓",
            "error": "✗",
            "file": "📄",
            "warning": "⚠",
        }.get(level, "·")
        self.log_text.insert("end", f"{prefix} {msg}\n", level)
        self.log_text.configure(state="disabled")
        self.log_text.see("end")
        self.root.update_idletasks()

    def _clear_log(self) -> None:
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    def _run_conversion(self) -> None:
        mod_dir = self.mod_dir_var.get().strip()
        if not mod_dir:
            messagebox.showwarning("No Folder", "Please select a mod folder first.")
            return

        granularity = self.granularity_var.get()
        self._clear_log()
        self._log(f"Starting conversion: {mod_dir}", "info")
        self._log(f"Granularity: {granularity}", "info")

        success = run_conversion(mod_dir, granularity, log_fn=self._log)

        if success:
            messagebox.showinfo(
                "Conversion Complete",
                "✓ Mod conversion completed successfully!\n\n"
                "A backup of your original mod has been created in the parent folder.",
            )
        else:
            messagebox.showerror(
                "Conversion Failed",
                "✗ Conversion failed. See the output log for details.",
            )


def gui_main() -> None:
    root = tk.Tk()
    StardewModConfiguratorApp(root)
    root.mainloop()


# ---------------------------------------------------------------------------
# Entry Point
# ---------------------------------------------------------------------------


def main() -> None:
    # Check for --cli flag before parsing the rest
    if "--cli" in sys.argv or not HAS_TKINTER:
        # Remove --cli from argv so argparse doesn't see it
        if "--cli" in sys.argv:
            sys.argv.remove("--cli")
        cli_main()
    else:
        gui_main()


if __name__ == "__main__":
    main()
