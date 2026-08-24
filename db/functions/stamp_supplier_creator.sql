-- db/functions/stamp_supplier_creator.sql
-- SOD-1:让 suppliers.created_by 真的落下来 —— 没有它,控制②是一条永不触发的规矩
-- (实测:线上 8 行全为 NULL,列无默认值,app/suppliers/new/actions.ts 不传它)。
--
-- 【为什么不是 DEFAULT auth.uid()】这一列有 FK -> auth.users(id),而 db/fixtures 里
-- 有 89 份会插 suppliers/customers 并把 claims 设成一个随机 uuid —— 那个 uuid 在
-- auth.users 里没有行,加 DEFAULT 会让它们整片撞 FK 违反。
-- 所以判据取自【外键自己的条件】:auth.uid() 是不是一个真的账号。是就落笔
-- (真人的每一次创建都留下主语,直连 INSERT 也一样),不是就留 NULL —— 那是实话。
--
-- NOTE: introduced by db/migrations/2026-08-24-sod1-one-rule-two-questions.sql.

CREATE OR REPLACE FUNCTION public.stamp_supplier_creator()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.created_by IS NULL
       AND auth.uid() IS NOT NULL
       AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = auth.uid())
    THEN
        NEW.created_by := auth.uid();
    END IF;
    RETURN NEW;
END;
$function$;