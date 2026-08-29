-- db/functions/save_counterparty_contact.sql
-- PARTY-1:写一个联系人 —— 新增或修改,以及"把它设成主联系人"。
--
-- 【为什么写入只有这一扇门】"设成主联系人"要在【同一笔事务】里把上一个主撤掉。
-- 两条直连写入之间那道缝会撞上部分唯一索引(报一个裸约束名),
-- 或者更坏 —— 顺序反过来时静静地留下两个主。所以本表不开 INSERT/UPDATE 策略。
--
-- 【空字符串在这里落成 NULL】表单交上来的空框是 '',而 '' 与 NULL 在
-- 「够不够得着人」那条 CHECK 面前是两回事:''不是 NULL,于是一个两个框都空着的
-- 联系人会溜过去。归一化放在这一支,而不是指望每个调用点都记得 —— 与
-- normalise_counterparty_identity 放触发器是同一条理由。

CREATE OR REPLACE FUNCTION public.save_counterparty_contact(
    p_customer_id uuid DEFAULT NULL::uuid,
    p_supplier_id uuid DEFAULT NULL::uuid,
    p_name text DEFAULT NULL::text,
    p_role text DEFAULT NULL::text,
    p_email text DEFAULT NULL::text,
    p_phone text DEFAULT NULL::text,
    p_notes text DEFAULT NULL::text,
    p_is_primary boolean DEFAULT false,
    p_contact_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_name  text := NULLIF(btrim(COALESCE(p_name,  '')), '');
    v_email text := NULLIF(btrim(COALESCE(p_email, '')), '');
    v_phone text := NULLIF(btrim(COALESCE(p_phone, '')), '');
    v_role  text := NULLIF(btrim(COALESCE(p_role,  '')), '');
    v_notes text := NULLIF(btrim(COALESCE(p_notes, '')), '');
    v_cust  uuid := p_customer_id;
    v_sup   uuid := p_supplier_id;
    v_id    uuid;
    v_old   counterparty_contacts%ROWTYPE;
BEGIN
    -- 【改一行时,归属从那一行读,不从调用方读】否则一次调用可以把某个客户的
    -- 联系人悄悄搬到另一个客户名下,而两边的权限检查各自都通过。
    IF p_contact_id IS NOT NULL THEN
        SELECT * INTO v_old FROM counterparty_contacts WHERE id = p_contact_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CONTACT_NOT_FOUND|%', p_contact_id;
        END IF;
        IF v_old.deleted_at IS NOT NULL THEN
            RAISE EXCEPTION 'CONTACT_DELETED|%', p_contact_id;
        END IF;
        v_cust := v_old.customer_id;
        v_sup  := v_old.supplier_id;
    END IF;

    -- 【SECURITY DEFINER 自己查权限】而且按【归属那一侧】查 ——
    -- 一个只做采购的人不该改得动客户的联系人。
    IF num_nonnulls(v_cust, v_sup) <> 1 THEN
        RAISE EXCEPTION 'CONTACT_OWNER_REQUIRED'
          USING HINT = '一个联系人要么属于一个客户,要么属于一个供应商 —— 恰好一个,不能都填也不能都不填';
    END IF;
    IF v_cust IS NOT NULL THEN
        PERFORM require_permission('module.customers.edit');
        IF NOT EXISTS (SELECT 1 FROM customers WHERE id = v_cust AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'CUSTOMER_NOT_FOUND|%', v_cust;
        END IF;
    ELSE
        PERFORM require_permission('module.suppliers.edit');
        IF NOT EXISTS (SELECT 1 FROM suppliers WHERE id = v_sup AND deleted_at IS NULL) THEN
            RAISE EXCEPTION 'SUPPLIER_NOT_FOUND|%', v_sup;
        END IF;
    END IF;

    IF v_name IS NULL THEN
        RAISE EXCEPTION 'CONTACT_NAME_REQUIRED'
          USING HINT = '一个没有名字的联系人在名单里读起来就是「没有人」—— 写下这个人怎么称呼';
    END IF;
    IF v_email IS NULL AND v_phone IS NULL THEN
        RAISE EXCEPTION 'CONTACT_UNREACHABLE|%', v_name
          USING HINT = '至少留一条够得着他的路(邮箱或电话)—— 只有名字的联系人在开票或催收时帮不上忙';
    END IF;

    -- ★【设主联系人:先撤旧的,同一笔事务】★ 顺序反过来会撞部分唯一索引。
    IF p_is_primary THEN
        UPDATE counterparty_contacts
           SET is_primary = false, updated_at = now(), updated_by = auth.uid()
         WHERE is_primary AND deleted_at IS NULL
           AND id IS DISTINCT FROM p_contact_id
           AND ((v_cust IS NOT NULL AND customer_id = v_cust)
             OR (v_sup  IS NOT NULL AND supplier_id = v_sup));
    END IF;

    IF p_contact_id IS NULL THEN
        INSERT INTO counterparty_contacts
            (customer_id, supplier_id, name, role, email, phone, notes, is_primary, updated_by)
        VALUES (v_cust, v_sup, v_name, v_role, v_email, v_phone, v_notes,
                COALESCE(p_is_primary, false), auth.uid())
        RETURNING id INTO v_id;
    ELSE
        UPDATE counterparty_contacts
           SET name = v_name, role = v_role, email = v_email, phone = v_phone,
               notes = v_notes, is_primary = COALESCE(p_is_primary, false),
               -- 【人改过名字之后,它就不再是"推出来的"了】
               name_inferred = CASE WHEN v_name IS DISTINCT FROM v_old.name
                                    THEN false ELSE v_old.name_inferred END,
               updated_at = now(), updated_by = auth.uid()
         WHERE id = p_contact_id
        RETURNING id INTO v_id;
    END IF;

    RETURN jsonb_build_object('contact_id', v_id, 'is_primary', COALESCE(p_is_primary, false));
END;
$function$;

COMMENT ON FUNCTION public.save_counterparty_contact(uuid, uuid, text, text, text, text, text, boolean, uuid) IS
'PARTY-1:联系人的唯一写入口。**"设成主联系人"要在同一笔事务里先撤掉上一个** —— 两条直连写入之间那道缝会撞部分唯一索引,或者顺序反过来时静静留下两个主,所以本表不开 INSERT/UPDATE 策略。改一行时【归属从那一行读,不从调用方读】,否则一次调用能把联系人从一个客户搬到另一个客户名下而两边权限各自都过。权限按归属那一侧查(customers.edit / suppliers.edit)。空字符串在这里落成 NULL —— '''' 不是 NULL,而那条「至少留一条够得着他的路」的 CHECK 拦不住两个空框。人改过名字之后 name_inferred 落回 false。';
