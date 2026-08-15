-- db/views/quote_status.sql
-- SO-4a:报价的读取面 —— 存下来的 status 加三个【派生】列。
--
-- NOTE: introduced by db/migrations/2026-08-15-so4a-quotation-engine.sql.
--
-- 【派生列与 status 并列,而不是替代它】与 medical_claim_status 的
-- settlement_state 同一个形状:存的那个说"人做了什么",派生的那个说"日历走到
-- 哪了"。合成一个会让"过期"看起来像一次有人做过的动作 —— 而没有人做过它。
--
-- 【三个派生列各自的理由】
--   expired            读 quote_is_expired(valid_until) ——【一处推导】,
--                      convert_quote 的拒绝读的是同一个函数。CMP-1 的证书过期
--                      是把谓词写了两遍(视图一遍、触发器一遍),它自己的注释
--                      写着"改一边要改两边";这里不重演。
--   convertible        与 convert_quote 的拒绝【顺序一致】,于是屏幕上禁用的
--                      理由与服务端拒绝的名字对得上(CMP-2)。
--   amended_since_issue quotes.updated_at 晚于最新一版签发时刻。没签发过 → false
--                      而不是 NULL:NULL 在这个仓库里已经有含义了(受限)。
--                      【只对 issued 成立 —— fu2】谢绝与转换也会写 quotes,
--                      于是它们同样会把 updated_at 顶到签发时刻之后;可那两种
--                      状态下"你和客户手里那份不一样了"根本不是一句有意义的话。
--                      不排除掉,灯就会在两个它无话可说的地方亮着,而人会学会
--                      忽略一个总是亮的灯。
--                      【时钟见 fu1】两侧都用 clock_timestamp():now() 是事务
--                      开始时刻,在一个事务里比不出先后 —— 用它的话这条信号在
--                      任何 fixture 里都观察不到,也就从来没有被验证过。
--                      【只对 issued 成立 —— fu2】谢绝与转换也会写 quotes,
--                      于是它们同样会把 updated_at 顶到签发时刻之后;可那两种
--                      状态下"你和客户手里那份不一样了"根本不是一句有意义的话。
--                      不排除掉,灯就会在两个它无话可说的地方亮着,而人会学会
--                      忽略一个总是亮的灯。
--                      【时钟见 fu1】两侧都用 clock_timestamp():now() 是事务
--                      开始时刻,在一个事务里比不出先后 —— 用它的话这条信号在
--                      任何 fixture 里都观察不到,也就从来没有被验证过。
--
-- 【属主权限 + 整表挂 module.sales.view】客户名跟着单据走 —— 那是 AGENTS.md
-- 常设决定 3 里"显示标签跟着单据"的那一条,借的只有 code 与 legal_name。

CREATE VIEW public.quote_status WITH (security_invoker = off) AS
 SELECT q.id AS quote_id,
    q.code,
    q.customer_id,
    c.code AS customer_code,
    c.legal_name AS customer_name,
    q.quote_date,
    q.valid_until,
    q.currency,
    q.fx_rate,
    q.status,
    q.decline_reason,
    q.converted_order_id,
    so.code AS converted_order_code,
    quote_is_expired(q.valid_until) AS expired,
    q.status = 'issued'::text AND NOT quote_is_expired(q.valid_until) AS convertible,
    ( SELECT max(i.version) AS max
           FROM qt_issues i
          WHERE i.quote_id = q.id) AS issue_version,
    q.status = 'issued'::text AND COALESCE((( SELECT max(i.issued_at) AS max
           FROM qt_issues i
          WHERE i.quote_id = q.id)) < q.updated_at, false) AS amended_since_issue,
    q.notes,
    q.terms_text,
    q.updated_at
   FROM quotes q
     JOIN customers c ON c.id = q.customer_id
     LEFT JOIN sales_orders so ON so.id = q.converted_order_id
  WHERE q.deleted_at IS NULL AND has_permission('module.sales.view'::text);

COMMENT ON VIEW public.quote_status IS
    'SO-4a:报价的读取面 —— 存下来的 status 加三个【派生】列:expired(quote_is_expired,一处推导)、convertible(与 convert_quote 的拒绝顺序一致,于是屏幕上禁用的理由与服务端拒绝的名字对得上)、amended_since_issue(quotes.updated_at 晚于最新一版签发时刻)。派生列与 status 【并列而不是替代】:存的那个说"人做了什么",派生的那个说"日历走到哪了"—— 合成一个会让"过期"看起来像一次有人做过的动作。属主权限 + 整表挂 module.sales.view。';

GRANT SELECT ON public.quote_status TO authenticated;
