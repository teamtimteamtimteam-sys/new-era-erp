#!/usr/bin/env python3
"""KPI-1:把机器生成的种子行写进【镜像文件】,好让 check_mirrors 逐行比对线上。

★ 为什么必须写进镜像 ★
check_mirrors 把镜像重放进一个 scratch schema,再拿 public.<表> 与 mir.<表>
【逐行】比。所以"这三十条目标是逐字的"要成为一条【常设】判据,
那三十行就必须住在镜像文件里 —— 否则 gate 无从比起,而一条悄悄漂掉的目标
与一条对的目标长得一模一样。

块用标记包起来,重跑就整块替换,不会越写越多。
"""
import pathlib
import re
import subprocess
import sys

BEGIN = "-- ⟨KPI-1 SEED BEGIN — 机器生成,勿手改⟩"
END = "-- ⟨KPI-1 SEED END⟩"

seed = subprocess.run([sys.executable, "db/scripts/kpi_seed_from_spec.py"],
                      capture_output=True, text=True)
if seed.returncode != 0:
    sys.exit("FATAL: 种子生成失败:\n" + seed.stderr)

# 按目标表把 INSERT 拆开
stmts = {}
for m in re.finditer(r"^INSERT INTO public\.(\w+)[\s\S]*?;$", seed.stdout, re.M):
    stmts[m.group(1)] = m.group(0)

expect = {"positions", "kpi_organisation", "kpi_position_templates", "kpi_template_org_links"}
if set(stmts) != expect:
    sys.exit("FATAL: 拆出来的表 %s ≠ 期望的 %s" % (sorted(stmts), sorted(expect)))

TARGET = {
    "db/tables/positions.sql": ["positions"],
    "db/tables/kpi_organisation.sql": ["kpi_organisation"],
    # 模板与它的链接表定义在同一个镜像文件里,种子也一起放
    "db/tables/kpi_position_templates.sql": ["kpi_position_templates", "kpi_template_org_links"],
}

for path, tables in TARGET.items():
    p = pathlib.Path(path)
    s = p.read_text()
    s = re.sub(re.escape(BEGIN) + r"[\s\S]*?" + re.escape(END) + r"\n?", "", s)
    block = [BEGIN,
             "-- 来源:docs/kpi-framework.md,经 db/scripts/kpi_seed_from_spec.py 逐格解析。",
             "-- **改这些行要先改规格,再重新生成**(规格 §1:一至七章不能改)。"]
    for t in tables:
        block.append("")
        block.append(stmts[t])
    block.append(END)
    p.write_text(s.rstrip() + "\n\n" + "\n".join(block) + "\n")
    print("seeded mirror:", path, "→", ", ".join(tables))
