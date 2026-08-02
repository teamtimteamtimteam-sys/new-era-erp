-- db/migrations/2026-08-05-ops1-system-accounts.sql
-- OPS-1:把"自动记账引擎点名依赖的科目"变成 schema 里说得出来的事实,并据此上锁。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【来由】OPS-1 的重建实验发现:db/tables/accounts.sql 一条种子都没有,38 个科目
-- 全靠四个迁移文件播下。也就是说,照镜像重建出来的库【一个会计科目都没有】,
-- 整个财务模块过不了一笔账。修镜像的时候必须先回答一个问题:哪些科目是【代码
-- 点名依赖的】、哪些是记账员可以随手加的?
--
-- 答案不是靠猜的 —— 把 db/functions、db/views、db/tables 里出现的四位数字面量
-- 全部扫出来,逐个核对:22 个,全部是 'account_code' 参数,全部在 accounts 里,
-- 没有一个是年份或数量误伤。另外扫了 app/ 与 lib/ 的 TypeScript,只出现 1000 与
-- 1010(银行账户选择器),两个都已在名单内;剩下 16 个科目【在代码里一次都没被
-- 点过名】,所以它们确实是可扩展的那一半。
--
-- 【为什么顺手上锁,而不只是打个标记】
-- 这一列恰好精确地识别出"删掉就会让过账在运行时炸掉、而且炸在离原因很远的地方"
-- 的那些行。既然已经知道是哪 22 行,就不该把"别删 6120"留成一句口头约定 ——
-- 规则在数据库里强制,这是本项目的立身之本。
--   * 不能删
--   * 不能改 code(引擎认的是 code,不是名字)
--   * 不能停用(is_active=false 与删掉对过账是同一个后果)
--   * 不能把 is_system 摘掉(否则先摘再删,锁形同虚设 —— 同 guard_system_role)
--   * 名字(name_en/name_zh)与备注【照旧可改】:引擎不看它们。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.accounts
    ADD COLUMN is_system boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.accounts.is_system IS
    '自动记账引擎按 code 点名依赖的科目。删除 / 改 code / 停用 / 摘掉本标记,四件事都被 '
    'guard_system_account 拦下 —— 任何一件都会让过账在运行时失败,且错误离原因很远。'
    '名字与备注可改。名单由 check_mirrors.py 扫描镜像里的科目字面量自动校验,不靠人工维护。';

-- 22 个:扫描 db/functions + db/views + db/tables 得到,逐个有据可查(见 OPS-1 报告)。
UPDATE public.accounts SET is_system = true
WHERE code IN (
    '1000',  -- bank_native_currency, post_payroll_period, record_expense, record_payment, 两个 bank 视图, 四个 CHECK
    '1010',  -- 同上(USD 侧)
    '1100',  -- record_output_sale, record_payment
    '1200',  -- allocate_processing_costs, inventory_ledger_triggers, post_stocktake, reprice_inbound_batch
    '1220',  -- allocate_processing_costs, inventory_ledger_triggers, post_stocktake, record_output_sale
    '1300',  -- apply_prepayment, record_payment
    '2000',  -- apply_prepayment, record_expense, record_payment, reprice_inbound_batch
    '2200',  -- finance_journal_triggers, post_payroll_period
    '2400',  -- post_payroll_period
    '4000',  -- record_output_sale
    '5000',  -- allocate_processing_costs, record_output_sale, reprice_inbound_batch
    '5100',  -- finance_journal_triggers(labour)
    '5110',  -- finance_journal_triggers(electricity)
    '5120',  -- finance_journal_triggers(gas)
    '5130',  -- finance_journal_triggers(depreciation)
    '5140',  -- finance_journal_triggers(consumables)
    '5150',  -- finance_journal_triggers(waste_treatment)
    '5190',  -- finance_journal_triggers 的 ELSE 兜底 —— 少了它,未知成本类型全都过不了账
    '5200',  -- inventory_ledger_triggers, post_stocktake
    '6100',  -- post_payroll_period
    '6110',  -- post_payroll_period
    '6120'   -- pay_medical_claim
);

-- 守卫。四条规则一个函数,错误串沿用 CODE|detail 约定。
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

COMMIT;
