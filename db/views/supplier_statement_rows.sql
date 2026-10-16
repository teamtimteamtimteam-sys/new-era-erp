-- db/views/supplier_statement_rows.sql
-- MES-8a(2026-10-16,MES-8 Step 0 Q7):供应商对账单清单页(/finance/supplier-statements)一份一行 —— 号、供应商、期间、期末、签发的人与时刻、
--   取代关系与它最新的一版字节。供应商的代码与名字读【冻在对账单上的那一份】(寄出去的那一份写的是谁),不连 suppliers ——
--   于是这张视图只读财务那一侧的表;仍写成属主权限 + module.finance.view 的明写谓词(与 ap_open_items 同一个形状)。
-- NOTE: introduced by db/migrations/2026-10-16-mes8a-supplier-scorecards-and-statements.sql.
-- First-run script. Re-running requires DROP VIEW first.

CREATE VIEW public.supplier_statement_rows WITH (security_invoker = off) AS
 SELECT st.id,
    st.code,
    st.supplier_id,
    st.supplier_code,
    st.supplier_name,
    st.period_start,
    st.period_end,
    st.base_currency,
    st.opening_base,
    st.closing_base,
    st.issued_at,
    st.issued_by,
    st.superseded_at,
    st.superseded_by,
    sb.code AS superseded_by_code,
    st.superseded_reason,
    iv.version AS latest_version,
    iv.issued_at AS latest_version_at
   FROM supplier_statements st
     LEFT JOIN supplier_statements sb ON sb.id = st.superseded_by
     LEFT JOIN LATERAL ( SELECT i.version,
            i.issued_at
           FROM supplier_statement_issues i
          WHERE i.statement_id = st.id
          ORDER BY i.version DESC
         LIMIT 1) iv ON true
  WHERE has_permission('module.finance.view'::text);

COMMENT ON VIEW public.supplier_statement_rows IS
    'MES-8a:供应商对账单清单一份一行(号 · 供应商代码与名字 · 期间 · 期初 / 期末 · 签发 · 取代 · 最新一版字节)。属主权限 + module.finance.view;供应商的代码与名字是冻在对账单上的那一份。';

-- F16:平台的默认权限给新视图授了 authenticated 的写 —— 先全收,再只授 SELECT(MES-7b-1 的惯例;迁移收尾的 F16 断言在 zzz 重放之前就要读到 0)
REVOKE ALL ON public.supplier_statement_rows FROM authenticated, anon;
GRANT SELECT ON public.supplier_statement_rows TO authenticated;
