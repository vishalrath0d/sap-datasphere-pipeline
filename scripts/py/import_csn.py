#!/usr/bin/env python3
"""Split a multi-object CSN file (Data Builder "Export to CSN/JSON", an E/R model export, SAP
sample content) into one CLI-ready file per object under definitions/<type>/<NAME>.json.

Why: SAP's CLI guide - a CSN file exported from the UI "contains the view and all its
dependencies. CSN files generated in this way cannot be used directly with the command line.
You must provide one CSN file for each object (excluding any dependencies)".

  python3 scripts/py/import_csn.py "Bike Sales Model.json"            # dry run: shows what it would write
  python3 scripts/py/import_csn.py "Bike Sales Model.json" --write    # writes definitions/...

Each output file is shaped like the create example in SAP's CLI guide (5.1): object-level
@EndUserText.label and @ObjectModel annotations, @EndUserText.label on every column.
Older exports label columns with @Common.Label; that is copied to @EndUserText.label.
Associations between tables are kept - deploy order takes care of their targets.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA_STRUCTURE = {"#": "DATA_STRUCTURE"}


def object_type(ent):
    if "query" in ent or "@DataWarehouse.sqlEditor.query" in ent:
        return "views"
    if any(k.startswith("@DataWarehouse.remote") for k in ent):
        return "remote-tables"
    return "local-tables"


def cli_shape(name, ent):
    out = {"kind": "entity"}
    out["@EndUserText.label"] = ent.get("@EndUserText.label") or ent.get("@Common.Label") or name
    out["@ObjectModel.modelingPattern"] = ent.get("@ObjectModel.modelingPattern", DATA_STRUCTURE)
    out["@ObjectModel.supportedCapabilities"] = ent.get("@ObjectModel.supportedCapabilities", [DATA_STRUCTURE])
    for k, v in ent.items():
        if k not in out and k not in ("@Common.Label", "elements"):
            out[k] = v
    elements = {}
    for col, el in (ent.get("elements") or {}).items():
        new = {}
        if el.get("type") not in ("cds.Association", "cds.Composition"):
            new["@EndUserText.label"] = el.get("@EndUserText.label") or el.get("@Common.Label") or col
        for k, v in el.items():
            if k not in ("@Common.Label", "@EndUserText.label"):
                new[k] = v
        elements[col] = new
    out["elements"] = elements
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csn_file")
    ap.add_argument("--out", default=str(ROOT / "definitions"))
    ap.add_argument("--write", action="store_true", help="write the files (default: dry run)")
    ap.add_argument("--overwrite", action="store_true", help="replace files that already exist")
    args = ap.parse_args()

    doc = json.loads(Path(args.csn_file).read_text(encoding="utf-8-sig"))
    defs = doc.get("definitions") or {}
    if not defs:
        sys.exit("no 'definitions' in %s" % args.csn_file)

    written = 0
    for name, ent in defs.items():
        if not isinstance(ent, dict) or ent.get("kind") != "entity":
            print("skip  %-30s kind=%s (not an entity)" % (name, ent.get("kind") if isinstance(ent, dict) else "?"))
            continue
        t = object_type(ent)
        path = Path(args.out) / t / ("%s.json" % name)
        if path.exists() and not args.overwrite:
            print("keep  %s (exists; --overwrite to replace)" % path.relative_to(ROOT) if ROOT in path.parents else path)
            continue
        print("%s %s/%s.json" % ("write" if args.write else "would write", t, name))
        if args.write:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"definitions": {name: cli_shape(name, ent)}}, indent=2, ensure_ascii=False) + "\n",
                            encoding="utf-8")
            written += 1
    if not args.write:
        print("\ndry run - add --write to create the files")
    else:
        print("\n%d file(s) written. Next: python3 scripts/py/validate.py && python3 scripts/py/order.py --plan" % written)
    return 0


if __name__ == "__main__":
    sys.exit(main())
