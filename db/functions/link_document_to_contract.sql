-- db/functions/link_document_to_contract.sql
-- CONTRACT-1:把一张单据挂到一份合同上,并**当场把在效条款抄下来**。
--
-- ★★【这支函数就是"登记簿不是文件柜"那句话的实现】★★
--   两条拒绝,而**两条都是【不一致】,不是【政策】**(Tim 2026-08-29 裁定 A1):
--     · CONTRACT_COUNTERPARTY_MISMATCH —— 合同是这家、单据是那家。
--       没有人会"故意"这么挂;这是一次录入错误,拒它不需要任何裁定。
--     · CONTRACT_NOT_ACTIVE —— 一份草稿/已终止的合同不该有新单据挂上来。
--   这正是 AGENTS.md 给 ALLOC_CURRENCY_MISMATCH(不一致 → 该拒)与
--   ALLOC_EXCEEDS(政策 → 先问这条规矩对不对)划的那条线。
--
-- ★【刻意【不】拒的那一条,写在这里而不是留成沉默】★
--   **单据日期落在合同期之外,本函数不拒。** 回填一张早于合同生效日的单据是
--   正当操作;而"能不能背靠一份尚未生效的合同下单"是一个**没有人裁过**的问题。
--   没有裁定就按名拒,买到的是绕过它的办法,不是控制(WHT-1 那条同款)。
--   要改这一条,先要有一次裁定,而不是先加一句 IF。
--
-- ★【抄写与检查在【同一笔事务】里,而那是本表不开 INSERT 策略的理由】★
--   分成两步(先查、再抄)之间那道缝,足够让一份刚被改成 terminated 的合同
--   把条款抄出去。所以两者必须同生共死。

CREATE OR REPLACE FUNCTION public.link_document_to_contract(
    p_document_kind text,
    p_document_id uuid,
    p_contract_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_con      contracts%ROWTYPE;
    v_doc_cp   uuid;
    v_doc_code text;
    v_specs    jsonb;
BEGIN
    IF p_document_kind IS NULL OR p_document_kind NOT IN ('purchase_order','sales_order') THEN
        RAISE EXCEPTION 'CONTRACT_DOCUMENT_KIND_INVALID|%', COALESCE(p_document_kind, 'null')
          USING HINT = '今天只有采购单与销售单挂得上合同 —— 别的单据要先决定"它算不算在合同之下开出来的"';
    END IF;

    SELECT * INTO v_con FROM contracts WHERE id = p_contract_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', p_contract_id;
    END IF;

    -- 【SECURITY DEFINER 自己查权限,按合同归属那一侧查】
    -- 属主权限绕过 RLS,所以这一句不是礼节。
    IF v_con.customer_id IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
    ELSE
        PERFORM require_permission('module.suppliers.edit');
    END IF;

    -- ★ 拒绝一:合同不是 active ★
    IF v_con.status <> 'active' THEN
        RAISE EXCEPTION 'CONTRACT_NOT_ACTIVE|%|%', v_con.code, v_con.status
          USING HINT = '只有生效中的合同才收得下新单据 —— 草稿还没谈定,已终止的不该再长出新单据。要挂上去,先把合同置为 active';
    END IF;

    -- 取单据的对手方与编号
    IF p_document_kind = 'purchase_order' THEN
        SELECT supplier_id, code INTO v_doc_cp, v_doc_code
          FROM purchase_orders WHERE id = p_document_id AND deleted_at IS NULL;
        IF v_doc_code IS NULL THEN
            RAISE EXCEPTION 'PO_NOT_FOUND|%', p_document_id; END IF;
        -- ★ 拒绝二:一张采购单只挂得上【买方】合同 ★
        IF v_con.supplier_id IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIDE_MISMATCH|%|%', v_con.code, 'purchase_order'
              USING HINT = '这是一份销售合同(对手方是客户),而你要挂的是一张采购单';
        END IF;
        IF v_doc_cp IS DISTINCT FROM v_con.supplier_id THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERPARTY_MISMATCH|%|%', v_con.code, v_doc_code
              USING HINT = '合同的对手方与单据的对手方不是同一家 —— 这是一次录入错误,不是一条可以斟酌的规矩';
        END IF;
    ELSE
        SELECT customer_id, code INTO v_doc_cp, v_doc_code
          FROM sales_orders WHERE id = p_document_id AND deleted_at IS NULL;
        IF v_doc_code IS NULL THEN
            RAISE EXCEPTION 'SO_NOT_FOUND|%', p_document_id; END IF;
        IF v_con.customer_id IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_SIDE_MISMATCH|%|%', v_con.code, 'sales_order'
              USING HINT = '这是一份采购合同(对手方是供应商),而你要挂的是一张销售单';
        END IF;
        IF v_doc_cp IS DISTINCT FROM v_con.customer_id THEN
            RAISE EXCEPTION 'CONTRACT_COUNTERPARTY_MISMATCH|%|%', v_con.code, v_doc_code
              USING HINT = '合同的对手方与单据的对手方不是同一家 —— 这是一次录入错误,不是一条可以斟酌的规矩';
        END IF;
    END IF;

    -- 已经挂过就按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。
    IF EXISTS (SELECT 1 FROM contract_document_terms
                WHERE (p_document_kind = 'purchase_order' AND purchase_order_id = p_document_id)
                   OR (p_document_kind = 'sales_order'    AND sales_order_id    = p_document_id)) THEN
        RAISE EXCEPTION 'DOCUMENT_ALREADY_UNDER_CONTRACT|%', v_doc_code
          USING HINT = '这张单据已经挂在一份合同之下了 —— 改挂会把它当初依据的条款换掉,而那是改历史。要换,先决定已经抄下的那一份怎么办';
    END IF;

    -- ★★ 抄:把在效条款的【值】写下来,不是留一个指针 ★★
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'metal', g.metal, 'material_id', g.material_id,
               'min_pct', g.min_pct, 'max_pct', g.max_pct) ORDER BY g.metal), '[]'::jsonb)
      INTO v_specs
      FROM contract_grade_specs g WHERE g.contract_id = v_con.id;

    INSERT INTO contract_document_terms (
        purchase_order_id, sales_order_id, contract_id,
        contract_code, contract_title, incoterm, currency, payment_terms_days,
        grade_specs, linked_by)
    VALUES (
        CASE WHEN p_document_kind = 'purchase_order' THEN p_document_id END,
        CASE WHEN p_document_kind = 'sales_order'    THEN p_document_id END,
        v_con.id,
        v_con.code, v_con.title, v_con.incoterm, v_con.currency, v_con.payment_terms_days,
        v_specs, auth.uid());

    -- 单据那一行也记下它挂在哪 —— 这一列是【导航】,条款仍然读上面那份副本。
    IF p_document_kind = 'purchase_order' THEN
        UPDATE purchase_orders SET contract_id = v_con.id WHERE id = p_document_id;
    ELSE
        UPDATE sales_orders SET contract_id = v_con.id WHERE id = p_document_id;
    END IF;

    RETURN jsonb_build_object(
        'document_kind', p_document_kind, 'document_code', v_doc_code,
        'contract_code', v_con.code,
        'grade_specs_copied', jsonb_array_length(v_specs));
END;
$function$;

COMMENT ON FUNCTION public.link_document_to_contract(text, uuid, uuid) IS
'CONTRACT-1:把一张单据挂到合同上,并**当场把在效条款抄下来**。★**这支函数就是"登记簿不是文件柜"那句话的实现**★:两条拒绝 —— 对手方对不上、合同不是 active —— 而**两条都是【不一致】不是【政策】**(AGENTS.md 给 ALLOC_CURRENCY_MISMATCH 与 ALLOC_EXCEEDS 划的线):没有人会故意把 A 家的单挂到 B 家的合同上。★**刻意不拒的那一条**★:单据日期落在合同期之外【不拒】—— 回填是正当操作,而"能不能背靠未生效的合同下单"没有人裁过,没裁定就按名拒买到的是绕过它的办法。**抄写与检查在同一笔事务里**,这也是 contract_document_terms 不开 INSERT 策略的理由:分两步之间那道缝足够让一份刚被改成 terminated 的合同把条款抄出去。已经挂过按名拒,不悄悄改挂 —— 改挂等于把一张单据当初依据的条款换掉。';
