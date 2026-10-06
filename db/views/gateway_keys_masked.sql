-- db/views/gateway_keys_masked.sql
-- MES-1(2026-10-06,MES-0 Q91;MES-1 Step 0 Q20,Tim):网关钥匙的遮蔽伴生视图。
-- 【遮什么】key_hash —— 【谁都看不见】:CASE WHEN false,恒为空。规则 never 与这一句同一个判据(change_log_mask_rules)。
--   表上的列授权里没有它,所以 API 读基表拿不到;读这张视图拿到的是空 —— 两条路都不给。页面只认 key_prefix。
-- 【行谓词】= 基表的读策略(module.processing.view)—— 属主视图绕过 RLS,所以这里必须再问一次。
-- 【列】基表的每一列都在这里(colgrant)。

CREATE VIEW public.gateway_keys_masked WITH (security_invoker = off) AS
 SELECT id,
    gateway_id,
    key_prefix,
        CASE
            WHEN false THEN key_hash
            ELSE NULL::bytea
        END AS key_hash,
    issued_at,
    issued_by,
    revoked_at,
    revoked_by,
    revoke_reason
   FROM gateway_keys
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.gateway_keys_masked IS
    'MES-1:网关钥匙的遮蔽伴生视图。key_hash 谁都看不见(恒为空,never 规则)。行谓词 = 基表的读策略(module.processing.view)。';

GRANT SELECT ON public.gateway_keys_masked TO authenticated;
REVOKE ALL ON public.gateway_keys_masked FROM anon;
