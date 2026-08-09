-- db/tables/po_issues.sql
-- PUR-1:采购单签发档 —— 数据一处导出、签发即成档
--
-- 规格在 docs/purchase-order-document.md(A 部分的报告先于本文件写成)。要点:
--   * "发送" = 生成并下载,【签发】作为事实记录(谁、何时、第几版、字节的 SHA-256);
--     没有"已发送"标志 —— 系统不知道对方收没收到,记录自己不知道的事是 ?? 0 那一族谎。
--   * 签发的是【记录,不是视图】:字节存进私有桶,一次签发一个对象,绝不覆盖。
--     付款计划抄副本、计价条款冻结在承诺上 —— 同一个形状第三次出现,答案不变。
--   * 【定价条款印在单据上】(B 部分):条款只活在数据库里的话,两边承诺的就不是
--     同一件事。逐行状态由 po_document_data 在 SQL 里推导 —— 一份实现,页面与 PDF
--     同源,fixture 直接断言("预览要问数据库"那条规矩,这次是单据要问数据库)。
--   * 【单据币种,只有单据币种】(D 部分):输出里没有 fx_rate、没有本位币数字。
--
-- NOTE: introduced by db/migrations/2026-08-09-pur1-purchase-order-document.sql.
-- First-run script (plain CREATEs). 桶与 storage 策略在迁移里(与 finance-attachments 同惯例)。

CREATE TABLE public.po_issues (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_order_id uuid NOT NULL REFERENCES public.purchase_orders (id),
    -- 每张单自己的版本号,从 1 起。供应商手里那份是【某个具体版本】——
    -- 重新签发产生新版本,旧版本原样留着(fixture 36 钉住)。
    version           integer NOT NULL CHECK (version >= 1),
    -- po-documents 桶里的对象键;字节的 SHA-256 使对象可对着记录校验
    file_path         text NOT NULL,
    sha256            text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    issued_at         timestamptz NOT NULL DEFAULT now(),
    issued_by         uuid,
    UNIQUE (purchase_order_id, version)
);

CREATE INDEX idx_po_issues_po ON public.po_issues (purchase_order_id, version DESC);

COMMENT ON TABLE public.po_issues IS
    '采购单签发档(PUR-1),只增不改。谁、何时、第几版、哪个对象、字节摘要。没有"已发送"标志:系统不知道对方收没收到。唯一写入口 record_po_issue();重新签发 = 新的一行,绝不覆盖旧行 —— 供应商手里那份是某个具体版本。';

-- 守卫函数体在 db/functions/guard_po_issues_append_only.sql

CREATE TRIGGER trg_po_issues_append_only
    BEFORE UPDATE OR DELETE ON public.po_issues
    FOR EACH ROW EXECUTE FUNCTION public.guard_po_issues_append_only();

ALTER TABLE public.po_issues ENABLE ROW LEVEL SECURITY;

CREATE POLICY "po_issues select by permission"
    ON public.po_issues
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.purchasing.view'::text));
-- 【没有 INSERT 策略】唯一写入口是 record_po_issue()(属主权限)——
-- 与 approval_log 同一条:档案不该有第二个写法。

REVOKE SELECT ON public.po_issues FROM authenticated, anon;
GRANT SELECT (id, purchase_order_id, version, file_path, sha256, issued_at, issued_by)
    ON public.po_issues TO authenticated;
