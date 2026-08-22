# -*- coding: utf-8 -*-
"""db/injection_probe.py —— 故障注入矩阵的【还原完整性】检查(EQP-2c,2026-08-21)。

════════════════════════════════════════════════════════════════════════════
【为什么存在:一个不完整的 restore() 会把一整张注入矩阵变成假的,而它全绿】

故障注入的每一格都假设一件事:**这一格看到的库,与基线那一格看到的库一模一样,
只差我刚注入的那一处。** 那个假设由 restore() 撑着,而 restore() 是手写的 ——
它得记住把每一格动过的每一样东西都还原回去。**漏一句,后面每一格都跑在一个
被污染的库上,而且不会有任何东西报错。**

这不是假想。EQP-2b 的注入脚本(fi109)里,F3 那一格执行

    ALTER TABLE equipment_maintenance ALTER COLUMN downtime_id SET NOT NULL;

而 restore() 里【没有对应的 DROP NOT NULL】。于是 F3 之后的 F4 / F5 / F6 全部跑在
一张 downtime_id 变成了必填的表上。下一版脚本(fi109b)里补上了那一句,旁边写着:

    -- 【上一轮就是漏了这两句 —— 于是 F3 的注入一直活到后面每一格】

**它是被人读出来的,不是被任何检查抓到的。** 连着两刀都栽在同一处之后,
那次会话的结论是"这里需要一张清单"。而本仓库对"需要一张清单"有一条成文的处置
(OPS-7 用脚本替掉两句"记得检查 B1 与 is_system";db/wait_for.sh 替掉"记得加上限"):
**清单要靠记,机制不用。** 这个模块就是那次替换。

【判据:比对象的【定义】,不比我记得改过什么】
restore() 出错的方式恰恰是"我忘了我改过它",所以任何"把改过的东西列一遍"的
检查都会和 restore() 本身犯同一个错。这里改成:注入之前把每个对象的定义
【整个抓下来】,每次 restore() 之后再抓一遍,逐字节比。
* 表  = 列(名/类型/可空/默认)+ 约束 + 索引 + RLS 开关 + 策略
* 视图 = pg_get_viewdef + reloptions(**reloptions 必须单独抓** ——
        pg_get_viewdef 不吐 WITH (…),AGENTS.md 为此记过一次 security_invoker)
* 函数 = pg_get_functiondef

════════════════════════════════════════════════════════════════════════════
【这个探针看得见什么,看不见什么 —— 站在用它的人面前把话说清楚】

**一个对自己没走过的地面报"干净"的检查,比没有检查更坏:它制造信心。**
这已经付过两次账,两次都是 assert_clean 说干净而库是脏的:
  * **PROC-4**:一格注入 `DELETE FROM substances WHERE code='fe'` —— 改的是【行】,
    对象定义一个字节没变,探针一路说干净,注入矩阵第一轮 **0/7**。
  * **PROC-6**:一格注入把触发器换成 `BEFORE INSERT OR UPDATE` —— 改的是【触发器】,
    当时不在捕获范围内,三格错落到别的臂,"还原后"才红。

现在的覆盖面(PROC-CLEANUP 之后):

  表 / 视图
    ✓ 列(名 / 类型 / 可空 / 默认)      ✓ 约束(名 / 定义 / convalidated)
    ✓ 索引                              ✓ RLS 开关 + 策略
    ✓ reloptions                        ✓ 表级授权
    ✓ 视图定义(pg_get_viewdef)
    ✓ **触发器**(pg_get_triggerdef,非内部)          ← PROC-CLEANUP 补
    ✓ **表注与列注**                                   ← PROC-CLEANUP 补
    ✓ **行内容**,当这张表是 RUNTIME CONFIG 字典时      ← PROC-CLEANUP 补
      (清单直接读 check_mirrors.RUNTIME_CONFIG_TABLES —— **不靠调用方记得声明**,
       那正是"清单要靠记、机制不用"的同一条)
  函数
    ✓ pg_get_functiondef

  **它【仍然】看不见的(点名,不含糊):**
    ✗ 非字典表的行内容 —— 业务表的数据不在捕获范围内。fixture 自己回滚,
      而注入脚本若去改业务数据,得自己还原。
    ✗ 序列的当前值(nextval 推进过就回不去了,而重放通常不在乎)
    ✗ 对象属主与列级授权(表级授权在,列级不在)
    ✗ 本次没有列进 objects 清单的任何对象 —— **探针只看你交给它的那些**。
      这一条最容易忘:注入改了 A,而你只把 B 交给了探针。

════════════════════════════════════════════════════════════════════════════
【能共享,而且【应当】共享 —— 这是本模块的第二个理由】
fi109 与 fi110 的 restore() 是两份【复制】,各自维护自己的还原清单,于是同一个
疏漏可以在两份里各犯一次(实际就是这样)。注入脚本本身住在仓库【外面】的
临时目录里、一刀一份、用完即弃 —— 那正是复制发生的原因。**所以共享的那一半
必须住在仓库里**,由临时脚本 import 进去:

    import sys; sys.path.insert(0, 'db')
    from injection_probe import Pristine
    P = Pristine(DSN, ['public.my_table', 'public.my_view', 'public.my_fn(text)'])
    P.capture()                     # 在任何注入【之前】
    for name, what, sql in CASES:
        restore(); P.assert_clean(name)   # ← 下一格开跑之前先证明库是干净的
        run_sql(sql); ...

**注意 assert_clean 的位置:在 restore() 之后、下一次注入之前。** 放在注入之后
就变成了"我注入的东西生效了吗",那是另一个问题。
════════════════════════════════════════════════════════════════════════════
"""
import os
import subprocess
import sys


def _runtime_config_tables():
    """RUNTIME CONFIG 字典的清单 —— **直接读 check_mirrors 那一份,不抄第二份**。

    PROC-4 的第一轮 0/7 就是因为一格注入删了一行字典而探针看不见。
    补它的时候有两条路:让调用方声明"这几张要连行一起比",或者让探针自己知道。
    **选后者**:清单要靠人记就会漏,而这个仓库对"需要一张清单"有成文处置 ——
    换成机制。于是加一张新字典时,探针自动开始守它的行,没有人需要记得什么。
    """
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import check_mirrors
        return set(check_mirrors.RUNTIME_CONFIG_TABLES)
    except Exception as e:                       # 读不到就【说出来】,不要静静当成空集
        sys.exit("✗ injection_probe:读不到 check_mirrors.RUNTIME_CONFIG_TABLES(%s)。"
                 "\n  空集合会让字典的行【重新变成盲区】,而那正是 PROC-4 栽过的地方 —— "
                 "所以这里宁可停下。" % e)

_TABLE_SQL = """
SELECT jsonb_build_object(
  'kind', 'relation',
  'relkind', (SELECT c.relkind::text FROM pg_class c WHERE c.oid = %(oid)s),
  'rls', (SELECT c.relrowsecurity FROM pg_class c WHERE c.oid = %(oid)s),
  'reloptions', (SELECT COALESCE(c.reloptions::text[], '{}') FROM pg_class c WHERE c.oid = %(oid)s),
  'columns', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'n', a.attname, 't', format_type(a.atttypid, a.atttypmod),
        'notnull', a.attnotnull, 'default', pg_get_expr(d.adbin, d.adrelid))
        ORDER BY a.attnum)
     FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = %(oid)s AND a.attnum > 0 AND NOT a.attisdropped), '[]'::jsonb),
  'constraints', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'n', con.conname, 'd', pg_get_constraintdef(con.oid), 'valid', con.convalidated)
        ORDER BY con.conname)
     FROM pg_constraint con WHERE con.conrelid = %(oid)s), '[]'::jsonb),
  'indexes', COALESCE((SELECT jsonb_agg(pg_get_indexdef(i.indexrelid) ORDER BY i.indexrelid::regclass::text)
     FROM pg_index i WHERE i.indrelid = %(oid)s), '[]'::jsonb),
  'policies', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'n', p.polname, 'cmd', p.polcmd::text, 'perm', p.polpermissive,
        'using', pg_get_expr(p.polqual, p.polrelid),
        'check', pg_get_expr(p.polwithcheck, p.polrelid)) ORDER BY p.polname)
     FROM pg_policy p WHERE p.polrelid = %(oid)s), '[]'::jsonb),
  'viewdef', CASE WHEN (SELECT c.relkind FROM pg_class c WHERE c.oid = %(oid)s) IN ('v','m')
                  THEN pg_get_viewdef(%(oid)s, true) ELSE NULL END,
  'grants', COALESCE((SELECT jsonb_agg(DISTINCT g.privilege_type || ':' || g.grantee)
     FROM information_schema.role_table_grants g
    WHERE (g.table_schema || '.' || g.table_name) = %(oid)s::regclass::text), '[]'::jsonb),
  -- PROC-CLEANUP:触发器。PROC-6 有一格注入把 BEFORE INSERT 换成了
  -- BEFORE INSERT OR UPDATE,而当时这里看不见 —— 于是三格错落到别的臂。
  'triggers', COALESCE((SELECT jsonb_agg(pg_get_triggerdef(t.oid) ORDER BY t.tgname)
     FROM pg_trigger t WHERE t.tgrelid = %(oid)s AND NOT t.tgisinternal), '[]'::jsonb),
  -- PROC-CLEANUP:表注与列注。check_mirrors 比它们,而注入矩阵此前不比 ——
  -- 一格改了注释的注入会安静地活到后面每一格。
  'comment', obj_description(%(oid)s),
  'colcomments', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'n', a.attname, 'c', col_description(%(oid)s, a.attnum)) ORDER BY a.attnum)
     FROM pg_attribute a WHERE a.attrelid = %(oid)s AND a.attnum > 0 AND NOT a.attisdropped
       AND col_description(%(oid)s, a.attnum) IS NOT NULL), '[]'::jsonb)
)::text
"""


class Pristine(object):
    """抓一组对象的定义,并在每次 restore() 之后证明它们一个字节都没变。"""

    def __init__(self, dsn, objects):
        # objects:'public.t' / 'public.v' / 'public.f(text)' —— 带括号的当函数
        self.dsn = dsn
        self.objects = list(objects)
        self.baseline = None
        self._dict_tables = _runtime_config_tables()
        if not self.objects:
            sys.exit("✗ injection_probe:对象清单是空的 —— 一个什么都不看的检查比没有更坏")

    # ── 底层 ────────────────────────────────────────────────────────────────
    def _psql(self, sql):
        p = subprocess.run(["psql", self.dsn, "-X", "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", sql],
                           capture_output=True, text=True)
        if p.returncode:
            sys.exit("✗ injection_probe:抓定义时 psql 失败 —— %s" % p.stderr.strip()[:500])
        return p.stdout.rstrip("\n")

    def _snap_one(self, obj):
        if "(" in obj:                                   # 函数
            out = self._psql("SELECT pg_get_functiondef('%s'::regprocedure);" % obj)
        else:                                            # 表 / 视图
            out = self._psql(_TABLE_SQL.replace("%(oid)s", "'%s'::regclass" % obj))
            # PROC-CLEANUP:**字典表连【行】一起比**。
            # 一行被 DELETE 掉的字典行不改变任何对象定义 —— PROC-4 的注入矩阵
            # 第一轮 0/7 就是这么来的,而 assert_clean 一路说"干净"。
            bare = obj.split(".")[-1]
            if bare in self._dict_tables:
                digest = self._psql(
                    "SELECT COALESCE(md5(string_agg(t::text, '|' ORDER BY t::text)), '(空表)') "
                    "|| ' / ' || count(*)::text FROM %s t;" % obj)
                out = out + "\n-- ROWS(RUNTIME CONFIG): " + digest
        # 【空回答不许被当成一份定义】对象被 DROP 之后 regclass 会直接报错(上面
        # 已退出);但万一某天它安静地回了空,那也是"我问错了",不是"它没变"。
        # 与 check-i18n 后缀解析、mustRows、restRows 是同一条规矩。
        if not out.strip():
            sys.exit("✗ injection_probe:%s 的定义读回来是空的 —— 这是问错了,不是【没变化】" % obj)
        return out

    def _snap(self):
        return dict((o, self._snap_one(o)) for o in self.objects)

    # ── 对外 ────────────────────────────────────────────────────────────────
    def capture(self):
        """在【任何注入之前】调用一次。"""
        self.baseline = self._snap()
        watched = [o for o in self.objects
                   if "(" not in o and o.split(".")[-1] in self._dict_tables]
        print("· injection_probe:抓下 %d 个对象的基线定义(%s)"
              % (len(self.objects), ", ".join(self.objects)))
        print("· injection_probe:覆盖 列/约束/索引/RLS/策略/reloptions/授权/视图定义/"
              "**触发器**/**注释**;字典表另比【行】:%s"
              % (", ".join(watched) if watched else "(本次没有字典表)"))
        return self

    def assert_clean(self, where=""):
        """在每次 restore() 之后、下一次注入之前调用。不干净就【当场停下并点名】。"""
        if self.baseline is None:
            sys.exit("✗ injection_probe:还没 capture() 就来 assert_clean() —— 没有基线可比")
        now = self._snap()
        bad = [o for o in self.objects if now[o] != self.baseline[o]]
        if bad:
            first = bad[0]
            sys.exit(
                "✗ 还原不完整%s:%s 与基线定义不一致(共 %d 个对象没还原干净)。\n"
                "  **后面每一格都会跑在一个被污染的库上,而且不会有任何东西报错** ——\n"
                "  这正是 EQP-2b 那次 F3 的 SET NOT NULL 活到后面每一格的形状。\n"
                "  先补 restore(),不要先看注入结果。\n"
                "  --- 基线 ---\n%s\n  --- 现在 ---\n%s"
                % (("(%s 之前)" % where) if where else "", first, len(bad),
                   self.baseline[first][:1200], now[first][:1200]))
