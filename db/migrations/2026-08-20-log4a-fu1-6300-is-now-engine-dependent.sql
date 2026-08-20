-- LOG-4a fu1(2026-08-20):6300 升 is_system —— 预检警告是对的,而它警告的那件事是真的。
--
-- 【为什么必须有这一支】record_export_freight_document 把 '6300' 【写死】在借方。
-- 而 6300 此前住在 accounts.sql 的【引导默认值】那一段:非 is_system,
-- 明写着"建账是操作员的地盘",check_mirrors 的科目比对带 WHERE is_system,
-- 于是它【不与线上逐行比对】—— 操作员改名、停用、甚至删掉它,没有任何东西会红,
-- 而下一张出口运费单会在 post_journal_entry 里撞上一个查不到的科目。
--
-- 【这是仓库自己立过的规矩,不是新判断】accounts.sql 里 1500 / 1510 / 3100 / 6700
-- 四行的注释各自写着「函数写死引用」而被 FIN-22b / FIN-23b 升成 is_system。
-- 6300 从这一刀起是同一类:它不再是"建账的人的地盘",它是引擎依赖。
--
-- 【为什么是第二支迁移,而不是并进上一支】上一支已经原子提交了,预检的警告
-- 是在它【应用之前】发出的、而我当时放行了(预检对科目码只警告不拒绝,理由写在
-- 它自己的抬头:它读的是执行前的状态,一支迁移完全可能自己 promote)。
-- 这一支就是那个 promote —— 记在这里,而不是假装本刀只有一支迁移。

BEGIN;

UPDATE public.accounts SET is_system = true WHERE code = '6300';

-- 断言,不祈祷:这一行必须真的动了,而且 6300 必须存在且在用。
DO $$
DECLARE v_ok boolean;
BEGIN
    SELECT is_system AND is_active AND account_type = 'expense'
      INTO v_ok FROM public.accounts WHERE code = '6300';
    IF v_ok IS NOT TRUE THEN
        RAISE EXCEPTION 'LOG4A_FU1_6300_NOT_PROMOTED —— 6300 必须存在、在用、是 expense、且 is_system';
    END IF;
END $$;

COMMIT;
