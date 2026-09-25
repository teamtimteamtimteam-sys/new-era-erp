-- db/functions/guard_journal_direct_write.sql
-- APR-6(2026-09-25,grilling Q1 · Q9):**journal_entries 与 journal_lines 没有直连写**。
--
-- 【量过的】写这两张表的只有 post_journal_entry(插入)与 reverse_journal_entry_internal(posted → reversed
-- 那一次翻转);调用它们的 30 支函数在线上全是 SECURITY DEFINER、属主 postgres(rolbypassrls)—— APR-6 Step 0
-- 以 postgres 读 pg_proc。app/ 里对这两张表只有读。于是两条 INSERT 写策略(都开在 module.finance.edit 上)
-- 一并拿掉。它们放行过的路:
--   · 直连 INSERT 一张分录头:自己挑编号(无缝编号从此有缝)、自己填 created_by(职责分离那条规矩认的就是它)、
--     自己填 status / reversed_by / source_type —— 一张 'purchase' 或 'payment' 分录不经任何单据就进了账;
--   · 直连 INSERT 分录行,挂在一张【已过账】的分录上(JE-APPEND):开着的期间里,一张过完账的凭证金额还能动;
--   · 一张没有行的分录头(平衡触发器只在插行时排队)。
--
-- 【为什么还要一支语句级守卫】没有写策略时,直连 INSERT 报的是一句 RLS 的原文(new row violates row-level
-- security policy),UPDATE / DELETE 则是【零行、不报错】(SILENT-1 那一族)。本守卫零行也照样触发,按名拒
-- JOURNAL_THROUGH_FUNCTION_ONLY。属主路径(row_security_active = false)一律放行 —— 那就是 30 支 DEFINER 过账
-- 函数与 reverse_journal_entry_internal 走的路。形状照 guard_invoice_direct_write。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_journal_direct_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'JOURNAL_THROUGH_FUNCTION_ONLY';
END;
$function$;

COMMENT ON FUNCTION public.guard_journal_direct_write() IS
'APR-6:journal_entries 与 journal_lines 的任何直连写(row_security_active,语句级,零行也触发)按名拒 JOURNAL_THROUGH_FUNCTION_ONLY。写它们的只有 post_journal_entry(EXECUTE 已从 authenticated 收回)与 reverse_journal_entry_internal,调用方全是 SECURITY DEFINER;一张手工凭证走 submit_journal_request → CFO 批准。';
