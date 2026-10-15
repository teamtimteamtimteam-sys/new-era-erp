-- db/functions/coa_issuer.sql
-- MES-7a-1(2026-10-15,MES-7a Step 0 Q8 · F9,Tim):【这个账号签发一张分析证书时,纸上会印成谁】—— 签发人的【唯一】一份解析。
--   issue_coa 用它决定快照里的 issuer;PDF 路由在【铸号之前】用它把名字与职位填进字体覆盖检查(MES6B2-ISSUED-WITHOUT-BYTES 漏掉的那一格:
--   此前名字与职位要到签发那一刻才进快照,于是一个纸上画不出来的字会在号已铸之后才让渲染失败);批次页的签发表单用它说出
--   "You will be named as <名字>, <职位>"。一份实现,三个读者。
--   名字 = 这个账号的员工(current_user_employee:主账号或 employee_accounts)的常用名、否则法定名;职位 = 他的 positions.title。
--   不是员工 → COA_ISSUER_NOT_AN_EMPLOYEE;没有职位 → COA_ISSUER_POSITION_MISSING|<名字>(与 issue_coa 原来那两句逐字相同,次序也相同)。
--   门 action.issue_coa(只有签发的人需要知道自己会被印成谁;不持码的人在 issue_coa 那里按码拒,不在这里被告知一个名字)。
--   返回 {employee_id, name, position}。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql (the resolution moved here from issue_coa).

CREATE OR REPLACE FUNCTION public.coa_issuer()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp      uuid;
    v_name     text;
    v_position text;
BEGIN
    PERFORM require_permission('action.issue_coa');
    v_emp := current_user_employee();
    IF v_emp IS NULL THEN
        RAISE EXCEPTION 'COA_ISSUER_NOT_AN_EMPLOYEE';
    END IF;
    SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name), NULLIF(btrim(p.title), '')
      INTO v_name, v_position
      FROM employees e LEFT JOIN positions p ON p.id = e.position_id
     WHERE e.id = v_emp;
    IF v_position IS NULL THEN
        RAISE EXCEPTION 'COA_ISSUER_POSITION_MISSING|%', v_name;
    END IF;
    RETURN jsonb_build_object('employee_id', v_emp, 'name', v_name, 'position', v_position);
END;
$function$;
