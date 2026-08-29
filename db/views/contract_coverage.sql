-- db/views/contract_coverage.sql
-- CONTRACT-1:★**多少张单据跑在合同之下,多少张没有**★ —— A1 那句"honest cost"的落地。
--
-- ★★【没有这张视图,那道闸会撒谎】★★(Tim 2026-08-29 裁定 A1)
--   本刀**没有强制**任何单据挂上合同,而且那是对的:现货采购本来就没有合同。
--   后果是覆盖率**完全是自愿的** —— 于是
--   **「没有任何合同被违反」很可能只意味着「没有人挂过任何东西」**。
--   两句话在屏幕上必须分得开,而分开它们的唯一办法就是把【分母】摆出来。
--
--   这与 PARTY-1 的重叠报告是同一条:那一份因为客户侧一个 tax_id 都没有,
--   「0 条重叠」必然为真而毫无信息,所以它带着 coverage 一起返回。
--   **一个永远为真的判词是装饰。**
--
-- 【它【不】评判覆盖率高低】没有人裁过"多少比例的采购应当在合同之下" ——
--   现货买卖是正当的商业形态,不是一个待修的缺口。所以这里只报数,不报警。

CREATE VIEW public.contract_coverage WITH (security_invoker = off) AS
 WITH po AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE contract_id IS NOT NULL) AS under_contract
      FROM purchase_orders WHERE deleted_at IS NULL
 ), so AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE contract_id IS NOT NULL) AS under_contract
      FROM sales_orders WHERE deleted_at IS NULL
 ), con AS (
    SELECT count(*) AS total,
           count(*) FILTER (WHERE status = 'active') AS active,
           count(*) FILTER (WHERE side = 'buy') AS buy_side,
           count(*) FILTER (WHERE side = 'sell') AS sell_side
      FROM contracts WHERE deleted_at IS NULL
 )
 SELECT po.total AS purchase_orders_total,
    po.under_contract AS purchase_orders_under_contract,
    so.total AS sales_orders_total,
    so.under_contract AS sales_orders_under_contract,
    con.total AS contracts_total,
    con.active AS contracts_active,
    con.buy_side AS contracts_buy_side,
    con.sell_side AS contracts_sell_side,
    -- 【能不能判品位】要三样都在:挂了合同的单、它的入库、以及化验。
    -- 这个数是 contract_grade_breaches 那张表的【分母】——
    -- 没有它,「0 条违反」说不出自己是哪一种 0。
    (SELECT count(*) FROM contract_document_terms t
      WHERE jsonb_array_length(t.grade_specs) > 0) AS documents_with_grade_specs
   FROM po, so, con
  WHERE has_permission('module.suppliers.view'::text)
     OR has_permission('module.customers.view'::text);

COMMENT ON VIEW public.contract_coverage IS
    'CONTRACT-1:多少张单据跑在合同之下,多少张没有 —— ★**没有它,那道闸会撒谎**★(Tim 2026-08-29)。本刀没有强制任何单据挂合同,而那是对的(现货采购本来就没有合同),后果是覆盖率完全自愿 —— 于是**「没有任何合同被违反」很可能只意味着「没有人挂过任何东西」**,而两句话必须分得开。分开它们的唯一办法是把分母摆出来。与 PARTY-1 的重叠报告同一条:那一份因为客户侧一个 tax_id 都没有,「0 条重叠」必然为真而毫无信息,所以它带着 coverage 一起返回 —— **一个永远为真的判词是装饰**。`documents_with_grade_specs` 是 contract_grade_breaches 的分母。**它不评判覆盖率高低**:没有人裁过"多少比例的采购应当在合同之下",现货买卖是正当的商业形态,不是待修的缺口 —— 所以只报数,不报警。';
