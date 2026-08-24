-- db/tables/tax_codes.sql
-- GST-1:税码字典 —— 一张单据行"在 GST 上是什么性质"。
--
-- ★【税率不在这张表上】★ 它挂在 db/tables/tax_rates.sql 的生效期间上。
--   把税率写成税码的一个列,等于宣称"SR 就是 9%",而 2022 年的 SR 是 7%、
--   2023 年是 8% —— 历史单据必须留住它当时那一个,一个标量列做不到这件事。
--
-- ★【为什么零税率 / 豁免 / 不在范围内是三个码,不是一个 0%】★
--   它们的税率都是零,进 F5 的格子却完全不同:ZR 进 box2,ES 进 box3,
--   OS 进 box4 之外根本不进供应额。用"税率 = 0"表达它们,F5 就再也拆不开
--   —— 这不是分类学上的讲究,是一张表能不能填对的问题。
--
-- 【is_claimable】只对进项侧有意义:BL(blocked input tax,如私家车、
--   俱乐部会籍、部分医疗保险)进项税【不可抵扣】。它不是"没有税",
--   而是"有税但不能要回来" —— 于是它进 box5 的采购额,却不进 box7 的进项税。
--
-- 写入只走 SECURITY DEFINER 函数;这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-24-gst1-tax-codes-f5-and-filing-periods.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.tax_codes (
    code            text PRIMARY KEY,
    side            text NOT NULL CHECK (side IN ('output', 'input')),
    name_en         text NOT NULL,
    name_zh         text NOT NULL,
    description_en  text,
    description_zh  text,
    -- 这一行进 F5 的哪一格。NULL = 不进那一类的格(例如 OS 不进任何供应额格)。
    f5_supply_box   text,   -- 销项侧:供应额进 box1 / box2 / box3
    f5_purchase_box text,   -- 进项侧:采购额进 box5
    f5_tax_box      text,   -- 税额进 box6(销项)/ box7(进项)
    is_claimable    boolean NOT NULL DEFAULT false,  -- 进项侧:进项税可否抵扣(BL = 不可)
    is_active       boolean NOT NULL DEFAULT true,
    sort_order      integer NOT NULL DEFAULT 0
);

ALTER TABLE public.tax_codes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "tax_codes select by permission"
    ON public.tax_codes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- ─────────────────────────────────────────────────────────────────────────────
-- 【安装种子:IRAS 的九个税码】。逐行跟踪线上(check_mirrors 的 SEED_TABLES)。
-- 措辞照 IRAS 自己的说法,不自创中文口径。
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.tax_codes
    (code, side, name_en, name_zh, description_en, description_zh,
     f5_supply_box, f5_purchase_box, f5_tax_box, is_claimable, is_active, sort_order) VALUES
    ('SR', 'output', 'Standard-rated supply', '标准税率销项',
     'A taxable supply made in Singapore at the prevailing rate.',
     '在新加坡作出的应税供应,按现行税率。',
     'box1', NULL, 'box6', false, true, 10),
    ('ZR', 'output', 'Zero-rated supply', '零税率销项',
     'Exports and international services. Taxable at 0% — NOT the same as exempt.',
     '出口与国际服务。按 0% 应税 —— 与豁免【不是】一回事。',
     'box2', NULL, NULL, false, true, 20),
    ('ES', 'output', 'Exempt supply', '豁免销项',
     'Prescribed exempt supplies. No tax, and input tax attributable to them is generally not claimable.',
     '法定豁免供应。不计税,且归属于它的进项税一般不可抵。',
     'box3', NULL, NULL, false, true, 30),
    ('OS', 'output', 'Out-of-scope supply', '不在范围内',
     'Outside the scope of Singapore GST. Reported in no supply box.',
     '不在新加坡 GST 范围内。不进任何一个销项格。',
     NULL, NULL, NULL, false, true, 40),
    ('TX', 'input', 'Standard-rated purchase', '标准税率进项',
     'A taxable purchase on which input tax may be claimed.',
     '可抵扣进项税的应税采购。',
     NULL, 'box5', 'box7', true, true, 50),
    ('ZP', 'input', 'Zero-rated purchase', '零税率进项',
     'A purchase taxable at 0%.',
     '按 0% 应税的采购。',
     NULL, 'box5', NULL, false, true, 60),
    ('EP', 'input', 'Exempt purchase', '豁免进项',
     'A purchase that is an exempt supply in the supplier''s hands.',
     '在供应商那一侧属于豁免供应的采购。',
     NULL, NULL, NULL, false, true, 70),
    ('BL', 'input', 'Blocked input tax', '不可抵进项',
     'Expenses on which input tax is blocked by regulation (e.g. private motor cars, club subscriptions, medical). The purchase is reported; the tax is NOT claimed.',
     '法规明令不可抵的开支(如私家车、俱乐部会籍、医疗)。采购要报,税【不抵】。',
     NULL, 'box5', NULL, false, true, 80),
    ('OP', 'input', 'Out-of-scope purchase', '不在范围内的采购',
     'Outside the scope of Singapore GST.',
     '不在新加坡 GST 范围内。',
     NULL, NULL, NULL, false, true, 90);

COMMENT ON TABLE public.tax_codes IS
    'GST-1:税码字典。**税率不在这里** —— 它在 tax_rates 上按生效期间挂着,因为税率按法令变而历史单据必须留住当时那一个。一个税码的意义是它进 F5 的哪一格:0% 的零税率、豁免与不在范围内是三件不同的事,而税率分不开它们。';
