-- db/functions/signing_password_verified_at.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q5):这个令牌【最近一次凭密码登录】的时刻 —— 令牌 amr 里 method = password 那一项的 timestamp。
--   签字的服务端动作用调用者刚刚重新输入的密码另开一个会话(不换掉浏览器里那一个),签字那几步都用这个新会话的令牌;
--   contract_sign_begin 要求这个时刻在 5 分钟之内 —— 于是"签字时重新输入了密码"是库自己从令牌里读出来的,不是谁说了算。
--   没有这一项 / 读不出 → NULL(调用方按名拒)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.signing_password_verified_at()
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ts timestamptz;
BEGIN
    SELECT max(to_timestamp((a ->> 'timestamp')::double precision)) INTO v_ts
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(auth.jwt() -> 'amr') = 'array' THEN auth.jwt() -> 'amr' ELSE '[]'::jsonb END) a
     WHERE a ->> 'method' = 'password' AND (a ->> 'timestamp') ~ '^[0-9]+(\.[0-9]+)?$';
    RETURN v_ts;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$function$;
