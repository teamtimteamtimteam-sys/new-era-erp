-- db/views/kpi_position_linkage_matrix.sql
-- KPI-1:联动矩阵 —— **职位这一层**。派生,不另存(规格 §9.1)。
--
-- ★★【原表第五页那六行数字,必须能从链接列【算出来】,而规格已经验算过】★★
--   §9.1 逐人统计过一遍,与原表写死的六行【逐格相同】(六行全中)。
--   所以"矩阵是派生的"是一句**被验过的话**,不是一句设计意图 ——
--   而本视图就是那次验算的可执行版本:fixture 146 拿它与 §9.1 那张表逐格对。
--
-- ★【为什么要有【职位级】这一张,而原表画的是【员工级】】★(Tim 2026-08-29)
--   原表六行是六个人,而六个人与六个职位一一对应。
--   **员工级那张今天是空的**(线上只有两个人挂了职位,原表另外四个人根本没有员工档案),
--   于是它**验不了** —— 一张空矩阵与一张对的矩阵长得一样。
--   职位级这一张在模板种下去的那一刻就是满的,而且【可以对着原表逐格核】。
--   两张都要,各自标清楚是哪一层 —— 见 kpi_employee_linkage_matrix。
--
-- ★★【这句话必须贴着数字放,原表原文,不许改写】★★(§9.1)
--   *A single employee KPI can support more than one organization KPI. The detailed
--   Employee KPIs sheet preserves the exact linkage. The matrix is a management view
--   of coverage, not a mathematical re-weighting of the organization scorecard.*
--
--   **为什么它必须贴着数字:** 那六行数字长得像权重(整数、按组织 KPI 分列,
--   下面还紧跟着一行 Weight 25/25/20/15/15)。没有这句话在旁边,
--   第一个读它的人会把「Sandra 在 O4 上有 5 条」读成「Sandra 的 O4 权重是 5」。
--
-- 【属主权限】它 join positions + templates + links 三张表,都在 HR 门内,
-- 谓词写进视图体(OPS-14 的补救 (a))。

CREATE VIEW public.kpi_position_linkage_matrix WITH (security_invoker = off) AS
 SELECT p.code AS position_code,
    p.title AS position_title,
    p.sort_order,
    count(*) FILTER (WHERE l.org_code = 'O1') AS o1_count,
    count(*) FILTER (WHERE l.org_code = 'O2') AS o2_count,
    count(*) FILTER (WHERE l.org_code = 'O3') AS o3_count,
    count(*) FILTER (WHERE l.org_code = 'O4') AS o4_count,
    count(*) FILTER (WHERE l.org_code = 'O5') AS o5_count,
    count(DISTINCT t.id) AS kpi_count,
    -- 【权重合计放在这里,是为了让那道闸的结果【看得见】】
    -- 子查询而不是 sum(t.weight_pct):上面 LEFT JOIN 链接表会把一条链两个组织
    -- KPI 的模板行【复制成两行】,直接 sum 会把它的权重算两遍。
    -- (这正是 §9.1 那句"矩阵是覆盖度不是权重"在 SQL 里的样子。)
    (SELECT COALESCE(sum(t2.weight_pct), 0)
       FROM kpi_position_templates t2 WHERE t2.position_id = p.id) AS weight_total
   FROM positions p
     JOIN kpi_position_templates t ON t.position_id = p.id
     LEFT JOIN kpi_template_org_links l ON l.template_id = t.id
  WHERE has_permission('module.hr.view'::text)
  GROUP BY p.id, p.code, p.title, p.sort_order;

COMMENT ON VIEW public.kpi_position_linkage_matrix IS
'KPI-1:联动矩阵的【职位】那一层 —— 派生,不另存(规格 §9.1:原表第四、五页每一个数字都能从 KPI 行推导,原表自己就是用公式算的)。★**这句话必须贴着数字放,原表原文**★:*A single employee KPI can support more than one organization KPI. The detailed Employee KPIs sheet preserves the exact linkage. **The matrix is a management view of coverage, not a mathematical re-weighting of the organization scorecard.*** —— 因为那六行数字长得像权重(整数、按组织 KPI 分列,下面还跟着 Weight 25/25/20/15/15),没有这句话在旁边,第一个读的人会把「Sandra 在 O4 上有 5 条」读成「Sandra 的 O4 权重是 5」。**为什么有职位级这一张**:原表画的是员工级,而员工级今天是空的(只有两人挂了职位,原表另外四人没有员工档案),空矩阵与对的矩阵长得一样、验不了;职位级在模板种下的那一刻就是满的,而且可以对着原表逐格核 —— fixture 146 就是这么核的。';
