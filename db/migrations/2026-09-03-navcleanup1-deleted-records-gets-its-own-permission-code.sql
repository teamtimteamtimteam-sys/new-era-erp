-- NAV-CLEANUP-1 ①:被删记录拿到【属于它自己的】权限码。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【为什么这必须是一次【铸码】,而不是换一个谓词写法 —— 这是一条证明】★★
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的裁定:/settings/deleted 只给 admin 与 auditor,其余角色维持 UI-FIX-1 的样子。
--
-- 那在【现有的权限词汇里表达不出来】,而这不是"没想到写法",是一条定理:
--
--   ① lib/modules.ts 的 allows() 是【单调】的 —— 它每一项都是 perms.includes(...),
--      只用 ∧ 与 ∨ 组合。所以给一个人【加】权限,永远不会把 true 变成 false。
--   ② 实测 live 授权:gm 持有 auditor 那 17 个码的【全部】,另外还多 16 个
--      (全部 .edit 码 + data.view_banking + data.view_reviews);
--      auditor 没有任何一个码是 gm 缺的。即 perms(gm) ⊋ perms(auditor)。
--   ③ 由 ① 与 ②:任何放 auditor 进来的谓词,【必然】也放 gm 进来。
--
-- 于是要么接受 gm 一起进来(Tim 明确否掉:一份【已经过期】的文档仍把 gm 写成 MD,
-- 而那个人已被另行裁定为只读 —— 今天授给 gm 等于在发账号那天把他放进来),
-- 要么【改词汇】。改词汇。
--
-- 【为什么这也是【对】的修法,不只是可行的那个】/deleted 一直骑在一个属于别人的
-- 判据上:先是六个模块码的并集(AUDEL-3),后是 action.manage_permissions(UI-FIX-1)。
-- 它已经搬进设置并被裁定为审计性质,那么"谁可以打开它"就是它自己的问题。
-- ★ 此后它的可见集不会再因为【别人的】权限变动而被顺带改掉。★
--
-- 【这张表为什么是"迁移级"的】见 db/tables/permissions.sql 抬头:一个权限码只有在
-- 有代码去检查它的时候才有意义,所以扩充目录天然与代码同行。**角色与授权是数据,
-- 目录不是。**
--
-- 【不动任何策略,不动任何视图】deleted_records 每一行自带的那个 permission 列
-- 一个字没改 —— 本码只回答"这一页对你有没有意义",行一级的过滤仍在视图里。
-- 【没有新列】所以没有遮蔽表的授权/伴生视图要跟着改。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order)
VALUES (
    'data.view_deleted', 'data',
    'View deleted records', '查看已删除记录',
    'The deleted-records register: what was removed, by whom and why, across every module. Audit-natured — not a day-to-day permission.',
    '被删记录台账:跨模块地看"什么被删了、谁删的、为什么"。审计性质 —— 不是一条日常权限。',
    260
);

-- ★ 只授 admin 与 auditor。**gm 不授** —— 见抬头。★
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'data.view_deleted'
FROM public.roles r
WHERE r.code IN ('admin', 'auditor') AND r.deleted_at IS NULL;

-- 【断言,不是注释】授出去的必须【恰好】是 2 行。角色表将来若少了一个 code,
-- 上面那句 INSERT 会静默地少插一行,而"少一行"与"本来就这样"长得一模一样。
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM public.role_permissions WHERE permission_code = 'data.view_deleted';
    IF n <> 2 THEN
        RAISE EXCEPTION 'NAVCLEANUP1_GRANT_COUNT|expected 2 (admin, auditor), got %', n;
    END IF;
END $$;

COMMIT;
