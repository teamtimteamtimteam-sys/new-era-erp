-- SO-4a fu2(2026-08-15):签发那一行必须【最后】写 —— 否则每一张刚签发的报价
--                        都立刻自称"签发之后又改过"
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【fu1 修好了时钟,fixture 72 G 臂立刻抓出了下一个 —— 而这一个是真的缺陷】
-- fu1 之前 now() 比不出先后,信号【永远不亮】;fu1 之后钟会走了,于是第一次
-- 签发【当场】把信号点亮:
--
--     record_qt_issue:  INSERT qt_issues (issued_at = T1)
--                       UPDATE quotes SET status='issued'  → updated_at = T2 > T1
--     信号:max(issued_at)=T1 < updated_at=T2  → true
--
-- 也就是说:每一张刚签发出去的报价,屏幕上都会写着"这份已经和客户手里那份
-- 不一样了"。**一个总是亮着的警报等于没有警报** —— 人会学会忽略它,而它真正
-- 该亮的那一天也就没人看了。这与"一个永远为 false 的已发送标志会被读成没发出去"
-- 是同一个病的两个方向。
--
-- 【修法一:签发那一行【最后】写】状态先翻,签发档后插 —— 那一行的时间戳是
-- 其它一切要与之比较的基准,所以它必须是这次调用里最晚发生的事。
-- 这就是这个仓库反复用的那条顺序纪律的又一例(作废前先释放预留、过账后再写
-- 单头、总额与明细同一条语句):**顺序本身就是判据的一部分。**
--
-- 【修法二:信号只对 issued 的报价成立】谢绝与转换都会写 quotes(状态、理由、
-- 订单号),于是它们也会把 updated_at 顶到签发时刻之后。可那两种状态下"你和
-- 客户手里那份不一样了"根本不是一句有意义的话 —— 这单已经结束了。
-- 不把它们排除掉,信号就会在两个它无话可说的地方亮着。
--
-- 【为什么不是把比较改成 <=】那是在给一个错的机制找一个刚好能过的边界:
-- 真正的问题不是"差了一微秒",是【谁在谁之后】这件事被写反了。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.record_qt_issue(p_quote_id uuid, p_file_path text, p_sha256 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_q    quotes%ROWTYPE;
    v_next integer;
BEGIN
    PERFORM require_permission('module.sales.edit');

    SELECT * INTO v_q FROM quotes WHERE id = p_quote_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'QT_NOT_FOUND|%', COALESCE(p_quote_id::text, '?');
    END IF;
    -- 谢绝了的、已经转成订单的,都不再签发:那两个状态说的是"这件事结束了",
    -- 而签发是把一份【还在谈】的东西发出去。
    IF v_q.status NOT IN ('draft', 'issued') THEN
        RAISE EXCEPTION 'QT_NOT_ISSUABLE|%|%', v_q.code, v_q.status;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('qt_issue_' || p_quote_id::text)::bigint);
    SELECT COALESCE(MAX(version), 0) + 1 INTO v_next FROM qt_issues WHERE quote_id = p_quote_id;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【顺序就是要点 —— fu2】状态先翻,签发档【最后】插。
    -- 反过来写,那次状态 UPDATE 会把 quotes.updated_at 顶到 issued_at 之后,
    -- 于是每一张刚签发的报价都立刻自称"签发之后又改过"——
    -- 而一个总是亮着的警报等于没有警报。
    -- 签发档那一行的时间戳是其它一切要与之比较的基准,所以它必须是这次调用里
    -- 最晚发生的事。
    -- 【第一次签发就是 draft → issued 那次转换】签发是"发给对方"这件事本身,
    -- 而 issued 的意思正是它。第二次起只追加版本,状态不动。
    -- ════════════════════════════════════════════════════════════════════════
    IF v_q.status = 'draft' THEN
        UPDATE quotes SET status = 'issued', updated_by = auth.uid() WHERE id = p_quote_id;
        INSERT INTO quote_history (quote_id, change_type, detail)
        VALUES (p_quote_id, 'issued', 'v' || v_next::text);
    END IF;

    INSERT INTO qt_issues (quote_id, version, file_path, sha256, issued_by)
    VALUES (p_quote_id, v_next, p_file_path, p_sha256, auth.uid());

    RETURN jsonb_build_object('version', v_next, 'status',
        CASE WHEN v_q.status = 'draft' THEN 'issued' ELSE v_q.status END);
END;
$function$;

-- ── 信号只对 issued 的报价成立 ─────────────────────────────────────────────
CREATE OR REPLACE VIEW public.quote_status WITH (security_invoker = off) AS
 SELECT q.id AS quote_id,
    q.code,
    q.customer_id,
    c.code AS customer_code,
    c.legal_name AS customer_name,
    q.quote_date,
    q.valid_until,
    q.currency,
    q.fx_rate,
    q.status,
    q.decline_reason,
    q.converted_order_id,
    so.code AS converted_order_code,
    quote_is_expired(q.valid_until) AS expired,
    (q.status = 'issued' AND NOT quote_is_expired(q.valid_until)) AS convertible,
    (SELECT max(i.version) FROM qt_issues i WHERE i.quote_id = q.id) AS issue_version,
    -- 【只对 issued 成立 —— fu2】谢绝与转换都会写 quotes,于是它们也会把
    -- updated_at 顶到签发时刻之后;可那两种状态下"你和客户手里那份不一样了"
    -- 根本不是一句有意义的话 —— 这单已经结束了。不排除掉,信号就会在两个
    -- 它无话可说的地方亮着,而人会学会忽略一个总是亮的灯。
    -- 【没签发过 → false,不是 NULL】NULL 在这个仓库里已经有含义了(受限)。
    (q.status = 'issued'
     AND COALESCE((SELECT max(i.issued_at) FROM qt_issues i WHERE i.quote_id = q.id) < q.updated_at,
                  false)) AS amended_since_issue,
    q.notes,
    q.terms_text,
    q.updated_at
   FROM quotes q
     JOIN customers c ON c.id = q.customer_id
     LEFT JOIN sales_orders so ON so.id = q.converted_order_id
  WHERE q.deleted_at IS NULL AND has_permission('module.sales.view'::text);

COMMIT;
