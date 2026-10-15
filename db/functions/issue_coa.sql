-- db/functions/issue_coa.sql
-- MES-6b-2(2026-10-15,MES-0 Q67 · Q68 · Q90;MES-6b Step 0 Q10–Q13 · Q29–Q32,Tim):【签发一张分析证书】—— 铸号、组装、冻住,一笔事务。
--   门 action.issue_coa(cco · admin)。
--   ① 拒绝清单 coa_issue_blockers 的第一句原样抛出(没有最终化验 · 质量暂扣 · 开着的争议 · 称重不在校准期内 · 点名的单越限而没被接受 ·
--      单不是这一批的 · 这一批 × 这张单已有一张活证书 · 公司名没录)—— 与批次页摆出来的是同一份判据。
--   ② 签发人(Q13):纸上印「Issued by <名字>, <职位>」与签发时刻,不放签名图片。★ MES-7a-1(F9):解析搬进 coa_issuer() ——
--      PDF 路由在铸号之前、批次页的签发表单在按下之前问的是同一支,所以三处说的是同一个人。名字 = 员工的常用名、否则法定名;
--      职位 = positions.title。不是员工 → COA_ISSUER_NOT_AN_EMPLOYEE;没有职位 → COA_ISSUER_POSITION_MISSING|<名字>
--      (纸上不印半句,与 COMPANY_LEGAL_NAME_MISSING 同一条:缺一格就按名拒,不印空白)。次序不变:拒绝清单之后、铸号之前。
--   ③ 号 next_coa_code(按年无洞);快照 = coa_assemble 的那一份 + certificate(号、签发时刻)+ issuer(名字、职位)——
--      【由库组装一次,不收调用者递进来的一份】,PDF 只从它渲染(Q31)。
--   ④ 这一批 × 这张单(或不点名)最近作废、还没有替代品的那一张,replaced_by_coa_id 指向这一张(Q32)。
--   返回 {coa_id, code, status, issued_at, replaces, snapshot} —— 路由拿 snapshot 渲染,不再回读。
-- NOTE: introduced by db/migrations/2026-10-15-mes6b2-certificate-of-analysis.sql.
CREATE OR REPLACE FUNCTION public.issue_coa(p_output_batch_id uuid, p_sales_order_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_block    text[];
    v_issuer   jsonb;
    v_code     text;
    v_now      timestamptz;
    v_snap     jsonb;
    v_id       uuid := gen_random_uuid();
    v_replaces text;
BEGIN
    PERFORM require_permission('action.issue_coa');
    -- 同一批的两次签发排队(唯一索引是第二道)
    PERFORM 1 FROM output_batches b WHERE b.id = p_output_batch_id FOR UPDATE;

    v_block := coa_issue_blockers(p_output_batch_id, p_sales_order_id);
    IF cardinality(v_block) > 0 THEN
        RAISE EXCEPTION '%', v_block[1];
    END IF;

    v_issuer := coa_issuer();

    v_code := next_coa_code();
    v_now := clock_timestamp();
    v_snap := coa_assemble(p_output_batch_id, p_sales_order_id)
        || jsonb_build_object('certificate', jsonb_build_object('id', v_id, 'code', v_code, 'status', 'issued', 'issued_at', v_now),
                              'issuer', jsonb_build_object('name', v_issuer ->> 'name', 'position', v_issuer ->> 'position'));

    INSERT INTO certificates_of_analysis (id, code, output_batch_id, sales_order_id, governing_assay_id, status,
                                          issued_at, issued_by, snapshot)
    VALUES (v_id, v_code, p_output_batch_id, p_sales_order_id, (v_snap -> 'assay' ->> 'id')::uuid, 'issued',
            v_now, auth.uid(), v_snap);

    UPDATE certificates_of_analysis c SET replaced_by_coa_id = v_id
     WHERE c.id = (SELECT x.id FROM certificates_of_analysis x
                    WHERE x.output_batch_id = p_output_batch_id AND x.sales_order_id IS NOT DISTINCT FROM p_sales_order_id
                      AND x.status = 'void' AND x.replaced_by_coa_id IS NULL AND x.id <> v_id
                    ORDER BY x.voided_at DESC, x.code DESC
                    LIMIT 1)
    RETURNING c.code INTO v_replaces;

    RETURN jsonb_build_object('coa_id', v_id, 'code', v_code, 'status', 'issued', 'issued_at', v_now,
                              'replaces', v_replaces, 'snapshot', v_snap);
END;
$function$
