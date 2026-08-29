-- db/views/kpi_employee_linkage_matrix.sql
-- KPI-1:联动矩阵 —— **员工这一层**,也就是原表第五页画的那一张。派生,不另存(§9.1)。
--
-- ★★【它今天【是空的】,而那必须被【说出来】,不能画成一片零】★★(Tim 2026-08-29)
--   实测:线上只有两个真员工(其余 19 行是 ZZ-* 脚手架),
--   而原表点名的六个人里【四个根本没有员工档案】。
--   **一张画满零的矩阵读起来是「这些人什么都没贡献」** ——
--   而事实是"他们还没被建档"。两句话差得很远,屏幕上必须分得开。
--   所以本视图只返回【真的有条目的人】,而"六个人里只到了两个"这句话
--   由页面上的具名缺席去说(见 /hr/kpi 那一段)。
--
-- 【它从 kpi_entries.org_codes 这个【快照数组】推导,而职位级那张从链接表推导】
--   两份推导是**刻意的**,不是重复:复制之后改模板,两边本来就该分开 ——
--   那正是"复制不是引用"看得见的样子。一份实现会把这件事藏起来。

CREATE VIEW public.kpi_employee_linkage_matrix WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name,
    p.code AS position_code,
    k.cycle_id,
    count(*) FILTER (WHERE c.org_code = 'O1') AS o1_count,
    count(*) FILTER (WHERE c.org_code = 'O2') AS o2_count,
    count(*) FILTER (WHERE c.org_code = 'O3') AS o3_count,
    count(*) FILTER (WHERE c.org_code = 'O4') AS o4_count,
    count(*) FILTER (WHERE c.org_code = 'O5') AS o5_count,
    count(DISTINCT k.id) AS kpi_count
   FROM kpi_entries k
     JOIN employees e ON e.id = k.employee_id
     JOIN positions p ON p.id = k.source_position_id
     LEFT JOIN LATERAL unnest(k.org_codes) AS c(org_code) ON true
  WHERE has_permission('module.hr.view'::text)
    AND has_permission('data.view_reviews'::text)
  GROUP BY e.id, e.code, e.legal_name, p.code, k.cycle_id;

COMMENT ON VIEW public.kpi_employee_linkage_matrix IS
'KPI-1:联动矩阵的【员工】那一层 —— 原表第五页画的就是这一张。派生,不另存。★**它今天是空的,而那必须被说出来、不能画成一片零**★:线上只有两个真员工,原表点名的六个人里四个没有员工档案 —— 一张画满零的矩阵读起来是「这些人什么都没贡献」,而事实是「他们还没被建档」。本视图只返回真的有条目的人,"六个里只到了两个"由页面上的具名缺席去说。**它从 kpi_entries.org_codes 这个快照数组推导,而职位级那张从链接表推导 —— 两份推导是刻意的**:改了模板之后两边本来就该分开,那正是"复制不是引用"看得见的样子;一份实现会把这件事藏起来。';
