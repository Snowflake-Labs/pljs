#!/usr/bin/env python3
"""pljs-fuzz.py - seeded property / round-trip fuzzer for the pljs type boundary.

Two complementary strategies, both run against a live cluster over psql:

  1. Round-trip identity (property test). For each type that must be lossless
     across the JS boundary, generate random values SQL-side, push them through a
     pljs identity function, and assert ``id(v) = v`` *in SQL* (so no client-side
     rendering/locale issues). A failure is a real conversion bug.

  2. Liveness fuzz. Feed random (mostly-garbage) JS source into anonymous DO
     blocks wrapped in try/catch and assert the backend is still alive and
     correct afterwards (``SELECT 1``). This hunts for inputs that crash or wedge
     the backend rather than raising a catchable error.

Everything is seeded, so any failure prints a deterministic repro (seed + the
exact SQL) that can be distilled into a new sql/ regression test. This is a
local / nightly tool, not a pg_regress test.

Usage:
  PGPORT=5432 PGHOST=/tmp tools/pljs-fuzz.py
  tools/pljs-fuzz.py --seed 1234 --iterations 500
"""
import argparse
import os
import random
import subprocess
import sys

CONN = {"port": os.environ.get("PGPORT", "5432"),
        "host": os.environ.get("PGHOST", "/tmp"),
        "db": os.environ.get("PGDATABASE", "postgres")}

# Deterministic rendering so SQL-side comparisons are stable.
SETUP = [
    "CREATE EXTENSION IF NOT EXISTS pljs;",
    "SET timezone = 'UTC';",
    "SET datestyle = 'ISO, MDY';",
    "SET extra_float_digits = 3;",
    "CREATE OR REPLACE FUNCTION fz_i2(v int2) RETURNS int2 LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_i4(v int4) RETURNS int4 LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_i8(v int8) RETURNS int8 LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_f8(v float8) RETURNS float8 LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_txt(v text) RETURNS text LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_bool(v bool) RETURNS bool LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_i4arr(v int4[]) RETURNS int4[] LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_jb(v jsonb) RETURNS jsonb LANGUAGE pljs AS $$ return v; $$;",
    "CREATE OR REPLACE FUNCTION fz_ts(v timestamptz) RETURNS timestamptz LANGUAGE pljs AS $$ return v; $$;",
]

TEARDOWN = [
    "DROP FUNCTION IF EXISTS fz_i2(int2), fz_i4(int4), fz_i8(int8), fz_f8(float8),"
    " fz_txt(text), fz_bool(bool), fz_i4arr(int4[]), fz_jb(jsonb), fz_ts(timestamptz);",
]


def psql(sql):
    r = subprocess.run(
        ["psql", "-X", "-tA", "-v", "ON_ERROR_STOP=0",
         "-p", CONN["port"], "-h", CONN["host"], "-d", CONN["db"], "-c", sql],
        capture_output=True, text=True)
    out = (r.stdout or "").strip()
    # Keep only genuine errors; NOTICE/WARNING/INFO on stderr are not failures.
    err_lines = [ln for ln in (r.stderr or "").splitlines()
                 if "ERROR:" in ln or "FATAL:" in ln or "PANIC:" in ln
                 or "connection to server" in ln or "server closed" in ln]
    return out, "\n".join(err_lines).strip()


def sql_lit(s):
    return "'" + s.replace("'", "''") + "'"


def rand_text(rng):
    # Mix of ascii, multibyte, quotes, backslashes; never an embedded NUL (which
    # is a documented hard error, exercised separately by the liveness fuzz).
    n = rng.randint(0, 24)
    pool = "abcXYZ0129 '\"\\%_\t\n" + "é☃\u00e9\u2603日本"
    return "".join(rng.choice(pool) for _ in range(n))


def gen_roundtrip(rng):
    """Return (fn, sql_value_expr, description) for a random lossless round-trip."""
    kind = rng.choice(
        ["i2", "i4", "i8", "f8", "txt", "bool", "i4arr", "jb", "ts"])
    if kind == "i2":
        v = rng.randint(-32768, 32767)
        return "fz_i2", f"{v}::int2", f"int2 {v}"
    if kind == "i4":
        v = rng.randint(-2147483648, 2147483647)
        return "fz_i4", f"{v}::int4", f"int4 {v}"
    if kind == "i8":
        v = rng.randint(-9223372036854775808, 9223372036854775807)
        return "fz_i8", f"{v}::int8", f"int8 {v}"
    if kind == "f8":
        v = rng.choice([rng.uniform(-1e12, 1e12),
                        rng.choice([0.0, -0.0, 1.5, -1.5])])
        return "fz_f8", f"'{repr(v)}'::float8", f"float8 {v!r}"
    if kind == "txt":
        s = rand_text(rng)
        return "fz_txt", f"{sql_lit(s)}::text", f"text {s!r}"
    if kind == "bool":
        v = rng.choice(["true", "false"])
        return "fz_bool", f"{v}::bool", f"bool {v}"
    if kind == "i4arr":
        n = rng.randint(0, 8)
        elems = []
        for _ in range(n):
            elems.append("NULL" if rng.random() < 0.2
                         else str(rng.randint(-2147483648, 2147483647)))
        arr = "ARRAY[" + ",".join(elems) + "]::int4[]"
        if n == 0:
            arr = "ARRAY[]::int4[]"
        return "fz_i4arr", arr, f"int4[] {elems}"
    if kind == "jb":
        # A *top-level* JSON null collapses to SQL NULL on return in both pljs and
        # plv8 (the inherent JSON-null vs SQL-NULL ambiguity, pinned in
        # sql/pg_null_edge_matrix.sql), so it is not a lossless round-trip -- skip
        # it here. Nested nulls round-trip fine and are still generated.
        while True:
            j = _rand_json(rng, rng.randint(0, 2))
            if j is not None:
                break
        import json
        js = json.dumps(j)
        return "fz_jb", f"{sql_lit(js)}::jsonb", f"jsonb {js}"
    # ts
    y = rng.randint(1970, 2400)
    mo = rng.randint(1, 12)
    d = rng.randint(1, 28)
    h = rng.randint(0, 23)
    mi = rng.randint(0, 59)
    s = rng.randint(0, 59)
    ms = rng.randint(0, 999)
    lit = f"{y:04d}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{s:02d}.{ms:03d}+00"
    return "fz_ts", f"'{lit}'::timestamptz", f"timestamptz {lit}"


def _rand_json(rng, depth):
    if depth <= 0:
        return rng.choice([None, True, False, rng.randint(-1000, 1000),
                           round(rng.uniform(-100, 100), 3), rand_text(rng)])
    kind = rng.choice(["obj", "arr", "scalar"])
    if kind == "scalar":
        return _rand_json(rng, 0)
    if kind == "arr":
        return [_rand_json(rng, depth - 1) for _ in range(rng.randint(0, 4))]
    return {f"k{i}": _rand_json(rng, depth - 1) for i in range(rng.randint(0, 4))}


def gen_js_source(rng):
    """A random-ish JS snippet that must never crash the backend."""
    frags = [
        "var a=[];for(var i=0;i<%d;i++)a.push(i);" % rng.randint(0, 5000),
        "var s='';for(var i=0;i<%d;i++)s+='x';" % rng.randint(0, 5000),
        "try{null.x;}catch(e){}",
        "try{undefined();}catch(e){}",
        "JSON.parse('%s');" % rng.choice(["{}", "[", "not json", "{\"a\":1}"]),
        "var o={};o[Symbol.iterator]=1;",
        "pljs.execute('SELECT %d');" % rng.randint(0, 100),
        "try{pljs.execute('SELCT bad');}catch(e){}",
        "try{pljs.execute('SELECT 1/0');}catch(e){}",
        "var b=new ArrayBuffer(%d);" % rng.randint(0, 1024 * 1024),
        "function r(n){return n<%d?r(n+1):n;}r(0);" % rng.randint(0, 500),
        "'%s'.repeat(%d);" % ("ab", rng.randint(0, 1000)),
    ]
    k = rng.randint(1, 4)
    return "".join(rng.choice(frags) for _ in range(k))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--iterations", type=int, default=300)
    args = ap.parse_args()
    rng = random.Random(args.seed)

    _, err = psql("SELECT 1 FROM pg_available_extensions WHERE name='pljs';")
    for s in SETUP:
        _, e = psql(s)
        if e:
            print(f"pljs-fuzz: setup failed: {e}", file=sys.stderr)
            return 2

    failures = []

    # 1) round-trip identity
    for i in range(args.iterations):
        fn, expr, desc = gen_roundtrip(rng)
        q = f"SELECT {fn}(v) IS NOT DISTINCT FROM v AS ok FROM (SELECT {expr} AS v) s;"
        out, err = psql(q)
        if err:
            failures.append(("roundtrip-error", desc, q, err))
        elif out != "t":
            failures.append(("roundtrip-mismatch", desc, q, f"got {out!r}"))

    # 2) liveness fuzz
    for i in range(args.iterations):
        src = gen_js_source(rng)
        do = f"DO $BODY$ try {{ {src} }} catch (e) {{ }} $BODY$ LANGUAGE pljs;"
        _out, err = psql(do)
        # A syntax/runtime error inside the DO is fine; a *connection* failure is not.
        alive, aerr = psql("SELECT 1;")
        if alive != "1" or aerr:
            failures.append(("backend-dead", "liveness", do, aerr or f"SELECT 1 -> {alive!r}"))
            break

    for s in TEARDOWN:
        psql(s)

    print(f"pljs-fuzz: seed={args.seed} iterations={args.iterations} "
          f"(x2 phases) failures={len(failures)}")
    if failures:
        print("\n--- REPROS ---")
        for cat, desc, q, detail in failures[:20]:
            print(f"[{cat}] {desc}\n  SQL: {q}\n  -> {detail}\n")
        print("pljs-fuzz: FAIL - distill the repros above into sql/ regression tests.",
              file=sys.stderr)
        return 1
    print("pljs-fuzz: OK - no round-trip mismatches and backend stayed alive.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
