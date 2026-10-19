#!/usr/bin/env python3
"""Turn the output of `datasphere objects <type> list --space X` (stdin) into one technical name per line.

I could not confirm the exact output format of `list` in every CLI version, so this accepts the
shapes it is likely to have: a JSON array of strings, a JSON array of objects, a JSON object keyed
by name, or plain text with the name in the first column. If it prints nothing for a space that has
objects, run the list command by hand and adapt this file - it is the only place that guesses.
"""
import json
import re
import sys

NAME_KEYS = ("technicalName", "technical_name", "name", "id", "qualifiedName", "objectName")
TOKEN = re.compile(r"^[A-Za-z][A-Za-z0-9_.]*$")


def from_json(doc):
    names = []
    if isinstance(doc, dict):
        for key in ("objects", "items", "results", "value", "definitions"):
            if isinstance(doc.get(key), (list, dict)):
                return from_json(doc[key])
        if all(isinstance(v, (dict, list)) for v in doc.values()):
            return list(doc.keys())
        return names
    if isinstance(doc, list):
        for item in doc:
            if isinstance(item, str):
                names.append(item)
            elif isinstance(item, dict):
                for k in NAME_KEYS:
                    if isinstance(item.get(k), str):
                        names.append(item[k])
                        break
    return names


def main():
    raw = sys.stdin.read()
    names = []
    start = min([i for i in (raw.find("["), raw.find("{")) if i != -1], default=-1)
    if start != -1:
        try:
            doc, _ = json.JSONDecoder().raw_decode(raw[start:])
            names = from_json(doc)
        except ValueError:
            names = []
    if not names:
        for line in raw.splitlines():
            first = line.strip().split()[:1]
            if first and TOKEN.match(first[0]) and first[0].lower() not in ("name", "technical", "objects"):
                names.append(first[0])
    for n in sorted(set(names)):
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
