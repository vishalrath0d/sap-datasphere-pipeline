"""Shared helpers: load CSN definition files, find dependencies, order them.

Folder name under definitions/ == the object-type segment of the Datasphere CLI
(`datasphere objects <type> ...`). File name == technical name of the object.
"""
import heapq
import json
import re
from pathlib import Path

# Lower rank = deployed earlier. Dependencies (below) always win over rank;
# rank only decides the order between objects that do not depend on each other.
TYPE_RANK = {
    "local-tables": 10,
    "remote-tables": 20,
    "views": 30,
    "data-flows": 40,
    "replication-flows": 40,
    "transformation-flows": 50,
    "analytic-models": 60,
    "task-chains": 90,
}

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*")


class Obj:
    __slots__ = ("type", "name", "path", "doc", "error")

    def __init__(self, type_, name, path):
        self.type = type_
        self.name = name
        self.path = path
        self.doc = None
        self.error = None

    @property
    def rel(self):
        return "%s/%s.json" % (self.type, self.name)

    @property
    def entity(self):
        defs = (self.doc or {}).get("definitions") or {}
        ent = defs.get(self.name)
        return ent if isinstance(ent, dict) else {}


def load_policy(config_dir):
    p = Path(config_dir) / "policy.json"
    if p.exists():
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    return {}


def load_all(def_dir):
    """Return (objects, problems). problems = [(path, message)] for structural issues."""
    base = Path(def_dir)
    objs, problems = [], []
    if not base.is_dir():
        return objs, [(str(base), "definitions directory not found")]
    for type_dir in sorted(p for p in base.iterdir() if p.is_dir() and not p.name.startswith(".")):
        t = type_dir.name
        if t not in TYPE_RANK:
            problems.append((str(type_dir), "unknown object type folder '%s' (allowed: %s)" % (t, ", ".join(sorted(TYPE_RANK)))))
            continue
        for f in sorted(type_dir.glob("*.json")):
            o = Obj(t, f.stem, f)
            try:
                with open(f, encoding="utf-8") as fh:
                    o.doc = json.load(fh)
            except (ValueError, OSError) as exc:
                o.error = "not valid JSON: %s" % exc
            objs.append(o)
    return objs, problems


# ---- dependency discovery ------------------------------------------------

def _from_refs(node):
    """Names of tables/views referenced in a CSN FROM clause (ignores join conditions)."""
    out = []
    if isinstance(node, list):
        for x in node:
            out.extend(_from_refs(x))
    elif isinstance(node, dict):
        ref = node.get("ref")
        if isinstance(ref, list) and ref:
            first = ref[0]
            if isinstance(first, dict):
                first = first.get("id")
            if isinstance(first, str):
                out.append(first)
        if "join" in node:  # only descend into join operands, never into 'on'
            for a in node.get("args") or []:
                out.extend(_from_refs(a))
        if "SELECT" in node or "SET" in node:
            out.extend(_query_refs(node))
    return out


def _query_refs(q):
    out = []
    if isinstance(q, dict):
        if isinstance(q.get("SELECT"), dict):
            out.extend(_from_refs(q["SELECT"].get("from")))
        if isinstance(q.get("SET"), dict):
            for a in q["SET"].get("args") or []:
                out.extend(_query_refs(a))
    return out


def structural_refs(obj):
    """Sources the object cannot exist without: FROM/JOIN of a view's query, plus the targets of
    associations (a local table with an association to another table needs that table first)."""
    return set(_query_refs(obj.entity.get("query"))) | association_targets(obj)


def association_targets(obj):
    out = set()
    for el in (obj.entity.get("elements") or {}).values():
        if isinstance(el, dict) and el.get("type") in ("cds.Association", "cds.Composition"):
            t = el.get("target")
            if isinstance(t, str):
                out.add(t)
    return out


def text_refs(obj):
    """Identifiers mentioned in the SQL editor text (fallback when 'query' is absent)."""
    sql = obj.entity.get("@DataWarehouse.sqlEditor.query")
    return set(IDENT.findall(sql)) if isinstance(sql, str) else set()


def dependencies(obj, known_names):
    """(resolved, unresolved_structural). resolved only contains names that exist in the repo."""
    s = structural_refs(obj)
    resolved = ((s | text_refs(obj)) & set(known_names)) - {obj.name}
    unresolved = s - set(known_names) - {obj.name}
    return resolved, unresolved


class CycleError(Exception):
    pass


def toposort(objs):
    """Deploy order. Dependencies first; ties broken by type rank, then name."""
    known = {o.name for o in objs}
    deps = {o.name: dependencies(o, known)[0] for o in objs}
    by_name = {o.name: o for o in objs}
    indeg = {n: len(d) for n, d in deps.items()}
    users = {n: [] for n in deps}
    for n, d in deps.items():
        for dep in d:
            users[dep].append(n)
    heap = [(TYPE_RANK[by_name[n].type], n) for n, k in indeg.items() if k == 0]
    heapq.heapify(heap)
    order = []
    while heap:
        _, n = heapq.heappop(heap)
        order.append(by_name[n])
        for u in users[n]:
            indeg[u] -= 1
            if indeg[u] == 0:
                heapq.heappush(heap, (TYPE_RANK[by_name[u].type], u))
    if len(order) != len(objs):
        stuck = sorted(n for n, k in indeg.items() if k > 0)
        raise CycleError("dependency cycle between: %s" % ", ".join(stuck))
    return order, deps
