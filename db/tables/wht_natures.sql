-- db/tables/wht_natures.sql
-- WHT-1:付款【性质】字典 —— 一笔付给非居民的款是什么,而那决定适用哪一条法令。
--
-- ★【税率不在这张表上】★ 它挂在 db/tables/wht_rates.sql 的生效期间上,
--   与 tax_codes / tax_rates 的关系逐字相同:一个标量列表达不了
--   「历史单据留住当时那一个税率」。
--
-- ★【''none'' 是一个显式的否,不是占位符】★ 付给非居民的款不一定要代扣 ——
--   买货就不要。没有这一行,记账人表达「这一笔不扣」的唯一方式就是留空,
--   于是【想过了并回答否】与【根本没想过】在库里长得一模一样。
--
-- 写入只走 SECURITY DEFINER 函数;这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-28-wht1-withholding-tax-on-non-resident-payments.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.wht_natures (
    code           text PRIMARY KEY,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    description_en text,
    description_zh text,
    -- 这一种性质的法令出处。**不是装饰** —— 下一个要核对税率的人从这里开始查。
    statute_ref    text NOT NULL,
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0
);

ALTER TABLE public.wht_natures ENABLE ROW LEVEL SECURITY;
CREATE POLICY "wht_natures select by permission"
    ON public.wht_natures
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

INSERT INTO public.wht_natures
    (code, name_en, name_zh, description_en, description_zh, statute_ref, is_active, sort_order) VALUES
    -- ★【''none'' 是一个【显式的否】,不是一个占位符】★ 付给非居民的款不一定要代扣
    --   —— 买货就不要。而"不要代扣"这个判断【本身】是一次判断,它要留下痕迹。
    --   没有这一行,记账人表达"这一笔不扣"的唯一方式就是把栏位留空,
    --   于是【想过了并回答否】与【根本没想过】在库里长得一模一样 ——
    --   而这正是本仓库对 NULL 反复说的那句话:NULL 不是一个默认值,
    --   是一个没有人回答过的问题。这一行把"否"从空白里救出来。
    ('none', 'Not subject to withholding', '不适用代扣',
     'A deliberate answer that this payment attracts no withholding tax — for example a purchase of goods from a non-resident. NOT a placeholder for "nobody looked".',
     '一个【显式的判断】:这笔款不触发预提税 —— 例如向非居民买货。它不是"没人看过"的占位符。',
     'Recorded judgement — no statutory provision applies', true, 0),
    ('interest', 'Interest, commission or fee on a loan', '利息/佣金/贷款相关费用',
     'Interest, commission, fee or other payment in connection with any loan or indebtedness.',
     '与任何贷款或债务有关的利息、佣金、费用或其他款项。',
     'ITA s45', true, 10),
    ('royalty', 'Royalty or lump sum for movable property', '特许权使用费',
     'Royalty or other lump sum payment for the use of movable property.',
     '因使用动产而支付的特许权使用费或一次性款项。',
     'ITA s45A', true, 20),
    ('know_how', 'Use of scientific or technical knowledge', '技术/商业知识使用费',
     'Payment for the use of, or right to use, scientific, technical, industrial or commercial knowledge or information.',
     '为使用或有权使用科学、技术、工业或商业知识或信息而支付的款项。',
     'ITA s45A', true, 30),
    ('management_fee', 'Management fee', '管理费',
     'Management fees paid to a non-resident.',
     '支付给非居民的管理费。',
     'ITA s45 / prevailing corporate rate', true, 40),
    ('technical_service_fee', 'Technical assistance or service fee', '技术协助/服务费',
     'Technical assistance and service fees for services rendered in Singapore.',
     '在新加坡境内提供的技术协助与服务费。',
     'ITA s45 / prevailing corporate rate', true, 50),
    ('rent_movable_property', 'Rent for movable property', '动产租金',
     'Rent or other payment for the use of movable property.',
     '为使用动产而支付的租金或其他款项。',
     'ITA s45D', true, 60);

COMMENT ON TABLE public.wht_natures IS
'WHT-1:付款性质字典 —— 一笔付给非居民的款【是什么】,而那决定适用哪一条法令。
**税率不在这里**,它在 wht_rates 上按生效期间挂着(与 tax_codes / tax_rates 同一条)。

★【这张表【少】两种性质,而那是刻意的,不是遗漏】★
【非居民董事酬金】(s45B,24%)与【非居民专业人士】(s45B,毛收入 15%)都是真实
存在的代扣类别,而且都比这里任何一种更常见。它们不在这里,因为**这套系统够不着
它们的收款人**:本刀的债务载体是 expenses,而 expenses 的往来对象是 supplier 或
employee —— 而 employees 【没有】税务居民身份这一列,payroll 那条路更是整条不经过
本刀。种一个系统结构上到不了的性质,是在字典里放一句假话。
两者按名记在 docs/known-issues.md 与 docs/accounting-policies.md,等它们真的到场。

★【这张表里的税率是【法律事实】,而这个仓库无权自己认定它】★
见 wht_rates 的表注释。';
