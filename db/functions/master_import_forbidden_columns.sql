CREATE OR REPLACE FUNCTION public.master_import_forbidden_columns()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT ARRAY[
        'id',                       -- 主键由库生成
        'created_at','updated_at','created_by','updated_by',   -- 审计,由库盖章
        'deleted_at','deleted_by','deletion_reason','owner_id',
        'user_id',                  -- 员工 ↔ 登录账号的关联走 set_user_employee_link
                                    -- (LINK-1 那条"两扇门两套规矩"还没裁,不在这里开第三扇)
        'status',                   -- suppliers.status 由 validate_supplier_status_transition 管
                                    -- 跳转规则;导入直接落一个状态会绕过那条规矩
        'default_payment_term_template_id'  -- 指向 payment_term_templates,本刀范围外
    ];
$function$
