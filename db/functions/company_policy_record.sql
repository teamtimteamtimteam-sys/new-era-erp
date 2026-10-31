-- db/functions/company_policy_record.sql
-- ESG-2(Tim 2026-10-31 Q9 · Q10):登记一份公司制度,或它的一个新版本(p_supersedes_id = 它取代的那一版)。要 action.manage_esg(admin · cco · cfo)。
--   新版本:被取代的那一版必须还是「现在」的那一版(COMPANY_POLICY_ALREADY_SUPERSEDED),版本号不能与它相同(COMPANY_POLICY_VERSION_SAME);
--     同一笔事务里给它记 superseded_at。
--   按名拒:COMPANY_POLICY_TITLE_REQUIRED · COMPANY_POLICY_VERSION_REQUIRED · COMPANY_POLICY_OWNER_NOT_FOUND(负责人要是一名没删的员工)·
--     COMPANY_POLICY_DATES_REQUIRED · COMPANY_POLICY_REVIEW_BEFORE_EFFECTIVE · COMPANY_POLICY_DOCUMENT_REQUIRED · COMPANY_POLICY_NOT_FOUND。
--   日期都必填、没有默认(AGENTS.md:决定一段时间的日期不许默认成今天)。
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
CREATE OR REPLACE FUNCTION public.company_policy_record(p_supersedes_id uuid, p_title text, p_version text, p_owner_employee_id uuid, p_effective_date date, p_review_date date, p_document_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_old company_policies%ROWTYPE;
    v_id  uuid;
BEGIN
    PERFORM require_permission('action.manage_esg');
    IF p_title IS NULL OR btrim(p_title) = '' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_TITLE_REQUIRED';
    END IF;
    IF p_version IS NULL OR btrim(p_version) = '' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_VERSION_REQUIRED';
    END IF;
    IF p_owner_employee_id IS NULL OR NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = p_owner_employee_id AND e.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'COMPANY_POLICY_OWNER_NOT_FOUND';
    END IF;
    IF p_effective_date IS NULL OR p_review_date IS NULL THEN
        RAISE EXCEPTION 'COMPANY_POLICY_DATES_REQUIRED';
    END IF;
    IF p_review_date < p_effective_date THEN
        RAISE EXCEPTION 'COMPANY_POLICY_REVIEW_BEFORE_EFFECTIVE';
    END IF;
    IF p_document_ref IS NULL OR btrim(p_document_ref) = '' THEN
        RAISE EXCEPTION 'COMPANY_POLICY_DOCUMENT_REQUIRED';
    END IF;
    IF p_supersedes_id IS NOT NULL THEN
        SELECT * INTO v_old FROM company_policies WHERE id = p_supersedes_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'COMPANY_POLICY_NOT_FOUND';
        END IF;
        IF v_old.superseded_at IS NOT NULL THEN
            RAISE EXCEPTION 'COMPANY_POLICY_ALREADY_SUPERSEDED|%', v_old.version;
        END IF;
        IF lower(btrim(v_old.version)) = lower(btrim(p_version)) THEN
            RAISE EXCEPTION 'COMPANY_POLICY_VERSION_SAME|%', v_old.version;
        END IF;
    END IF;
    INSERT INTO company_policies (title, version, owner_employee_id, effective_date, review_date, document_ref, supersedes_id, recorded_by)
    VALUES (btrim(p_title), btrim(p_version), p_owner_employee_id, p_effective_date, p_review_date, btrim(p_document_ref), p_supersedes_id, auth.uid())
    RETURNING id INTO v_id;
    IF p_supersedes_id IS NOT NULL THEN
        UPDATE company_policies SET superseded_at = now() WHERE id = p_supersedes_id;
    END IF;
    RETURN jsonb_build_object('id', v_id, 'supersedes_id', p_supersedes_id);
END;
$function$;
