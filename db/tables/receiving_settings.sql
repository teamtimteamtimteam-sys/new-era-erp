-- db/tables/receiving_settings.sql
-- GRN-1a:收货模块的单行配置(形状取自 pricing_settings / processing_settings)。
-- 装着收货差异的三个阈值 —— 【短交与超收是两个数,不是一个】。
--
-- NOTE: introduced by db/migrations/2026-08-17-grn1a-receiving-discrepancy-db-half.sql.
-- First-run script (plain CREATEs).
--
-- 【RUNTIME CONFIG】这张表运营改得动(编辑面板属于 GRN-1b),所以
-- check_mirrors 不逐行比对它的内容 —— 线上与文件不同【是系统在正常工作】。
-- 但引导那一行必须在,而且【列的语义变了要回来重读这个文件】(AGENTS.md 那一节:
-- 改了含义而没改列名的迁移,没有任何一道检查看得见)。
--
-- 【重放顺序:它必须在 db/views/grn_discrepancies.sql 之前存在】—— 而 tables 本就
-- 排在 views 前面,所以这条不需要任何特殊处理。这一句写下来是因为它已经犯过一次:
-- 本文件缺席时,重建死在 grn_discrepancies 上,报的是"relation receiving_settings
-- does not exist",而那读起来像视图的毛病,不像少了一张表。

CREATE TABLE public.receiving_settings (
    id boolean PRIMARY KEY DEFAULT true CHECK (id),
    -- 短交:某个采购行【累计】收到的比订量少百分之几算"短了"
    grn_short_pct           numeric NOT NULL DEFAULT 5
        CHECK (grn_short_pct > 0),
    -- 超收:累计收到的比订量多百分之几算"超了"
    grn_over_pct            numeric NOT NULL DEFAULT 5
        CHECK (grn_over_pct > 0),
    -- 化验偏差:实际与预期的【相对】偏差超过百分之几算"超差"
    grn_assay_tolerance_pct numeric NOT NULL DEFAULT 10
        CHECK (grn_assay_tolerance_pct > 0),
    notes      text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.receiving_settings IS
    'GRN-1a:收货模块的单行配置(形状取自 pricing_settings / processing_settings)。装着收货差异的三个阈值。【短交与超收是两个数,不是一个】—— 与 processing_settings 的两个工单阈值同一条道理:短交是履约问题(货没到齐,该找供应商),超收是仓储与现金问题(地方、钱、以及一张对不上的单),合成一个数等于说它们一样严重。grn_discrepancies 【现读这三列】,没有任何地方写死它们。';
COMMENT ON COLUMN public.receiving_settings.grn_short_pct IS
    '短交阈值(百分比)。某个采购行【累计收到】的量低于订量 ×(1 − 本值/100)时,该行的每一条收货都带上 short。【只在采购单 closed / cancelled 时报】—— 与 wo_output_shortfall_pct 完全同一条:单还开着的时候"少"只是"还没收完",报出来等于每天提醒一件正在进行的事。也用作【申报量 vs 实收】方向为"少"时的阈值。';
COMMENT ON COLUMN public.receiving_settings.grn_over_pct IS
    '超收阈值(百分比)。某个采购行累计收到的量高于订量 ×(1 + 本值/100)时报 over。【任何状态都报,不等关单】—— 超收在它发生的那一刻就是可处理的事(货已经占了地方、钱已经欠出去了),这与 wo_input_overrun_pct 对开着的工单也报是同一条。也用作【申报量 vs 实收】方向为"多"时的阈值。';
COMMENT ON COLUMN public.receiving_settings.grn_assay_tolerance_pct IS
    '化验偏差阈值(百分比)。采购行的 expected_assay 与【已应用】化验的 content_pct 逐金属比,|实际 − 预期| / 预期 × 100 超过本值时报 assay_beyond_tolerance。【是相对偏差,不是百分点】—— 这是一个决定,写在这里而不是留给读的人猜:锂常在 0.5% 量级、镍常在 30% 量级,十个百分点对前者是整整二十倍、对后者是三分之一,一个绝对阈值对两者不可能同时有意义。相对偏差对两者都成立。预期为 0 或缺失时【不下任何断言】,而不是判成"在容差内"。';

INSERT INTO public.receiving_settings (id) VALUES (true);

ALTER TABLE public.receiving_settings ENABLE ROW LEVEL SECURITY;
-- 收货的设置归收货。procurement 也持 module.inbound.view(实测),所以采购侧一样读得到。
CREATE POLICY "receiving_settings select by permission" ON public.receiving_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));
CREATE POLICY "receiving_settings update by permission" ON public.receiving_settings
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text))
    WITH CHECK (has_permission('module.inbound.edit'::text));

GRANT SELECT ON public.receiving_settings TO authenticated;
GRANT UPDATE ON public.receiving_settings TO authenticated;
