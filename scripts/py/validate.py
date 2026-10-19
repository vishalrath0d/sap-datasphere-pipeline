#!/usr/bin/env python3
"""Static checks on definitions/ - runs in the 'validate' stage, needs no tenant.

Checks: valid JSON, CSN shape, file name == definitions key, naming policy,
no duplicate names, no secrets, every FROM reference resolvable, no cycles.
Exit code 1 if any error. Optional JUnit XML for GitLab's test report widget.
"""
import argparse
import os
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import dslib

ROOT = Path(__file__).resolve().parents[2]

SECRET_PATTERNS = [
    re.compile(r'(?i)"(client_?secret|password|passwd|api[_-]?key|refresh_token|access_token|token)"\s*:\s*"[^"]+"'),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=os.environ.get("DEF_DIR", str(ROOT / "definitions")))
    ap.add_argument("--config", default=str(ROOT / "config"))
    ap.add_argument("--junit", help="write a JUnit XML report to this path")
    args = ap.parse_args()

    policy = dslib.load_policy(args.config)
    name_re = re.compile(policy.get("name_regex", r"^[A-Za-z][A-Za-z0-9_]{0,49}$"))
    prefixes = policy.get("required_prefix", {})
    external = set(policy.get("external_sources", []))

    objs, problems = dslib.load_all(args.root)
    results = {}  # rel path -> list of error strings
    warnings = []

    for path, msg in problems:
        results.setdefault(path, []).append(msg)

    def err(o, msg):
        results.setdefault(o.rel, []).append(msg)

    seen = {}
    for o in objs:
        results.setdefault(o.rel, [])
        if o.error:
            err(o, o.error)
            continue
        if not name_re.match(o.name):
            err(o, "name '%s' violates policy regex %s" % (o.name, name_re.pattern))
        pre = prefixes.get(o.type)
        if pre and not o.name.startswith(pre):
            err(o, "%s must start with '%s'" % (o.type, pre))
        if o.name in seen:
            err(o, "duplicate technical name (also in %s) - names are unique per space" % seen[o.name])
        seen[o.name] = o.rel

        defs = o.doc.get("definitions") if isinstance(o.doc, dict) else None
        if not isinstance(defs, dict) or not defs:
            err(o, "missing top-level 'definitions' object")
            continue
        if o.name not in defs:
            err(o, "file name '%s' does not match any key in 'definitions' (%s)" % (o.name, ", ".join(defs)))
            continue
        ent = defs[o.name]
        if not isinstance(ent, dict) or ent.get("kind") != "entity":
            warnings.append("%s: definitions.%s has no kind=entity (ok for flows/models, check anyway)" % (o.rel, o.name))
        if o.type in ("local-tables", "views") and not ent.get("elements"):
            err(o, "no 'elements' (columns) defined")

        raw = o.path.read_text(encoding="utf-8")
        for pat in SECRET_PATTERNS:
            if pat.search(raw):
                err(o, "looks like it contains a credential - never commit secrets (pattern: %s)" % pat.pattern[:40])

    good = [o for o in objs if not o.error and o.doc]
    known = {o.name for o in good}
    all_names = {o.name for o in objs}  # a file that failed to parse still "exists" - don't cascade misleading errors
    for o in good:
        resolved, unresolved = dslib.dependencies(o, all_names)
        for u in sorted(unresolved):
            if u in external or "." in u:
                continue  # shared/remote sources outside this repo
            err(o, "references '%s' which is neither in this repo nor listed in policy.external_sources" % u)

    try:
        order, _ = dslib.toposort(good)
        order_msg = " -> ".join(o.name for o in order)
    except dslib.CycleError as exc:
        results.setdefault("(graph)", []).append(str(exc))
        order_msg = None

    errors = 0
    for rel in sorted(results):
        errs = results[rel]
        errors += len(errs)
        if errs:
            print("FAIL %s" % rel)
            for e in errs:
                print("     - %s" % e)
        else:
            print("OK   %s" % rel)
    for w in warnings:
        print("WARN %s" % w)
    print()
    print("%d object file(s), %d error(s), %d warning(s)" % (len(objs), errors, len(warnings)))
    if order_msg:
        print("deploy order: %s" % order_msg)

    if args.junit:
        suite = ET.Element("testsuite", name="datasphere-definitions", tests=str(len(results)), failures=str(sum(1 for v in results.values() if v)), time="0")
        for rel, errs in sorted(results.items()):
            case = ET.SubElement(suite, "testcase", classname="validate", name=rel, time="0")
            if errs:
                f = ET.SubElement(case, "failure", message=errs[0])
                f.text = "\n".join(errs)
        Path(args.junit).parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(suite).write(args.junit, encoding="utf-8", xml_declaration=True)

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
