#!/usr/bin/env python3
"""Copy rigged monsters and their props from monster-forge into assets/ (stdlib only).

    python3 -I tools/sync_monsters.py --all                 # every rigged monster with clips + every prop
    python3 -I tools/sync_monsters.py --ids wolf harpy      # these monsters + the props they wield
    python3 -I tools/sync_monsters.py --props               # every prop (or --props scimitar shield)
    python3 -I tools/sync_monsters.py --all --forge ~/workspace/monster-forge --source srd-5.2.1

Copies only what the game loads: model_rigged.glb (LOD0, textures embedded),
model_rigged_lod<k>.glb (geometry only, they use LOD0's material) and anims/<clip>.glb (for UAL
bipeds only their own clips: the rest come from the shared UAL library, out/<source>/_shared/ual/,
copied once to assets/monsters/_shared/ual/; manifest anim.ual_shared; the paired animations,
out/<source>/_shared/paired/, come along the same way to assets/monsters/_shared/paired/), and
writes a trimmed monster.json (id, name, scale_m, body_plan, sockets, clips, lods, plus
wields / shield from data/registry/<source>.json, rider_height_m from the manifest or
data/overrides/<source>/<id>.json, swarm_unit from the manifest when the swarm was made as
one unit, tags from data/tags.computed.json: monster-forge docs/tags.md). Props (out/props/<id>/, already in prop
space) go to assets/props/<id>/: model.glb, model_lod<k>.glb, lods.json, manifest.json.
Never model_hi.glb, model_raw.glb, PNGs or paint/. Idempotent: files are compared by content, unchanged files are
left alone, files the source no longer has are removed. Monsters without a rig are skipped,
and --all also skips rigged monsters that have no clips yet.
See docs/monsters.md.
"""
import argparse
import hashlib
import json
import os
import shutil
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / "assets" / "monsters"
PROPS_DEST = ROOT / "assets" / "props"
DEFAULT_FORGE = Path(os.environ.get("MONSTER_FORGE", ROOT.parent / "monster-forge"))


def digest(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def glb_json(p: Path) -> dict:
    with p.open("rb") as f:
        head = f.read(20)
        if head[:4] != b"glTF":
            raise ValueError(f"{p} is not a GLB")
        n = struct.unpack("<I", head[12:16])[0]
        return json.loads(f.read(n))


def glb_tris(p: Path) -> int:
    j = glb_json(p)
    tris = 0
    for m in j.get("meshes", []):
        for prim in m["primitives"]:
            if "indices" in prim:
                tris += j["accessors"][prim["indices"]]["count"] // 3
            else:
                tris += j["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
    return tris


def wanted_files(src: Path) -> dict[str, Path]:
    """Relative destination path -> source file."""
    files = {"model_rigged.glb": src / "model_rigged.glb"}
    for p in sorted(src.glob("model_rigged_lod*.glb")):
        files[p.name] = p
    for p in sorted((src / "anims").glob("*.glb")):
        files[f"anims/{p.name}"] = p
    return files


def registry(forge: Path, source: str) -> dict:
    """id -> registry record (empty if the registry is missing)."""
    p = forge / "data" / "registry" / f"{source}.json"
    if not p.exists():
        return {}
    r = json.loads(p.read_text())
    recs = r if isinstance(r, list) else r.get("monsters", r)
    recs = recs if isinstance(recs, list) else list(recs.values())
    return {m["id"]: m for m in recs if isinstance(m, dict) and "id" in m}


def content_tags(forge: Path, source: str) -> dict:
    """id -> content tags from monster-forge's data/tags.computed.json (tools/tags.py; docs/tags.md),
    empty when that file is missing or for another source (the registry's own tags are used then)."""
    try:
        d = json.loads((forge / "data" / "tags.computed.json").read_text())
    except (OSError, ValueError):
        return {}
    return d.get("monsters") or {} if d.get("source") == source else {}


def override(forge: Path, source: str, mid: str) -> dict:
    """data/overrides/<source>/<id>.json (empty if missing or unreadable)."""
    p = forge / "data" / "overrides" / source / f"{mid}.json"
    try:
        o = json.loads(p.read_text())
    except (OSError, ValueError):
        return {}
    return o if isinstance(o, dict) else {}


# monster.json ual_shared: what scripts/monster.gd needs to play the shared UAL clips (monster-forge
# tools/ual_library.py; "own" and "check" stay upstream)
UAL_SHARED_KEYS = ("library", "version", "hip_scale", "pelvis_offset", "root_bone", "pelvis_bone", "lift_axis", "fps",
                   "clips", "lift")


def ual_shared(man: dict) -> dict:
    sh = (man.get("anim") or {}).get("ual_shared") or {}
    return {k: sh[k] for k in UAL_SHARED_KEYS if k in sh} if sh.get("clips") else {}


def monster_json(src: Path, files: dict[str, Path], rec: dict, ov: dict | None = None,
                 tags: list | None = None) -> dict:
    man = json.loads((src / "manifest.json").read_text())
    rig = man.get("rig") or {}
    shared = ual_shared(man)
    lods = {"0": {"file": "model_rigged.glb", "tris": glb_tris(files["model_rigged.glb"])}}
    for name in files:
        if name.startswith("model_rigged_lod"):
            k = name[len("model_rigged_lod"):-len(".glb")]
            lods[k] = {"file": name, "tris": glb_tris(files[name])}
    # The rig stage renames each socket bone to the socket name in the GLB; the manifest
    # maps socket -> the bone it was derived from (kept for reference).
    sockets = {s: {"bone": s, "from": b} for s, b in sorted(rig.get("sockets", {}).items())}
    ov = ov or {}
    out = {
        "id": man["id"],
        "name": man.get("name", man["id"]),
        "source": man.get("source"),
        "scale_m": man.get("scale_m"),
        # D&D size category (tiny .. gargantuan): scripts/paired_anim.gd refuses a pair beyond the
        # entry's max_size_up (a grapple reaches one size up)
        "size": man.get("size"),
        "body_plan": man.get("body_plan"),
        "sockets": sockets,
        "clips": sorted({Path(n).stem for n in files if n.startswith("anims/")} | set(shared.get("clips", {}))),
        "lods": dict(sorted(lods.items(), key=lambda kv: int(kv[0]))),
        "joints": rig.get("joints"),
        "wields": rec.get("wields", []),
        "shield": bool(rec.get("shield", False)),
        # content tags (srd, type-beast, dinosaur, flying, large, cr-low ...): scripts/monster.gd ids_with_tags()
        "tags": list(tags if tags is not None else rec.get("tags", [])),
    }
    # Props are sized for a 1.8 m wielder: centauroids / merfolk-naga carry the rider's height
    # (override rider_height_m, docs/equipment.md "Prop space"); the game scales props by it.
    rh = man.get("rider_height_m", ov.get("rider_height_m", rec.get("rider_height_m")))
    if rh is not None:
        out["rider_height_m"] = rh
    # A swarm made as ONE unit (monster-forge docs/references.md "Swarm units"): the model is a
    # single unit at swarm_unit.scale_m, the game multiplies it over swarm_unit.swarm.scale_m.
    if man.get("swarm_unit"):
        out["swarm_unit"] = man["swarm_unit"]
    if shared:
        out["ual_shared"] = shared
    # ground speed (m/s at 1x) of each locomotion clip with planted feet: monster-forge manifest anim.speeds
    # (quadruped mocap walk / run); scripts/monster.gd clip_speed() / move_speed_scale()
    speeds = (man.get("anim") or {}).get("speeds") or {}
    if speeds:
        out["speeds"] = {c: v for c, v in sorted(speeds.items()) if c in out["clips"]}
    return out


PAIRED_REL = "_shared/paired"


def sync_library(out: Path, rel: str, dest: Path) -> list[str]:
    """The shared UAL clip library out/<source>/<rel>/ (library.json + one GLB per clip) to
    <dest>/<rel>/, once for every monster that uses it; GLBs it no longer lists are removed."""
    src = out / rel
    lib = json.loads((src / "library.json").read_text())
    files = {"library.json": src / "library.json"}
    for e in lib.get("clips", {}).values():
        files[e["file"]] = src / e["file"]
    for side in lib.get("paired", {}).values():   # paired animations: one sidecar per entry
        files[side] = src / side
    changes = copy_files(files, dest / rel)
    for dp in sorted((dest / rel).glob("*.glb")):
        if dp.name not in files:
            dp.unlink()
            Path(str(dp) + ".import").unlink(missing_ok=True)
            changes.append("removed " + dp.name)
    return changes


def copy_files(files: dict[str, Path], dest: Path) -> list[str]:
    changes = []
    dest.mkdir(parents=True, exist_ok=True)
    for rel, sp in files.items():
        dp = dest / rel
        if dp.exists() and dp.stat().st_size == sp.stat().st_size and digest(dp) == digest(sp):
            continue
        dp.parent.mkdir(parents=True, exist_ok=True)
        tmp = dp.with_suffix(dp.suffix + ".tmp")
        shutil.copyfile(sp, tmp)
        changes.append(("updated " if dp.exists() else "added   ") + rel)
        tmp.replace(dp)
    return changes


def has_shared(src: Path) -> bool:
    try:
        return bool(ual_shared(json.loads((src / "manifest.json").read_text())))
    except (OSError, ValueError):
        return False


def sync_one(src: Path, dest: Path, rec: dict, ov: dict | None = None, tags: list | None = None) -> list[str]:
    files = wanted_files(src)
    changes = copy_files(files, dest)
    # Remove GLBs the source no longer has (and Godot's .import sidecars for them).
    for dp in sorted(list(dest.glob("*.glb")) + list(dest.glob("anims/*.glb"))):
        rel = dp.relative_to(dest).as_posix()
        if rel not in files:
            dp.unlink()
            Path(str(dp) + ".import").unlink(missing_ok=True)
            changes.append("removed " + rel)
    text = json.dumps(monster_json(src, files, rec, ov, tags), indent=1) + "\n"
    mj = dest / "monster.json"
    if not mj.exists() or mj.read_text() != text:
        changes.append(("updated " if mj.exists() else "added   ") + "monster.json")
        mj.write_text(text)
    return changes


def sync_prop(src: Path, dest: Path) -> list[str]:
    files = {"model.glb": src / "model.glb", "manifest.json": src / "manifest.json"}
    if (src / "lods.json").exists():
        files["lods.json"] = src / "lods.json"
    for p in sorted(src.glob("model_lod*.glb")):
        files[p.name] = p
    changes = copy_files(files, dest)
    for dp in sorted(dest.glob("model_lod*.glb")):
        if dp.name not in files:
            dp.unlink()
            Path(str(dp) + ".import").unlink(missing_ok=True)
            changes.append("removed " + dp.name)
    return changes


def sync_props(prop_root: Path, ids: list[str], dest: Path) -> int:
    failed = 0
    for pid in ids:
        src = prop_root / pid
        if not (src / "model.glb").exists() or not (src / "manifest.json").exists():
            print(f"prop {pid}: skipped (no model.glb or manifest.json in {src})")
            failed += 1
            continue
        changes = sync_prop(src, dest / pid)
        print(f"prop {pid}: " + ("unchanged" if not changes else f"{len(changes)} change(s)"))
        for c in changes:
            print("  " + c)
    return failed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--ids", nargs="+", metavar="ID", help="these monsters and the props they wield")
    g.add_argument("--all", action="store_true", help="every monster with model_rigged.glb and clips, every prop")
    g.add_argument("--props", nargs="*", metavar="PROP", help="props only (all when no id is given)")
    ap.add_argument("--forge", type=Path, default=DEFAULT_FORGE, help="monster-forge checkout")
    ap.add_argument("--source", default="srd-5.2.1")
    ap.add_argument("--dest", type=Path, default=DEST)
    ap.add_argument("--props-dest", type=Path, default=PROPS_DEST)
    a = ap.parse_args()
    forge = a.forge.expanduser()
    prop_root = forge / "out" / "props"
    all_props = sorted(p.name for p in prop_root.iterdir() if (p / "model.glb").exists()) if prop_root.is_dir() else []
    if a.props is not None:
        return 1 if sync_props(prop_root, a.props or all_props, a.props_dest) else 0

    out = forge / "out" / a.source
    reg = registry(forge, a.source)
    tags = content_tags(forge, a.source)
    if not out.is_dir():
        print(f"no such directory: {out}", file=sys.stderr)
        return 2
    # --all: every rigged monster that also has clips (a rig without anims/ is still being
    # made, e.g. centaur-trooper in round 4; --ids syncs it anyway).
    ids = a.ids or sorted(p.name for p in out.iterdir()
                          if (p / "model_rigged.glb").exists() and (any((p / "anims").glob("*.glb")) or has_shared(p)))
    if a.all:
        for p in sorted(out.iterdir()):
            if (p / "model_rigged.glb").exists() and p.name not in ids:
                print(f"{p.name}: skipped (rigged, no anims/*.glb clips yet)")
    if a.all and a.dest.is_dir():
        for p in sorted(a.dest.iterdir()):
            if (p / "monster.json").exists() and p.name not in ids:
                print(f"{p.name}: kept (no model_rigged.glb upstream right now; delete the folder to drop it)")
    failed = 0
    libraries = set()
    for mid in ids:
        src = out / mid
        if not (src / "model_rigged.glb").exists() or not (src / "manifest.json").exists():
            print(f"{mid}: skipped (no model_rigged.glb or manifest.json in {src})")
            failed += 1
            continue
        try:
            changes = sync_one(src, a.dest / mid, reg.get(mid, {}), override(forge, a.source, mid), tags.get(mid))
        except (OSError, ValueError, KeyError) as e:
            print(f"{mid}: FAILED {e}")
            failed += 1
            continue
        print(f"{mid}: " + ("unchanged" if not changes else f"{len(changes)} change(s)"))
        for c in changes:
            print("  " + c)
        if has_shared(src):
            libraries.add(ual_shared(json.loads((src / "manifest.json").read_text()))["library"])
    # paired animations (monster-forge tools/paired.py): same clip format as the UAL library, for every
    # UAL biped; synced whenever any UAL biped is
    if libraries and (out / PAIRED_REL / "library.json").exists():
        libraries.add(PAIRED_REL)
    for rel in sorted(libraries):
        try:
            changes = sync_library(out, rel, a.dest)
        except (OSError, ValueError, KeyError) as e:
            print(f"{rel}: FAILED {e}")
            failed += 1
            continue
        print(f"{rel} (shared clips): " + ("unchanged" if not changes else f"{len(changes)} change(s)"))
        for c in changes:
            print("  " + c)
    if a.all:
        props = all_props
    else:
        props = sorted({w for mid in ids for w in reg.get(mid, {}).get("wields", [])})
    failed += sync_props(prop_root, props, a.props_dest)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
