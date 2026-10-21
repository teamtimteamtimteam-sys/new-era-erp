-- db/tables/expense_claim_receipts.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1–Q14):报销单【每一笔】的收据 —— 一行一份文件:哪张单 · 哪一笔 · 文件名 / 类型 / 大小 ·
--   私有桶 claim-receipts 里的路径 · 到了哪一步 · 谁传的、谁拿掉的。
--
-- 【收据按笔】(Tim 2026-10-20 的形状)每一笔要么有自己的收据、要么有自己的无收据理由,批准时逐笔查
--   (decide_expense_claim_items,EXPENSE_CLAIM_NO_EVIDENCE|单号|第几笔)。一笔可以有几份文件(Q9,不设份数上限)。
-- 【状态】uploading(登记了,字节还没到)→ attached(字节到了、类型与大小对得上)| abandoned(没传成);
--   attached → removed(Q5:单还在 submitted 时,传的人可以拿掉一份;拿掉的从单上隐去,谁、何时记在这一行;
--   【对象留在桶里】—— 没有任何员工持存储的删除权限,与门户同一条)。
-- 【谁传】(Q4)这张单说的那名员工,以及替他提单的那个人(expense_claims.created_by);只在单还是 submitted 时;别人都不行。
--   「提单人不能批」那一条照旧(decide_expense_claim_items 的 forbid_self_approval)。
-- 【上限】(Q1)与门户同一个数 —— 读的就是门户那两列(account_settings.portal_upload_max_bytes / portal_upload_types,V39):10 MB · PDF / JPEG / PNG。
--   HEIC、Word、Excel 按名拒并说明为什么。照片在浏览器里先缩到长边约 2,000 px、存成 JPEG(Q3);PDF 原样。
--   (Q10)整个项目的存储到了 900 MB,新的收据一律按名拒(CLAIM_RECEIPT_STORAGE_FULL)。
-- 【谁写】只经函数:claim_receipt_begin / _finish / _abandon / _remove(SECURITY DEFINER,各自先判调用者)。没有任何写策略,
--   authenticated 与 anon 连写的授权都没有。
-- 【谁读】(Q6 · Q7)持 module.finance.view 的人读全部;这张单说的那名员工与替他提单的人读这张单的。决定之后仍然读得到;
--   之后谁都拿不掉(拿掉只在 submitted 时)。没有另设 HR / 审计的规矩。
-- 【变更记录】记(不是豁免);审计记录里它挂在报销单那一条下(trail_subject_members:expense_claim · my_expense_claim)。
--
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.expense_claim_receipts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    claim_id      uuid NOT NULL REFERENCES public.expense_claims (id) ON DELETE RESTRICT,
    item_id       uuid NOT NULL REFERENCES public.expense_claim_items (id) ON DELETE RESTRICT,
    file_name     text NOT NULL CHECK (length(file_name) BETWEEN 1 AND 200),
    file_type     text NOT NULL,
    file_size     bigint NOT NULL CHECK (file_size > 0),
    bucket_id     text NOT NULL DEFAULT 'claim-receipts' CHECK (bucket_id = 'claim-receipts'),
    storage_path  text NOT NULL UNIQUE,
    status        text NOT NULL DEFAULT 'uploading'
                  CHECK (status IN ('uploading', 'attached', 'abandoned', 'removed')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid NOT NULL,
    attached_at   timestamptz,
    removed_at    timestamptz,
    removed_by    uuid,
    CONSTRAINT expense_claim_receipts_attached CHECK ((status IN ('attached', 'removed')) = (attached_at IS NOT NULL)),
    CONSTRAINT expense_claim_receipts_removed CHECK ((status = 'removed') = (removed_at IS NOT NULL AND removed_by IS NOT NULL))
);

CREATE INDEX idx_expense_claim_receipts_claim ON public.expense_claim_receipts (claim_id, item_id);
CREATE INDEX idx_expense_claim_receipts_item ON public.expense_claim_receipts (item_id) WHERE status = 'attached';

COMMENT ON TABLE public.expense_claim_receipts IS
    'CLAIM-RECEIPTS-1(Tim 2026-10-21):报销单每一笔的收据(一份文件一行),私有桶 claim-receipts。uploading → attached | abandoned;attached → removed(只在单 submitted 时,对象留在桶里)。传:这张单说的员工与替他提单的人,只在 submitted 时(Q4)。读:module.finance.view 全部,员工与提单人读自己那张单的(Q6)。只经函数写。批准时每一笔要么有一份 attached 的收据、要么有无收据理由。';

-- 【状态只往前走,别的列不可改,行不可删】函数之外的路(postgres 手改)也挡在这里
CREATE OR REPLACE FUNCTION public.guard_expense_claim_receipt_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_IMMUTABLE';
    END IF;
    IF NEW.id IS DISTINCT FROM OLD.id OR NEW.claim_id IS DISTINCT FROM OLD.claim_id OR NEW.item_id IS DISTINCT FROM OLD.item_id
       OR NEW.file_name IS DISTINCT FROM OLD.file_name OR NEW.file_type IS DISTINCT FROM OLD.file_type
       OR NEW.file_size IS DISTINCT FROM OLD.file_size OR NEW.bucket_id IS DISTINCT FROM OLD.bucket_id
       OR NEW.storage_path IS DISTINCT FROM OLD.storage_path OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NOT ((OLD.status = 'uploading' AND NEW.status IN ('attached', 'abandoned'))
               OR (OLD.status = 'attached' AND NEW.status = 'removed')) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_expense_claim_receipts_immutable
    BEFORE UPDATE OR DELETE ON public.expense_claim_receipts
    FOR EACH ROW EXECUTE FUNCTION public.guard_expense_claim_receipt_mutation();

ALTER TABLE public.expense_claim_receipts ENABLE ROW LEVEL SECURITY;

-- Q6:财务看得见全部;这张单说的那名员工与替他提单的人看得见这张单的
CREATE POLICY "expense_claim_receipts select by permission" ON public.expense_claim_receipts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text)
        OR EXISTS (SELECT 1 FROM public.expense_claims c
                    WHERE c.id = expense_claim_receipts.claim_id
                      AND (c.employee_id = current_user_employee() OR c.created_by = auth.uid())));

-- 【没有 INSERT/UPDATE/DELETE 策略】唯一写入口是属主权限函数(claim_receipt_begin · _finish · _abandon · _remove)。
REVOKE ALL ON public.expense_claim_receipts FROM authenticated, anon;
GRANT SELECT ON public.expense_claim_receipts TO authenticated;
