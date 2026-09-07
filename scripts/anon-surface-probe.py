#!/usr/bin/env python3
"""ANON-0:量【匿名请求实际拿得到什么】,而不是【目录里授了什么权】。

用法
    python3 scripts/anon-surface-probe.py --out /tmp/anon
    python3 scripts/anon-surface-probe.py --out /tmp/anon --phase relations
    python3 scripts/anon-surface-probe.py --out /tmp/anon --phase functions
    python3 scripts/anon-surface-probe.py --out /tmp/anon --phase storage

═══════════════════════════════════════════════════════════════════════════════
安全性 —— 改本文件前先读懂这三段:

1. 【只读,且写操作必回滚】关系探测只发 SELECT。函数探测里【会真的调用函数】,
   但所有可能写的调用都跑在【一个 BEGIN … ROLLBACK 里】,并带 statement_timeout /
   lock_timeout。HTTP 那条路【只调】读函数(provolatile 为 s/i 且函数体无写语句)。
2. 【两条路,失败模式不同,不许互相纠正】
   路 A = 真实 HTTP 请求,带 anon key,走 PostgREST —— 外面的人实际拿到的东西。
   路 B = 库内 SET LOCAL ROLE anon,同一事务里回滚 —— 绕过 API 层,看得见
   PostgREST 不路由的关系。
   两条路的差异【单独成表】,不在报告里被悄悄合并成一个数。
3. 【目录只做点名册,不做答案】REST 根 (`GET /rest/v1/`) 对 anon 返回 401
   (Only the service_role API key can be used for this endpoint),所以 API
   不肯自报家门,点名册只能来自 pg_class。但目录【永远不回答】"anon 看得到什么" ——
   那是路 A 和路 B 的活。
═══════════════════════════════════════════════════════════════════════════════
"""
import argparse, json, os, re, subprocess, sys, urllib.request, urllib.error
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DSN = os.environ.get("ANON_PROBE_DSN") or (
    "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 "
    "user=postgres.wvywpohbwkiinmipmuku dbname=postgres")

def env_local():
    vals = {}
    for line in (REPO / ".env.local").read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            vals[k.strip()] = v.strip()
    return vals

def psql(sql, timeout=180):
    p = subprocess.run(["psql", DSN, "-X", "-Atq", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql],
                       capture_output=True, text=True, timeout=timeout)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[:2000])
    return p.stdout

def psql_json(sql, timeout=600):
    out = psql(sql, timeout=timeout).strip()
    return json.loads(out) if out else None

# ── path A ────────────────────────────────────────────────────────────────────
def http(url, key, method="GET", body=None, prefer=None):
    req = urllib.request.Request(url, method=method)
    req.add_header("apikey", key)
    req.add_header("Authorization", "Bearer " + key)
    req.add_header("User-Agent", "curl/8.4.0")
    if prefer: req.add_header("Prefer", prefer)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=25) as r:
            return r.status, r.read().decode("utf-8", "replace"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)
    except Exception as e:
        return -1, repr(e), {}

def path_a_relations(rels, url, key):
    out = {}
    for name, kind in rels:
        st, body, hdr = http(f"{url}/rest/v1/{name}?select=*&limit=5", key)
        rec = {"status": st, "rows": None, "nonnull_cols": [], "error": None, "count": None}
        if st == 200:
            try:
                rows = json.loads(body)
            except Exception:
                rows = []
            rec["rows"] = len(rows)
            cols = set()
            for row in rows:
                if isinstance(row, dict):
                    cols |= {k for k, v in row.items() if v is not None}
            rec["nonnull_cols"] = sorted(cols)
            if rows:
                st2, _b2, h2 = http(f"{url}/rest/v1/{name}?select=*&limit=1", key,
                                    prefer="count=exact")
                cr = h2.get("Content-Range") or h2.get("content-range") or ""
                rec["count"] = cr.split("/")[-1] if "/" in cr else None
        else:
            try:
                rec["error"] = json.loads(body).get("message")
            except Exception:
                rec["error"] = body[:200]
        out[name] = rec
        print(f"A {name} {st} rows={rec['rows']}", flush=True)
    return out

# ── path B ────────────────────────────────────────────────────────────────────
PATH_B_RELATIONS = r"""
BEGIN;
SET LOCAL statement_timeout = '20s';
SET LOCAL lock_timeout = '3s';
CREATE TEMP TABLE probe_b(relname text, relkind text, n bigint, sample jsonb, err text)
    ON COMMIT DROP;
DO $probe$
DECLARE r record; v_n bigint; v_s jsonb; v_e text;
BEGIN
    FOR r IN
        SELECT c.relname, c.relkind::text AS relkind
          FROM pg_class c JOIN pg_namespace nsp ON nsp.oid = c.relnamespace
         WHERE nsp.nspname = 'public' AND c.relkind IN ('r','v','m','p','f')
         ORDER BY c.relname
    LOOP
        v_n := NULL; v_s := NULL; v_e := NULL;
        BEGIN
            EXECUTE 'SET LOCAL ROLE anon';
            EXECUTE format('SELECT count(*) FROM public.%I', r.relname) INTO v_n;
            EXECUTE format('SELECT jsonb_agg(t) FROM (SELECT * FROM public.%I LIMIT 5) t',
                           r.relname) INTO v_s;
        EXCEPTION WHEN OTHERS THEN
            v_e := SQLSTATE || ' ' || SQLERRM;
        END;
        EXECUTE 'RESET ROLE';
        INSERT INTO probe_b VALUES (r.relname, r.relkind, v_n, v_s, v_e);
    END LOOP;
END
$probe$;
SELECT coalesce(jsonb_agg(jsonb_build_object(
           'relname', relname, 'relkind', relkind, 'n', n,
           'nonnull_cols', (SELECT coalesce(jsonb_agg(DISTINCT k), '[]'::jsonb)
                              FROM jsonb_array_elements(coalesce(sample,'[]'::jsonb)) e,
                                   jsonb_each(e) kv(k, v)
                             WHERE jsonb_typeof(v) <> 'null'),
           'sample_rows', jsonb_array_length(coalesce(sample, '[]'::jsonb)),
           'err', err)), '[]'::jsonb)
  FROM probe_b;
ROLLBACK;
"""

def path_b_relations(outdir):
    sqlf = outdir / "path_b_relations.sql"
    sqlf.write_text(PATH_B_RELATIONS)
    p = subprocess.run(["psql", DSN, "-X", "-Atq", "-v", "ON_ERROR_STOP=1", "-f", str(sqlf)],
                       capture_output=True, text=True, timeout=900)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip()[:3000])
    line = [l for l in p.stdout.splitlines() if l.startswith("[")]
    return {r["relname"]: r for r in json.loads(line[-1])}

# ── functions ─────────────────────────────────────────────────────────────────
FN_ENUM = r"""
SELECT jsonb_agg(x) FROM (
  SELECT p.oid::text AS oid,
         p.proname,
         p.prokind::text AS prokind,
         p.provolatile::text AS volatility,
         p.prosecdef AS secdef,
         has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_execute,
         pg_get_userbyid(p.proowner) AS owner,
         pg_get_function_identity_arguments(p.oid) AS ident_args,
         pg_catalog.format_type(p.prorettype, NULL) AS rettype,
         (SELECT coalesce(string_agg('NULL::' || pg_catalog.format_type(t, NULL), ', '
                                     ORDER BY ord), '')
            FROM unnest(p.proargtypes) WITH ORDINALITY AS a(t, ord)) AS null_args,
         coalesce(p.prosrc, '') AS src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.objid = p.oid AND d.deptype = 'e')
   ORDER BY p.proname
) x;
"""

WRITE_RE = re.compile(
    r"\b(insert\s+into|update\s+[a-z_\"]|delete\s+from|truncate\s|create\s+(table|index|schema)"
    r"|drop\s+(table|index)|alter\s+table|nextval\s*\(|setval\s*\(|perform\s+set_config)",
    re.I)
GUARD_PERM_RE = re.compile(r"has_permission\s*\(", re.I)
GUARD_IDENT_RE = re.compile(r"auth\.uid\s*\(|current_user_employee\s*\(|auth\.role\s*\(", re.I)

def classify_functions(rows):
    for f in rows:
        src = f.pop("src", "")
        f["writes"] = bool(WRITE_RE.search(src))
        f["guard_permission"] = bool(GUARD_PERM_RE.search(src))
        f["guard_identity"] = bool(GUARD_IDENT_RE.search(src))
        f["src_len"] = len(src)
    return rows

def path_b_functions(outdir, fns, batch=40):
    """Tier (iii): call each function as anon inside one BEGIN … ROLLBACK."""
    # 【不看 anon_execute】目录说 anon 一个函数都执行不了 —— 那正是要用调用去验的话,
    # 不是拿来筛掉调用的理由。整批跑在 BEGIN … ROLLBACK 里,写了也留不下。
    callable_fns = [f for f in fns
                    if f["prokind"] == "f"
                    and f["rettype"] not in ("trigger", "event_trigger")]
    results = {}
    for i in range(0, len(callable_fns), batch):
        chunk = callable_fns[i:i + batch]
        oids = ",".join(f["oid"] for f in chunk)
        sql = PATH_B_FUNCTIONS_TEMPLATE.replace("__OIDS__", oids)
        sqlf = outdir / f"path_b_functions_{i}.sql"
        sqlf.write_text(sql)
        p = subprocess.run(["psql", DSN, "-X", "-Atq", "-v", "ON_ERROR_STOP=1", "-f", str(sqlf)],
                           capture_output=True, text=True, timeout=300)
        if p.returncode != 0:
            print(f"!! batch {i} failed: {p.stderr.strip()[:300]}", flush=True)
            for f in chunk:
                results[f["oid"]] = {"outcome": "batch_failed", "detail": p.stderr.strip()[:200]}
            continue
        line = [l for l in p.stdout.splitlines() if l.startswith("[")]
        for r in json.loads(line[-1]):
            results[r["oid"]] = r
        print(f"B functions {i + len(chunk)}/{len(callable_fns)}", flush=True)
    return results

PATH_B_FUNCTIONS_TEMPLATE = r"""
BEGIN;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';
CREATE TEMP TABLE probe_f(oid text, proname text, outcome text, detail text, ret text)
    ON COMMIT DROP;
DO $probe$
DECLARE r record; v_ret text; v_out text; v_det text;
BEGIN
    FOR r IN
        SELECT p.oid::text AS oid, p.proname,
               (SELECT coalesce(string_agg('NULL::' || pg_catalog.format_type(t, NULL), ', '
                                           ORDER BY ord), '')
                  FROM unnest(p.proargtypes) WITH ORDINALITY AS a(t, ord)) AS null_args
          FROM pg_proc p
         WHERE p.oid IN (__OIDS__)
         ORDER BY p.proname
    LOOP
        v_ret := NULL; v_out := NULL; v_det := NULL;
        BEGIN
            EXECUTE 'SET LOCAL ROLE anon';
            EXECUTE format('SELECT (public.%I(%s))::text', r.proname, r.null_args) INTO v_ret;
            v_out := 'executed';
        EXCEPTION WHEN OTHERS THEN
            v_out := CASE WHEN SQLSTATE = '42501' THEN 'permission_denied' ELSE 'error' END;
            v_det := SQLSTATE || ' ' || left(SQLERRM, 200);
        END;
        EXECUTE 'RESET ROLE';
        INSERT INTO probe_f VALUES (r.oid, r.proname, v_out, v_det, left(v_ret, 300));
    END LOOP;
END
$probe$;
SELECT coalesce(jsonb_agg(to_jsonb(probe_f)), '[]'::jsonb) FROM probe_f;
ROLLBACK;
"""

def arg_names(ident_args):
    """Named args only — PostgREST calls functions by argument name."""
    names = []
    if not ident_args.strip():
        return names
    for spec in ident_args.split(", "):
        toks = spec.split()
        if toks and toks[0].upper() in ("IN", "OUT", "INOUT", "VARIADIC"):
            toks = toks[1:]
        if len(toks) >= 2:
            names.append(toks[0])
        else:
            return None          # at least one unnamed arg: cannot call by name
    return names

def path_a_functions(fns, url, key):
    """Tier (ii): call read-only functions over HTTP as anon."""
    out = {}
    for f in fns:
        if f["prokind"] != "f" or f["rettype"] in ("trigger", "event_trigger"):
            continue
        if f["writes"] or f["volatility"] == "v":
            # HTTP 不回滚,所以这条路【只碰】STABLE/IMMUTABLE 且函数体无写语句的函数 ——
            # PostgreSQL 本身禁止非 volatile 函数执行数据修改语句,这是硬保证,不是猜测。
            # VOLATILE 的一律留给路 B 的回滚事务。
            continue
        names = arg_names(f["ident_args"])
        if names is None:
            continue
        body = {n: None for n in names}
        st, txt, _h = http(f"{url}/rest/v1/rpc/{f['proname']}", key, method="POST", body=body)
        out[f["oid"]] = {"proname": f["proname"], "status": st, "body": txt[:300]}
        print(f"A rpc {f['proname']} {st}", flush=True)
    return out

# ── storage & the other doors ─────────────────────────────────────────────────
STORAGE_SQL = r"""
SELECT jsonb_build_object(
  'buckets', (SELECT jsonb_agg(jsonb_build_object('id', id, 'public', public)
                               ORDER BY id) FROM storage.buckets),
  'object_policies', (SELECT jsonb_agg(jsonb_build_object(
                          'policy', policyname, 'cmd', cmd, 'roles', roles::text,
                          'qual', left(coalesce(qual, ''), 300)) ORDER BY policyname)
                        FROM pg_policies
                       WHERE schemaname = 'storage' AND tablename = 'objects'),
  'anon_storage_grants', (SELECT jsonb_agg(DISTINCT table_name)
                            FROM information_schema.role_table_grants
                           WHERE grantee = 'anon' AND table_schema = 'storage'),
  'realtime_publication', (SELECT jsonb_agg(jsonb_build_object('pub', p.pubname,
                                   'tables', (SELECT count(*) FROM pg_publication_rel r
                                               WHERE r.prpubid = p.oid)))
                             FROM pg_publication p),
  'graphql_schema_present', (SELECT count(*) > 0 FROM pg_namespace
                              WHERE nspname = 'graphql_public')
);
"""

def probe_doors(url, key, outdir):
    doors = {"sql": psql_json(STORAGE_SQL)}
    st, txt, _ = http(f"{url}/graphql/v1", key, method="POST",
                      body={"query": "{ __schema { queryType { name } } }"})
    doors["graphql"] = {"status": st, "body": txt[:400]}
    for bucket in ("avatars", "cod-documents"):
        st, txt, _ = http(f"{url}/storage/v1/object/list/{bucket}", key,
                          method="POST", body={"prefix": "", "limit": 5})
        doors[f"storage_list_{bucket}"] = {"status": st, "body": txt[:400]}
    st, txt, _ = http(f"{url}/rest/v1/nonexistent_relation_probe?select=*", key)
    doors["control_missing_relation"] = {"status": st, "body": txt[:200]}
    return doors

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--phase", default="all",
                    choices=["all", "relations", "functions", "doors"])
    a = ap.parse_args()
    outdir = Path(a.out); outdir.mkdir(parents=True, exist_ok=True)
    env = env_local()
    url = env["NEXT_PUBLIC_SUPABASE_URL"].rstrip("/")
    key = env["NEXT_PUBLIC_SUPABASE_ANON_KEY"]

    if a.phase in ("all", "relations"):
        rels = [(l.split("\t")[1], l.split("\t")[0])
                for l in psql("""SELECT c.relkind, c.relname FROM pg_class c
                                   JOIN pg_namespace n ON n.oid = c.relnamespace
                                  WHERE n.nspname = 'public'
                                    AND c.relkind IN ('r','v','m','p','f')
                                  ORDER BY c.relname""").strip().splitlines()]
        (outdir / "path_a_relations.json").write_text(
            json.dumps(path_a_relations(rels, url, key), indent=1))
        (outdir / "path_b_relations.json").write_text(
            json.dumps(path_b_relations(outdir), indent=1))
    if a.phase in ("all", "functions"):
        fns = classify_functions(psql_json(FN_ENUM) or [])
        (outdir / "functions.json").write_text(json.dumps(fns, indent=1))
        (outdir / "path_a_functions.json").write_text(
            json.dumps(path_a_functions(fns, url, key), indent=1))
        (outdir / "path_b_functions.json").write_text(
            json.dumps(path_b_functions(outdir, fns), indent=1))
    if a.phase in ("all", "doors"):
        (outdir / "doors.json").write_text(json.dumps(probe_doors(url, key, outdir), indent=1))
    print("done")

if __name__ == "__main__":
    main()
