-- db/functions/guard_performance_review_write.sql
-- APR-9(2026-09-27,grilling Q1):**绩效评估的生命周期列只经函数写;提交之后,调薪与转正结论冻结。**
--
-- 【洞 —— Step 0 以 sandra@(cco)在一笔回滚的事务里实测】performance_reviews 的写策略只问 action.hr_reviews,
-- 列上没有任何守卫:cco 直连 INSERT 一张 status = 'submitted'、submitted_by = tim@、new_monthly_salary = 9999 的
-- 评估,再以自己调 approve_review —— review_approval_code 读的 submitted_by 说"CFO 是提交人",于是路由给 cco;
-- 四眼那一腿查的也是这个伪造的 submitted_by。批准成功,employees.monthly_salary 变成 9999,**没有 CFO**。
-- 同一条路还能在评估等 CFO 的时候改掉 new_monthly_salary,CFO 批的就不是他看见的那个数。
--
-- 【规则】一次【直连】写(row_security_active = true —— 属主路径 / SECURITY DEFINER 那些函数一律放行):
--   · INSERT 只许建草稿:status = 'draft',且生命周期列(submitted_* · approved_* · acknowledged_at · void_* ·
--     voided_*)全空 → 否则 REVIEW_DIRECT_INSERT_DRAFT_ONLY。
--   · UPDATE 不许动生命周期列(status、submitted_at / submitted_by、approved_at / approved_by、acknowledged_at、
--     void_reason / voided_at / voided_by)—— 任何状态下都不许:从草稿直接改成 submitted 就是那次伪造本身
--     → REVIEW_STATUS_THROUGH_FUNCTION_ONLY|<列>。它们只经 submit_review / approve_review / acknowledge_review /
--     void_review 写。
--   · 提交之后(OLD.status 不是 draft / self_review):调薪两列、转正结论、被评估人 → REVIEW_FROZEN_AFTER_SUBMIT|<列>。
--     被评估人不在 Tim 的原话里,是 Step 1 加的:一张已提交、带调薪的评估换一个被评估人,就是把加薪挪给另一个人。
-- 评分、总结、自评文字这些不动钱的列照旧由评估的写策略管。
-- 【INVOKER,故意的】row_security_active 要反映【调用者】—— guard_employee_salary_write 同形。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.guard_performance_review_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft'
           OR num_nonnulls(NEW.submitted_at, NEW.submitted_by, NEW.approved_at, NEW.approved_by,
                           NEW.acknowledged_at, NEW.void_reason, NEW.voided_at, NEW.voided_by) > 0 THEN
            RAISE EXCEPTION 'REVIEW_DIRECT_INSERT_DRAFT_ONLY';
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|status';
    ELSIF NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|submitted_at';
    ELSIF NEW.submitted_by IS DISTINCT FROM OLD.submitted_by THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|submitted_by';
    ELSIF NEW.approved_at IS DISTINCT FROM OLD.approved_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|approved_at';
    ELSIF NEW.approved_by IS DISTINCT FROM OLD.approved_by THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|approved_by';
    ELSIF NEW.acknowledged_at IS DISTINCT FROM OLD.acknowledged_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|acknowledged_at';
    ELSIF NEW.void_reason IS DISTINCT FROM OLD.void_reason THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|void_reason';
    ELSIF NEW.voided_at IS DISTINCT FROM OLD.voided_at THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|voided_at';
    ELSIF NEW.voided_by IS DISTINCT FROM OLD.voided_by THEN
        RAISE EXCEPTION 'REVIEW_STATUS_THROUGH_FUNCTION_ONLY|voided_by';
    END IF;

    IF OLD.status NOT IN ('draft', 'self_review') THEN
        IF NEW.new_monthly_salary IS DISTINCT FROM OLD.new_monthly_salary THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|new_monthly_salary';
        ELSIF NEW.salary_effective_date IS DISTINCT FROM OLD.salary_effective_date THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|salary_effective_date';
        ELSIF NEW.probation_outcome IS DISTINCT FROM OLD.probation_outcome THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|probation_outcome';
        ELSIF NEW.employee_id IS DISTINCT FROM OLD.employee_id THEN
            RAISE EXCEPTION 'REVIEW_FROZEN_AFTER_SUBMIT|employee_id';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_performance_review_write() IS
'APR-9(Q1):绩效评估的直连写 —— INSERT 只许建草稿(REVIEW_DIRECT_INSERT_DRAFT_ONLY);生命周期列(status · submitted_* · approved_* · acknowledged_at · void_* · voided_*)任何时候只经函数写(REVIEW_STATUS_THROUGH_FUNCTION_ONLY|列);提交之后调薪两列、转正结论、被评估人冻结(REVIEW_FROZEN_AFTER_SUBMIT|列)。INVOKER + row_security_active:属主路径放行。关的是 Step 0 实测的那条路 —— cco 直连插一张 submitted_by = CFO 的已提交评估、自己批掉、改了别人的月薪。';
