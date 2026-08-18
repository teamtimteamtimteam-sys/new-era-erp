-- PAYEE-1a fu1:把 employee_id 补进两份【手写的不可变列清单】
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【先说清楚这一刀【不是】在补什么洞 —— 我一开始说错了,实测纠正】
-- 写这支迁移时我以为:两份逐列枚举漏了 employee_id,所以一条已过账的应付
-- 可以被悄悄改挂到另一个人名下。**那是错的。**
--
-- guard_expense_mutation / guard_payment_mutation 在列清单【之后】还有一句
-- 兜底:
--     IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
--             AND OLD.reversed_by_* IS NULL AND NEW.reversed_by_* IS NOT NULL)
--     THEN RAISE ... _IMMUTABLE
-- 也就是说,**任何一次不是"过账→冲销"的 UPDATE 都会被拒**,与改了哪一列无关。
-- 实测(回滚型探针,2026-08-18):把守卫换成【不含 employee_id】的版本,
-- `UPDATE expenses SET employee_id = …` 依然抛 EXPENSE_IMMUTABLE。
--
-- 【那这一刀还做不做?做 —— 但理由是"清单要完整",不是"有洞"】
-- 那份逐列枚举是给读的人看的:它声称自己列出了所有不可改的列。
-- 少一列,下一个人会合理地推断那一列是可以改的 ——
-- **一份声称完整而实际不完整的清单,本身就是一句假话**,哪怕兜底救了它。
-- 而且兜底与清单是两道独立的闸:哪天有人为了某个正当需求放宽兜底
-- (例如允许补一个 notes),清单立刻就是唯一的那道。
--
-- 【留下这段自我更正,而不是把标题改干净】
-- 本仓库反复付账的正是"注释断言了一个不可能发生的隐患"。我差点把它写进
-- 一支迁移的抬头并就此定案;是故障注入把它翻出来的(fixture 90 的 J 臂
-- 在【去掉 employee_id 的守卫】下依然通过 —— 那一刻它说的不是"J 没用",
-- 而是"你以为的那个洞不在那里")。
--
-- 【所以 J 臂断言的是什么】它断言 employee_id 在两张不可变凭证上【改不动】,
-- 这一条为真,且由兜底与清单共同保证。它【不】证明本迁移补上了一个洞。
--
-- 【两个函数体取自线上,只插入一行】手抄二十几行枚举,抄错一个列名
-- 就等于悄悄放开那一列,而没有任何东西会报错。
--
-- 镜像:db/tables/{expenses,payments}.sql;行为断言:fixture 90 的 J 臂。
-- ════════════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.guard_expense_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.expense_date        IS DISTINCT FROM OLD.expense_date
       OR NEW.account_code        IS DISTINCT FROM OLD.account_code
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
       OR NEW.payment_status      IS DISTINCT FROM OLD.payment_status
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       -- PAYEE-1a fu1:往来对象的另一半,补进这份清单是为了【让清单完整】。
       -- 注意:即使少了这一行,下面那句"只放行 过账→冲销"的兜底也会拒掉
       -- 任何别的 UPDATE(实测过)—— 所以这不是在补洞,是在让这份
       -- 声称完整的枚举名副其实。两道闸各自独立,兜底放宽时清单就是唯一那道。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
       OR NEW.payee_name          IS DISTINCT FROM OLD.payee_name
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_expense IS NULL AND NEW.reversed_by_expense IS NOT NULL) THEN
        RAISE EXCEPTION 'EXPENSE_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.guard_payment_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE';
    END IF;
    IF NEW.id                  IS DISTINCT FROM OLD.id
       OR NEW.code                IS DISTINCT FROM OLD.code
       OR NEW.direction           IS DISTINCT FROM OLD.direction
       OR NEW.counterparty_type   IS DISTINCT FROM OLD.counterparty_type
       OR NEW.customer_id         IS DISTINCT FROM OLD.customer_id
       OR NEW.supplier_id         IS DISTINCT FROM OLD.supplier_id
       -- PAYEE-1a fu1:同上 —— 让清单完整;兜底本已拒掉非冲销的 UPDATE。
       OR NEW.employee_id         IS DISTINCT FROM OLD.employee_id
       OR NEW.amount_ccy          IS DISTINCT FROM OLD.amount_ccy
       OR NEW.currency            IS DISTINCT FROM OLD.currency
       OR NEW.fx_rate             IS DISTINCT FROM OLD.fx_rate
       OR NEW.amount_base          IS DISTINCT FROM OLD.amount_base
       OR NEW.bank_account_code   IS DISTINCT FROM OLD.bank_account_code
       OR NEW.payment_date        IS DISTINCT FROM OLD.payment_date
       OR NEW.notes               IS DISTINCT FROM OLD.notes
       OR NEW.journal_entry_id    IS DISTINCT FROM OLD.journal_entry_id
       OR NEW.created_at          IS DISTINCT FROM OLD.created_at
       OR NEW.created_by          IS DISTINCT FROM OLD.created_by
    THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE';
    END IF;
    IF NOT (OLD.status = 'posted' AND NEW.status = 'reversed'
            AND OLD.reversed_by_payment IS NULL AND NEW.reversed_by_payment IS NOT NULL) THEN
        RAISE EXCEPTION 'PAYMENT_IMMUTABLE';
    END IF;
    RETURN NEW;
END;
$function$;

COMMIT;
