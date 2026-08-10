-- db/views/customer_credit_status.sql
-- 客户的信用状况(SAL-B6):限额、冻结、当前敞口、余额,以及新销售是否必然被拒。
--
-- 销售面板与客户状况页读【同一份】—— 此前限额只在客户编辑表单上、敞口只在应收页上,
-- 没有一处把两者摆在一起,于是唯一会说话的是销售被拒的那一刻。
--
-- 敞口走【有检查的外壳】customer_ar_exposure_visible:内层已从 authenticated 收回,
-- 而属主权限视图只把表访问换成属主身份,函数 EXECUTE 仍按调用者查(SAL-B4 撞出来的)。
--
-- 【无权者拿不到行,而不是拿到 0】0 在信用面板上读作没有限额、余额充足,
-- 是这个管控最危险的一种失败。fixture 46 C 臂钉住这一点。
--
-- 【sales_blocked 只认服务端保证会拒的两种】冻结,或敞口已 ≥ 限额 —— 那时任何金额
-- 都会被 record_output_sale 拒。这一单会不会顶过线取决于金额与汇率,提交时才知道:
-- 面板给余额让人自己判断,不假装算得出。

CREATE VIEW public.customer_credit_status WITH (security_invoker = off) AS
 SELECT id AS customer_id,
    code,
    legal_name,
    credit_limit_base,
    credit_hold,
    customer_ar_exposure_visible(id) AS exposure_base,
        CASE
            WHEN credit_limit_base IS NOT NULL THEN round(credit_limit_base - customer_ar_exposure_visible(id), 2)
            ELSE NULL::numeric
        END AS headroom_base,
    credit_hold OR credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(id) >= credit_limit_base AS sales_blocked
   FROM customers c
  WHERE deleted_at IS NULL AND has_permission('module.customers.view'::text);

COMMENT ON VIEW public.customer_credit_status IS
    '客户的信用状况(SAL-B6):限额、冻结、当前敞口、余额,以及"新销售是否必然被拒"。销售面板与客户页读同一份 —— 此前限额只在编辑表单上、敞口只在应收页上,没有一处把两者摆在一起。敞口走【有检查的外壳】customer_ar_exposure_visible(内层已从 authenticated 收回,而属主视图里函数 EXECUTE 按调用者查 —— SAL-B4)。无 module.customers.view 的读者【拿不到行】而不是拿到 0:0 在信用面板上读作"没有限额、余额充足",是这个管控最危险的失败。';

GRANT SELECT ON public.customer_credit_status TO authenticated;
