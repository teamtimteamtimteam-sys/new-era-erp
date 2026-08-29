#!/usr/bin/env python3
"""KPI-1:从 docs/kpi-framework.md 【机器抽取】O1–O5 与 30 条个人 KPI,生成种子 SQL。

★ 为什么是脚本而不是手抄 ★
规格自己写着:那些英文是【机器从 xlsx 抄出来的】,不是人打的 ——
「三十条 KPI 的目标句子由人重打一遍,就是三十次漏字的机会,
 而这份文件正是模块要照着建的那一份。」
把它们从 .md 手抄进 .sql,就是把那三十次机会又给自己一遍。所以再抄一次也用机器。

它只读第二章与第三章的表格,输出 INSERT。**任何解析不出来的东西当场退出**,
不静默跳过 —— 一条漏掉的 KPI 与一条不存在的 KPI 在输出里长得一模一样。

用法:python3 db/scripts/kpi_seed_from_spec.py   (在仓库根目录跑,输出到 stdout)
"""
import re
import sys
import pathlib
import hashlib

SPEC = pathlib.Path("docs/kpi-framework.md")
src = SPEC.read_text()


def q(s):
    return "'" + s.replace("'", "''") + "'"


# ── 第二章:O1–O5 ────────────────────────────────────────────────────────────
orgs = []
weights = {}
for m in re.finditer(r"^### (O\d) · (.+?) —— (\d+)%\s*$", src, re.M):
    code, title, weight = m.group(1), m.group(2).strip(), int(m.group(3))
    nxt = src.find("\n### ", m.end())
    block = src[m.end(): nxt if nxt > 0 else len(src)]
    fields = {}
    for row in re.finditer(r"^\| `([^`]+)` \| (.+?) \|\s*$", block, re.M):
        fields[row.group(1)] = row.group(2).strip()
    need = ['Definition', 'Month 3 target', 'Month 6 target',
            'Measurement / evidence', 'Criticality / management note']
    missing = [k for k in need if k not in fields]
    if missing:
        sys.exit("FATAL: %s 缺栏 %s —— 解析失败,不是空值" % (code, missing))
    orgs.append((code, title, weight, fields))
    weights[code] = weight

if len(orgs) != 5:
    sys.exit("FATAL: 组织 KPI 解析出 %d 条,应当 5 条" % len(orgs))
if sum(weights.values()) != 100:
    sys.exit("FATAL: 组织权重合计 %d ≠ 100" % sum(weights.values()))

# ── 第三章:六个职位,各 5 条 ────────────────────────────────────────────────
POSITION_CODE = {
    "Founder / Managing Director": "MD",
    "Chief Financial Officer": "CFO",
    "Chief Technology Officer": "CTO",
    "Chief Commercial Officer": "CCO",
    "Lead – Accounts & Corporate Services": "LEAD-ACC",
    "Lead – Warehouse & Logistics": "LEAD-WH",
}
positions = []
templates = []
ch3 = src[src.index("## 三、Employee KPIs"): src.index("## 四、Associate Roll-up")]
for m in re.finditer(r"^### (.+?) — (.+?)\s*$", ch3, re.M):
    person, role = m.group(1).strip(), m.group(2).strip()
    if role not in POSITION_CODE:
        sys.exit("FATAL: 职位名对不上代号表:%r" % role)
    code = POSITION_CODE[role]
    nxt = ch3.find("\n### ", m.end())
    block = ch3[m.end(): nxt if nxt > 0 else len(ch3)]
    rows = []
    for r in re.finditer(r"^\| ([A-Z]\d) \| (.+?) \| (\d+) \| (.+?) \| (.+?) \|\s*$", block, re.M):
        rows.append((r.group(1), r.group(2).strip(), int(r.group(3)),
                     r.group(4).strip(), r.group(5).strip()))
    if len(rows) != 5:
        sys.exit("FATAL: %s 解析出 %d 条 KPI,应当 5 条" % (person, len(rows)))
    tot = sum(x[2] for x in rows)
    if tot != 100:
        sys.exit("FATAL: %s 权重合计 %d ≠ 100" % (person, tot))
    positions.append((code, role, person, len(positions) + 1))
    templates.append((code, rows))

if len(positions) != 6:
    sys.exit("FATAL: 解析出 %d 个职位,应当 6 个" % len(positions))

# ── §9.2 的那段 target-setting note —— 原表自己的句子,不是本仓库的转述 ─────
prov_note = None
for row in re.finditer(r"^> \*Some targets are management recommendations(.+?)\*$",
                       src, re.M | re.S):
    prov_note = "Some targets are management recommendations" + row.group(1)
    prov_note = re.sub(r"\s+", " ", prov_note.replace("\n>", " ")).strip()
    break
if not prov_note:
    sys.exit("FATAL: 找不到 §9.2 那段 target-setting note —— 它是 provisional_note 的唯一来源")

# O1 的 Notes / limitation(§7 第一格),同样原文
o1_note = None
mm = re.search(r"\| `Notes / limitation` \| (The profile does not specify.+?) \|\s*$", src, re.M)
if mm:
    o1_note = re.sub(r"\s+", " ", mm.group(1)).strip()
if not o1_note:
    sys.exit("FATAL: 找不到 O1 的 Notes / limitation 原文")

# O4 那句「423 MT/月 是已识别、非已签约」—— §7 第二格
o4_note = None
mm = re.search(r"\| `Notes / limitation` \| (The deck gives identified feedstock.+?) \|\s*$", src, re.M)
if mm:
    o4_note = re.sub(r"\s+", " ", mm.group(1)).strip()
if not o4_note:
    sys.exit("FATAL: 找不到 O4 的 Notes / limitation 原文")

# 【哪些个人 KPI 标 provisional】判据写在这里,不靠记忆:
# §9.2 点名六项 —— 3/6 月的日期、≥3 months fixed-OPEX、DSO ≤45、≥70% capacity、
# ≥98% inventory accuracy、≥90% milestone adherence。
# 组织层五条【全部】标(因为"the 3-month/6-month dates"覆盖每一条的两栏目标);
# 个人层按目标文本里是否出现那几个具名的数逐条判。
PROV_MARKERS = [
    "3 months fixed OPEX", "3 months fixed-OPEX", "months fixed-OPEX",
    "DSO ≤45", "≥70%", "≥98%", "≥90%",
]

out = []
out.append("-- ⚠ 本段由 db/scripts/kpi_seed_from_spec.py 从 docs/kpi-framework.md 【机器生成】。")
out.append("-- **不要手改**:要改先改规格,再重新生成 —— 与规格自己第一章那条同一规矩")
out.append("-- (「一至七章不能改,要改先改原表,再重新转录」)。")
out.append("-- 生成时规格文件 sha256: %s" % hashlib.sha256(SPEC.read_bytes()).hexdigest())
out.append("")

out.append("INSERT INTO public.positions (code, title, source_incumbent_name, sort_order) VALUES")
out.append(",\n".join("    (%s, %s, %s, %d)" % (q(c), q(t), q(p), o)
                      for c, t, p, o in positions) + ";")
out.append("")

out.append("INSERT INTO public.kpi_organisation (code, title, weight_pct, definition,"
           " month3_target, month6_target, measurement_evidence, criticality_note,"
           " is_provisional, provisional_note, sort_order) VALUES")
rows = []
for i, (code, title, weight, f) in enumerate(orgs, start=1):
    note = prov_note
    if code == "O1":
        note = prov_note + " || " + o1_note
    elif code == "O4":
        note = prov_note + " || " + o4_note
    rows.append("    (%s, %s, %d, %s,\n     %s,\n     %s,\n     %s,\n     %s,\n"
                "     true, %s, %d)"
                % (q(code), q(title), weight, q(f['Definition']),
                   q(f['Month 3 target']), q(f['Month 6 target']),
                   q(f['Measurement / evidence']), q(f['Criticality / management note']),
                   q(note), i))
out.append(",\n".join(rows) + ";")
out.append("")

out.append("INSERT INTO public.kpi_position_templates (position_id, kpi_ref, title, weight_pct,"
           " target_text, is_provisional, provisional_note, sort_order) VALUES")
rows = []
nprov = 0
for pcode, krows in templates:
    for i, (ref, title, weight, links, target) in enumerate(krows, start=1):
        is_prov = any(mk in target for mk in PROV_MARKERS)
        if is_prov:
            nprov += 1
        rows.append("    ((SELECT id FROM public.positions WHERE code = %s),"
                    " %s, %s, %d,\n     %s,\n     %s, %s, %d)"
                    % (q(pcode), q(ref), q(title), weight, q(target),
                       'true' if is_prov else 'false',
                       q(prov_note) if is_prov else 'NULL', i))
out.append(",\n".join(rows) + ";")
out.append("")

out.append("INSERT INTO public.kpi_template_org_links (template_id, org_code) VALUES")
rows = []
nlink = 0
for pcode, krows in templates:
    for ref, title, weight, links, target in krows:
        codes = re.findall(r"O\d", links)
        if not codes:
            sys.exit("FATAL: %s/%s 的 Linked Org KPI(s) 解析不出组织代号:%r"
                     % (pcode, ref, links))
        for oc in codes:
            nlink += 1
            rows.append("    ((SELECT t.id FROM public.kpi_position_templates t"
                        " JOIN public.positions p ON p.id = t.position_id"
                        " WHERE p.code = %s AND t.kpi_ref = %s), %s)"
                        % (q(pcode), q(ref), q(oc)))
out.append(",\n".join(rows) + ";")

print("\n".join(out))
sys.stderr.write("OK: 6 职位 · 5 组织 KPI · %d 条模板 · %d 条链接 · %d 条标为 provisional\n"
                 % (sum(len(r) for _, r in templates), nlink, nprov))
