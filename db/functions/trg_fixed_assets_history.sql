CREATE OR REPLACE FUNCTION public.trg_fixed_assets_history()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- INSERT 时把"改动前"当成空对象 —— 于是每一列都算变了,'created' 那一行的
    -- new_* 侧全部填满(出生快照)。这一句是 change_type 之外唯一分 INSERT/UPDATE 的地方。
    v_old     jsonb  := CASE WHEN TG_OP = 'INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    v_new     jsonb  := to_jsonb(NEW);
    v_payload jsonb  := '{}'::jsonb;
    v_cols    text[] := ARRAY[]::text[];
    k         text;
BEGIN
    -- 差集。**键名在运行时拼**,所以这个函数体里没有出现过任何一个列名 ——
    -- 那正是 fixtures/120 不用改的原因(见迁移抬头)。
    FOR k IN SELECT key FROM jsonb_each(v_new) ORDER BY key LOOP
        IF v_old -> k IS DISTINCT FROM v_new -> k THEN
            v_cols    := v_cols || k;
            v_payload := v_payload
                || jsonb_build_object('old_' || k, v_old -> k, 'new_' || k, v_new -> k);
        END IF;
    END LOOP;

    -- 【什么都没改的 UPDATE 不留行】与 trg_so_history_header 那一句同一条理由:
    -- 一行"什么都没变"的历史会把真正的修改淹掉。而这里的判据是【差集】,
    -- 不是任何一个具名的列 —— 所以它没有把那条规矩换成一份列名清单。
    IF cardinality(v_cols) = 0 THEN
        RETURN NULL;
    END IF;

    -- jsonb_populate_record 把运行时拼出来的键落进【真正带类型的】成对列。
    -- ⚠ 它会静默丢掉没有对应列的键 —— fixtures/201 的「成对齐全」判据守这一头。
    INSERT INTO fixed_asset_history
    SELECT (jsonb_populate_record(NULL::fixed_asset_history, v_payload || jsonb_build_object(
        'id',              gen_random_uuid(),
        'fixed_asset_id',  NEW.id,
        'change_type',     CASE WHEN TG_OP = 'INSERT' THEN 'created' ELSE 'updated' END,
        'changed_columns', to_jsonb(v_cols),
        'changed_at',      now(),
        'changed_by',      auth.uid(),
        'changed_by_kind', CASE WHEN auth.uid() IS NULL THEN 'no_session' ELSE 'user' END
    ))).*;

    RETURN NULL;   -- AFTER 触发器,返回值不作数
END;
$function$
