-- SAL-B6:客户信用状况一张视图 —— 销售表单与客户页读同一份
--
-- SAL-B 建了管控,却没有任何一块屏把【限额】与【敞口】放在一起:限额在客户编辑
-- 表单上(一个可改的字段),敞口在应收页上(按客户合计,看不见限额),没有一处
-- 拿两者相比。于是唯一会说话的是销售被拒的那一刻 —— 而拒绝之前本可以说。
--
-- 一份实现两个消费方(reprice_split 的规矩):
--   * 销售面板:选中客户后【在录入之前】说出限额、当前敞口、余额;
--     已越限或已冻结时禁钮 —— 那时服务端【保证会拒】,给一个必定失败的按钮是谎话。
--   * 客户页(本刀新建):同样三个数,外加它们的明细。
--
-- 【敞口走有检查的外壳 customer_ar_exposure_visible,不走内层】SAL-B4 撞出来的事实:
-- 属主权限视图只把【表访问】换成属主身份,视图体里的【函数 EXECUTE】仍按当前用户查,
-- 而内层 customer_ar_exposure_base 已从 authenticated 收回。外壳无权时返回 NULL,
-- 但本视图整体挂在 module.customers.view 后面,所以进得来的人拿到的是真数。
--
-- 【无权者拿不到行,而不是拿到 0】这条对本视图尤其要命:0 在信用面板上读作
-- "没有限额、余额充足",是这个管控最危险的一种失败。页面据"没有行"渲染「受限」。
--
-- 【sales_blocked 是"服务端保证会拒"的那一半,不是全部】冻结,或敞口已 ≥ 限额 ——
-- 这两种情形下【任何】金额的销售都会被 record_output_sale 拒,所以按钮可以禁。
-- 而"这一单会不会把敞口顶过线"取决于金额与汇率,那是提交时才知道的事:面板给出
-- 余额让人自己判断,不假装算得出。
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

CREATE VIEW public.customer_credit_status WITH (security_invoker = off) AS
SELECT c.id                     AS customer_id,
       c.code,
       c.legal_name,
       c.credit_limit_base,
       c.credit_hold,
       customer_ar_exposure_visible(c.id) AS exposure_base,
       CASE WHEN c.credit_limit_base IS NOT NULL
            THEN round(c.credit_limit_base - customer_ar_exposure_visible(c.id), 2)
       END                      AS headroom_base,
       -- 服务端【保证会拒】的两种:冻结,或敞口已经够到限额
       (c.credit_hold
        OR (c.credit_limit_base IS NOT NULL
            AND customer_ar_exposure_visible(c.id) >= c.credit_limit_base)) AS sales_blocked
FROM customers c
WHERE c.deleted_at IS NULL
  AND has_permission('module.customers.view'::text);

COMMENT ON VIEW public.customer_credit_status IS
    '客户的信用状况(SAL-B6):限额、冻结、当前敞口、余额,以及"新销售是否必然被拒"。销售面板与客户页读同一份 —— 此前限额只在编辑表单上、敞口只在应收页上,没有一处把两者摆在一起。敞口走【有检查的外壳】customer_ar_exposure_visible(内层已从 authenticated 收回,而属主视图里函数 EXECUTE 按调用者查 —— SAL-B4)。无 module.customers.view 的读者【拿不到行】而不是拿到 0:0 在信用面板上读作"没有限额、余额充足",是这个管控最危险的失败。';

GRANT SELECT ON public.customer_credit_status TO authenticated;

COMMIT;
