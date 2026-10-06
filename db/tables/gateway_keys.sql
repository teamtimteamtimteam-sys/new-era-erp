-- db/tables/gateway_keys.sql
-- MES-1(2026-10-06,MES-0 Q5 · §3.4;MES-1 Step 0 Q5 · Q20,Tim):【网关钥匙】—— 每一台网关自己的、可单独撤销的密钥。
--
-- 【只存哈希】密钥本身在发放那一刻显示一次(issue_gateway_key 的返回值),之后哪里都没有它:这里存的是
--   key_hash = sha256(密钥)(PostgreSQL 内建的 sha256 —— Q5:不用 pgcrypto,线上 17.6 实测)与 key_prefix(密钥里
--   'ngk_' 之后的 8 个十六进制字符,页面显示 "ngk_1a2b3c4d…",认得出是哪一把,推不出整把)。
-- 【哈希谁都看不见】(Q20)key_hash 不在给 authenticated 的列授权里;gateway_keys_masked 里它恒为空
--   (CASE WHEN false);变更记录用 never 规则遮它 —— 任何读者、任何页面、任何一份记录都不给。
--   它推不出密钥(sha256 · 244 位随机),藏它是卫生,不是唯一的锁。
-- 【一台网关同一时刻最多两把有效】(Q5)两把才能【不停线】轮换:发第二把 → 网关换上 → 撤第一把。第三把按名拒
--   (GATEWAY_KEY_TWO_ACTIVE)。
-- 【撤销】下一次调用就生效 —— ingest_submit 每一次都现查。撤销只写一次(撤了的不能再撤、不能复活);任何人都删不掉一行。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.gateway_keys (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway_id    uuid NOT NULL REFERENCES public.devices (id),
    key_prefix    text NOT NULL CHECK (key_prefix ~ '^[0-9a-f]{8}$'),
    key_hash      bytea NOT NULL UNIQUE CHECK (octet_length(key_hash) = 32),
    issued_at     timestamptz NOT NULL DEFAULT now(),
    issued_by     uuid,
    revoked_at    timestamptz,
    revoked_by    uuid,
    revoke_reason text,
    CONSTRAINT gateway_keys_revoked_shape
        CHECK ((revoked_at IS NULL AND revoked_by IS NULL AND revoke_reason IS NULL)
            OR (revoked_at IS NOT NULL AND btrim(COALESCE(revoke_reason, '')) <> ''))
);

COMMENT ON TABLE public.gateway_keys IS
    'MES-1:网关钥匙。每一台网关自己的密钥,只存 sha256 哈希与 8 个字符的前缀;密钥在发放那一刻显示一次。哈希谁都看不见(列授权里没有它,gateway_keys_masked 恒为空,变更记录 never 规则)。一台网关同一时刻最多两把有效,好让轮换不停线。撤销在下一次调用生效;不能复活、不能删。';
COMMENT ON COLUMN public.gateway_keys.key_hash IS
    'sha256(密钥 UTF-8 字节)。谁都看不见 —— 不在列授权里,遮蔽视图里恒为空,变更记录 never 规则(Q20)。';

CREATE INDEX gateway_keys_gateway_active ON public.gateway_keys (gateway_id) WHERE revoked_at IS NULL;

-- 最多两把有效 · 只能撤一次 · 撤销之外一个字都不改 · 任何人都删不掉(语句级 —— 零行也触发)。
CREATE TRIGGER trg_gateway_keys_write
    BEFORE INSERT OR UPDATE ON public.gateway_keys
    FOR EACH ROW EXECUTE FUNCTION public.guard_gateway_keys_write();
CREATE TRIGGER trg_gateway_keys_no_delete
    BEFORE DELETE ON public.gateway_keys
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_gateway_keys_write();

ALTER TABLE public.gateway_keys ENABLE ROW LEVEL SECURITY;

CREATE POLICY "gateway_keys select by permission" ON public.gateway_keys
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.gateway_keys FROM anon;
-- 【遮蔽:列授权】key_hash 不给任何人(AGENTS.md 遮蔽表三件事:列授权 · _masked 视图 · 变更记录规则,一支迁移)。
REVOKE SELECT ON public.gateway_keys FROM authenticated;
GRANT SELECT (id, gateway_id, key_prefix, issued_at, issued_by, revoked_at, revoked_by, revoke_reason)
    ON public.gateway_keys TO authenticated;
