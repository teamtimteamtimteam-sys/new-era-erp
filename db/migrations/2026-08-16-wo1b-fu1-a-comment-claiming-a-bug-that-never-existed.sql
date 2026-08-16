-- WO-1b-fu1:把两处注释改成真话 —— 它们声称修掉了一个并不存在的 bug
--
-- WO-1b 的 cancel_work_order / close_work_order 里写着:
--     "WO-1a 这里只写了 deleted_at IS NULL,于是一张工单在它唯一的加工被冲销
--      之后仍然取消不掉…… 这里对齐到后者。"
-- **那句话是错的。** `rollback_processing_run` 同时写 `status = 'reversed'` 与
-- `deleted_at = now()`(该函数第 135-140 行),所以 `deleted_at IS NULL` 早就把
-- 冲销掉的排除在外了 —— WO-1a 的守卫在这一点上是对的,两个写法今天等价。
-- fixture 75 的注入 2 是这么发现的:它退回旧口径、断言"取消应当重新被拦",
-- 而取消【成功了】。注入本来是用来证明门有牙的,这一次它证明的是【我描述错了】。
--
-- 【为什么这值得一支迁移,而不是下次顺手改】AGENTS.md 有一条:
-- "一条描述着不存在的隐患的注释,与一条断言不可能发生的事的注释,是同一种缺陷" ——
-- 它让读的人付出同样错误的相信,而没有任何闸门抓得住。这两句注释此刻就活在
-- 线上的函数体里。
--
-- 补上 `status = 'committed'` 这件事【仍然是对的】,只是理由变了:不是修 bug,
-- 是把一个隐含的巧合(回滚恰好同时写两列)写成一个显式的判据。哪天有一条路径
-- 只写其中一列,两个条件就分开了,而那时没有任何东西会喊。
BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_work_order(p_work_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status NOT IN ('draft','released') THEN
        RAISE EXCEPTION 'WO_NOT_CANCELLABLE|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CANCEL_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【已经开过工的单子不能取消 —— 它只能收工】取消的意思是"这件事没有发生过";
    -- 而挂着一条加工单,就意味着料真的下去了、产出真的进了库。把它标成 cancelled
    -- 会让那几次加工失去它们的出处,而出处是这套系统存在的理由。
    --
    -- 【只数没有被冲销的 —— 而这两个条件今天是【等价】的】
    -- 链接是历史,它断言过的消耗不是:一次被冲销的加工,料退回了、产出批作废了,
    -- 那次消耗不再是发生过的事实,所以它拦不住取消。
    -- rollback_processing_run 同时写 status='reversed' 与 deleted_at,所以单写
    -- deleted_at IS NULL 也能得到同一个结果 —— 两个条件都在这里,是因为它们的
    -- 等价【是一个巧合】:哪天有一条路径只写其中一列,它们就分开了,而那时没有
    -- 任何东西会喊。把隐含的巧合写成显式的判据。
    -- (WO-1b 一度把这写成"修掉了 WO-1a 的一个 bug" —— 那句话是错的,
    --  见 db/migrations/2026-08-16-wo1b-fu1-*.sql。)
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';
    IF v_runs > 0 THEN
        RAISE EXCEPTION 'WO_HAS_RUNS|%|%', v_wo.code, v_runs;
    END IF;

    UPDATE work_orders
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user,
           cancel_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, amend_reason, changed_by)
    VALUES (p_work_order_id, 'cancelled', btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code, 'status', 'cancelled');
END;
$function$;

CREATE OR REPLACE FUNCTION public.close_work_order(p_work_order_id uuid, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_wo   work_orders%ROWTYPE;
    v_runs integer;
BEGIN
    PERFORM require_permission('module.processing.edit');
    SELECT * INTO v_wo FROM work_orders WHERE id = p_work_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'WO_NOT_FOUND|%', COALESCE(p_work_order_id::text, '?');
    END IF;
    IF v_wo.status <> 'released' THEN
        -- draft 的单子要"不做了",走 cancel —— 见上面那张迁移表的最后一段
        RAISE EXCEPTION 'WO_NOT_RELEASED|%|%', v_wo.code, v_wo.status;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'WO_CLOSE_REASON_REQUIRED|%', v_wo.code;
    END IF;

    -- 【短交不拦 —— 这是一个决定,不是遗漏】实际做的比计划少,是一个要记下来的
    -- 事实。拦住它只会让人把计划改小以求关单,而那正好把差异从账上抹掉 ——
    -- 一条逼人去伪造数据的规则比没有规则更坏。收工时挂了几条加工单一并记进理由行,
    -- 让"关的时候是什么样"留在历史里,而不必事后重算。
    -- 口径与 WO_HAS_RUNS、与改单的地板一致(见 cancel_work_order 里那段说明:
    -- 两个条件今天等价,写全是为了让判据显式而不是靠巧合)。
    SELECT count(*) INTO v_runs FROM processing_runs
     WHERE work_order_id = p_work_order_id AND deleted_at IS NULL AND status = 'committed';

    UPDATE work_orders
       SET status = 'closed', closed_at = now(), closed_by = v_user,
           close_reason = btrim(p_reason), updated_at = now(), updated_by = v_user
     WHERE id = p_work_order_id;
    INSERT INTO work_order_history (work_order_id, change_type, detail, amend_reason, changed_by)
    VALUES (p_work_order_id, 'closed', 'runs=' || v_runs::text, btrim(p_reason), v_user);

    RETURN jsonb_build_object('work_order_id', p_work_order_id, 'code', v_wo.code,
                              'status', 'closed', 'runs', v_runs);
END;
$function$;

COMMIT;
