#!/usr/bin/env python3
"""Rejoue la détection du souffle sur des prises CSV du mode debug.

Usage : scripts/analyse-souffle.py ~/Downloads/*.csv [--seuil -48] [--harmonicite 0.6] [--graves 0.75]
                                     [--aigus 0.05] [--centre 250] [--duree 0.12] [--tolerance 0.18]

Pour chaque prise : nombre de blocs « souffle », temps porte ouverte, et médianes des mesures sur les
blocs au-dessus du seuil. Les valeurs par défaut sont celles de BlowClassifier.
"""
import argparse, csv, statistics, sys

p = argparse.ArgumentParser()
p.add_argument("fichiers", nargs="+")
p.add_argument("--seuil", type=float, default=-45)
p.add_argument("--harmonicite", type=float, default=0.6)
p.add_argument("--graves", type=float, default=0.75)
p.add_argument("--aigus", type=float, default=0.05)
p.add_argument("--centre", type=float, default=200)
p.add_argument("--duree", type=float, default=0.12)
p.add_argument("--tolerance", type=float, default=0.18)
p.add_argument("--direct", type=float, default=-20, help="niveau de la voie « souffle direct » (dB)")
a = p.parse_args()

def load(path):
    with open(path) as fh:
        lines = [l for l in fh if not l.startswith("#")]
    return [{k: float(v) for k, v in row.items()} for row in csv.DictReader(lines)]

for path in a.fichiers:
    rows = load(path)
    if len(rows) < 2:
        continue
    dt = rows[1]["t"] - rows[0]["t"]
    run = other = 0.0
    is_open = False
    like_n = open_n = 0
    for r in rows:
        like = (r["levelDB"] >= a.seuil and r["harmonicity"] <= a.harmonicite and r["lowRatio"] >= a.graves
                and r["highRatio"] <= a.aigus and r["centroidHz"] <= a.centre)
        # Voie « souffle direct » (même logique que BlowClassifier.isDirectBlow).
        like = like or (r["levelDB"] >= a.direct and r["lowRatio"] >= 0.6 and r["highRatio"] <= 0.15
                        and r["centroidHz"] <= 400 and r["harmonicity"] <= 0.7)
        like_n += like
        # Même hystérésis que BlowGate : blocs consécutifs pour ouvrir, tolérance pour refermer.
        if is_open:
            other = 0 if like else other + dt
            if other >= a.tolerance:
                is_open, run = False, 0
        else:
            run = run + dt if like else 0
            if run >= a.duree:
                is_open, other = True, 0
        open_n += is_open
    loud = [r for r in rows if r["levelDB"] >= a.seuil]
    med = lambda k: statistics.median(r[k] for r in loud) if loud else float("nan")
    name = path.split("/")[-1]
    print(f"{name:60} souffle {like_n:3d} blocs · ouvert {open_n * dt:4.1f} s · "
          f"au-dessus du seuil : {len(loud):3d} blocs, centre {med('centroidHz'):5.0f} Hz, "
          f"harmon. {med('harmonicity'):.2f}, graves {med('lowRatio'):.2f}")
