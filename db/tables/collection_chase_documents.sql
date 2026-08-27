-- db/tables/collection_chase_documents.sql
-- CHASE-1：一次催收里具体谈到的单据（可选、可多条），(subject_type, subject_id) 形状。
--
-- NOTE: introduced by db/migrations/2026-08-27-chase1-collection-records.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.collection_chase_documents (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chase_id     uuid NOT NULL REFERENCES public.collection_chases (id) ON DELETE RESTRICT,
    subject_type text NOT NULL CHECK (subject_type IN ('sales_record', 'invoice', 'statement')),
    subject_id   uuid NOT NULL,
    -- 【把可读标识抄下来】未开票的销售【没有单号】,批号是它唯一可读的东西,
    -- 而批号还会随重新计价改变含义 —— 抄下当时那个,与冻结数字同一条理由。
    subject_code text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (chase_id, subject_type, subject_id)
);

COMMENT ON TABLE public.collection_chase_documents IS
    'CHASE-1:一次催收里【具体谈到的单据】,可选、可多条。形状取自 approval_log / notifications 的 (subject_type, subject_id):三种主体(未开票销售 / 发票 / 对账单)住在三张表里,写三个可空外键只会得到三列里永远有两列是空。subject_code 是当时那个可读标识的【抄件】—— 未开票的销售没有单号,产出批号是它唯一可读的东西而且不唯一,所以抄下来而不是每次去 join 一个会变的东西。★【statement 这一种就是"对账单寄出去了没有"的答案】★ 八张签发档一张都没有"已发送"标志,而这是全库唯一记录"与客户接触过"的地方:一份对账单寄没寄出去 = 有没有一条催收引用了它。刻意【不】给 statement_issues 加 sent_at —— 那会是同一件事的第二份记录,并且在第二次寄出的那一刻就错了。';

CREATE INDEX idx_collection_chase_documents_subject
    ON public.collection_chase_documents (subject_type, subject_id);

CREATE TRIGGER trg_collection_chase_documents_append_only
    BEFORE UPDATE OR DELETE ON public.collection_chase_documents
    FOR EACH ROW EXECUTE FUNCTION public.guard_credit_note_append_only();

ALTER TABLE public.collection_chase_documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collection_chase_documents select by permission" ON public.collection_chase_documents
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
