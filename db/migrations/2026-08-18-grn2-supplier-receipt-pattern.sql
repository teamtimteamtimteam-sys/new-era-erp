-- GRN-2:这家供应商是不是【一直】短交 —— 数据库那一半
--
-- ════════════════════════════════════════════════════════════════════════════
-- 一次短交是行情,连续短交是供应商问题,而【今天这两件事在屏幕上一模一样】。
-- grn_discrepancies 逐条说得出"这一条怎么了",它说不出"这一家一向如何"。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【本刀的地面勘察,三条结论都改变了设计,所以写在最前面】
--
-- ① 每一行差异【都够得到供应商,而且是结构性的】。
--    inbound_batches.supplier_id 是 uuid NOT NULL REFERENCES suppliers(id),
--    grn_discrepancies 内连接 suppliers。所以不存在"够不到供应商"的差异行。
--    【为什么要查列的可空性而不是只数一下】内连接之下,一行 supplier_id 为空
--    的记录会【整行从视图里消失】—— 那样数出来的 0 与一条保证长得一模一样。
--
-- ② 【一半的收货没有到货日期】—— 实测 14 条在册收货里 7 条 arrival_date 为空,
--    而其中【3 条是可比对的】。一个朴素的窗口谓词会把它们静默丢掉。
--    最要命的一条:**IN-2026-0029 是全库唯一一条 short,而它没有到货日**。
--    也就是说,朴素窗口会让 Acme 显示"零次短交" —— 正是这一刀要消灭的那种假话。
--    所以【无日期不是"不在窗口内",它是第三类】,单独计数、单独说出来,
--    并且【再单独说出其中有几条带着差异】—— 那一句才让人知道"补上日期会改变答案"。
--    (FIN-32 之后新行必填到货日,所以这一类只会缩小,不会增长。)
--
-- ③ 【line_delta_qty 会重复计算】它是【行级】事实,挂在该采购行的每一条收货上
--    (grn_discrepancies 的注释原话:要按行计数请 DISTINCT line_id)。
--    线上已经有一条采购行挂着 2 次收货。所以:
--       * 次数按【收货】数 —— "7 次里 3 次短" 是人读得懂的那个单位;
--       * 数量按【采购行】汇总 —— 否则那条行的差额会被算两遍。
--    一张视图里两种单位,各自在列名与注释里说清楚。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【不做的三件事,每一件都是刻意的】
--   * **不发明"一贯短交"这个布尔量**。那需要一个没有人选过的阈值(几次算一贯?
--     占比多少算一贯?),而这张视图没有资格替采购员做这个判断。它给原始计数,
--     分母摆在明处,判断留给读的人 —— "5 次里 4 次" 与 "5 次里 1 次" 之间的
--     区别,人一眼看得出来,而一个 boolean 会把它抹平成同一个红点。
--   * **不给百分比**。43% 藏起了分母,而 1 次里 1 次也是 100%。
--   * **不重新定义什么叫短交**。短交的定义只有一处:grn_discrepancies。
--     本视图【读它】,不重算 —— 两份定义必然漂开,而漂开的那天没有人会发现。
--
-- 【权限:属主权限 + module.purchasing.view,与 grn_discrepancies 同一道门】
-- 本视图跨 purchasing(差异)与 inbound(收货)两个模块。invoker 会让无权那一侧
-- 的行被 RLS 静默丢掉(OPS-14 的 xmodule:那不是限制,是撒谎),所以属主权限,
-- 谓词原样写回体内。取 purchasing 而不放宽:实测(2026-08-18)线上【没有任何
-- 一个角色持 module.purchasing.view 而不持 module.inbound.view】,所以这道门
-- 不比今天任何一条路径更宽。
--
-- 镜像:db/views/supplier_receipt_pattern.sql;行为断言:fixture 88。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE VIEW public.supplier_receipt_pattern WITH (security_invoker = off) AS
WITH win AS (
    -- 【窗口 180 天,而这个数由视图【返回】,不由页面写一份】
    -- 页面要在屏幕上说出窗口是多久;如果它自己写一个 180,就有了第二份定义,
    -- 而两份定义迟早不一样(本仓库反复付账的那条)。所以它是一列。
    --
    -- 【为什么是 180 而不是 30 或"全部"】收货是稀疏事件:线上 3 家供应商
    -- 10 周内一共 14 次收货。30 天的窗口对多数供应商只框得住一两次收货,
    -- 而"1 次里 1 次短"不构成任何模式 —— 那样这张视图会天天报一个读不出
    -- 结论的数。反过来不设窗口,等于让一家两年前不好、此后一直很好的供应商
    -- 永远背着旧账,而采购要判断的是【现在这段关系】。
    -- 180 天≈两个季度:够攒出几次收货,又足够近,说的是当下。
    SELECT 180 AS window_days
),
cfg AS (
    -- 【阈值现读 —— 而且原样返回】页面显示的那三个数,必须就是判出这些计数的
    -- 那三个数。分开取两次就是两个时刻的答案。
    SELECT grn_short_pct, grn_over_pct, grn_assay_tolerance_pct FROM receiving_settings LIMIT 1
),
d AS (
    -- 窗口内、【有日期的】可比对收货。短交的定义在这里【被读取】,不被重写。
    SELECT g.batch_id, g.batch_code, g.arrival_date, g.supplier_id,
           g.line_id, g.line_delta_qty, g.kinds
      FROM grn_discrepancies g
      CROSS JOIN win w
     WHERE g.arrival_date IS NOT NULL
       AND g.arrival_date >= CURRENT_DATE - w.window_days
),
receipt_agg AS (
    -- 【按收货计数】—— 分母就是 comparable_receipts,摆在明处
    SELECT d.supplier_id,
           count(*) AS comparable_receipts,
           count(*) FILTER (WHERE 'short' = ANY (d.kinds)) AS short_receipts,
           count(*) FILTER (WHERE 'over' = ANY (d.kinds)) AS over_receipts,
           count(*) FILTER (WHERE 'declared_vs_actual' = ANY (d.kinds)) AS declared_vs_actual_receipts,
           count(*) FILTER (WHERE 'material_mismatch' = ANY (d.kinds)) AS material_mismatch_receipts,
           count(*) FILTER (WHERE 'assay_beyond_tolerance' = ANY (d.kinds)) AS assay_beyond_receipts,
           count(*) FILTER (WHERE cardinality(d.kinds) > 0) AS receipts_with_any_discrepancy,
           min(d.arrival_date) AS earliest_receipt,
           max(d.arrival_date) AS latest_receipt
      FROM d GROUP BY d.supplier_id
),
line_facts AS (
    -- 【一采购行一行】—— 数量必须在这个粒度上加,否则挂 2 次收货的那条行算两遍。
    -- 【只许拿 short / over 出去】它们是行级事实,同一行的每条收货上都一样;
    -- declared_vs_actual 与 material_mismatch 是【收货级】的,逐条不同,
    -- 在这里取 DISTINCT ON 会随机挑中一条 —— 所以下面的 line_agg 只用前两个。
    SELECT DISTINCT ON (d.supplier_id, d.line_id)
           d.supplier_id, d.line_id, d.line_delta_qty, d.kinds
      FROM d ORDER BY d.supplier_id, d.line_id, d.batch_id
),
line_agg AS (
    SELECT lf.supplier_id,
           count(*) FILTER (WHERE 'short' = ANY (lf.kinds)) AS short_lines,
           count(*) FILTER (WHERE 'over' = ANY (lf.kinds)) AS over_lines,
           -- line_delta_qty 短交时为负、超收时为正 —— 原样保留符号,不取绝对值:
           -- 屏幕上"-2000"与"+80000"一眼分得出方向,而 abs 之后就分不出了。
           COALESCE(sum(lf.line_delta_qty) FILTER (WHERE 'short' = ANY (lf.kinds)), 0) AS short_qty,
           COALESCE(sum(lf.line_delta_qty) FILTER (WHERE 'over' = ANY (lf.kinds)), 0) AS over_qty
      FROM line_facts lf GROUP BY lf.supplier_id
),
excluded_agg AS (
    -- 【比不了的那些:有日期、在窗口内,却不在差异视图里】
    -- 判据是【不在视图里】而不是【没挂采购行】—— 后者漏掉另一条路:
    -- 采购行还在、但采购单被软删了(视图过滤 po.deleted_at IS NULL)。
    -- 线上今天这条路是 0 条,但按"不在视图里"写就不需要将来有人记得补。
    SELECT b.supplier_id, count(*) AS excluded_receipts
      FROM inbound_batches b CROSS JOIN win w
     WHERE b.deleted_at IS NULL
       AND b.arrival_date IS NOT NULL
       AND b.arrival_date >= CURRENT_DATE - w.window_days
       AND NOT EXISTS (SELECT 1 FROM grn_discrepancies g WHERE g.batch_id = b.id)
     GROUP BY b.supplier_id
),
undated_agg AS (
    -- 【放不进时间里的那些】—— 第三类,既不是"可比对"也不是"比不了"。
    -- undated_with_discrepancy 是这一族里最要紧的一个数:它回答
    -- "把日期补上会不会改变结论"。实测线上全库唯一一条 short 就在这一类里。
    SELECT b.supplier_id,
           count(*) AS undated_receipts,
           count(*) FILTER (
               WHERE EXISTS (SELECT 1 FROM grn_discrepancies g
                              WHERE g.batch_id = b.id AND cardinality(g.kinds) > 0)
           ) AS undated_with_discrepancy
      FROM inbound_batches b
     WHERE b.deleted_at IS NULL AND b.arrival_date IS NULL
     GROUP BY b.supplier_id
)
SELECT s.id AS supplier_id,
    s.code AS supplier_code,
    s.legal_name AS supplier_name,
    w.window_days,
    (CURRENT_DATE - w.window_days) AS window_from,
    -- 【一家没有可比对收货的供应商仍然出现在这里,值为 0】—— 从 suppliers 左连接
    -- 出发,而不是从差异行分组出发。少了这一条,这家供应商在视图里【整行不存在】,
    -- 而页面就分不出"没有可比对的收货"与"查不到这家供应商" —— 两句完全不同的话。
    COALESCE(ra.comparable_receipts, 0::bigint) AS comparable_receipts,
    COALESCE(ra.short_receipts, 0::bigint) AS short_receipts,
    COALESCE(ra.over_receipts, 0::bigint) AS over_receipts,
    COALESCE(ra.declared_vs_actual_receipts, 0::bigint) AS declared_vs_actual_receipts,
    COALESCE(ra.material_mismatch_receipts, 0::bigint) AS material_mismatch_receipts,
    COALESCE(ra.assay_beyond_receipts, 0::bigint) AS assay_beyond_receipts,
    COALESCE(ra.receipts_with_any_discrepancy, 0::bigint) AS receipts_with_any_discrepancy,
    COALESCE(la.short_lines, 0::bigint) AS short_lines,
    COALESCE(la.over_lines, 0::bigint) AS over_lines,
    COALESCE(la.short_qty, 0::numeric) AS short_qty,
    COALESCE(la.over_qty, 0::numeric) AS over_qty,
    COALESCE(ea.excluded_receipts, 0::bigint) AS excluded_receipts,
    COALESCE(ua.undated_receipts, 0::bigint) AS undated_receipts,
    COALESCE(ua.undated_with_discrepancy, 0::bigint) AS undated_with_discrepancy,
    ra.earliest_receipt,
    ra.latest_receipt,
    cfg.grn_short_pct,
    cfg.grn_over_pct,
    cfg.grn_assay_tolerance_pct
   FROM suppliers s
     CROSS JOIN win w
     CROSS JOIN cfg
     LEFT JOIN receipt_agg ra ON ra.supplier_id = s.id
     LEFT JOIN line_agg la ON la.supplier_id = s.id
     LEFT JOIN excluded_agg ea ON ea.supplier_id = s.id
     LEFT JOIN undated_agg ua ON ua.supplier_id = s.id
  WHERE s.deleted_at IS NULL
    AND has_permission('module.purchasing.view'::text);

COMMENT ON VIEW public.supplier_receipt_pattern IS
    'GRN-2:一家供应商一行 —— 这家是不是【一直】短交。一次短交是行情,连续短交是供应商问题,而 grn_discrepancies 逐条说得出"这一条怎么了",说不出"这一家一向如何"。
【三个计数是三件不同的事,永远不许合并】comparable_receipts(窗口内、有日期、比对得了的)是分母;excluded_receipts(有日期但没有订量可比 —— 判据是【不在 grn_discrepancies 里】,因此也涵盖采购单被软删这条路)【不是合规】,它是"没法评判";undated_receipts(没有到货日,放不进任何窗口)是第三类。把后两类折进分母,等于把"不知道"算成"没问题"。
【undated_with_discrepancy 是这一族最要紧的数】它回答"把日期补上会不会改变结论"。实测(2026-08-18):全库唯一一条 short(IN-2026-0029)正在这一类里 —— 一个朴素的窗口谓词会让那家供应商显示"零次短交"。
【次数按收货算,数量按采购行算】line_delta_qty 是行级事实、挂在该行的每一条收货上,直接按收货求和会把挂了多次收货的行算两遍(线上已有一条)。所以 short_qty / over_qty 在 DISTINCT line_id 上汇总,而 *_receipts 按收货计数。两种单位,列名各自说清。
【没有"一贯短交"这个布尔量,也没有百分比】那需要一个没有人选过的阈值,而这张视图没有资格替采购员做那个判断;百分比则藏起分母(1 次里 1 次也是 100%)。给原始计数,分母摆在明处。
【短交的定义只有一处】本视图读 grn_discrepancies,不重算 —— 两份定义必然漂开。三个阈值同样现读 receiving_settings,并【原样返回】,好让屏幕显示的就是判出这些计数的那三个数。
【一家没有可比对收货的供应商仍然出现,值为 0】从 suppliers 左连接出发,于是页面分得出"没有可比对的收货"与"查不到这家供应商"。
【属主权限 + module.purchasing.view】跨 purchasing × inbound 两模块,invoker 会让无权那侧的行被 RLS 静默丢掉(OPS-14)。实测线上没有任何角色持 purchasing.view 而不持 inbound.view,所以这道门不比今天任何一条路径更宽。';

GRANT SELECT ON public.supplier_receipt_pattern TO authenticated;

COMMIT;
