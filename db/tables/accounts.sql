-- db/tables/accounts.sql
-- Chart of accounts (bilingual names). NO soft delete: posted journals must
-- always resolve their account — deactivate (is_active=false) instead.
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【混合表:一半是安装种子,一半是记账员的地盘】(OPS-1 定的规矩)
--   is_system = true  的 22 行 = 自动记账引擎【按 code 点名依赖】的科目。
--     它们与代码版本绑定,本文件【逐行跟踪线上】,check_mirrors.py 逐行比对,
--     任何缺失 / 多余 / 内容不符都判失败。名单不靠人工维护 —— check_mirrors 会
--     扫描 db/functions、db/views、db/tables 里的四位科目字面量,发现某个被点名
--     的 code 没打 is_system 就直接报错。
--   其余科目(GST、权益、租金、水电……)是【正常可扩展的会计科目表】,由建账的人
--     按需增删,线上与本文件不一致是【正常的】,不比对。
--
-- 【为什么 22 行删不得】见 guard_system_account:删除 / 改 code / 停用 / 摘标记
--   四件事都拦下。任何一件都会让过账在运行时失败,而且错误离原因很远
--   (例如少了 5190,finance_journal_triggers 的 ELSE 兜底就没有落点,
--    所有未知成本类型的加工单一律过不了账)。名字与备注照旧可改。
-- ════════════════════════════════════════════════════════════════════════════
--
-- NOTE: introduced by db/migrations/2026-07-05-phase3-cut1-finance-foundation.sql;
--       seeded further by phase3-s2a-expenses / hr1a-hr-core / hr2b-leave-exceptions;
--       is_system + guard added by db/migrations/2026-08-05-ops1-system-accounts.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.accounts (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code         text NOT NULL UNIQUE,
    name_en      text NOT NULL,
    name_zh      text NOT NULL,
    account_type text NOT NULL CHECK (account_type IN ('asset','liability','equity','revenue','cogs','expense')),
    is_active    boolean NOT NULL DEFAULT true,
    notes        text,
    created_by   uuid DEFAULT auth.uid(),
    updated_by   uuid DEFAULT auth.uid(),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    -- ── OPS-1 追加(ALTER 加的列排在末尾)────────────────────────────────────
    -- 自动记账引擎按 code 点名依赖的科目。见文件头与 guard_system_account。
    is_system    boolean NOT NULL DEFAULT false,
    -- ── FIN-3 追加(ALTER 加的列排在末尾)────────────────────────────────────
    -- 货币性科目(现金、应收、应付)才做期末重估;存货/预付/损益类保持历史汇率。
    -- 分类错一个,资产负债表每期都悄悄错 —— 所以是数据,不是代码里的名单。
    -- 【没有 DEFAULT,故意的】建新科目必须明说货币性与否 —— 明年新增一个应付科目,
    -- 不该因为没人问过就悄悄跳过重估(FIN-3 追问的第 1 条)。
    is_monetary  boolean NOT NULL
);

CREATE TRIGGER trg_accounts_updated_at
    BEFORE UPDATE ON public.accounts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 引擎点名的科目:不能删、不能改 code、不能停用、不能摘掉标记。
-- 【摘标记那一条不是多余的】—— 少了它,先 is_system=false 再 DELETE 就把锁绕过去了
-- (与 guard_system_role 防的是同一个失效模式)。
CREATE OR REPLACE FUNCTION public.guard_system_account()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.is_system THEN
            RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED|%', OLD.code;
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.is_system THEN
        -- 引擎认的是 code
        IF NEW.code IS DISTINCT FROM OLD.code THEN
            RAISE EXCEPTION 'SYSTEM_ACCOUNT_CODE_IMMUTABLE|%', OLD.code;
        END IF;
        -- 停用与删除对过账是同一个后果
        IF NOT NEW.is_active THEN
            RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED|%', OLD.code;
        END IF;
        -- 摘掉标记 = 先摘再删,那把上面两条一起绕过去了
        IF NOT NEW.is_system THEN
            RAISE EXCEPTION 'SYSTEM_ACCOUNT_PROTECTED|%', OLD.code;
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_accounts_system_protected
    BEFORE UPDATE OR DELETE ON public.accounts
    FOR EACH ROW EXECUTE FUNCTION public.guard_system_account();

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "accounts select by permission"
    ON public.accounts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);

CREATE POLICY "accounts insert by permission"
    ON public.accounts
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "accounts update by permission"
    ON public.accounts
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.finance.edit'::text)) WITH CHECK (has_permission('module.finance.edit'::text));

CREATE POLICY "accounts delete by permission"
    ON public.accounts
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.finance.edit'::text));

-- ─────────────────────────────────────────────────────────────────────────────
-- 【安装种子:22 个引擎依赖科目】。逐行跟踪线上,check_mirrors 逐行比对。
-- 括号里是点名它的对象 —— 这份名单是有据可查的,不是分类学。
-- 其余 14 个科目(1210/1400/2100/3000/3100/4100/4900/6000/6200/
-- 6300/6400/6500/6600/6900)【故意不在这里】:它们是建账的人的地盘。
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
    ('1000', 'Cash at Bank – SGD', '现金及银行-SGD', 'asset', true, true),               -- bank_native_currency, record_payment, record_expense, post_payroll_period, 两个 bank 视图, 四处 CHECK
    ('1010', 'Cash at Bank – USD', '现金及银行-USD', 'asset', true, true),               -- 同上(USD 侧)
    ('1100', 'Accounts Receivable', '应收账款', 'asset', true, true),                    -- record_output_sale, record_payment
    ('1200', 'Inventory – Raw Materials', '存货-原料', 'asset', true, false),             -- allocate_processing_costs, inventory_ledger_triggers, post_stocktake, reprice_inbound_batch
    ('1220', 'Inventory – Finished Goods', '存货-成品', 'asset', true, false),            -- allocate_processing_costs, inventory_ledger_triggers, post_stocktake, record_output_sale
    ('1300', 'Prepayments', '预付款项', 'asset', true, false),                            -- apply_prepayment, record_payment
    ('2000', 'Accounts Payable', '应付账款', 'liability', true, true),                   -- apply_prepayment, record_expense, record_payment, reprice_inbound_batch
    ('2200', 'Accrued Expenses', '应计费用', 'liability', true, true),                   -- finance_journal_triggers, post_payroll_period
    ('2300', 'Net Salary Payable', '应付净薪', 'liability', true, true),           -- post_payroll_period / pay_payroll_lines(FIN-4)
    ('2400', 'CPF Payable', '公积金应付', 'liability', true, true),                      -- post_payroll_period
    ('4000', 'Sales – Metal Products', '销售收入-金属产品', 'revenue', true, false),      -- record_output_sale
    ('5000', 'Material Cost', '材料成本', 'cogs', true, false),                           -- allocate_processing_costs, record_output_sale, reprice_inbound_batch
    ('5100', 'Processing – Labour', '加工成本-人工', 'cogs', true, false),                -- finance_journal_triggers(labour)
    ('5110', 'Processing – Electricity', '加工成本-电力', 'cogs', true, false),           -- finance_journal_triggers(electricity)
    ('5120', 'Processing – Gas', '加工成本-气体', 'cogs', true, false),                   -- finance_journal_triggers(gas)
    ('5130', 'Processing – Depreciation', '加工成本-折旧', 'cogs', true, false),          -- finance_journal_triggers(depreciation)
    ('5140', 'Processing – Consumables', '加工成本-耗材', 'cogs', true, false),           -- finance_journal_triggers(consumables)
    ('5150', 'Processing – Waste Treatment', '加工成本-废物处理', 'cogs', true, false),   -- finance_journal_triggers(waste_treatment)
    ('5190', 'Processing – Other', '加工成本-其他', 'cogs', true, false),                 -- finance_journal_triggers 的 ELSE 兜底
    ('5200', 'Inventory Adjustment', '存货调整损益', 'cogs', true, false),                -- inventory_ledger_triggers, post_stocktake
    ('6100', 'Salaries & Wages', '工资薪金', 'expense', true, false),                     -- post_payroll_period
    ('6110', 'CPF – Employer', '公积金-雇主部分', 'expense', true, false),                -- post_payroll_period
    ('6120', 'Staff Welfare & Medical', '员工福利与医疗', 'expense', true, false),        -- pay_medical_claim
    -- FIN-3:汇兑损益拆【已实现/未实现】(新加坡税务口径不同,Tim 已拍板)。
    -- 7100 已实现:只由【结算时点】的差额进(record_payment);
    -- 7110 未实现:只由【期末重估】进(revalue_foreign_balances);
    --              行内转账(实际金额两边入账,无 FX 行)的折算差异也最终落在这里。
    ('1500', 'Fixed Assets – Equipment', '固定资产-设备', 'asset', true, false),        -- record_expense 资本分支借方(FIN-22b 升 system:函数写死引用)
    ('1510', 'Accumulated Depreciation', '累计折旧', 'asset', true, false),               -- depreciate_fixed_assets 贷方 / dispose 解除(FIN-22b 同上)
    ('6700', 'Depreciation Expense', '折旧费用', 'expense', true, false),                    -- depreciate_fixed_assets 默认落点(FIN-22)
    ('7100', 'FX Gain/Loss — Realised', '汇兑损益(已实现)', 'expense', true, false),      -- record_payment
    ('7110', 'FX Gain/Loss — Unrealised', '汇兑损益(未实现)', 'expense', true, false),
    ('7200', 'Gain/Loss on Asset Disposal', '资产处置损益', 'expense', true, false);   -- dispose_fixed_asset(FIN-22,与 7100/7110 同形:两个方向都过)
-- ═══════════════════════════════════════════════════════════════════════════
-- 【引导默认值 / BOOTSTRAP DEFAULT —— 非 is_system 行】(FIN-3-fu2)
-- 全新安装该有的完整科目表:权益、GST、固定资产、在制品、常规收入与费用。
-- 一个建不出权益部分的库配不平,不算一个能用的安装。
-- 这一段【不与线上逐行比对】(check_mirrors 的 accounts 比对带 WHERE is_system):
-- 建账是操作员的地盘,他们之后加科目、改名,永远不该把门变红。
-- 【6600 'FX Gain/Loss' 故意不在这里】—— 它是 7100/7110 之前的一次失误,已停用;
-- 第三个汇兑桶会让人从下拉里顺手选错,不许它在每次全新安装里复活。
-- ═══════════════════════════════════════════════════════════════════════════
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
    ('1210', 'Inventory – Work in Progress', '存货-在制品', 'asset', false, false),
    ('1400', 'GST Input Tax', 'GST 进项税', 'asset', false, true),        -- 对 IRAS 的定额债权:货币性
    ('2100', 'GST Output Tax', 'GST 销项税', 'liability', false, true),   -- 对 IRAS 的定额义务:货币性
    ('3000', 'Share Capital', '实收资本', 'equity', false, false),
    ('3100', 'Retained Earnings', '留存收益', 'equity', false, false),
    ('4100', 'Disposal Service Income', '处置服务收入', 'revenue', false, false),
    ('4900', 'Other Income', '其他收入', 'revenue', false, false),
    ('6000', 'Rent', '租金', 'expense', false, false),
    ('6200', 'Utilities', '水电杂费', 'expense', false, false),
    ('6300', 'Transport & Logistics', '运输物流费', 'expense', false, false),
    ('6400', 'Professional Fees', '专业服务费', 'expense', false, false),
    ('6500', 'Bank Charges', '银行手续费', 'expense', false, false),
    ('6900', 'Miscellaneous', '杂项开支', 'expense', false, false);    -- revalue_foreign_balances
COMMENT ON COLUMN public.accounts.is_monetary IS
    '货币性科目 = 期末按收盘中间价重估外币余额(FIN-3)。非货币(存货/预付/损益)保持历史汇率,重估一个不碰。';

-- 列注释:说明写在数据库里,重建出来的库也带着它们(OPS-1 补齐)。
COMMENT ON COLUMN public.accounts.is_system IS
    '自动记账引擎按 code 点名依赖的科目。删除 / 改 code / 停用 / 摘掉本标记,四件事都被 guard_system_account 拦下 —— 任何一件都会让过账在运行时失败,且错误离原因很远。名字与备注可改。名单由 check_mirrors.py 扫描镜像里的科目字面量自动校验,不靠人工维护。';
