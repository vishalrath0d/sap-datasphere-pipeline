#!/usr/bin/env python3
"""Read raw CLI output on stdin, emit clean, diff-friendly JSON on stdout.

The CLI may print warnings (e.g. "Your local CLI installation is outdated") around the
JSON document, so we locate the first parseable JSON object instead of assuming the
whole stream is JSON. Key order is preserved on purpose: in CSN the order of
'elements' is the column order.
"""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def extract_json(text):
    dec = json.JSONDecoder()
    i = text.find("{")
    while i != -1:
        try:
            obj, _ = dec.raw_decode(text[i:])
            return obj
        except ValueError:
            i = text.find("{", i + 1)
    raise ValueError("no JSON object found in CLI output")


def strip(node, keys):
    if isinstance(node, dict):
        return {k: strip(v, keys) for k, v in node.items() if k not in keys}
    if isinstance(node, list):
        return [strip(x, keys) for x in node]
    return node


def own_definitions_only(doc, name):
    """SAP's CLI guide: a file passed to `objects ... create` must hold one object, without its
    dependencies. Keep the object itself and, for a delta-capture local table, its <NAME>_Delta
    companion; report anything else that was dropped."""
    defs = doc.get("definitions") if isinstance(doc, dict) else None
    if not isinstance(defs, dict) or name not in defs:
        return doc
    keep = {k: v for k, v in defs.items() if k in (name, name + "_Delta")}
    dropped = sorted(set(defs) - set(keep))
    if dropped:
        print("normalize: %s: dropped dependency definitions %s" % (name, ", ".join(dropped)), file=sys.stderr)
    doc["definitions"] = keep
    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", help="technical name of the object being exported")
    args = ap.parse_args()
    cfg = {}
    cfg_path = ROOT / "config" / "normalize.json"
    if cfg_path.exists():
        cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    keys = set(cfg.get("strip_keys", []))
    raw = sys.stdin.read()
    try:
        doc = extract_json(raw)
    except ValueError as exc:
        print("normalize: %s\n--- raw output (first 500 chars) ---\n%s" % (exc, raw[:500]), file=sys.stderr)
        return 1
    if args.name and cfg.get("own_definition_only", True):
        doc = own_definitions_only(doc, args.name)
    doc = strip(doc, keys)
    sys.stdout.write(json.dumps(doc, indent=cfg.get("indent", 2), ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
