-- CMP-2:收货拦截【看得见】—— 表单在按钮旁说出挡它的证书,服务端拒绝有译文
--
-- 起因:PO-2026-0003 的收货表单保存钮点不动,Tim 说不出为什么。查明:钮的失灵
-- 是到货日期未填(FIN-32 的必填守卫,只灰不说话);而 CMP-1 的证书拦截根本不在
-- 钮上 —— 它只在触发器里,且 SUPPLIER_QUALIFICATION_EXPIRED 不在任何本地化表,
-- 打到操作员脸上的是一串裸管道符。两处都是同一族病:【什么都不说的拒绝】。
--
-- 这张视图让页面【问数据库】"这家供应商收货会不会被拒"——谓词与
-- guard_inbound_po_receivable 的 CMP-1 段完全同一份(供应商未删、block 类型、
-- valid_until < CURRENT_DATE)。日期一律 CURRENT_DATE(库内新加坡时区,FIN-20),
-- 不在 JS 里算"今天"—— 服务器时区跟库不同的那几个小时里,钮和触发器会互相矛盾。
-- 【重复的谓词会漂】:fixture 37 F 臂钉"视图有行 ⇔ 收货被拒",改一边必须改两边。
--
-- 属主权限 + 体内 module.inbound.view 谓词(xmodule 补法 a):收货表单的读者是
-- inbound 模块;借来的只有供应商 code 与证书名 —— 标签随行,实体属性不随
-- (AGENTS.md 三条常设决定之三)。
-- NOTE: apply with ./db/apply_migration.sh
BEGIN;

CREATE VIEW public.supplier_receiving_blocked WITH (security_invoker = off) AS
SELECT sc.supplier_id,
       s.code AS supplier_code,
       ct.code AS cert_type_code,
       ct.name_en,
       ct.name_zh,
       sc.valid_until
FROM supplier_compliance sc
JOIN certificate_types ct ON ct.code = sc.cert_type_code
JOIN suppliers s ON s.id = sc.supplier_id
WHERE has_permission('module.inbound.view'::text)
  AND sc.deleted_at IS NULL
  AND ct.disposition = 'block'
  AND sc.valid_until IS NOT NULL
  AND sc.valid_until < CURRENT_DATE;

COMMENT ON VIEW public.supplier_receiving_blocked IS
    '收货会被 CMP-1 拦截的供应商(CMP-2)。谓词与 guard_inbound_po_receivable 的证书段【同一份】—— fixture 37F 钉两者一致,改一边要改两边。表单用它把"为什么点不动"写在按钮旁,而不是让操作员对着灰钮猜。';

GRANT SELECT ON public.supplier_receiving_blocked TO authenticated;

COMMIT;
