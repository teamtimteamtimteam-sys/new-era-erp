#!/usr/bin/env python3
"""镜像漂移体检:把 db/tables + db/functions + db/views 整套重放进一个临时 schema,
与线上目录逐对象比对,报告漂移与覆盖缺口。

用法
    python3 db/check_mirrors.py            # 人类可读摘要
    python3 db/check_mirrors.py --json     # 完整 JSON 报告
退出码:0 = 全部一致;1 = 有漂移或覆盖缺口;2 = 执行失败(SQL 报错/连不上等)。

═══════════════════════════════════════════════════════════════════════════════
安全性 —— 这两段是本脚本的立身之本,改动本文件前先读懂:

1. 【回滚保证】整个重放 + 比对跑在【一个】事务里,脚本生成的 SQL 从不包含 COMMIT,
   末尾是显式 ROLLBACK;psql 以 ON_ERROR_STOP 运行,中途任何报错都会中断会话,
   而连接断开 = 事务中止 = 自动回滚。所以无论成功、失败还是半途被杀,线上库都
   不会留下任何东西(临时 schema、表、函数、种子行,统统随事务蒸发)。

2. 【CREATE OR REPLACE FUNCTION 陷阱】表镜像文件里【混着函数定义】(守卫触发器
   函数、code 生成函数……)。谁要是图省事把镜像文件直接灌进线上库"看看能不能跑",
   这些 CREATE OR REPLACE 会【当场覆盖同名线上函数】—— 若镜像恰好落后于线上,
   这一下就把漂移写进了生产,而且没有任何报错。本脚本因此把每个文件里的
   `public.` 全部改写为临时 schema 前缀后才执行,任何语句都不触碰 public 下的
   对象;比对时再把两侧的 schema 前缀归一化掉。【绝不要】绕过改写直接重放镜像。
═══════════════════════════════════════════════════════════════════════════════

方法概要
  * 重放顺序:先 db/functions(SET check_function_bodies=off,函数体不在创建时
    校验,故可先于表存在)→ 再 db/tables(按 FK / 跨表触发器依赖拓扑排序)→
    最后 db/views(按视图间引用排序)。
  * 比对维度:表 = 列(名/类型/可空/默认值/生成列/【列注释】,按 attnum 顺序)+ 约束 +
    索引 + 触发器 + RLS 开关 + 策略;函数 = pg_get_functiondef;视图 = pg_get_viewdef +
    reloptions(security_invoker)。
    【列注释为什么要比】OPS-1 的重建实验发现 7 条 COMMENT ON COLUMN 只存在于线上,
    镜像里一条都没有 —— 其中就有 HR-3b 那句界定"月固定工资总额不含加班"的说明。
    照镜像重建出来的库,那些说明【整条丢失】,而当时的检查看不见。注释是写在数据库里
    的规格说明,不是排版;它跟着列走,就该跟着列一起比。定义文本先把 schema 前缀(mir./public.)剥掉
    再比,因此文件里的排版、约束写法(IN vs = ANY)都不影响结果 —— 目录归一化
    之后是二元的:一致,或不一致。
  * 覆盖:public 里存在而重放结果里没有 = 缺镜像;反之 = 镜像的对象已不在线上。
    表/视图/函数/序列/枚举都查,双向。排除扩展自带的对象(pg_depend deptype 'e')。
  * 【种子行 / SEED ROWS】(OPS-1 增补)结构一致不等于装得起来 —— 照镜像重建出来的
    库曾经【一个会计科目都没有】,财务模块过不了任何一笔账,而本脚本一路是绿的。
    现在按 SEED_TABLES 清单逐行比对【安装种子】表(见该常量的分类规则):
      INSTALL SEED  —— 操作员在应用里【改不了】的行,与代码版本绑定 ⇒ 逐行比对线上。
      RUNTIME CONFIG —— 操作员改得了的行 ⇒ 镜像里的是"全新安装默认值",【不与线上比】。
  * 【镜像自洽 / INTEGRITY】(OPS-1 增补)不看线上,只看镜像这一套自己首尾相顾:
      - 每条 has_permission('X') 里的 X 必须在 permissions 的种子里;
      - role_permissions 种子引用的每个码必须在 permissions 的种子里;
      - 镜像里出现的每个科目字面量必须在 accounts 的种子里,【且必须打了 is_system】。
    这三条里的任何一条,单独就能抓住 OPS-1 那个 bug,而且完全不需要连线上。
  * 【看不见的东西 —— 这一条比"不比"更要紧】本脚本把镜像重放进【线上库里】的一个
    临时 schema(mir),并把文件里的 `public.` 改写成 `mir.`。于是任何【没有加架构
    前缀】的引用会顺着 search_path 落到【线上的 public】上,借到一个真实存在的对象,
    然后一路绿灯 —— 哪怕空库里根本没有它。
    实例:`RETURNS performance_reviews`(未加前缀)在这里解析到线上那张表,本脚本
    报"体检通过",而照镜像重建一个空库【当场失败】。
    能抓住这一类的只有 db/verify_rebuild.py —— 它真的建进一个空库,没有东西可借。
    所以【动了数据库的每一切,两个都要跑】。
  * 【不比】:约束名(只比定义)、GRANT、序列参数与当前值、表存储参数。文件级排版(如尾随换行)也不在此查 —— 目录里没有这个概念。

约定(与 AGENTS.md 呼应):动了表的迁移必须在【同一个提交】里更新该表的镜像;
拿不准就跑本脚本。
"""

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCHEMA = "mir"  # 临时 schema 名;若与真实 schema 撞名请改(线上不该有叫这个的)

# 连接串:host/port/user/db 与 ~/evoltrya-backups/backup.sh 一致,密码走 ~/.pgpass。
# 需要指向别处时用环境变量 CHECK_MIRRORS_DSN 覆盖。
DEFAULT_DSN = (
    "host=aws-1-ap-southeast-1.pooler.supabase.com port=5432 "
    "user=postgres.wvywpohbwkiinmipmuku dbname=postgres"
)

MARKER = "<<<MIRROR_REPORT>>>"
SEED_MARKER = "<<<SEED_REPORT>>>"

# ═══════════════════════════════════════════════════════════════════════════
# 种子行清单。分类的判据【只有一句话】:操作员能不能通过应用的正常使用改动这些行?
#   不能 → INSTALL SEED:行与代码版本绑定,镜像逐行跟踪线上,不一致即失败。
#          这些表【只许迁移写】,db/scripts/ 的数据脚本永远不许碰 —— 于是
#          db/scripts/README.md 那句"脚本不涉及镜像"继续成立。
#   能   → RUNTIME CONFIG:线上理应与文件不同,那是系统在正常工作。不比对。
# 判据要有证据(哪个页面 / RPC / 脚本在写),不靠直觉。证据见各镜像文件的抬头。
# ═══════════════════════════════════════════════════════════════════════════
# ── ★【比对表达式里的表名一律写 {S}. —— 不许写 public.】★ ────────────────────
# 【CHECK-1(2026-08-31):这一条是被一个实测的假阳性买来的】
# 本文件把镜像重建进【同一个库的另一个 schema】(mir),而 gate.py 把镜像建进
# 【另一个库】的 public。于是同一句 cols 在两个工具里含义不同:
#   * gate:两侧都是 public,各在自己的库里 —— public. 写死【碰巧】是对的;
#   * 本文件:live 侧是 public、mirror 侧是 mir —— public. 写死就是【跨 schema】,
#     相关子查询拿 mir 的 position_id 去 public.positions 里找,当然找不到。
#
# 症状:kpi_position_templates 的 position_code 在 live 侧是 'CFO'、mirror 侧是
# NULL,于是每一行都"漂移"。**镜像其实一个字都没错** —— 错的是比对表达式。
# 本地两 schema 复现(CHECK-1 实测):写死 public. → drift 2;改成各自的 schema
# → drift 0;而把 mirror 的 title 改一个字 → drift 2 回来。**它没有变瞎,只是不再撒谎。**
#
# 【为什么这不是"两个检查测的东西不同"】gate 的 colgrant/seed 与本文件问的是
# 同一个问题。一个报红一个报绿,只可能有一个是对的,而这次对的是 gate。
# 一个在种子上喊狼来了的检查,与一个被人关掉的检查是同一种坏 —— 都是让人
# 学会不看它。所以这里不是把两个名字分开,是【把错的那个修好】。
#
# 【为什么是占位符而不是把那两行改对】改对两行,只是让今天的两行对;
# 下一个写相关子查询的人会原样再写一遍 public.。占位符 + 下面那条断言,
# 让"写死 public."这件事【做不到】,而不是"记得别做"。
# ────────────────────────────────────────────────────────────────────────────
SEED_TABLES = {
    # table: (WHERE 子句 or None, 比对的列 —— 表名一律 {S}.,见上)
    "permissions": (None, "code, category, name_en, name_zh, "
                          "COALESCE(description_en,'') AS description_en, "
                          "COALESCE(description_zh,'') AS description_zh, sort_order"),
    "currencies":  (None, "code, name, is_base"),
    # GST-1:税码与税率是【法定事实】,不是操作员的地盘 —— 仓库与线上不一致
    # 正是必须被抓住的那件事。加一个税码只有在有代码认它、且它进哪一格被写下来
    # 之后才有意义,所以它与 permissions 同一类:扩充目录天生是迁移级动作。
    "tax_codes":   (None, "code, side, name_en, name_zh, "
                          "COALESCE(f5_supply_box,'') AS f5_supply_box, "
                          "COALESCE(f5_purchase_box,'') AS f5_purchase_box, "
                          "COALESCE(f5_tax_box,'') AS f5_tax_box, is_claimable, sort_order"),
    # 税率史更硬:一行写错,一张历史单据就会拿到一个当时并不适用的税率。
    "tax_rates":   (None, "tax_code, rate_pct, effective_from, "
                          "COALESCE(effective_to, DATE '9999-12-31') AS effective_to"),
    # WHT-1:预提税的性质字典与税率史 —— 与 tax_codes / tax_rates 【逐字同一条理由】,
    # 而且更硬一层:这张税率表的内容**还没有被会计师核对过**(见
    # db/tables/wht_rates.sql 的表注释与 accounting-policies.md §8.3)。
    # 一张"内容待核对"的表如果连【仓库与线上是否一致】都没人比,
    # 那么核对过的那一版与线上跑着的那一版可以安静地分开 —— 而它算得出数、
    # 报得出表、一条错误都不会有。所以它必须逐行比对。
    "wht_natures": (None, "code, name_en, name_zh, statute_ref, is_active, sort_order"),
    "wht_rates":   (None, "nature, rate_pct, effective_from, "
                          "COALESCE(effective_to, DATE '9999-12-31') AS effective_to"),
    # ★ KPI-1:职位与 KPI 框架 —— 与 tax_codes / wht_rates 【同一条理由,而且更硬】。
    #   规格 docs/kpi-framework.md 第一至七章是**不可改的逐格转录**,而那三十条目标
    #   句子是【机器从 xlsx 抄出来的】,不是人打的 ——「由人重打一遍就是三十次漏字
    #   的机会」。**如果这几张表不逐行比对,一条悄悄漂掉的目标与一条对的目标
    #   长得一模一样**,而系统照样算得出加权分、报得出 roll-up、一条错误都没有。
    #   操作员在界面上【改不动】它们(没有 INSERT/UPDATE 策略,写入只经迁移),
    #   所以按本文件抬头那句判据,它们是 INSTALL SEED 而不是 RUNTIME CONFIG。
    #   **代价说清楚:调一条目标从此是迁移级动作** —— 而规格 §9.2 说的正是
    #   "目标应随排期/产能/商务条款变化而调整",不是"谁都可以在表单里重打一遍"。
    "positions": (None, "code, title, COALESCE(source_incumbent_name,'') AS source_incumbent_name, "
                        "is_active, sort_order"),
    "kpi_organisation": (None, "code, title, weight_pct, definition, month3_target, month6_target, "
                               "measurement_evidence, criticality_note, is_provisional, "
                               "COALESCE(provisional_note,'') AS provisional_note, sort_order"),
    "kpi_position_templates": (None,
        "(SELECT p.code FROM {S}.positions p WHERE p.id = position_id) AS position_code, "
        "kpi_ref, title, weight_pct, target_text, "
        "COALESCE(evidence_source,'') AS evidence_source, is_provisional, "
        "COALESCE(provisional_note,'') AS provisional_note, version, sort_order"),
    "kpi_template_org_links": (None,
        "(SELECT p.code || '/' || t.kpi_ref FROM {S}.kpi_position_templates t "
        " JOIN {S}.positions p ON p.id = t.position_id WHERE t.id = template_id) AS tpl, org_code"),
    # PROC-WIRE-1B-i:工序的【种类】—— INSTALL SEED。判据与下面那条同源:
    # 加一种工序种类【不是加一行数据】,运行时要先懂得它意味着什么
    # (consumes_input / produces_outputs 驱动 commit_processing_run 的分支)。
    # 操作员改不动它(没有写策略),所以线上多一行就是真漂移。
    "operation_kinds": (None, "code, name_en, name_zh, consumes_input, produces_outputs, is_active, sort_order"),
    # PROC-WIRE-1A:产出批次的【销售状态】字典 —— INSTALL SEED,不是 RUNTIME CONFIG。
    # 判据与 KPI-1 那条逐字相同:操作员在界面上改不动它(没有 INSERT/UPDATE 策略,
    # 写入只经迁移)。而且更硬一层 —— **加一个销售状态没有意义,因为没有任何东西
    # 会写它**:那三个取值是 record_output_sale / ship_order 里同一句 CASE WHEN
    # 算出来的,多一行只会得到一个永远零行的状态。所以线上多出一行【就是】真漂移。
    "output_batch_states": (None, "code, name_en, name_zh, is_active, sort_order"),
    # accounts 是【混合表】:引擎点名的 34 行跟踪线上,其余是建账的人的地盘。
    # FIN-30:is_cash / cash_flow_section 也纳入比对 —— 它们决定现金流量表取哪些
    # 科目、归哪一段;线上被人翻了标记而无人察觉,报表会安静地算错一整类活动。
    "accounts":    ("is_system", "code, name_en, name_zh, account_type, is_system, "
                                 "is_cash, COALESCE(cash_flow_section,'') AS cash_flow_section"),
}


def _assert_seed_cols_schema_neutral() -> None:
    """比对表达式里不许出现写死的 public. —— 见 SEED_TABLES 抬头。

    【为什么是断言而不是注释】上面那段注释在被违反的那一刻【什么也不会发生】。
    这一条会:任何人再写一次 public.,两个工具在【导入的那一瞬间】就起不来,
    而不是安静地报一整张表的假漂移。零必须是测量,红也必须是真的。
    """
    bad = [f"{t}: {cols}" for t, (_w, cols) in SEED_TABLES.items()
           if re.search(r"\bpublic\.", cols)]
    if bad:
        raise SystemExit(
            "✗ check_mirrors:SEED_TABLES 的比对表达式里写死了 public. —— "
            "两个工具把镜像放在不同地方(mir schema / 另一个库),写死就是跨 schema 比对。\n"
            "  【怎么改】把表名写成 {S}.<表>,调用方会各自替换成 public / mir。\n"
            "  违反的项:\n    " + "\n    ".join(bad))


_assert_seed_cols_schema_neutral()

RUNTIME_CONFIG_TABLES = [
    "roles", "role_permissions", "leave_types", "public_holidays",
    "review_rating_scale", "company_profile", "finance_settings", "hr_settings",
    # HR-2c:HR 会在界面上加 override 行(一份谈定的年假是合同条款),
    # 逐行跟踪线上会让第一个 override 就把 check_mirrors 变红,那样这个检查就没人信了。
    "leave_accrual_rates",
    # CMP-1:证书类型 —— disposition 与 lead days 是操作员的地盘,改了是系统在
    # 正常工作(引导值只是默认)。逐行比对会让第一次改处置就把检查变红。
    "certificate_types",
    # METAL-1:行情异常提示的阈值 —— 与 warn_lead_days 同一条。50 是引导默认值,
    # 不是决定;Tim 在 /metal-prices 上改一次,线上就与本文件不同,那是对的。
    "pricing_settings",
    # METAL-2:行情指数字典 —— 加一个指数是加一行(与 certificate_types 同一条)。
    # SMM 的 quote_currency 引导里【故意为空】,Tim 声明之后线上会与本文件不同,
    # 那是系统在正常工作。
    "metal_price_indices",
    # MAT-1:受控废物分类 —— 加一种分类是加一行(与 certificate_types 同一条)。
    "waste_classifications",
    # PROC-1:物料种类字典 —— 加一种物料种类是加一行(与 certificate_types 同一条)。
    # 引导播五行;Tim 在界面上加一种,线上就与本文件不同,那是系统在正常工作。
    "material_kinds",
    # PROC-4:我们测量并核算的元素与物质(七个金属起步;氟/氯/石墨/塑料是排着队的)
    "substances",
    # PROC-5:F7 点名的最后两处自由文本分类
    "battery_chemistries", "laboratories",
    # PROC-2:五条进料状态轴,五张字典 —— 同一条。轴在 PROC-2 定死,取值可以后到,
    # 而"后到"的代价正是一行数据,这就是把它们做成字典换来的东西。
    "material_forms", "material_sources", "material_size_formats",
    "inbound_safety_states", "inbound_chemistry_certainties",
    # PROC-1B-iii:【能不能深度放电】这个采购时的判断 —— RUNTIME CONFIG,
    # 判据与 inbound_safety_states / output_batch_purposes 同源:操作员改得动它
    # (有写策略,module.materials.edit),所以线上与文件不同是系统在正常工作。
    # 【它有一条载荷列 is_a_claim】grn_discrepancies 现读它来决定"这一侧算不算
    # 一次主张" —— 与 inbound_safety_states.may_be_fed 同形(那一张也是 RUNTIME
    # CONFIG 且带一条载荷列)。于是加第四个取值真的只是加一行。
    "deep_discharge_judgements",
    # GRN-1a:收货差异的三个阈值 —— 与 processing_settings 的两个工单阈值同一条。
    # 5/5/10 是引导默认值,不是决定;运营改一次线上就与本文件不同,那是对的。
    "receiving_settings",
    # PROC-WIRE-1B-i:工序字典与它的三张 N×M 受理表 —— 加一道工序(= 加一台机器)
    # 是加一行,与 certificate_types 同一条。三张表【同形】,那是刻意的:
    # "这道工序受理什么"只有一个定义方式,不是形态一套、安全状态另一套。
    "operation_types", "operation_type_input_forms", "operation_type_output_forms",
    # 【这一张是那道【起火】闸的受理清单】它是 RUNTIME CONFIG,于是【线上悄悄多一行
    # 不会被镜像抓到】—— 具名缺口,记在 docs/proc-operations-wired.md。
    # 护着它的是 fixture 的那条不变式(只许收紧),不是逐行比对。
    "operation_type_safety_states",
    # PROC-WIRE-1A:产出批次【用途】—— 与 certificate_types 同一条:加一种是加一行。
    # 第四条拒绝(SALE_BATCH_EARMARKED)读的是 is_saleable_stock 那一列,不是写死的
    # 码,所以多一种不可售用途【不需要改代码】。它与同刀的 output_batch_states
    # 分属两类,那不是随手放的:那一张操作员改不动,这一张改得动。
    "output_batch_purposes",
    # EQP-2b:资本化阈值(百分比 + 绝对下限)—— 同上。10 / 1000 是引导默认值,
    # 而它是一条【会计政策】,Tim 改一次线上就与本文件不同,那是系统在正常工作。
    "maintenance_settings",
    # PROC-SUPPORT-1(R4):班次字典 —— 加一个班次是加一行(与 certificate_types 同一条)。
    # 【引导的两行【故意】不带时刻】Tim 说了"会有两个班",所以两行有出处;他【没有】
    # 说几点到几点,而这个库的规矩是没人说过的数不许被发明出来填上。Tim 在班次那一屏
    # 上填一次,线上就与本文件不同 —— 那是系统在正常工作,不是漂移。
    "shifts",
    # PROC-SUPPORT-1(R4):交接班记哪几类内容 —— ★ 第七个字段是加一行,不是改代码 ★。
    # 引导只有一行(unfinished_work),因为其余六项要么是 shift_handovers 上的列、
    # 要么是【引用】(设备状态)、要么阻塞在 G8(这个班处理了什么)、要么属于尚未建的
    # WSH 登记簿(事故)。一行不是"建少了",是每一项都放回它该在的地方之后剩下的那一项。
    "handover_item_types",
    # RECV-SOURCE-1(R2):无单收货的理由字典 —— 第五个理由必须是一行,不是一次改码。
    # requires_explanation 是规则列(R3:other 必须带书面说明),触发器读它,
    # 所以"第五个也要说明的理由"同样只是一行。与 certificate_types 同一条。
    "inbound_source_reasons",
    # ★ C-2:0–5 打分刻度与安全/监管否决 —— 与 public_holidays 同一条论证:
    #   **打分的规则必须能不发版就改正**(module.hr.edit 可改)。引导的六行是原表
    #   第六页的逐格转录,是"全新安装的默认值",不是线上快照。Tim 在界面上改一句
    #   措辞,线上就与本文件不同 —— 那是系统在正常工作,不是漂移。
    "kpi_score_rubric",
]

# 【引导默认值一行都不许是空的】RUNTIME CONFIG 的种子不与线上比对(那是对的:界面改得动),
# 但"不比对"把另一类失败也一起藏了起来 —— 一条 INSERT ... SELECT 只要 WHERE 不再匹配,
# 就会【安安静静地插入零行】,不报错、不漂移。实测:把 role_permissions 里 admin 的
# 那条 WHERE 改成一个错的角色码,重建出来的库管理员一个权限都没有,而本脚本报"体检通过"。
# 所以对每张 RUNTIME CONFIG 表:重放之后行数必须 > 0。
# 若将来某张表【确实】应当空着引导,把它写进下面这个集合,让那件事是一次明写的决定。
BOOTSTRAP_MAY_BE_EMPTY: set = set()

# ═══════════════════════════════════════════════════════════════════════════
# 【SECURITY DEFINER 必须自己查调用者】(OPS-3)
# DEFINER 函数以属主身份运行,而 public 架构里的函数默认把 EXECUTE 授给 PUBLIC ——
# 所以"内部函数"只是命名上内部,任何登录用户都调得到。OPS-3 实测:七个假期函数
# 让零权限员工读到了别人的余额,而对外的包装函数是拒绝的。
#
# 这个扫描【只看得见有没有"像样的检查"】,看不见检查得对不对:
#   * 认得出:require_permission( / has_permission( / current_user_employee( /
#             is_reviewer_of( / require_reviewer_of( / require_leave_visibility(
#   * 认不出:检查写错了对象、检查了却没 RAISE、状态门当权限用(OPS-3 叫它"(e) 侥幸")
# 所以它是一张网,不是一份证明。放行项必须写进下面的名单并说明理由。
DEFINER_NO_CHECK_ALLOWED = {
    # 权限判断本身的原语 —— 它们就是"检查",不可能再检查自己
    "has_permission": "the permission check itself",
    "current_user_permissions": "resolves the caller's own permission set",
    "current_user_employee": "resolves the caller's own employee row",
    "is_reviewer_of": "the identity check itself",
    "require_permission": "raises on behalf of its callers",
    "require_reviewer_of": "raises on behalf of its callers",
    # 触发器函数:返回 trigger,调不动;闸门是触发它的那次基表写入(perm2a 的设计)
    # —— 由返回类型自动排除,不需要列在这里。
    # 已收回 EXECUTE 的内层函数(ACL 里没有 PUBLIC 项)
    "calculate_metal_price_internal": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # CHAIN-BUILD-1:审批链的两支内层判据。同 calculate_metal_price_internal ——
    # EXECUTE 已从 authenticated 收回(db/views/zzz_function_grants.sql),靠的就是
    # 【调不到】,所以 gate 的 B2(definer-unchecked-and-CALLABLE)是 0。
    # 它们【不能】自己查权限:三个调用方里 guard_approvals_switch 是触发器、
    # require_approver_for 是授权判据本身,两者都以属主身份跑而属主没有 claims ——
    # 加一道门反而会在开关与审批的路上抛权限错(与 GST-1 那两支逐字同一条理由)。
    # EQP-PAY-1:一张采购单是设备单还是材料单。EXECUTE 已从 authenticated/anon/PUBLIC
    # 收回(db/views/zzz_function_grants.sql),所以 gate 的 B2
    # (definer-unchecked-and-CALLABLE)是 0 —— 靠的就是【调不到】。
    # 【它不能自己查权限】唯一的库内调用者 guard_payment_term_applicable 是
    # 【属主身份跑的触发器】,属主(postgres)没有 claims,加一道门会在每一次写
    # 付款计划的路上抛权限错(与 gst_registered / real_role_holders 逐字同一条理由)。
    # 【它为什么必须是 DEFINER】守卫靠它认主语。受 RLS 约束的话,一个看不见行的
    # 调用者会拿到 NULL,而守卫会因此【静默放行】—— 正是"守卫对主语缺席这一格
    # 是瞎的"那条病。
    "purchase_order_kind": "EXECUTE revoked from PUBLIC/authenticated/anon; its only caller is the owner-run trigger guard_payment_term_applicable, and postgres has no claims so a permission check would raise on every payment-terms write",
    "real_role_holders": "EXECUTE revoked from authenticated; callers guard_approvals_switch / approvals_readiness / require_approver_for are all definer and each checks its own caller",
    # C-1(2026-09-04):real_role_grants —— real_role_holders 的行级形状,四条判据的唯一住处。
    # 同源同理由:读 auth.users,EXECUTE 已从 authenticated 收回(zzz_function_grants.sql)。
    # 唯一调用方 guard_last_admin 是属主身份跑的触发器,收回之后照常工作。
    "real_role_grants": "EXECUTE revoked from authenticated; its only caller is the owner-run trigger guard_last_admin, which is SECURITY DEFINER precisely so this stays unreachable",
    "role_can_see_amounts": "EXECUTE revoked from authenticated; callers guard_approvals_switch / approvals_readiness are both definer and each checks its own caller",
    # TASK-1c-a:两扇门(创建门与升级门)共用的那一个写入者。没有调用者检查,
    # 靠的就是调不到 —— fu1 已把 authenticated 的 EXECUTE 收回(gate 的 B2 抓过一次:
    # 留着它等于给每个登录用户一把针对全部团队任务的写权限)。
    "ensure_task_owner_participant": "EXECUTE revoked from PUBLIC/authenticated/anon (TASK-1c-a-fu1); only called from the two door triggers, owner-rights",
    # IOD-1 的两个内层算子:库存排空与冲销镜像。三个调用方分属不同模块
    # (销售 output.edit / 投料 processing.edit / 注销触发器 批次侧 edit),各自
    # 已把过关;给它们挑一个权限码只能挑一个比三者都松的 —— 那不是把关。
    # 走的是"调不到"这条路,REVOKE 写在 db/views/zzz_function_grants.sql 里。
    "drain_stock": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "mirror_consume_restore": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # IOD-1b:收货库位翻译器,三个建批次 RPC 共用;同上,靠"调不到"
    "resolve_receipt_location": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # IOD-2:库位/物料分类的判词。四个落地点共用,而它们分属三个模块
    # (inbound.edit / output.edit / inventory.edit)且各自已把过关 —— 给它挑一个
    # 权限码只能挑一个比三者都松的。同 resolve_receipt_location,靠"调不到"。
    "check_location_class": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # NTF-1:两个通知发射器。它们能凭空写出一条通知,而 notifications 可信的全部
    # 依据就是"只有属主身份的函数写得进"(同 approval_log)。靠"调不到"。
    "notify_landing_warnings": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "notify_class_violations": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "reverse_journal_entry_internal": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # GST-2:税码解析器。**它什么权限码都挑不出来** —— 它服务的是三个单据族
    # (开票 finance.edit、订单开票 finance.edit、记费用 finance.edit),而它自己
    # 只做一件事:把"往来对象默认 + 本单指定"归结成一个码,或者按名拒。
    # 越权面是 tax_codes 这张字典(它的 RLS 谓词是 module.finance.view)——
    # 留着 authenticated 的 EXECUTE 就等于让任何登录用户读出整本税码字典。
    # 走"调不到"这条路,REVOKE 写在 db/views/zzz_function_grants.sql 里
    # (GST-1 学到的那一条:迁移里写 REVOKE 是没有用的,它会被函数授权兜底撤销)。
    "resolve_tax_code": "EXECUTE revoked from PUBLIC/authenticated/anon (GST-2)",
    # SOD-1:职责分离的三支内层函数。**它们不是同一个理由,写成两段。**
    #
    # 【前两支:真的越权读 —— 收权限【就是】那道控制】
    # sod_manual_posters_in 读 journal_entries,sod_supplier_creator 读 suppliers。
    # 都是 SECURITY DEFINER,留着 authenticated 的 EXECUTE 就等于让任何登录用户
    # 绕过 RLS 读出"谁记过手工凭证"与"谁建了这家供应商"。
    # 【为什么不给它们加 require_permission】它们没有一个自己的权限码可挑:
    # 关账走 module.finance.edit,建供应商走 module.suppliers.edit,而这两支服务的是
    # 【同一条规矩的两侧】—— 挑任何一个都会比另一侧松。所以走"调不到"这条路。
    #
    # 【第三支 assert_segregated:它【什么表都不读】—— 收权限是纵深防御,不是控制】
    # 函数体只有 auth.uid()、一次 cardinality 检查、与调用方传进来的数组比一次、
    # 一句 RAISE。**没有可泄露的东西**,所以它没有调用者检查的理由不是"挑不出权限码",
    # 而是"没有要保护的东西"。两个理由分开写,免得下一个读的人以为它也在读表。
    # (这条区分由第二个会话的 prosrc 实测指出,2026-08-24。)
    #
    # 三支都只从 guard_payment_sod / guard_finance_settings_sod 的函数体内被调用,
    # 那两个是属主身份跑的触发器,所以收回之后照常工作(fixture 127 全绿即证,
    # 另有 R1–R4 四次独立复测确认"收回之后闸仍然咬合")。
    # REVOKE 写在 db/views/zzz_function_grants.sql 里(否则活不过一次重建)。
    "assert_segregated": "EXECUTE revoked from PUBLIC/authenticated/anon (SOD-1-fu3)",
    "sod_manual_posters_in": "EXECUTE revoked from PUBLIC/authenticated/anon (SOD-1-fu3)",
    "sod_supplier_creator": "EXECUTE revoked from PUBLIC/authenticated/anon (SOD-1-fu3)",
    # GST-1(2026-08-24):两支查表函数,理由与上面三支【不是同一条】,所以分开写。
    # 【tax_rate_for 是真的越权读】它绕过 tax_rates 的 RLS —— 虽然读到的是 IRAS
    #   公开的法定税率,但"读到的东西不敏感"不是留着 EXECUTE 的理由(B2 的教训);
    #   没有任何调用方需要它,那就不该够得着。
    # 【gst_registered 同样绕过 finance_settings 的 RLS】它答的是"这家公司注册了
    #   GST 没有"—— 界面要这个答案时读的是那张表的【列】,走该表自己的 RLS,
    #   从来不调这个函数。
    # 两支都只从 f5_return 与 post_journal_entry 的函数体内被调用(属主身份),
    # 收回之后照常工作。加 require_permission 反而会坏:属主没有 claims。
    "tax_rate_for": "EXECUTE revoked from PUBLIC/authenticated/anon (GST-1-fu)",
    "gst_registered": "EXECUTE revoked from PUBLIC/authenticated/anon (GST-1-fu)",
    # FIN-27 的内层算子:条款解析、计价算术、承诺写入。同上,靠"调不到"而非"查调用者"
    "pricing_terms_of_formula": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "pricing_terms_of_commitment": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "calculate_metal_price_from_terms": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "commit_pricing_terms": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "resolve_pricing_commitment": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "committed_terms_price": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # APR-1:审批留痕的唯一写入口。同上 —— 靠"调不到"而非"查调用者":它只从五个
    # 各自已把过关的 HR 决定函数体内以属主身份被调用。给了 authenticated 就等于
    # 任何登录用户都能伪造一行留痕。
    "record_approval_decision": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # APR-2:审批引擎的内层算子。同上 —— 靠"调不到"而非"查调用者";
    # 公开入口 approve_purchase_order / reject_purchase_order 各自 require_permission。
    "approval_level_for": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "require_approver_for": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # SAL-B:敞口算子,同上 —— 靠调不到。
    "customer_ar_exposure_base": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # SO-3b:发货单号的取号器。唯一调用方是 ship_order(它 require_permission
    # 了 module.sales.edit),而取号本身没有可检查的调用者 —— 它不读也不写任何
    # 业务数据,只推一个序号。给了 authenticated 就等于任何登录用户都能凭空
    # 烧掉一个无缝单号。同上,靠"调不到"。
    "next_shipment_code": "EXECUTE revoked from PUBLIC/authenticated/anon",
    "next_container_code": "EXECUTE revoked from PUBLIC/authenticated/anon (LOG-2a); same shape as next_shipment_code",
    # EQP-1c-a:固定资产取号器。同上 —— 靠"调不到"而非"查调用者",它不读也不写
    # 任何业务数据,只推一个序号。【它有两个消费方】record_expense 的新建支与
    # create_fixed_asset,两个都 DEFINER、都 require_permission(module.finance.edit)。
    # 提成一个函数正是为了让两扇建卡的门共用一个号段(两份取号逻辑迟早漂开)。
    "next_fixed_asset_code": "EXECUTE revoked from PUBLIC/authenticated/anon (EQP-1c-a); same shape as next_shipment_code",
    # SO-3b fu5:行的"已许出去"算子(已发 + 活预留)。同上 —— 靠"调不到"而非
    # "查调用者":消费方是 reserve_stock(require_permission 过了)与 SO-1b 的
    # 改单下限。给了 authenticated 就等于把别人订单的发货进度逐行敞开。
    "line_spoken_for": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # SO-1b:一张单的履约状态(已发 vs 已订)。同上 —— 靠"调不到"而非"查调用者":
    # 【一处推导,两个消费方】ship_order 与 amend_sales_order,两个都 DEFINER、
    # 都 require_permission 过 module.sales.edit。给了 authenticated 就等于任何
    # 登录用户都能一张一张问出别人订单的履约进度,而那是 module.sales.view 的东西。
    "sales_order_fulfilment_status": "EXECUTE revoked from PUBLIC/authenticated/anon",
    # APR-2c:审批是否生效 —— 它【必须】留给 authenticated,因为界面有义务把
    # "审批未生效"说出来(悄悄放行才是缺陷)。吐露的只有一个布尔量,而这个
    # 布尔量本来就该印在屏幕上,所以没有可检查的调用者,也没有要保护的东西。
    "approvals_enabled": "discloses one boolean the UI is required to display",
    # PDPA-1:当事人查阅。**这一条与上面每一条都不同 —— 它没有可要求的权限,
    # 而不是"有一个但绕过了"。** 它没有参数,唯一的主语是 auth.uid():
    # 一名员工对【自己的】个人数据有法定查阅权,那项权利不由本系统的权限模型授予,
    # 也不该被它否决。给它挂 module.hr.view 会把这条路只留给 HR —— 那恰好是反的
    # (查阅权的主体正是被查阅的那个人);挂任何别的码都是同一个错的不同写法。
    # DEFINER 在这里只用来越过 employees 的列级遮蔽,**不用来放宽主语** ——
    # 遮蔽保护的是"别人看不到",不是"他自己看不到"。范围与待决项见 docs/pdpa.md;
    # "只导出调用者自己"这件事由 db/fixtures/126 的 G 臂断言(含 pronargs = 0)。
    "export_my_personal_data": "no requirable permission exists: the subject IS the caller (auth.uid()), no arguments; DEFINER only bypasses column masking (PDPA-1)",
    # PROC-COST-2(2026-08-31):两支【计值读取器】与它们共用的单位落地成本。
    # **它们【必须】没有调用者检查,而这一条与上面每一条的理由都不同 ——
    # 不是"加了门会在属主身份下抛错",是【加了门就是缺陷本身】。**
    # 带判据的那一对(batch_freight_base / batch_processing_cost_base)对无权读者
    # 返回 NULL,那是给【屏幕】的:「受限」与 0.00 不是同一件事。而注销与盘点要
    # 过账的那个金额【不许取决于谁按的按钮】:一个只有 module.inbound.edit 的仓管
    # 按下注销时,若计值读的是带判据的那一支,COALESCE(NULL, 0) 会让它安静地退回
    # 按 unit_price 计值 —— 也就是 PROC-COST-2 正在修的那个缺陷原样复发,
    # 而且再没有人看得见。所以【算术】与【受众】分成两层,这三支是算术那一层。
    # 三支的 EXECUTE 都已从 authenticated 收回(db/views/zzz_function_grants.sql),
    # 靠的就是调不到 —— gate 的 B2(definer-unchecked-and-CALLABLE)因此是 0。
    # 调用方逐个点名,全部以属主身份执行:
    #   batch_freight_base_all         ← batch_freight_base / inbound_batch_landed_unit_cost_all
    #   batch_processing_cost_base_all ← batch_processing_cost_base / inbound_batch_landed_unit_cost_all
    #   inbound_batch_landed_unit_cost_all ← emit_batch_writeoff_movement(触发器)/ post_stocktake
    #                                      / inventory_control_reconciliation / inventory_valuation_snapshot
    # 理由全文见 docs/landed-cost-relief.md 第四节。
    #
    # ★【CLEANUP-A fu1(2026-08-31):这个名单里少了一层,而上面那段话早就写着它】★
    #   上面写的是「算术与受众分成两层」,但当时【单位落地成本只有一个名字】——
    #   它同时充当两层。CLEANUP-A 给它加了 R3 要的判据,当场把过账那一层打断了:
    #   gate 退 4、db/fixtures/172 红,而注销触发器的抬头自己写着"计值不许取决于
    #   谁按的按钮"。fu1 于是把它拆成这一族早就有的形状:
    #     · inbound_batch_landed_unit_cost_all —— 算术层,无判据,靠"调不到"活着;
    #     · inbound_batch_landed_unit_cost     —— 受众层,自带判据,【因此不再在本名单里】。
    #   受众层从这张表里【删掉】,不是改判词:它现在真的有调用者检查了。
    "batch_freight_base_all": "EXECUTE revoked from PUBLIC/authenticated/anon; a VALUATION reader must not depend on who pressed the button (PROC-COST-2)",
    "batch_processing_cost_base_all": "EXECUTE revoked from PUBLIC/authenticated/anon; a VALUATION reader must not depend on who pressed the button (PROC-COST-2)",
    "inbound_batch_landed_unit_cost_all": "EXECUTE revoked from PUBLIC/authenticated/anon; the POSTING primitive - the amount that reaches the ledger must not depend on who pressed the button (PROC-COST-2 / CLEANUP-A fu1)",
}

CHECK_PATTERNS = ("require_permission(", "has_permission(", "current_user_employee(",
                  "is_reviewer_of(", "require_reviewer_of(",
                  # AUD-1(2026-08-17):has_any_permission 也是一次【调用者检查】——
                  # 它就是 has_permission 的析取(见那个函数的函数体),按 auth.uid()
                  # 解析调用者。此前没有任何 DEFINER 函数用它,所以这条漏认从来没有
                  # 显形;AUD-1 的两个函数用 OR 把关(销售 或 加工),当场被判成
                  # "看不出任何调用者检查"。**漏认的方向是安全的那一边(误报,不是漏报)**,
                  # 但一个把正确写法判成违规的检查,会教人去 allowlist 它 —— 而那才是
                  # 真正的损失。verify_rebuild.py 的 CALLER_CHECK_RE 同改,两处必须一致。
                  "has_any_permission(")


def strip_sql_comments(sql: str) -> str:
    """去掉整行的 SQL 注释。【注释里提一句不是一次引用】—— 与
    account_codes_in_text / scan_literals 同一条,只是这里是给判词用的。

    【为什么需要它:SO-4a 实测】quote_is_expired 的函数体注释里写着
    "不是 SECURITY DEFINER,所以不进 B2 那道判词",而下面那句判据是一次朴素的
    子串匹配 —— 于是【那句解释自己】把这个函数判成了 SECURITY DEFINER,
    definer 判词当场报了一个不存在的缺口。
    两个方向都因此更准:一个只在注释里提过 require_permission 的函数,
    此后也不再被算作"有调用者检查"。
    """
    return "\n".join(l for l in sql.splitlines() if not l.lstrip().startswith("--"))


def definer_without_caller_check() -> list:
    """扫 db/functions:SECURITY DEFINER 且看不出任何调用者检查的函数。

    【判据只看代码,不看注释】见 strip_sql_comments 的抬头。
    """
    bad = []
    for f in sorted((REPO / "db" / "functions").glob("*.sql")):
        txt = f.read_text()
        for m in re.finditer(r"CREATE OR REPLACE FUNCTION\s+public\.([a-z0-9_]+)\s*\((.*?)\)\s*\n(.*?)(?=\nCREATE OR REPLACE FUNCTION|\Z)",
                             txt, re.S):
            name, body = m.group(1), strip_sql_comments(m.group(3))
            if "SECURITY DEFINER" not in body:
                continue
            if re.search(r"\bRETURNS\s+trigger\b", body, re.I):
                continue          # 触发器函数:闸门是基表写入
            if name in DEFINER_NO_CHECK_ALLOWED:
                continue
            if any(p in body for p in CHECK_PATTERNS):
                continue
            bad.append(f"{name}  ({f.name})")
    return sorted(set(bad))

# 科目字面量扫描的例外名单。【只放误伤,不放"懒得处理"】,每条必须写明理由。
# 空着是对的 —— 现在一条都不需要。
ACCOUNT_LITERAL_ALLOWLIST = {
    # "1234": "reason why this four-digit literal is not an account code",
}


def account_codes_in_text(sql: str) -> set:
    """一段 SQL 里【引用到的科目码】。注释行不算 —— 注释里提一句不是依赖。

    【本仓库里科目码的判据只有这一处】正则与例外名单都在这里。OPS-7 的迁移预检
    (db/preflight_migration.py)导入它,不另写第二份 —— 两份判据迟早会各说各话,
    而那正是"再检查一遍"这类提醒失效的方式。
    """
    out = set()
    for line in sql.splitlines():
        if line.lstrip().startswith("--"):
            continue
        out.update(re.findall(r"'(\d{4})'", line))
    return out - set(ACCOUNT_LITERAL_ALLOWLIST)


def scan_literals() -> dict:
    """扫描镜像文件里的三类字面量。注释行不算 —— 注释里提一句不是依赖。"""
    perms, accounts, roles = set(), set(), set()
    for sub in ("functions", "views", "tables"):
        for f in sorted((REPO / "db" / sub).glob("*.sql")):
            txt = f.read_text()
            for line in txt.splitlines():
                if line.lstrip().startswith("--"):
                    continue
                perms.update(re.findall(r"has_permission\(\s*'([^']+)'", line))
                perms.update(re.findall(r"require_permission\(\s*'([^']+)'", line))
            # 科目码:定义科目表的那个文件不算"引用"—— FIN-3-fu2 的引导默认值
            # (非 is_system 的整套科目)就住在 accounts.sql 的种子里,把种子行
            # 当引擎引用会逼着给权益科目打 is_system。引擎引用都在函数/视图里。
            if f.name != "accounts.sql":
                accounts |= account_codes_in_text(txt)
    # role_permissions 种子里 IN (...) 与 p.code = '...' 引用到的码
    rp = (REPO / "db" / "tables" / "role_permissions.sql").read_text()
    rp = "\n".join(l for l in rp.splitlines() if not l.lstrip().startswith("--"))
    perms.update(re.findall(r"'((?:module|data|action)\.[a-z_.]+)'", rp))
    # 【外键的另一侧】OPS-1 加了"授权引用的权限码必须存在",却没加对称的那一条:
    # 授权引用的【角色码】也必须存在。少了它,把 WHERE r.code = 'admin' 打错成
    # 'admin_TYPO' 会安安静静地少插 33 行,重建出来的库管理员一个权限都没有,
    # 而行数仍然大于零,所以连"引导不能为空"那条也拦不住。实测确认过。
    roles.update(re.findall(r"r\.code\s*=\s*'([^']+)'", rp))
    for grp in re.findall(r"r\.code\s+IN\s*\(([^)]*)\)", rp):
        roles.update(re.findall(r"'([^']+)'", grp))
    return {"permission_codes": sorted(perms), "account_codes": sorted(accounts),
            "role_codes": sorted(roles)}


def rewrite(sql: str) -> str:
    """把文件里的 public. 全部指到临时 schema —— 见文件头【安全性】第 2 条。

    另:pg_get_functiondef 的原样输出【不带结尾分号】(单函数镜像文件按约定就是
    原样字节),拼接重放时必须补上,否则下一条语句会被吞进同一条里报语法错。
    只补"整行恰为 $function$"的行,已带分号的文件不受影响。
    """
    sql = re.sub(r"^\$function\$$", "$function$;", sql, flags=re.M)
    return sql.replace("public.", f"{SCHEMA}.")


def created_tables(sql: str) -> set:
    return set(re.findall(r"CREATE TABLE\s+public\.([a-z0-9_]+)", sql, re.I))


def table_deps(sql: str, own: set, all_tables: set) -> set:
    """本文件依赖哪些【别的文件创建的】表:FK 引用 + 挂在别的表上的触发器。"""
    refs = set(re.findall(r"REFERENCES\s+public\.([a-z0-9_]+)", sql, re.I))
    refs |= set(re.findall(r"ON\s+public\.([a-z0-9_]+)", sql, re.I))
    return (refs & all_tables) - own


def toposort(files: dict) -> list:
    """files: path -> (own_tables, dep_tables)。Kahn,按文件名保证确定性。"""
    owner = {}
    for f, (own, _) in files.items():
        for t in own:
            owner[t] = f
    edges = {f: sorted({owner[d] for d in deps if d in owner} - {f}) for f, (_, deps) in files.items()}
    order, placed = [], set()
    pending = sorted(files)
    while pending:
        progressed = False
        for f in list(pending):
            if all(d in placed for d in edges[f]):
                order.append(f)
                placed.add(f)
                pending.remove(f)
                progressed = True
        if not progressed:
            sys.exit(f"表镜像之间存在循环依赖,无法排序:{pending}")
    return order



def view_replay_order(view_files):
    """视图的重放顺序:正文里引用了别的视图名的排在后面。

    【一处实现,两个调用方】check_mirrors 与 verify_rebuild 都要这一份顺序。
    此前两边各写了一遍,于是 RPT-1 修好了这边、那边照旧红 —— 正是本仓库反复
    付账的"第二份实现"。verify_rebuild 现在调这个函数。
    """
    txt = {f: strip_sql_strings(f.read_text()) for f in view_files}
    names = {f.stem for f in view_files}
    return sorted(
        view_files,
        key=lambda f: (len([v for v in names - {f.stem} if re.search(rf"\b{v}\b", txt[f])]), f.name),
    )


def strip_sql_strings(sql: str) -> str:
    """把字符串字面量与 -- 行注释去掉,供【依赖扫描】用。

    只服务于"哪张视图引用了哪张视图"的判断。视图之间的引用只出现在【标识符】
    位置,而抬头注释与 COMMENT ON 正文经常点名别的对象 —— RPT-1 两处都踩到:
      * COMMENT ON VIEW 的正文里写了另一张视图的名字;
      * 文件抬头的 -- 注释里也写了。
    两者都会被算成一次"引用",让两张视图互相依赖、计数打平,顺序退化成文件名
    排序,重放当场失败(relation ... does not exist)。所以两种都剥掉。
    不处理 $$ 引用体 —— 视图镜像里没有。
    """
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)      # 字符串字面量
    return re.sub(r"--[^\n]*", "", sql)             # -- 行注释

def build_sql() -> str:
    fn_files = sorted((REPO / "db" / "functions").glob("*.sql"))
    tbl_files = sorted((REPO / "db" / "tables").glob("*.sql"))
    view_files = sorted((REPO / "db" / "views").glob("*.sql"))

    tbl_txt = {f: f.read_text() for f in tbl_files}
    all_tables = set().union(*(created_tables(t) for t in tbl_txt.values()))
    tbl_meta = {
        f: (created_tables(t), table_deps(t, created_tables(t), all_tables))
        for f, t in tbl_txt.items()
    }
    tbl_order = toposort(tbl_meta)

    # 视图排序:正文里引用了别的视图名的排后面(目前仅一层,通用写法防患未然)
    #
    # 【先把字符串字面量剥掉再扫】(RPT-1 实测)COMMENT ON VIEW 的正文里提到另一张
    # 视图的名字,会被当成一次【引用】—— 于是两张互相在注释里点名的视图各自都
    # "依赖对方",计数打平,顺序退化成文件名排序,重放当场失败:
    #     REPLAY FAILED ... relation "stock_class_violations_all" does not exist
    # 而真正的依赖是单向的。视图之间的引用只会出现在【标识符】位置,不会写在
    # 字符串里,所以剥掉字面量既安全又更准。
    view_order = view_replay_order(view_files)

    parts = [
        "BEGIN;",
        f"CREATE SCHEMA {SCHEMA};",
        "SET LOCAL check_function_bodies = off;",
        f"SET LOCAL search_path = {SCHEMA}, public;",
    ]
    for f in fn_files:
        parts.append(f"-- ═══ replay {f.relative_to(REPO)} ═══")
        parts.append(rewrite(f.read_text()))
    for f in tbl_order:
        parts.append(f"-- ═══ replay {f.relative_to(REPO)} ═══")
        parts.append(rewrite(tbl_txt[f]))
    for f in view_order:
        parts.append(f"-- ═══ replay {f.relative_to(REPO)} ═══")
        # 【读原文,不读依赖扫描用的那一份】view_replay_order 内部会把字符串与
        # 注释剥掉【只为排序】—— 重放要的是文件本身。RPT-1 抽取排序函数时这里
        # 曾指向那份被剥过的文本(实为 NameError),而 db/gate.py 只从本模块借
        # 常量、自己走 verify_rebuild 重建,所以【门看不见这条路坏了】。
        parts.append(rewrite(f.read_text()))

    compare = COMPARE_SQL.replace("'mir'", f"'{SCHEMA}'").replace("'mir.'", f"'{SCHEMA}.'")
    parts.append(compare)
    parts.append(seed_sql())
    parts.append("ROLLBACK;")  # 万无一失:正常路径也显式回滚(本脚本永不 COMMIT)
    return "\n".join(parts)


# 比对查询:一个 SELECT 产出整份 jsonb 报告。norm() 剥掉 schema 前缀再比。
COMPARE_SQL = r"""
SELECT '""" + MARKER + r"""' || (
WITH
norm AS (SELECT 1),  -- 占位,归一化直接内联 replace(replace(x,'mir.',''),'public.','')
live_tables AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
mir_tables AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'mir' AND c.relkind = 'r'),
tbl_sig AS (
  SELECT ns.nspname AS sch, c.relname, jsonb_build_object(
    'columns', (SELECT jsonb_agg(a.attname || ' | ' || replace(replace(format_type(a.atttypid, a.atttypmod),'mir.',''),'public.','')
                       || ' | ' || CASE WHEN a.attnotnull THEN 'NOT NULL' ELSE 'NULL' END
                       || ' | ' || COALESCE(replace(replace(pg_get_expr(d.adbin, d.adrelid),'mir.',''),'public.',''), '')
                       -- 列注释是写在库里的规格说明;镜像丢了它,重建出来的库就少了那句话。
                       || ' | comment=' || COALESCE(col_description(c.oid, a.attnum), '-')
                       ORDER BY a.attnum)
       FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
       WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped),
    'constraints', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT replace(replace(pg_get_constraintdef(oid),'mir.',''),'public.','') x
        FROM pg_constraint WHERE conrelid = c.oid) s),
    'indexes', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT replace(replace(pg_get_indexdef(indexrelid),'mir.',''),'public.','') x
        FROM pg_index WHERE indrelid = c.oid) s),
    'triggers', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT replace(replace(pg_get_triggerdef(oid),'mir.',''),'public.','') x
        FROM pg_trigger WHERE tgrelid = c.oid AND NOT tgisinternal) s),
    'rls', c.relrowsecurity,
    'policies', (SELECT COALESCE(jsonb_agg(x ORDER BY x), '[]'::jsonb) FROM
       (SELECT DISTINCT polname || ' | ' || polpermissive::text || ' | ' || polcmd::text
               || ' | ' || COALESCE((SELECT string_agg(rolname, ',' ORDER BY rolname) FROM pg_roles WHERE oid = ANY (polroles)), '-')
               || ' | ' || COALESCE(replace(replace(pg_get_expr(polqual, polrelid),'mir.',''),'public.',''), '-')
               || ' | ' || COALESCE(replace(replace(pg_get_expr(polwithcheck, polrelid),'mir.',''),'public.',''), '-') x
        FROM pg_policy WHERE polrelid = c.oid) s)
  ) AS sig
  FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
  WHERE ns.nspname IN ('public', 'mir') AND c.relkind = 'r'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
tbl_drift AS (
  SELECT l.relname, (SELECT jsonb_object_agg(k.key, jsonb_build_object('live', l.sig->k.key, 'mirror', m.sig->k.key))
                     FROM jsonb_object_keys(l.sig) k(key)
                     WHERE l.sig->k.key IS DISTINCT FROM m.sig->k.key) AS diff
  FROM tbl_sig l JOIN tbl_sig m ON m.relname = l.relname AND m.sch = 'mir'
  WHERE l.sch = 'public' AND l.sig IS DISTINCT FROM m.sig),
live_fns AS (
  SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig,
         replace(replace(pg_get_functiondef(p.oid),'mir.',''),'public.','') AS def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.prokind = 'f'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')),
mir_fns AS (
  SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig,
         replace(replace(pg_get_functiondef(p.oid),'mir.',''),'public.','') AS def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'mir' AND p.prokind = 'f'),
live_views AS (
  SELECT c.relname,
         replace(replace(pg_get_viewdef(c.oid, true),'mir.',''),'public.','') AS def,
         COALESCE(array_to_string(c.reloptions, ','), '') AS opts
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'v'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
mir_views AS (
  SELECT c.relname,
         replace(replace(pg_get_viewdef(c.oid, true),'mir.',''),'public.','') AS def,
         COALESCE(array_to_string(c.reloptions, ','), '') AS opts
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'mir' AND c.relkind = 'v'),
live_seqs AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'S'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')),
mir_seqs AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'mir' AND c.relkind = 'S'),
live_enums AS (
  SELECT t.typname, (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid) AS labels
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public' AND t.typtype = 'e'
    AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')),
mir_enums AS (
  SELECT t.typname, (SELECT string_agg(enumlabel, ',' ORDER BY enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid) AS labels
  FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'mir' AND t.typtype = 'e')
SELECT jsonb_build_object(
  'summary', jsonb_build_object(
     'tables',    jsonb_build_object('live', (SELECT count(*) FROM live_tables), 'mirrored', (SELECT count(*) FROM mir_tables),
                                     'drifted', (SELECT count(*) FROM tbl_drift)),
     'functions', jsonb_build_object('live', (SELECT count(*) FROM live_fns), 'mirrored', (SELECT count(*) FROM mir_fns),
                                     'drifted', (SELECT count(*) FROM live_fns l JOIN mir_fns m USING (sig) WHERE l.def <> m.def)),
     'views',     jsonb_build_object('live', (SELECT count(*) FROM live_views), 'mirrored', (SELECT count(*) FROM mir_views),
                                     'drifted', (SELECT count(*) FROM live_views l JOIN mir_views m USING (relname)
                                                 WHERE l.def <> m.def OR l.opts <> m.opts))),
  'table_drift', COALESCE((SELECT jsonb_object_agg(relname, diff) FROM tbl_drift), '{}'::jsonb),
  'function_drift', COALESCE((SELECT jsonb_object_agg(l.sig, 'definition differs')
                              FROM live_fns l JOIN mir_fns m USING (sig) WHERE l.def <> m.def), '{}'::jsonb),
  'view_drift', COALESCE((SELECT jsonb_object_agg(l.relname,
                              CASE WHEN l.def <> m.def THEN 'definition differs' ELSE 'options differ: ' || l.opts || ' vs ' || m.opts END)
                          FROM live_views l JOIN mir_views m USING (relname)
                          WHERE l.def <> m.def OR l.opts <> m.opts), '{}'::jsonb),
  'coverage', jsonb_build_object(
     'tables_without_mirror',      COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM live_tables WHERE relname NOT IN (SELECT relname FROM mir_tables)), '[]'::jsonb),
     'mirrors_without_live_table', COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM mir_tables  WHERE relname NOT IN (SELECT relname FROM live_tables)), '[]'::jsonb),
     'functions_without_mirror',   COALESCE((SELECT jsonb_agg(sig ORDER BY sig) FROM live_fns WHERE sig NOT IN (SELECT sig FROM mir_fns)), '[]'::jsonb),
     'mirrors_without_live_fn',    COALESCE((SELECT jsonb_agg(sig ORDER BY sig) FROM mir_fns  WHERE sig NOT IN (SELECT sig FROM live_fns)), '[]'::jsonb),
     'views_without_mirror',       COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM live_views WHERE relname NOT IN (SELECT relname FROM mir_views)), '[]'::jsonb),
     'mirrors_without_live_view',  COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM mir_views  WHERE relname NOT IN (SELECT relname FROM live_views)), '[]'::jsonb),
     'sequences_without_mirror',   COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM live_seqs WHERE relname NOT IN (SELECT relname FROM mir_seqs)), '[]'::jsonb),
     'mirrors_without_live_seq',   COALESCE((SELECT jsonb_agg(relname ORDER BY relname) FROM mir_seqs  WHERE relname NOT IN (SELECT relname FROM live_seqs)), '[]'::jsonb),
     'enums_without_mirror',       COALESCE((SELECT jsonb_agg(typname ORDER BY typname) FROM live_enums WHERE typname NOT IN (SELECT typname FROM mir_enums)), '[]'::jsonb),
     'mirrors_without_live_enum',  COALESCE((SELECT jsonb_agg(typname ORDER BY typname) FROM mir_enums  WHERE typname NOT IN (SELECT typname FROM live_enums)), '[]'::jsonb),
     'enum_label_drift',           COALESCE((SELECT jsonb_object_agg(l.typname, jsonb_build_object('live', l.labels, 'mirror', m.labels))
                                             FROM live_enums l JOIN mir_enums m USING (typname) WHERE l.labels <> m.labels), '{}'::jsonb))
))::text AS report;
"""


def seed_sql() -> str:
    """种子行 + 镜像自洽,一条 SELECT 一份 jsonb 报告。"""
    lit = scan_literals()
    perm_arr = "ARRAY[" + ",".join(f"'{c}'" for c in lit["permission_codes"]) + "]::text[]" \
        if lit["permission_codes"] else "ARRAY[]::text[]"
    acct_arr = "ARRAY[" + ",".join(f"'{c}'" for c in lit["account_codes"]) + "]::text[]" \
        if lit["account_codes"] else "ARRAY[]::text[]"
    role_arr = "ARRAY[" + ",".join(f"'{c}'" for c in lit["role_codes"]) + "]::text[]" \
        if lit["role_codes"] else "ARRAY[]::text[]"

    blocks = []
    for tbl, (where, cols) in SEED_TABLES.items():
        w = f" WHERE {where}" if where else ""
        # ★【每一侧的表名解析到【它自己那一侧】】★ 见 SEED_TABLES 抬头:
        #   live 侧是 public,mirror 侧是 mir。相关子查询里的表名同样要跟着换 ——
        #   不换就是拿 mir 的外键去 public 里找,永远找不到,于是整张表"漂移"。
        cols_live = cols.replace("{S}", "public")
        cols_mirror = cols.replace("{S}", SCHEMA)
        blocks.append(f"""
    '{tbl}', (
      WITH l AS (SELECT to_jsonb(x) j FROM (SELECT {cols_live} FROM public.{tbl}{w}) x),
           m AS (SELECT to_jsonb(x) j FROM (SELECT {cols_mirror} FROM {SCHEMA}.{tbl}{w}) x)
      SELECT jsonb_build_object(
        'live_rows',   (SELECT count(*) FROM l),
        'mirror_rows', (SELECT count(*) FROM m),
        'missing_from_mirror', COALESCE((SELECT jsonb_agg(j ORDER BY j::text) FROM (SELECT j FROM l EXCEPT SELECT j FROM m) s), '[]'::jsonb),
        'extra_in_mirror',     COALESCE((SELECT jsonb_agg(j ORDER BY j::text) FROM (SELECT j FROM m EXCEPT SELECT j FROM l) s), '[]'::jsonb))
    )""")

    integ = (
        "  'integrity', jsonb_build_object(\n"
        f"    'permission_codes_referenced', array_length({perm_arr}, 1),\n"
        f"    'permission_codes_missing_from_seed', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({perm_arr}) c "
        f"WHERE c NOT IN (SELECT code FROM {SCHEMA}.permissions)), '[]'::jsonb),\n"
        f"    'account_codes_referenced', array_length({acct_arr}, 1),\n"
        f"    'account_codes_missing_from_seed', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({acct_arr}) c "
        f"WHERE c NOT IN (SELECT code FROM {SCHEMA}.accounts)), '[]'::jsonb),\n"
        # 【自维护的那一条】被代码点名、线上存在、却没打 is_system 的科目 = 名单漏了一个。
        # 宁可多打标记也不能漏 —— 漏掉的那一个正是 OPS-1 这个 bug 换一层楼重演。
        f"    'account_codes_referenced_but_not_is_system', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({acct_arr}) c "
        f"WHERE EXISTS (SELECT 1 FROM public.accounts a WHERE a.code = c AND NOT a.is_system)), '[]'::jsonb),\n"
        f"    'role_codes_referenced', array_length({role_arr}, 1),\n"
        f"    'role_codes_missing_from_seed', COALESCE((SELECT jsonb_agg(c ORDER BY c) FROM unnest({role_arr}) c "
        f"WHERE c NOT IN (SELECT code FROM {SCHEMA}.roles)), '[]'::jsonb)\n"
        "  )"
    )
    boot = ",".join(
        f"'{t}', (SELECT count(*) FROM {SCHEMA}.{t})" for t in sorted(RUNTIME_CONFIG_TABLES))
    return ("SELECT '" + SEED_MARKER + "' || (SELECT jsonb_build_object(\n"
            "  'seed', jsonb_build_object(" + ",".join(blocks) + "\n  ),\n"
            "  'bootstrap', jsonb_build_object(" + boot + "),\n"
            + integ + "))::text AS seed_report;\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--json", action="store_true", help="输出完整 JSON 报告")
    ap.add_argument("--dsn", default=None, help="覆盖连接串(默认走 CHECK_MIRRORS_DSN 或内置值)")
    args = ap.parse_args()

    # ── FIX-3:gate 或冒烟在跑的时候,这里【当场拒绝】而不是排队等 ──────────
    # 单独跑本脚本会把 ~14,000 行重放推过连接池;与 gate/冒烟撞上就超时,
    # 而 pkill 掉本机进程【不会】结束它在线上开着的那笔事务(GO-4:613 秒的
    # idle in transaction,最后用 pg_terminate_backend 收的尾)。
    # 【gate 内部会调用本模块的函数,不走这条命令行入口】,所以不会自己挡自己。
    import live_lock
    live_lock.refuse_if_held("check_mirrors.py")

    import os
    dsn = args.dsn or os.environ.get("CHECK_MIRRORS_DSN") or DEFAULT_DSN

    sql = build_sql()
    with tempfile.NamedTemporaryFile("w", suffix=".sql", delete=False) as tf:
        tf.write(sql)
        script = tf.name

    proc = subprocess.run(
        ["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-t", "-A", "-f", script],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        sys.stderr.write(f"\n重放失败(线上库未被改动 —— 见文件头【回滚保证】)。生成的 SQL 留在:{script}\n")
        return 2

    report = seed = None
    for line in proc.stdout.splitlines():
        if line.startswith(MARKER):
            report = json.loads(line[len(MARKER):])
        elif line.startswith(SEED_MARKER):
            seed = json.loads(line[len(SEED_MARKER):])
    if report is None or seed is None:
        sys.stderr.write("没有在输出里找到报告标记 —— psql 输出异常。\n")
        return 2
    report["seed"] = seed["seed"]
    report["integrity"] = seed["integrity"]
    report["bootstrap"] = seed["bootstrap"]

    Path(script).unlink(missing_ok=True)

    seed_dirty = any(v["missing_from_mirror"] or v["extra_in_mirror"]
                     for v in report["seed"].values())
    unchecked = definer_without_caller_check()
    empty_bootstraps = sorted(t for t, n in report["bootstrap"].items()
                              if n == 0 and t not in BOOTSTRAP_MAY_BE_EMPTY)
    integ_dirty = any(report["integrity"][k] for k in (
        "permission_codes_missing_from_seed",
        "account_codes_missing_from_seed",
        "account_codes_referenced_but_not_is_system",
        "role_codes_missing_from_seed"))
    dirty = (
        report["table_drift"] or report["function_drift"] or report["view_drift"]
        or any(v for v in report["coverage"].values())
        or seed_dirty or integ_dirty or empty_bootstraps or unchecked
    )

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        s = report["summary"]
        print(f"tables    live {s['tables']['live']:3d}  mirrored {s['tables']['mirrored']:3d}  drifted {s['tables']['drifted']}")
        print(f"functions live {s['functions']['live']:3d}  mirrored {s['functions']['mirrored']:3d}  drifted {s['functions']['drifted']}")
        print(f"views     live {s['views']['live']:3d}  mirrored {s['views']['mirrored']:3d}  drifted {s['views']['drifted']}")
        # 【种子行的覆盖面要在每次输出里看得见】—— 不然"比了什么"又变成一个没人查的假设。
        for tbl in sorted(report["seed"]):
            v = report["seed"][tbl]
            bad = len(v["missing_from_mirror"]) + len(v["extra_in_mirror"])
            print(f"seed:{tbl:<11s} live {v['live_rows']:3d}  mirrored {v['mirror_rows']:3d}  drifted {bad}")
        ig = report["integrity"]
        print(f"integrity  permission codes {ig['permission_codes_referenced'] or 0:3d}"
              f"  role codes {ig['role_codes_referenced'] or 0:3d}"
              f"  account codes {ig['account_codes_referenced'] or 0:3d}"
              f"  unresolved {len(ig['permission_codes_missing_from_seed']) + len(ig['account_codes_missing_from_seed']) + len(ig['account_codes_referenced_but_not_is_system']) + len(ig['role_codes_missing_from_seed'])}")
        # 引导默认值【不与线上比对】,但要看得见它到底装进去了多少行 ——
        # 一个悄悄变成零行的引导,是这套豁免唯一藏得住的失败。
        print(f"definer    {len(unchecked)} SECURITY DEFINER function(s) with no recognisable caller check"
              f"  ({len(DEFINER_NO_CHECK_ALLOWED)} allowlisted, trigger functions excluded by return type)")
        print("bootstrap  (runtime config, not compared against live; rows must be > 0)")
        print("           " + "  ".join(f"{t}={report['bootstrap'][t]}"
                                        for t in sorted(report["bootstrap"])))
        for section in ("table_drift", "function_drift", "view_drift"):
            for k, v in report[section].items():
                print(f"  DRIFT [{section}] {k}: {json.dumps(v, ensure_ascii=False)[:400]}")
        for k, v in report["coverage"].items():
            if v:
                print(f"  COVERAGE {k}: {json.dumps(v, ensure_ascii=False)}")
        for tbl, v in sorted(report["seed"].items()):
            for row in v["missing_from_mirror"]:
                print(f"  SEED [{tbl}] MISSING FROM MIRROR: {json.dumps(row, ensure_ascii=False)}")
            for row in v["extra_in_mirror"]:
                print(f"  SEED [{tbl}] EXTRA IN MIRROR:     {json.dumps(row, ensure_ascii=False)}")
        for k, v in report["integrity"].items():
            if k.endswith("_referenced") or not v:
                continue
            print(f"  INTEGRITY {k}: {json.dumps(v, ensure_ascii=False)}")
        for u in unchecked:
            print(f"  DEFINER {u}: SECURITY DEFINER with no caller check — add one, or allowlist it with a reason")
        for t in empty_bootstraps:
            print(f"  BOOTSTRAP {t}: seeded ZERO rows — a rebuilt database would start without them")
        print("clean bill of health ✓" if not dirty else "drift / coverage gaps found ✗")

    return 1 if dirty else 0


if __name__ == "__main__":
    sys.exit(main())
