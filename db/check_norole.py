#!/usr/bin/env python3
"""db/check_norole.py — 判词七【无角色面】:一个登录了、却一个角色都没有的会话,够得着什么(NOROLE-SURFACE,2026-10-19,Step 0 Q12 · Q20)

════════════════════════════════════════════════════════════════════════════
它与判词六【匿名面】(db/check_grants.py)是两种病、两种药
════════════════════════════════════════════════════════════════════════════
  判词六问的是 anon(没登录)够得着什么 —— 那是 GRANT 的事。
  本判词问的是【登录了、没有角色】的会话够得着什么 —— 那是 RLS 与函数判据的事:Supabase 的默认权限把每一张新表 / 视图 / 函数
  都授给 authenticated(Step 0 的 DEFAULT_ACL),于是一张忘了写谓词的表、一条 USING (true)、一张 body 里没有判据的属主视图、
  一支不查调用者的 SECURITY DEFINER 函数,都是一扇【任何一个登录的人】推得开的门 —— 而此前没有任何东西在看。
  公开注册已经关了(disable_signup = true),但一个账号被建出来、角色还没挂上(或角色被收回)的那一刻,它就是这样一个会话;
  MES-9 的供应商账号也会是 authenticated 之外的另一种会话,这一条判词是那之前的地板。

════════════════════════════════════════════════════════════════════════════
它每一次都数什么(线上;重建侧同一份 SQL)
════════════════════════════════════════════════════════════════════════════
  两个身份(Q20):norole —— 一个随机 uuid,什么都不持;display —— 一个随机 uuid,只挂 floor_display(data.view_floor_board 一个码)。
  两个都只活在一笔【最后必然 ROLLBACK】的事务里(display 那一行 user_roles 随它回滚)。
    rows     每一个 authenticated 有 SELECT(含列级)的关系(public 与 storage),以两个身份各读一次:读得到一行就是一条
             (user_roles 只数【不是自己】的行 —— 自己那一行按 Q3 本来就该读得到);
    storage  storage.objects 里两个身份看得见的文件,按桶;
    call     floor_board() —— display 必须调得通、norole 必须被拒(Q20:display 的基线 = norole 的基线 + floor_board());
    policy   public 与 storage 上每一条作用于 authenticated / public、而表达式里【没有任何判据函数】的策略;
    rls-off  authenticated 有读写授权、而 RLS 关着的表;
    view     authenticated 读得到的属主权限视图里,body 一个判据函数都不调的;
    definer  authenticated 执行得到的 SECURITY DEFINER 函数里,body 一个判据都不查的。
  判据函数只有一份(JUDGE,下面):加一个新的把关函数,必须加到这里,否则用它的地方会被点名 —— 那是刻意的。
  与 db/norole-surface-baseline.tsv 比:**线上(或重建)出现了基线里没有的一条 → 红,并点名。** 基线里有、两侧都没有 → 点名,不红
  (一次刻意的收窄不该让门红着等人改文件 —— check_grants.py 的同一条规矩)。基线每一行必须带理由,没有理由的一行 = 读不懂 = 红。

  另外比一件事(Q11):线上的 19 个桶与每一条存储策略 == db/storage/buckets-and-policies.sql 装进重建库旁那个桩之后的样子。

════════════════════════════════════════════════════════════════════════════
它自己怎么证明自己没瞎(每一次都跑,不是有人想起来才跑)
════════════════════════════════════════════════════════════════════════════
  ① 探针:重建库上,一笔回滚的事务里建一张 zz_norole_probe —— GRANT SELECT TO authenticated + USING (true) + 一行 —— 同一份 SQL
     必须同时点出它的 policy 与 rows,点不出来这一判词就是瞎的;
  ② 基线读不到 → 抛,绝不当成空基线;
  ③ 把关系那条查询打瞎(恒假)→ universe 为 0 → 必须红(零是一次失明,不是一次测量);
  ④ 从基线里拿掉一条线上确实有的 → 必须红并点名它;
  ⑤ 覆盖面下限:关系 ≥ 400 · 策略 ≥ 400 · 函数 ≥ 500(线上与重建各自),桶 ≥ 19。
  ⑥ 故障注入(由 db/gate.py 做,GATE_NOROLE_FAULT=policy):在重建库的 accounts 上真的加一条 USING (true) —— 必须红并点名它。

用法:
    python3 db/check_norole.py --live <dsn> --rebuild <dsn>     # 整门(gate 调它)
    python3 db/check_norole.py --rebuild <dsn> --offline        # 迁移前那一相:只问重建侧
    python3 db/check_norole.py --live <dsn> --list              # 把线上读数印出来(写基线时用;不写文件)
退出码:0 干净 / 1 有违规(或自证没咬人、或覆盖面不足)/ 5 够不到线上
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINE = HERE / "norole-surface-baseline.tsv"
STORAGE_MIRROR = HERE / "storage" / "buckets-and-policies.sql"

# 判据函数 —— 只有这一份。一个表达式 / body 里出现其中之一,就算"有人在判";否则点名。
JUDGE = (r"(has_permission|has_any_permission|require_permission|require_any_permission|require_[a-z_]+\(|"
         r"current_user_permissions|approval_log_readable|can_view_task|can_edit_task|can_write_task|assert_[a-z_]+\(|"
         r"auth\.uid\(\)|current_user_employee|arm_permission)")
KINDS = ("rows", "storage", "call", "policy", "rls-off", "view", "definer")
FLOORS = {"relations": 400, "policies": 400, "functions": 500}


class Unreachable(RuntimeError):
    pass


def psql(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-At", "-q", "-v", "ON_ERROR_STOP=1", "-f", "-"], input=sql,
                       capture_output=True, text=True)
    if p.returncode != 0:
        err = (p.stderr or "").strip()
        if any(s in err for s in ("could not connect", "could not translate", "server closed the connection",
                                  "timeout expired", "Connection refused", "SSL SYSCALL")):
            raise Unreachable(err[:300])
        raise RuntimeError(err[-800:])
    return (p.stdout or "") + "\n" + (p.stderr or "")


# ── the one enumeration (as postgres; every session read inside it is a SET LOCAL ROLE authenticated) ──────────
ENUM_SQL = r"""
SET LOCAL statement_timeout = '600s';
DO $nr$
DECLARE
    v_judge text := @@JUDGE@@;
    v_blind boolean := @@BLIND@@;
    v_ids jsonb := '{}'::jsonb; v_uid uuid; v_who text; r record; v_hit boolean; v_n bigint;
    n_rel int := 0; n_pol int := 0; n_fn int := 0; n_view int := 0; n_bucket int := 0;
BEGIN
    v_ids := jsonb_build_object('norole', gen_random_uuid());
    v_uid := gen_random_uuid();
    INSERT INTO user_roles (user_id, role_id) SELECT v_uid, id FROM roles WHERE code = 'floor_display';
    IF NOT FOUND THEN RAISE EXCEPTION 'NOROLE_SETUP|there is no floor_display role — the display identity cannot be built'; END IF;
    v_ids := v_ids || jsonb_build_object('display', v_uid);

    -- shapes (as postgres, catalog only)
    FOR r IN SELECT schemaname, tablename, policyname, COALESCE(qual, '') || ' ' || COALESCE(with_check, '') AS e
               FROM pg_policies WHERE schemaname IN ('public', 'storage') AND roles && ARRAY['authenticated', 'public']::name[]
                AND NOT v_blind LOOP
        n_pol := n_pol + 1;
        IF r.e !~ v_judge THEN RAISE NOTICE 'NR|policy|%.%:%', r.schemaname, r.tablename, r.policyname; END IF;
    END LOOP;
    FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname IN ('public', 'storage') AND c.relkind IN ('r', 'p') AND NOT c.relrowsecurity
                AND (has_any_column_privilege('authenticated', c.oid, 'SELECT') OR has_any_column_privilege('authenticated', c.oid, 'INSERT')
                     OR has_any_column_privilege('authenticated', c.oid, 'UPDATE') OR has_table_privilege('authenticated', c.oid, 'DELETE'))
                AND NOT v_blind LOOP
        RAISE NOTICE 'NR|rls-off|%.%', r.nspname, r.relname;
    END LOOP;
    FOR r IN SELECT c.relname, pg_get_viewdef(c.oid) AS d,
                    COALESCE((SELECT o.option_value FROM pg_options_to_table(c.reloptions) o WHERE o.option_name = 'security_invoker'), 'off') AS inv
               FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm') AND has_table_privilege('authenticated', c.oid, 'SELECT') AND NOT v_blind LOOP
        n_view := n_view + 1;
        IF r.inv NOT IN ('on', 'true') AND r.d !~ v_judge THEN RAISE NOTICE 'NR|view|%', r.relname; END IF;
    END LOOP;
    FOR r IN SELECT p.oid::regprocedure::text AS sig, p.prosecdef, p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'public' AND p.prokind = 'f' AND pg_get_function_result(p.oid) <> 'trigger'
                AND has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT v_blind LOOP
        n_fn := n_fn + 1;
        IF r.prosecdef AND r.prosrc !~ v_judge THEN RAISE NOTICE 'NR|definer|%', r.sig; END IF;
    END LOOP;

    -- rows / storage / call, as each identity
    FOR v_who IN SELECT k FROM jsonb_object_keys(v_ids) k ORDER BY k LOOP
        PERFORM set_config('request.jwt.claims', json_build_object('sub', v_ids ->> v_who, 'role', 'authenticated')::text, true);
        FOR r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname IN ('public', 'storage') AND c.relkind IN ('r', 'v', 'm', 'p', 'f')
                    AND has_any_column_privilege('authenticated', c.oid, 'SELECT') AND NOT v_blind
                    AND NOT (n.nspname = 'storage' AND c.relname = 'objects')
                  ORDER BY 1, 2 LOOP
            IF v_who = 'norole' THEN n_rel := n_rel + 1; END IF;
            BEGIN
                EXECUTE 'SET LOCAL ROLE authenticated';
                EXECUTE format('SELECT EXISTS (SELECT 1 FROM %I.%I t %s)', r.nspname, r.relname,
                               CASE WHEN r.nspname = 'public' AND r.relname = 'user_roles' THEN 'WHERE t.user_id IS DISTINCT FROM auth.uid()' ELSE '' END)
                   INTO v_hit;
                EXECUTE 'RESET ROLE';
                IF v_hit THEN RAISE NOTICE 'NR|rows|%:%.%', v_who, r.nspname, r.relname; END IF;
            EXCEPTION WHEN OTHERS THEN
                EXECUTE 'RESET ROLE';
                -- a refusal (42501, or a shell's P0001 PERMISSION_DENIED) is an answer; anything else is a blind spot and is named
                IF SQLSTATE NOT IN ('42501', 'P0001') THEN RAISE NOTICE 'NR|error|%:%.%:%', v_who, r.nspname, r.relname, SQLSTATE; END IF;
            END;
        END LOOP;
        EXECUTE 'SET LOCAL ROLE authenticated';
        FOR r IN SELECT o.bucket_id, count(*) AS n FROM storage.objects o GROUP BY o.bucket_id LOOP
            RAISE NOTICE 'NR|storage|%:%', v_who, r.bucket_id;
        END LOOP;
        EXECUTE 'RESET ROLE';
        BEGIN
            EXECUTE 'SET LOCAL ROLE authenticated';
            PERFORM floor_board();
            EXECUTE 'RESET ROLE';
            RAISE NOTICE 'NR|call|%:floor_board()', v_who;
        EXCEPTION WHEN OTHERS THEN EXECUTE 'RESET ROLE';
        END;
    END LOOP;
    PERFORM set_config('request.jwt.claims', '', true);
    SELECT count(*) INTO n_bucket FROM storage.buckets;
    RAISE NOTICE 'NR|universe|relations=%|policies=%|functions=%|views=%|buckets=%', n_rel, n_pol, n_fn, n_view, n_bucket;
END
$nr$;
"""

PROBE_SQL = """
CREATE TABLE public.zz_norole_probe (x int);
INSERT INTO public.zz_norole_probe VALUES (1);
ALTER TABLE public.zz_norole_probe ENABLE ROW LEVEL SECURITY;
CREATE POLICY "zz norole probe open" ON public.zz_norole_probe FOR SELECT TO authenticated USING (true);
GRANT SELECT ON public.zz_norole_probe TO authenticated;
"""
PROBE_MUST = {"policy\tpublic.zz_norole_probe:zz norole probe open", "rows\tnorole:public.zz_norole_probe",
              "rows\tdisplay:public.zz_norole_probe"}

STORAGE_SHAPE_SQL = r"""
SELECT json_build_object(
  'buckets', (SELECT COALESCE(json_agg(json_build_object('id', id, 'name', name, 'public', public, 'file_size_limit', file_size_limit,
                                                           'allowed_mime_types', allowed_mime_types) ORDER BY id), '[]') FROM storage.buckets),
  'policies', (SELECT COALESCE(json_agg(json_build_object('name', policyname, 'cmd', cmd, 'permissive', permissive, 'roles', roles,
                                                            'qual', qual, 'with_check', with_check) ORDER BY policyname), '[]')
                 FROM pg_policies WHERE schemaname = 'storage' AND tablename = 'objects'))::text;
"""


def enumerate_side(dsn: str, blind: bool = False, probe: bool = False) -> tuple:
    sql = "BEGIN;\n" + (PROBE_SQL if probe else "") + ENUM_SQL.replace(
        "@@JUDGE@@", "'" + JUDGE.replace("'", "''") + "'").replace("@@BLIND@@", "true" if blind else "false") + "ROLLBACK;\n"
    out = psql(dsn, sql)
    items, universe = set(), {}
    for line in out.splitlines():
        line = re.sub(r"^.*NOTICE:\s+", "", line.strip())
        if not line.startswith("NR|"):
            continue
        p = line.split("|")
        if p[1] == "universe":
            universe = {kv.split("=")[0]: int(kv.split("=")[1]) for kv in p[2:]}
        else:
            items.add(p[1] + "\t" + "|".join(p[2:]))
    if not universe:
        raise RuntimeError("the enumeration printed no universe line — it did not run to the end; that is blindness, not a reading")
    return items, universe


def read_baseline(path: Path) -> dict:
    """kind<TAB>object<TAB>reason. ★ An unreadable baseline RAISES — it is never read as an empty one."""
    if not path.exists():
        raise RuntimeError("baseline unreadable: %s — refusing to read it as an empty baseline" % path)
    out, n = {}, 0
    for raw in path.read_text().splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3 or parts[0] not in KINDS or not parts[1].strip() or not parts[2].strip():
            raise RuntimeError("baseline line unreadable (kind<TAB>object<TAB>reason, reason required): %r" % raw)
        out[parts[0] + "\t" + parts[1]] = parts[2]
        n += 1
    if n == 0:
        raise RuntimeError("baseline parsed to zero lines: %s — an empty baseline and a blind parser look the same" % path)
    return out


def coverage_problems(label: str, u: dict, need_buckets: bool) -> list:
    out = []
    for k, floor in FLOORS.items():
        if u.get(k, 0) < floor:
            out.append("%s: coverage %s = %d (floor %d) — a short count is blindness, not a clean reading" % (label, k, u.get(k, 0), floor))
    if need_buckets and u.get("buckets", 0) < 19:
        out.append("%s: coverage buckets = %d (floor 19)" % (label, u.get("buckets", 0)))
    return out


def compare(items: set, base: dict) -> list:
    return sorted(i for i in items if i not in base)


def storage_shape(dsn: str) -> dict:
    out = psql(dsn, "BEGIN READ ONLY;\n" + STORAGE_SHAPE_SQL + "ROLLBACK;\n")
    line = next(l for l in out.splitlines() if l.startswith("{"))
    return json.loads(line)


def main() -> int:
    ap = argparse.ArgumentParser(description="verdict 7 — what a signed-in session with no role reaches")
    ap.add_argument("--live")
    ap.add_argument("--rebuild")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--baseline", default=str(BASELINE))
    args = ap.parse_args()
    problems, notes = [], []
    try:
        print("== db/check_norole.py —— 判词七【无角色面】")
        if args.list:
            items, u = enumerate_side(args.live)
            for i in sorted(items):
                print(i)
            print("universe", u)
            return 0
        # ② unreadable baseline must raise
        try:
            read_baseline(HERE / "__no_such_norole_baseline__.tsv")
            problems.append("self-test ②: an unreadable baseline was read as an empty one")
        except RuntimeError:
            pass
        base = read_baseline(Path(args.baseline))
        sides = []
        if args.rebuild:
            sides.append(("rebuild", args.rebuild))
        if args.live and not args.offline:
            sides.append(("live", args.live))
        if not sides:
            raise RuntimeError("nothing to check: give --rebuild (and --live unless --offline)")
        seen = {}
        for label, dsn in sides:
            items, u = enumerate_side(dsn)
            seen[label] = items
            problems += coverage_problems(label, u, need_buckets=True)
            notes.append("%-7s relations %d · policies %d · functions %d · views %d · buckets %d · items %d"
                         % (label, u.get("relations", 0), u.get("policies", 0), u.get("functions", 0), u.get("views", 0),
                            u.get("buckets", 0), len(items)))
            for i in compare(items, base):
                problems.append("★ %s reaches what the baseline does not name: %s" % (label, i.replace("\t", " ")))
            # ④ a baseline missing one line that this side has must go red
            present = sorted(i for i in items if i in base)
            if present:
                cut = dict(base); cut.pop(present[0])
                if present[0] not in compare(items, cut):
                    problems.append("self-test ④ (%s): removing the baseline line %r did not go red" % (label, present[0]))
            else:
                problems.append("self-test ④ (%s): no baseline line is present on this side — nothing to remove; blindness?" % label)
        # ③ blinded query must read as blindness
        _, ub = enumerate_side(sides[0][1], blind=True)
        if not coverage_problems("blind", ub, need_buckets=False):
            problems.append("self-test ③: the blinded enumeration (universe 0) was not reported as blindness")
        # ① the always-on probe (rebuild only — it creates a table inside a rolled-back transaction)
        if args.rebuild:
            pitems, _ = enumerate_side(args.rebuild, probe=True)
            missing = PROBE_MUST - pitems
            if missing:
                problems.append("self-test ① : the probe table (USING (true) + SELECT grant + a row) was not named: %s"
                                % ", ".join(sorted(m.replace("\t", " ") for m in missing)))
        # stale baseline lines: named, not red
        allseen = set().union(*seen.values())
        stale = sorted(k for k in base if k not in allseen)
        # storage mirror == live (Q11)
        if args.rebuild and args.live and not args.offline:
            lv, rb = storage_shape(args.live), storage_shape(args.rebuild)
            for part in ("buckets", "policies"):
                key = "id" if part == "buckets" else "name"
                L = {x[key]: x for x in lv[part]}; R = {x[key]: x for x in rb[part]}
                for k in sorted(set(L) | set(R)):
                    if L.get(k) != R.get(k):
                        problems.append("storage mirror ≠ live (%s %s): live=%s mirror=%s" % (part, k, json.dumps(L.get(k))[:220], json.dumps(R.get(k))[:220]))
            notes.append("storage mirror: %d buckets · %d policies compared with live" % (len(lv["buckets"]), len(lv["policies"])))
        elif args.rebuild:
            rb = storage_shape(args.rebuild)
            notes.append("storage mirror installed on the rebuild: %d buckets · %d policies (live comparison runs in the full gate)"
                         % (len(rb["buckets"]), len(rb["policies"])))
        for n in notes:
            print("   " + n)
        print("   self-tests: probe · unreadable baseline · blinded query · removed baseline line —"
              + (" all bit" if not any(p.startswith("self-test") for p in problems) else " ✗ one did not bite"))
        for s in stale:
            print("   ⚠ baseline line no side reaches any more (delete it in the next commit): " + s.replace("\t", " "))
        if problems:
            print("判词【无角色面】:✗")
            for p in problems:
                print("   " + p)
            return 1
        print("判词【无角色面】:✓ %s 都是基线的子集(基线 %d 条,每条带理由)" % (" · ".join(l for l, _ in sides), len(base)))
        return 0
    except Unreachable as e:
        print("判词【无角色面】:够不到线上 —— 环境故障,不是仓库的毛病:%s" % e)
        return 5
    except Exception as e:
        print("判词【无角色面】:✗ 检查本身出错(这也是红的,不是通过):%s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
