#!/usr/bin/env python3
"""ANON-0:把两条路的原始结果合成三张表(有数据 / 授了权但拿不到 / 没授权)。

    python3 scripts/anon-surface-report.py --in <probe 输出目录>

输入由 scripts/anon-surface-probe.py 产生,外加两份目录快照(catalogue.json、
owner_rows.json)。本脚本【不连数据库】,只做归并 —— 于是判词可以复算。

【一条不许省的分辨】"返回 0 行"有两种,它们不是同一件事:
  * 关系里【有】行,匿名请求拿到 0 行 —— 有东西在挡(RLS / 视图谓词 / 函数守卫)。
  * 关系里【本来就没有行】—— 什么都没挡,今天恰好没东西可看。
    这一类会随着第一条业务数据落库【自己变成泄漏】,所以它单独成列。
"""
import argparse, json
from pathlib import Path

def load(p):
    t = Path(p).read_text()
    if t.lstrip().startswith(("[", "{")):
        return json.loads(t)
    return json.loads([l for l in t.splitlines() if l.startswith("[")][-1])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="ind", required=True)
    a = ap.parse_args()
    d = Path(a.ind)
    A = load(d / "path_a_relations.json")
    B = load(d / "path_b_relations.json")
    cat = {r["relname"]: r for r in load(d / "catalogue.json")}
    own = {r["relname"]: r for r in load(d / "owner_rows.json")}

    rows = []
    for name, c in sorted(cat.items()):
        a_r, b_r, o = A.get(name, {}), B.get(name, {}), own.get(name, {})
        a_verdict = ("denied" if a_r.get("status") in (401, 403)
                     else "missing" if a_r.get("status") == 404
                     else "data" if a_r.get("rows") else "empty")
        b_verdict = ("denied" if b_r.get("err") else "data" if (b_r.get("n") or 0) else "empty")
        owner_has = o.get("has_rows")
        owner_err = o.get("err")
        if a_verdict == b_verdict:
            verdict = a_verdict
        elif {a_verdict, b_verdict} == {"denied", "missing"}:
            verdict = "denied"
        else:
            verdict = f"DISAGREE(A={a_verdict},B={b_verdict})"

        err = (b_r.get("err") or a_r.get("error") or "")
        if verdict == "denied":
            if not c["anon_select"]:
                stops = "SELECT 未授予 anon"
            elif "function" in err:
                fn = err.split("function")[-1].strip()
                stops = f"函数 EXECUTE 未授予 anon:{fn}"
            else:
                stops = "底层对象上的授权缺失"
        elif verdict == "empty":
            if owner_err:
                stops = f"视图体内的守卫直接抛错({owner_err.split()[0]})"
            elif owner_has:
                stops = "RLS(策略只写给 authenticated)" if c["relkind"] == "r" else "视图谓词 / 底表 RLS"
            else:
                stops = "★ 什么都没挡 —— 这张关系今天是空的"
        else:
            stops = ""
        rows.append({"relname": name, "kind": c["relkind"], "verdict": verdict,
                     "anon_grant": c["anon_select"], "owner_has_rows": owner_has,
                     "owner_err": owner_err, "stops": stops,
                     "a_status": a_r.get("status"), "a_rows": a_r.get("rows"),
                     "b_n": b_r.get("n"), "err": err[:120]})

    print(json.dumps(rows, ensure_ascii=False, indent=1))

if __name__ == "__main__":
    main()
