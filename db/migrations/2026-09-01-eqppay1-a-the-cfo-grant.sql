-- db/migrations/2026-09-01-eqppay1-a-the-cfo-grant.sql
-- EQP-PAY-1 第一项:CFO 拿到 module.finance.view 与 data.view_pay(Tim 裁定,已闭合)。
--
-- 【这一支只动数据,不动结构】role_permissions 上的两行 INSERT。授权是数据 ——
-- 这张表的抬头写着"重新分配权限就是这张表上的 INSERT/DELETE,永远不需要改代码
-- 或做迁移"。之所以仍然写成一支迁移而不是在界面上点两下,是因为【理由要跟着走】:
-- 一次界面点击留不下"为什么",而薪酬是谁能看见必须答得出来的那一类。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么 CFO 要看得见【个人】薪酬明细,而不是一个人力成本合计】
--
--   Tim 的裁定,逐字:**"the CFO reviews payroll expenditure"** ——
--   CFO 复核薪酬支出。
--
-- 【为什么合计不够】复核薪酬支出这件事,要能回答的是"这个月为什么多了两万" ——
-- 那个答案永远是某一个人的某一笔:一次调薪、一笔奖金、一个月中入职。一个合计
-- 数【看得见问题、看不见成因】,而一个看得见问题却查不到成因的复核不是复核。
--
-- 【它是个人敏感数据,所以这条理由必须写下来】员工报酬属于个人敏感信息。
-- 谁可以看见它,必须【在文字里答得出来】,而不是从一张授权表里反推 ——
-- 一张授权表说得出"谁能看",说不出"凭什么"。这一段与
-- docs/approvals.md §0 里那一段是同一件事的两处落点,两处都要在。
--
-- 【它顺带关闭一条已知问题】docs/known-issues.md 的 CFO-NO-FINANCE-VIEW:
-- cfo 没有 module.finance.view,于是 gl_control_reconciliation 与
-- management_pack_data 对它一律 PERMISSION_DENIED。那条记录自己写着处置是
-- "排进开账前的权限清理" —— 这一支就是那次清理的第一半。
--
-- 【只授这两个,不多授一个】R3 明说"不要授本条未点名的任何东西"。
-- 下面的自检把它做成机制:授完之后 cfo 恰好持有 4 个权限码,多一个就回滚。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, p.code
FROM public.roles r
JOIN public.permissions p ON p.code IN ('module.finance.view', 'data.view_pay')
WHERE r.code = 'cfo'
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 自检:授到了,而且【只】授到了 ──────────────────────────────────────────
-- 一支报告了却不拦的迁移不是闸(AGENTS.md)。这三段各拦一件事:
--   ① cfo 这个角色根本不在 → 上面那条 INSERT 会静默地插 0 行并"成功";
--   ② 两个码没有都落地;
--   ③ 落地了,但顺手多带了别的 —— R3 的"不要授未点名的东西"。
DO $eqppay1_a_check$
DECLARE
    v_missing text;
    v_total   integer;
    v_extra   text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.roles WHERE code = 'cfo' AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'CFO_ROLE_ABSENT'
          USING HINT = 'cfo 角色不存在,上面那条 INSERT 会插 0 行然后假装成功';
    END IF;

    SELECT string_agg(x.code, ', ') INTO v_missing
    FROM (VALUES ('module.finance.view'), ('data.view_pay')) AS x(code)
    WHERE NOT EXISTS (
        SELECT 1 FROM public.role_permissions rp
        JOIN public.roles r ON r.id = rp.role_id
        WHERE r.code = 'cfo' AND rp.permission_code = x.code);
    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'CFO_GRANT_INCOMPLETE|%', v_missing;
    END IF;

    SELECT count(*), string_agg(rp.permission_code, ', ' ORDER BY rp.permission_code)
    INTO v_total, v_extra
    FROM public.role_permissions rp
    JOIN public.roles r ON r.id = rp.role_id
    WHERE r.code = 'cfo';

    -- 授权前 cfo 持 2 个(module.purchasing.view / data.view_prices,CHAIN-CONFIG-1
    -- 定下的"批一张采购单的实测最小集")。加这两个恰好 4。
    IF v_total <> 4 THEN
        RAISE EXCEPTION 'CFO_GRANT_UNEXPECTED_TOTAL|%|%', v_total, v_extra
          USING HINT = 'R3:不要授本条未点名的任何东西。预期恰好 4 个权限码';
    END IF;
END
$eqppay1_a_check$;

COMMIT;
