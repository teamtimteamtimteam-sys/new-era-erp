#!/usr/bin/env python3
"""KPI-1:从镜像 + 种子生成器拼出迁移文件。拼装用机器,理由与种子同一条。"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql"

HEADER = """-- KPI-1:职位主数据 + KPI 框架 —— 规格是 docs/kpi-framework.md,本刀只是【建它】。
--
-- ★★【这一刀不【推导】任何东西:规格已经写好了,而它的一至七章是不可改的转录】★★
--   规格第 12 行:一至七章是「原表的逐格转录,英文原文」,**不能改**;
--   要改先改原表,再重新转录。第 17 行:那些英文是**机器从 xlsx 抄出来的**,
--   不是人打的 ——「三十条 KPI 的目标句子由人重打一遍,就是三十次漏字的机会」。
--   **所以本迁移里的英文也是机器抄的**:见 db/scripts/kpi_seed_from_spec.py,
--   它从 .md 里逐格解析,解析不出来就当场退出(一条漏掉的 KPI 与一条不存在的
--   KPI 在输出里长得一模一样)。
--
-- 【顺序,以及为什么是这个顺序 —— 规格 §11 的六步】
--   1 职位主数据 → 2 组织 KPI → 3 职位模板(要 1 与 2 都在)→
--   4 周期与打分 → 5 按职位复制 → 6 派生视图
--   表必须先于视图;kpi_template_org_links 的外键要求 kpi_organisation 先有行。
--
-- ★【两条【裁定】写在这里,因为它们解释了下面为什么长这样】★
--
--   (一)**KPI 不扩建 review_goals,两者并存**(Tim 2026-08-29;规格 §12.2 曾把它
--        列为公开问题,现已裁定)。代码本身给出了理由:`review_goals` 的表注写着
--        **「没有权重、没有逐条打分」**——「一旦有了分数,谈话就会围着分数转,
--        而不是围着结果转」。而 KPI 的全部内容就是 0–5 乘权重。
--        **两者是设计上的对立面,不是偶然的重复。**
--        本迁移因此【一个字节都不动】既有考核模块 —— 尤其不碰 review_goals
--        那三条 SELECT 策略,其中一条是「本人只在评估 approved/acknowledged 之后
--        才看得见自己的目标」,那是自评的可见性机制。
--
--   (二)**kpi_cycles 不复用 review_cycles,尽管形状一模一样。**
--        共用周期是两个模块悄悄变成一个的方式:第一次有人开一个 HR 评估周期,
--        每块 KPI 屏幕都会继承它,而上面那条裁定就被一条没人再读过的外键推翻了。
--        五个重复的列,对上一次永久的耦合。
--
-- 【employees.job_title 从员工行上【删掉】,而 employment_history.job_title 留着】
--   §12.1 点过名:「两个都留着、两个都能填,就是同一个事实有两个写入口」。
--   职位从此由 employees.position_id 回答。
--   **但履历那一列是【不可变的快照】**,记的是"那一天这个人的头衔写的是什么" ——
--   与 collection_chases.contacted_person、invoices.bill_to_snapshot 同一族。
--   快照不该变成指针:否则删一个职位就改写了一段发生过的履历。
--   **改职位仍然要写一行履历**(app/hr/employees/actions.ts),
--   而那一行的 job_title 是【当时那个职位的 title 文本】—— 少了这一半,
--   一次实质变动会在一条今天还工作着的审计轨迹里【无声消失】,那是回归不是省略。

BEGIN;
"""

FOOTER = """
COMMIT;
"""


def strip_note(text):
    return re.sub(r"^-- NOTE: introduced by.*\n-- First-run script.*\n", "", text, flags=re.M)


parts = [HEADER]

parts.append("\n-- ═══ 第 1 步:职位主数据 ═══════════════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/positions.sql").read_text()))

parts.append("""
-- ── employees:挂到职位上,并把 job_title 从这一行上退役 ────────────────────
ALTER TABLE public.employees
    ADD COLUMN position_id uuid REFERENCES public.positions (id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.employees.position_id IS
    'KPI-1:这个人今天在哪个职位上。**KPI 绑在职位上,不绑在人上**(规格 §8.1)—— 那是 exec-views-plan 开篇「答案取自职责,不取自职级」的第二次落地。它取代了本表上原来那个自由文本的 job_title(已删):两个都能填就是同一个事实有两个写入口(§12.1)。**employment_history.job_title 保留**,那是一条不可变的履历快照,记的是"那一天头衔写的是什么"。';
""")

parts.append("\n-- ═══ 第 2 步:组织 KPI ════════════════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/kpi_organisation.sql").read_text()))

parts.append("\n-- ═══ 第 3 步:职位 KPI 模板 ═══════════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/kpi_position_templates.sql").read_text()))

parts.append("\n-- ═══ 第 4 步:周期与条目 ══════════════════════════════════════════════\n")
parts.append(strip_note((ROOT / "db/tables/kpi_cycles.sql").read_text()))
parts.append(strip_note((ROOT / "db/tables/kpi_entries.sql").read_text()))

parts.append("\n-- ═══ 第 5 步:按职位复制 + 打分 ═══════════════════════════════════════\n")
parts.append((ROOT / "db/functions/assign_position_kpis.sql").read_text())
parts.append((ROOT / "db/functions/score_kpi_entry.sql").read_text())

# 【种子不在这里再拼一次】它已经住在上面那三个镜像文件里了
# (db/scripts/kpi_seed_into_mirrors.py 写进去的),而镜像是本迁移的来源。
# 在这里再 append 一遍会插两次 —— 第二次撞唯一约束。
# **顺序是对的**:positions(第 1 步)→ kpi_organisation(第 2 步)→
# 模板与链接(第 3 步),而 kpi_template_org_links 的外键要求 kpi_organisation 先有行。

parts.append("""
-- ── 把两位在册员工挂到职位上 ───────────────────────────────────────────────
-- ★【这一步是【有据】的,不是推断的】★(Tim 2026-08-29 裁定)
--   · Choo Er Teh → LEAD-ACC:她在原表第三、四页被点名在这个职位上,
--     那是一条【记录在案的事实】。
--   · Tim → CFO:Tim 本人确认他就是 Tim Chen、职位是 CFO。
--     那是【他关于自己的陈述】,所以不是本刀从四个字母去猜一个人是谁。
--   实测线上 employees 有 21 行,其中 19 行是 ZZ-* 脚手架,真员工只有这两位;
--   而原表点名的六个人里【另外四个根本没有员工档案】。
--   **于是员工级 roll-up 今天只会显示【六分之二】,而那必须被说出来**
--   ——一张只显示两个人、什么都不说的 roll-up,看起来像是全部。
UPDATE public.employees SET position_id = (SELECT id FROM public.positions WHERE code = 'LEAD-ACC')
 WHERE code = 'EMP-2026-0001';
UPDATE public.employees SET position_id = (SELECT id FROM public.positions WHERE code = 'CFO')
 WHERE code = 'EMP-2026-0002';

""")

parts.append("""
-- ── my_profile 跟着改:头衔从职位来 ────────────────────────────────────────
-- 【必须在 DROP COLUMN job_title 【之前】替换】否则那张视图会拦住 DROP:
-- 它今天 SELECT e.job_title,而一个被视图引用的列删不掉。
""")
# 【镜像是【首次运行】脚本,里面是 CREATE VIEW;而 my_profile 线上已经存在】
# 所以拼进迁移时换成 CREATE OR REPLACE —— 新加的列在末尾,替换得动
# (中间插一列就得 DROP + 重建,而这张视图有下游读者)。
# ★【DROP COLUMN 之前,要替换的不止 my_profile —— 实测有四张视图引用它】★
#   employees_masked / employee_directory(经 employees_masked)/ my_review_subjects / my_profile。
#   这一条是迁移【第一次跑失败时数据库自己说出来的】,不是我事先想全的:
#   「cannot drop column job_title … because other objects depend on it」。
#   单事务的好处正在这里 —— 失败即整支回滚,库一个字节都没动。
#   employees_masked 有下游(employee_directory),所以它要先于下游被替换。
for _v in ["employees_masked", "employee_directory", "my_review_subjects", "my_profile"]:
    parts.append((ROOT / f"db/views/{_v}.sql").read_text()
                 .replace(f"CREATE VIEW public.{_v}", f"CREATE OR REPLACE VIEW public.{_v}", 1))
    parts.append("\n")

parts.append("\n-- ═══ 第 6 步:派生视图(roll-up 与联动矩阵,不建表)═══════════════════\n")
for v in ["kpi_position_linkage_matrix", "kpi_employee_linkage_matrix",
          "kpi_employee_rollup", "my_kpi_entries"]:
    parts.append((ROOT / f"db/views/{v}.sql").read_text())
    parts.append("\n")

parts.append("""
-- ── 现在才删 employees.job_title —— ★顺序不是风格问题★ ─────────────────────
-- 【为什么放在最后】my_profile 今天 SELECT e.job_title,
-- 而**一个被视图引用的列删不掉**(PostgreSQL 会拒)。所以必须先把那张视图
-- 替换成读 positions.title 的版本(就在上面),这一句才走得通。
-- employment_history 上的同名列【不动】:它是不可变的履历快照,见本文件抬头。
ALTER TABLE public.employees DROP COLUMN job_title;
""")

parts.append(FOOTER)
OUT.write_text("".join(parts))
print("written:", OUT, sum(1 for _ in OUT.open()), "lines")
