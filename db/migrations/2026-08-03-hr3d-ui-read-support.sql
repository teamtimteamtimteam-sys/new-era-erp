-- db/migrations/2026-08-03-hr3d-ui-read-support.sql
-- HR cut 3d(界面切)里发现的两条读路径缺口。屏幕本身不进数据库,但两块屏幕
-- 在【零 HR 权限的评估人】(部门经理)面前撞上了同一堵墙:
--
-- 1)评级档位目录读不到。review_rating_scale 的 SELECT 要 module.hr.view,而
--    set_review_conclusion 要求评估人从档位里挑一个 —— 零 HR 权限的部门经理
--    在界面上连可选项都列不出来(写入本身走 SECURITY DEFINER,反而写得进去,
--    这正说明拦错了地方)。本表自己的文件头写着"与 leave_types 同一套路",
--    而 leave_types 的 SELECT 是 USING (true):每个员工都要知道有哪些假可以请。
--    同一个理由在这里成立两次:评估人要知道有哪些档位可以评;被评估人在批准
--    之后读得到 rating_code,而那一档的【名字】在这张表里。
--    档位目录是配置的标签,不含任何一个人的任何数据。
--
-- 2)评估人读不到被评估人的名字。employees 的 SELECT 是 module.hr.view 或本人,
--    employee_directory 是 SECURITY INVOKER、继承同一条 —— 于是 /my-reviews
--    列表里只剩一串 uuid。修法沿用 cut 2b / HR-3c 的属主权限视图:
--    行谓词把基表那条 "select as reviewer" 策略【原样】写进视图体,
--    【列清单就是权限边界】—— 工号、姓名、职务、部门名、评估轮名;
--    没有薪酬、没有证件号、没有银行、没有在职状态。

BEGIN;

-- ════════════════════════════════════════════════════════════════════════════
-- 1. 评级档位目录人人可读(leave_types 平级)
-- ════════════════════════════════════════════════════════════════════════════
-- 策略名保持不变(与 leave_types 同名同形);写入三条一个字不动,仍是 module.hr.edit。
DROP POLICY "review_rating_scale select by permission" ON public.review_rating_scale;
CREATE POLICY "review_rating_scale select by permission"
    ON public.review_rating_scale AS PERMISSIVE FOR SELECT TO authenticated
    -- 档位目录人人可读:评估人要挑档位,被评估人要读得出自己那一档的名字
    USING (true);

-- ════════════════════════════════════════════════════════════════════════════
-- 2. 评估人视角的被评估人名录 —— 属主权限视图,窄到只够画一张列表
-- ════════════════════════════════════════════════════════════════════════════
-- 【视图体里把谓词原样加回来】(cut 2b 铁律):我是这一行的评估人。
-- current_user_employee() 为 NULL 或 reviewer 为 NULL 时,= 比较得 NULL、行不返回,
-- 与 is_reviewer_of 的"任何一边 NULL 都判 false"同一语义。
CREATE VIEW public.my_review_subjects WITH (security_invoker = off) AS
 SELECT r.id AS review_id,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    e.job_title,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    c.name AS cycle_name
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id = current_user_employee();

COMMENT ON VIEW public.my_review_subjects IS
    '评估人读得到的被评估人名录:每份"我评的评估"一行。列清单就是权限边界 —— 只有名录与评估轮名,没有任何受限数据。';

COMMIT;
