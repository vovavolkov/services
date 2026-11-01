#!/usr/bin/env python3
"""
Reconcile the worldgen datapacks/mods on an itzg/minecraft-server data volume.

Several of the installed mods overwrite the same vanilla files whole-file, so
mod load order silently decides which one applies. This script reads whatever
versions are actually present, merges the contested files, and emits a single
datapack that loads last and therefore wins deterministically.

What it resolves
  biomes            Terralith terrain + Geophilic detail + Matcha's mob/audio
                    rebalance, in one file per biome
  villages          Matcha's rarity pacing + Trek's village variants
  end_cities        Nullscape's island-matched spacing + Trek's building pieces
  outposts/dungeons Trek's geometry wins over Matcha's (see POLICY below)

Everything is derived from the archives at runtime, so upgrading any mod is
just a re-run. Exits non-zero if the result would crash worldgen.

Usage:  mc-worldgen-merge.py [--data /data] [--dry-run]
Env:    MC_DATA_DIR, MC_MODS_DIR, MC_DATAPACKS_DIR, MATCHA_VERSION
"""

import argparse
import collections
import io
import itertools
import json
import os
import re
import shutil
import sys
import urllib.request
import zipfile

PACK_NAME = "zzz-worldgen-merge"  # sorts last -> applied last -> wins
PACK_FORMAT = 107
MATCHA_PROJECT = "matcha-flavoured"

BIOME_DIR = "data/minecraft/worldgen/biome/"
BIOME_RE = re.compile(r"^data/[a-z0-9_.-]+/worldgen/biome/[a-z0-9_/.-]+\.json$")
VILLAGES = "data/minecraft/worldgen/structure_set/villages.json"
END_CITIES = "data/minecraft/worldgen/structure_set/end_cities.json"

# Files where Trek's structure geometry must beat Matcha's vanilla-shaped
# version: Trek ships its own NBT under these names and its outpost variants
# build from these pools. Letting Matcha win here would break Trek's pieces.
TREK_WINS = [
    "data/minecraft/worldgen/structure/pillager_outpost.json",
    "data/minecraft/worldgen/template_pool/pillager_outpost/features.json",
    "data/minecraft/worldgen/template_pool/pillager_outpost/towers.json",
]

# Trek pins every dungeon to a single Y: its "lower" set to above_bottom 30
# (y -34) and its "upper" set to absolute -70 -- which is below the -64 world
# floor that Terralith and Tectonic both keep, so those four never place at all.
# Spread all eight through the cave column instead. `start_height` is a height
# provider, so a uniform range is valid here.
TREK_DUNGEON_DIR = "data/trek/worldgen/structure/monster_room/"
TREK_DUNGEON_BAND = {
    "type": "minecraft:uniform",
    "min_inclusive": {"above_bottom": 9},   # y -55
    "max_inclusive": {"absolute": 40},
}

# Trek ships its dungeon sets at spacing 1 / separation 0 -- one attempt in
# every chunk, from each of two sets. That is roughly two guaranteed dungeons
# per chunk, which is not "common", it is wall-to-wall.
#
# Matcha's own numbers say what it wants: villages went 34/8 -> 80/50 (much
# sparser) while monster_room went 8 -> 15 (denser). So the design is distant
# settlements over a rewarding underground -- not fewer dungeons, just fewer
# towns. Honour that split: vanilla dungeons keep Matcha's counts and stay the
# baseline you meet while caving, and Trek's custom rooms become the occasional
# find rather than the norm.
#
# 3/1 puts one attempt per 3x3 chunk cell per set. Across both sets that is
# roughly one Trek room every 4-5 chunks (~70 blocks) -- still something you
# run into regularly while caving, just not the two-per-chunk carpet Trek
# ships. separation must stay below spacing.
TREK_DUNGEON_SET_DIR = "data/trek/worldgen/structure_set/monster_room/"
TREK_DUNGEON_SPACING = 3
TREK_DUNGEON_SEPARATION = 1

# None means "keep whatever Matcha chose". We still have to emit the file:
# Trek zeroes these to disable vanilla dungeons, so without an explicit winner
# the outcome depends on mod load order.
VANILLA_DUNGEONS = {
    "data/minecraft/worldgen/placed_feature/monster_room.json": None,
    "data/minecraft/worldgen/placed_feature/monster_room_deep.json": None,
}

# Biome fields taken from Matcha. Its worldgen is stock vanilla -- the whole
# point of the pack is the rebalance -- so we take gameplay and audio only.
# Visuals stay with the terrain mod: Matcha moved colours into the 26.x
# `attributes` block while Terralith still uses `effects`, and mixing the two
# would fight over the same colours.
MATCHA_FIELDS = ["spawners", "spawn_costs", "creature_spawn_probability"]
MATCHA_ATTR_PREFIX = "minecraft:audio/"

# Mods identified by filename, since itzg names files by whatever version it
# resolved. Order matters only for reporting.
JAR_PATTERNS = {
    "terralith": r"terralith.*\.jar$",
    "geophilic": r"geophilic.*\.jar$",
    "nullscape": r"nullscape.*\.jar$",
    "trek": r"trek.*\.jar$",
    "terraphilic": r"terraphilic.*\.jar$",  # optional, mined for hints
}

# Geophilic ships its per-version biomes as pack.mcmeta overlays; these are the
# directories that apply at pack_format 107, in declaration order.
GEO_LAYERS = [
    "", "f26data", "f41data", "f61-pale_garden", "f71-spring_to_life",
    "f101-2026-1", "f26-2", "biomes_1_21_4", "biomes_1_21_5", "biomes_1_21_11",
]
TP_LAYERS = ["biomes_21", "biomes_21_2", "biomes_21_4"]


# --------------------------------------------------------------------------
# discovery


def find_jars(mods_dir):
    found = {}
    if not os.path.isdir(mods_dir):
        return found
    names = sorted(os.listdir(mods_dir))
    for key, pattern in JAR_PATTERNS.items():
        rx = re.compile(pattern, re.I)
        hits = [n for n in names if rx.search(n)]
        if hits:
            found[key] = os.path.join(mods_dir, sorted(hits)[-1])
    return found


def find_matcha(datapacks_dir):
    if not os.path.isdir(datapacks_dir):
        return None
    hits = [n for n in sorted(os.listdir(datapacks_dir))
            if re.search(r"matcha.*\.zip$", n, re.I)]
    return os.path.join(datapacks_dir, hits[-1]) if hits else None


def download_matcha(datapacks_dir, want_version=None):
    """Fetch Matcha from Modrinth if it is not already on the volume."""
    url = f"https://api.modrinth.com/v2/project/{MATCHA_PROJECT}/version"
    with urllib.request.urlopen(url, timeout=30) as r:
        versions = json.load(r)
    picks = [v for v in versions if "26.2" in v["game_versions"]]
    if want_version:
        picks = [v for v in picks if v["version_number"] == want_version] or picks
    if not picks:
        return None
    f = picks[0]["files"][0]
    dst = os.path.join(datapacks_dir, f["filename"])
    os.makedirs(datapacks_dir, exist_ok=True)
    with urllib.request.urlopen(f["url"], timeout=120) as r, open(dst, "wb") as out:
        shutil.copyfileobj(r, out)
    return dst


# --------------------------------------------------------------------------
# archive readers


def zip_biomes(path, layers=None, minecraft_only=False):
    """{biome_id: doc}. `layers` resolves pack.mcmeta overlays, later winning."""
    out = {}
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        if layers is None:
            for n in names:
                if BIOME_RE.match(n):
                    ns = n.split("/")[1]
                    name = n[n.index("/worldgen/biome/") + 16:-5]
                    if minecraft_only and ns != "minecraft":
                        continue
                    out[f"{ns}:{name}"] = json.loads(z.read(n))
        else:
            for layer in layers:
                prefix = (layer + "/" if layer else "") + BIOME_DIR
                for n in names:
                    if n.startswith(prefix) and n.endswith(".json"):
                        out["minecraft:" + os.path.basename(n)[:-5]] = json.loads(z.read(n))
    return out


def zip_json(path, member):
    with zipfile.ZipFile(path) as z:
        try:
            return json.loads(z.read(member))
        except KeyError:
            return None


def dir_or_zip_json(path, member):
    if os.path.isdir(path):
        f = os.path.join(path, member)
        return json.load(open(f)) if os.path.exists(f) else None
    return zip_json(path, member)


def matcha_biomes(path):
    out = {}
    with zipfile.ZipFile(path) as z:
        for n in z.namelist():
            if n.startswith(BIOME_DIR) and n.endswith(".json"):
                out["minecraft:" + os.path.basename(n)[:-5]] = json.loads(z.read(n))
    return out


# --------------------------------------------------------------------------
# Terralith + Geophilic merge (ordering-safe)


def flat(doc):
    return {f for step in doc.get("features", []) for f in step}


def mine_suppression(tp_path, geo):
    """Which Geophilic features Terraphilic dropped as Terralith duplicates."""
    if not tp_path:
        return {}, set()
    tp = zip_biomes(tp_path, TP_LAYERS)
    per, glob_ = {}, set()
    for bid, doc in tp.items():
        if bid not in geo:
            continue
        dropped = {f for f in flat(geo[bid]) - flat(doc) if f.startswith("geophilic:")}
        if dropped:
            per[bid] = dropped
            glob_ |= dropped
    return per, glob_


def select_features(base, geo, suppress):
    """Terralith features, minus what Geophilic removes, plus what it adds."""
    geo_all = flat(geo)
    b_steps, g_steps = base.get("features", []), geo.get("features", [])
    steps, stats = [], collections.Counter()
    for i in range(max(len(b_steps), len(g_steps))):
        b = b_steps[i] if i < len(b_steps) else []
        g = g_steps[i] if i < len(g_steps) else []
        kept = []
        for f in b:
            if f.startswith("minecraft:") and f not in geo_all:
                stats["vanilla_dropped"] += 1
                continue
            kept.append(f)
        chosen, seen = list(kept), set(kept)
        for f in g:
            if f in suppress:
                stats["geophilic_suppressed"] += 1
                continue
            if f in seen:
                continue
            seen.add(f)
            chosen.append(f)
            stats["geophilic_added"] += 1
        steps.append(chosen)
    return steps, stats


def canonical_order(biomes):
    """Total order per step, consistent with every biome we are NOT rewriting."""
    nsteps = max((len(d.get("features", [])) for d in biomes.values()), default=0)
    orders = []
    for step in range(nsteps):
        edges, indeg, nodes = collections.defaultdict(set), collections.Counter(), set()
        for doc in biomes.values():
            fs = doc.get("features", [])
            seq = fs[step] if step < len(fs) else []
            nodes.update(seq)
            for a, b in zip(seq, seq[1:]):
                if b not in edges[a]:
                    edges[a].add(b)
                    indeg[b] += 1
        ready = sorted(n for n in nodes if indeg[n] == 0)
        out = []
        while ready:
            u = ready.pop(0)
            out.append(u)
            for v in sorted(edges[u]):
                indeg[v] -= 1
                if indeg[v] == 0:
                    ready.append(v)
            ready.sort()
        out += [n for n in sorted(nodes) if n not in out]
        orders.append({f: i for i, f in enumerate(out)})
    return orders


def global_ranks(canon, selected):
    """
    One rank table per step for every biome we emit. Features the baseline
    already orders keep their rank; anything new gets a single global slot.
    Sorting every emitted biome by this table makes ordering cycles impossible
    -- provided `selected` covers every biome carrying a non-baseline feature.
    """
    ranks, conflicts = [dict(r) for r in canon], []
    for step, rank in enumerate(ranks):
        bounds = {}
        for steps in selected.values():
            seq = steps[step] if step < len(steps) else []
            for idx, f in enumerate(seq):
                if f in rank:
                    continue
                lower = max((rank[p] for p in seq[:idx] if p in rank), default=None)
                upper = min((s for s in (rank.get(x) for x in seq[idx + 1:])
                             if s is not None), default=None)
                lo, hi = bounds.get(f, (None, None))
                if lower is not None:
                    lo = lower if lo is None else max(lo, lower)
                if upper is not None:
                    hi = upper if hi is None else min(hi, upper)
                bounds[f] = (lo, hi)
        for f in sorted(bounds):
            lo, hi = bounds[f]
            if lo is None and hi is None:
                rank[f] = -1.0
            elif lo is None:
                rank[f] = hi - 0.5
            elif hi is None:
                rank[f] = lo + 0.5
            elif lo < hi:
                rank[f] = (lo + hi) / 2.0
            else:
                rank[f] = lo + 0.5
                conflicts.append((step, f))
        for i, f in enumerate(sorted(rank, key=lambda x: (rank[x], x))):
            rank[f] = float(i)
    return ranks, conflicts


def apply_matcha(doc, mdoc, stats):
    """Overlay Matcha's rebalance onto a terrain-owner's biome."""
    if mdoc is None:
        return doc
    for key in MATCHA_FIELDS:
        if key in mdoc:
            if doc.get(key) != mdoc[key]:
                stats["matcha_fields"] += 1
            doc[key] = mdoc[key]
    audio = {k: v for k, v in (mdoc.get("attributes") or {}).items()
             if k.startswith(MATCHA_ATTR_PREFIX)}
    if audio:
        merged = dict(doc.get("attributes") or {})
        merged.update(audio)
        doc["attributes"] = merged
        stats["matcha_audio"] += 1
    return doc


# --------------------------------------------------------------------------
# structure set merges


def merge_villages(matcha_path, trek_path):
    """Matcha's rarity, Trek's roster. Neither survives the other alone."""
    m = zip_json(matcha_path, VILLAGES) if matcha_path else None
    t = zip_json(trek_path, VILLAGES) if trek_path else None
    if m is None and t is None:
        return None, None
    if m is None:
        return t, "trek only"
    if t is None:
        return m, "matcha only"
    out = json.loads(json.dumps(m))          # Matcha placement
    seen = {s.get("structure") for s in out.get("structures", [])}
    added = []
    for entry in t.get("structures", []):
        if entry.get("structure") not in seen:
            seen.add(entry.get("structure"))
            out["structures"].append(entry)
            added.append(entry["structure"])
    return out, added


def respread_trek_dungeons(trek_path):
    """Give Trek's fixed-depth dungeons a real Y range. {member: doc}."""
    if not trek_path:
        return {}, []
    out, notes = {}, []
    with zipfile.ZipFile(trek_path) as z:
        for n in z.namelist():
            if not (n.startswith(TREK_DUNGEON_DIR) and n.endswith(".json")):
                continue
            doc = json.loads(z.read(n))
            before = doc.get("start_height")
            doc["start_height"] = json.loads(json.dumps(TREK_DUNGEON_BAND))
            out[n] = doc
            notes.append((n[len(TREK_DUNGEON_DIR):-5], before))
    return out, notes


def thin_trek_dungeon_sets(trek_path):
    """Pull Trek's dungeon sets back off spacing 1. {member: doc}, plus notes."""
    if not trek_path:
        return {}, []
    out, notes = {}, []
    with zipfile.ZipFile(trek_path) as z:
        for n in z.namelist():
            if not (n.startswith(TREK_DUNGEON_SET_DIR) and n.endswith(".json")):
                continue
            doc = json.loads(z.read(n))
            place = doc.get("placement", {})
            before = (place.get("spacing"), place.get("separation"))
            place["spacing"] = TREK_DUNGEON_SPACING
            place["separation"] = TREK_DUNGEON_SEPARATION
            doc["placement"] = place
            out[n] = doc
            notes.append((n[len(TREK_DUNGEON_SET_DIR):-5], before))
    return out, notes


def tune_vanilla_dungeons(matcha_path, trek_path):
    """
    Emit the vanilla dungeon features with an explicit winner. Matcha's file is
    the base -- it carries the real placement modifiers, and Trek's is stripped
    down to `count: 0` to switch them off. A count of None keeps Matcha's value.
    """
    out = {}
    for member, count in VANILLA_DUNGEONS.items():
        doc = None
        for src in (matcha_path, trek_path):
            if src:
                doc = dir_or_zip_json(src, member)
                if doc and any(p.get("type") == "minecraft:count"
                               and p.get("count") for p in doc.get("placement", [])):
                    break
        if not doc:
            continue
        doc = json.loads(json.dumps(doc))
        if count is not None:
            for p in doc.get("placement", []):
                if p.get("type") == "minecraft:count":
                    p["count"] = count
        out[member] = doc
    return out


def merge_end_cities(null_path, trek_path):
    """Nullscape's spacing (it reshapes the islands), union of the rosters."""
    n = zip_json(null_path, END_CITIES) if null_path else None
    t = zip_json(trek_path, END_CITIES) if trek_path else None
    if n is None:
        return None, None
    out = json.loads(json.dumps(n))
    seen = {s.get("structure") for s in out.get("structures", [])}
    added = []
    for entry in (t or {}).get("structures", []):
        if entry.get("structure") not in seen:
            seen.add(entry.get("structure"))
            out["structures"].append(entry)
            added.append(entry["structure"])
    return out, added


# --------------------------------------------------------------------------
# validation


def write_member(z, name, data):
    """
    Write with a fixed timestamp. This script runs on every container start, so
    a stable byte-for-byte result makes "did anything actually change?" a
    hash comparison instead of a guess.
    """
    info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    z.writestr(info, data)


def find_cycles(biomes):
    """Minecraft rejects biomes that imply contradictory feature orderings."""
    nsteps = max((len(d.get("features", [])) for d in biomes.values()), default=0)
    bad = []
    for step in range(nsteps):
        edges, nodes = collections.defaultdict(set), set()
        for doc in biomes.values():
            fs = doc.get("features", [])
            seq = fs[step] if step < len(fs) else []
            nodes.update(seq)
            for a, b in itertools.combinations(seq, 2):
                edges[a].add(b)
        color = {}

        def dfs(u):
            color[u] = 1
            for v in sorted(edges.get(u, ())):
                if color.get(v) == 1:
                    return (u, v)
                if color.get(v) is None:
                    hit = dfs(v)
                    if hit:
                        return hit
            color[u] = 2
            return None

        sys.setrecursionlimit(10000)
        for u in sorted(nodes):
            if color.get(u) is None:
                hit = dfs(u)
                if hit:
                    bad.append((step,) + hit)
                    break
    return bad


# --------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=os.environ.get("MC_DATA_DIR", "/data"))
    ap.add_argument("--mods", default=os.environ.get("MC_MODS_DIR"))
    ap.add_argument("--datapacks", default=os.environ.get("MC_DATAPACKS_DIR"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    mods = args.mods or os.path.join(args.data, "mods")
    datapacks = args.datapacks or os.path.join(args.data, "world", "datapacks")

    jars = find_jars(mods)
    print("mods dir:      ", mods)
    print("datapacks dir: ", datapacks)
    for k in sorted(JAR_PATTERNS):
        print(f"  {k:<12} {os.path.basename(jars[k]) if k in jars else '-- not found --'}")

    if "terralith" not in jars or "geophilic" not in jars:
        sys.exit("need at least Terralith and Geophilic in %s" % mods)

    matcha = find_matcha(datapacks)
    if not matcha:
        print("  matcha       not on volume, downloading...")
        matcha = download_matcha(datapacks, os.environ.get("MATCHA_VERSION"))
    print(f"  {'matcha':<12} {os.path.basename(matcha) if matcha else '-- none --'}")

    terra_all = zip_biomes(jars["terralith"])
    terra = {k: v for k, v in terra_all.items() if k.startswith("minecraft:")}
    geo = zip_biomes(jars["geophilic"], GEO_LAYERS)
    null_ = zip_biomes(jars["nullscape"]) if "nullscape" in jars else {}
    mat = matcha_biomes(matcha) if matcha else {}

    per_sup, glob_sup = mine_suppression(jars.get("terraphilic"), geo)

    shared = sorted(set(terra) & set(geo))
    geo_only = sorted(set(geo) - set(terra))

    # Every biome we rewrite must be ranked together, or their orders can
    # contradict each other at runtime.
    selected, stats_by = {}, {}
    for bid in shared:
        steps, st = select_features(terra[bid], geo[bid],
                                    per_sup.get(bid, glob_sup))
        selected[bid], stats_by[bid] = steps, st
    for bid in geo_only:
        selected[bid] = [list(s) for s in geo[bid].get("features", [])]
        stats_by[bid] = collections.Counter()

    canon = canonical_order(terra_all)
    ranks, conflicts = global_ranks(canon, selected)

    def order(steps):
        return [sorted(step, key=lambda f, i=i: (
            ranks[i].get(f, len(ranks[i])) if i < len(ranks) else 0, f))
            for i, step in enumerate(steps)]

    out_docs, totals = {}, collections.Counter()

    for bid in shared + geo_only:
        st = stats_by[bid]
        if bid in shared:
            doc = json.loads(json.dumps(terra[bid]))
            spawn = {k: list(v) for k, v in doc.get("spawners", {}).items()}
            for cat, entries in geo[bid].get("spawners", {}).items():
                dst = spawn.setdefault(cat, [])
                for e in entries or []:
                    if e not in dst:
                        dst.append(e)
                        st["spawns_added"] += 1
            if spawn:
                doc["spawners"] = spawn
        else:
            doc = json.loads(json.dumps(geo[bid]))
        doc["features"] = order(selected[bid])
        out_docs[bid] = apply_matcha(doc, mat.get(bid), st)
        totals.update(st)

    # Biomes Matcha rebalances that a terrain mod owns but Geophilic never
    # touched -- Terralith's other vanilla biomes, and Nullscape's End.
    extra = 0
    for bid, mdoc in sorted(mat.items()):
        if bid in out_docs:
            continue
        base = null_.get(bid) or terra.get(bid)
        if base is None:
            continue  # nobody contests it; Matcha's own file applies
        st = collections.Counter()
        out_docs[bid] = apply_matcha(json.loads(json.dumps(base)), mdoc, st)
        totals.update(st)
        extra += 1

    villages, v_added = merge_villages(matcha, jars.get("trek"))
    end_cities, e_added = merge_end_cities(jars.get("nullscape"), jars.get("trek"))
    trek_dungeons, dungeon_notes = respread_trek_dungeons(jars.get("trek"))
    trek_dungeon_sets, set_notes = thin_trek_dungeon_sets(jars.get("trek"))
    vanilla_dungeons = tune_vanilla_dungeons(matcha, jars.get("trek"))

    # ---- validate against everything that stays on disk -------------------
    effective = dict(terra_all)
    effective.update(null_)
    for bid, doc in geo.items():
        effective.setdefault(bid, doc)
    for bid, doc in mat.items():
        effective.setdefault(bid, doc)
    effective.update(out_docs)          # ours load last
    cycles = find_cycles(effective)

    print()
    print(f"biomes rewritten:        {len(out_docs)}"
          f"  ({len(shared)} merged, {len(geo_only)} geophilic-only, {extra} matcha-overlay)")
    print(f"geophilic features added:{totals['geophilic_added']:>6}")
    print(f"vanilla features dropped:{totals['vanilla_dropped']:>6}")
    print(f"geophilic suppressed:    {totals['geophilic_suppressed']:>6}")
    print(f"mob spawns added:        {totals['spawns_added']:>6}")
    print(f"matcha fields applied:   {totals['matcha_fields']:>6}")
    print(f"matcha audio applied:    {totals['matcha_audio']:>6}")
    print(f"ordering conflicts eased:{len(conflicts):>6}")
    print(f"villages:   {'placement=matcha, +%d trek variants' % len(v_added) if isinstance(v_added, list) else v_added}")
    print(f"end_cities: {'placement=nullscape' if end_cities else 'n/a'}"
          f"{', +%d from trek' % len(e_added) if e_added else ''}")
    print(f"trek-wins passthrough:   {len(TREK_WINS)} files")
    band = "%s..%s" % (TREK_DUNGEON_BAND["min_inclusive"],
                       TREK_DUNGEON_BAND["max_inclusive"])
    print(f"trek dungeons respread:  {len(trek_dungeons)} structures -> {band}")
    for name, before in dungeon_notes:
        flag = "  <- was below world floor" if before == {"absolute": -70} else ""
        print(f"    {name:<24} was {json.dumps(before)}{flag}")
    print(f"trek dungeon sets thinned: {len(trek_dungeon_sets)} -> "
          f"spacing {TREK_DUNGEON_SPACING}, separation {TREK_DUNGEON_SEPARATION}")
    for name, (sp, sep) in set_notes:
        print(f"    {name:<24} was spacing {sp}, separation {sep}")
    print("vanilla dungeons:        " + ", ".join(
        "%s=%s" % (os.path.basename(k)[:-5],
                   next((p.get("count") for p in vanilla_dungeons[k].get("placement", [])
                         if p.get("type") == "minecraft:count"), "?"))
        for k in sorted(vanilla_dungeons)) or "none")
    print(f"biomes in ordering graph:{len(effective):>6}")
    print(f"ORDERING CYCLES: {cycles or 'NONE'}")

    if cycles:
        sys.exit("refusing to write: worldgen would crash on chunk generation")
    if args.dry_run:
        print("dry run, nothing written")
        return

    # ---- write ------------------------------------------------------------
    os.makedirs(datapacks, exist_ok=True)
    dst = os.path.join(datapacks, PACK_NAME + ".zip")
    tmp = dst + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        write_member(z, "pack.mcmeta", json.dumps({
            "pack": {
                "name": PACK_NAME,
                "description": "Merged worldgen: Terralith + Geophilic + Matcha + Trek/Nullscape",
                "pack_format": PACK_FORMAT,
                "supported_formats": [PACK_FORMAT, 512],
                "min_format": PACK_FORMAT,
                "max_format": 512,
            }
        }, indent=2))
        for bid, doc in sorted(out_docs.items()):
            ns, name = bid.split(":", 1)
            write_member(z, f"data/{ns}/worldgen/biome/{name}.json",
                         json.dumps(doc, indent=2))
        if villages:
            write_member(z, VILLAGES, json.dumps(villages, indent=2))
        if end_cities:
            write_member(z, END_CITIES, json.dumps(end_cities, indent=2))
        trek = jars.get("trek")
        if trek:
            with zipfile.ZipFile(trek) as tz:
                for member in TREK_WINS:
                    try:
                        write_member(z, member, tz.read(member))
                    except KeyError:
                        pass
        for member, doc in sorted(trek_dungeons.items()):
            write_member(z, member, json.dumps(doc, indent=2))
        for member, doc in sorted(trek_dungeon_sets.items()):
            write_member(z, member, json.dumps(doc, indent=2))
        for member, doc in sorted(vanilla_dungeons.items()):
            write_member(z, member, json.dumps(doc, indent=2))
    os.replace(tmp, dst)
    print("\nwrote", dst)


if __name__ == "__main__":
    main()
