#!/usr/bin/env python3
"""Print objects from definitions/ in a deployable order.

  order.py            TSV: type<TAB>name<TAB>path   (dependencies first)  - used by deploy.sh
  order.py --plan     human readable plan with dependencies               - used by the 'plan' job
  order.py --list     TSV: type<TAB>name, alphabetical (what is tracked)  - used by export.sh
"""
import argparse
import os
import sys
from pathlib import Path

import dslib

ROOT = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.environ.get("DEF_DIR", str(ROOT / "definitions")))
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--plan", action="store_true")
    g.add_argument("--list", action="store_true")
    g.add_argument("--types", action="store_true", help="print supported object types")
    args = ap.parse_args()

    if args.types:
        print(" ".join(sorted(dslib.TYPE_RANK, key=lambda t: dslib.TYPE_RANK[t])))
        return 0

    objs, problems = dslib.load_all(args.root)
    for path, msg in problems:
        print("ERROR %s: %s" % (path, msg), file=sys.stderr)
    bad = [o for o in objs if o.error]
    for o in bad:
        print("ERROR %s: %s" % (o.rel, o.error), file=sys.stderr)
    if problems or bad:
        return 2

    if args.list:
        for o in sorted(objs, key=lambda o: (o.type, o.name)):
            print("%s\t%s" % (o.type, o.name))
        return 0

    try:
        order, deps = dslib.toposort(objs)
    except dslib.CycleError as exc:
        print("ERROR %s" % exc, file=sys.stderr)
        return 2

    if args.plan:
        print("Deployment plan (%d objects) - dependencies first" % len(order))
        print("-" * 60)
        for i, o in enumerate(order, 1):
            d = ", ".join(sorted(deps[o.name])) or "-"
            print("%2d. %-14s %-24s depends on: %s" % (i, o.type, o.name, d))
        return 0

    for o in order:
        print("%s\t%s\t%s" % (o.type, o.name, o.path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
