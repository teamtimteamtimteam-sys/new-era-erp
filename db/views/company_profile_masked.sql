-- db/views/company_profile_masked.sql
-- 公司档案的遮蔽伴生视图:抬头信息人人可读,【银行明细要 data.view_banking】。
--
-- 为什么需要它:cut 2a 为了让发票抬头渲染,把 company_profile 定为任何登录用户可读,
-- 代价是公司银行账号 / SWIFT / 户名对每一个登录员工可见(2b 的报告里点名了这个暴露面)。
-- 抬头要公开,收款账号不必。
--
-- 属主权限,机制与 cut 2b 的遮蔽视图一致。company_profile 的行策略本就是 true,
-- 所以这里没有额外的行谓词要加回 —— 行访问不变,只是银行列按权限置空。
--
-- NOTE: introduced by db/migrations/2026-08-02-perm3-banking-and-directory.sql.

CREATE VIEW public.company_profile_masked WITH (security_invoker = off) AS
 SELECT id,
    legal_name,
    registration_no,
    address_lines,
    city,
    postal_code,
    country,
    phone,
    email,
    website,
        CASE
            WHEN has_permission('data.view_banking'::text) THEN bank_name
            ELSE NULL::text
        END AS bank_name,
        CASE
            WHEN has_permission('data.view_banking'::text) THEN bank_account_name
            ELSE NULL::text
        END AS bank_account_name,
        CASE
            WHEN has_permission('data.view_banking'::text) THEN bank_account_no
            ELSE NULL::text
        END AS bank_account_no,
        CASE
            WHEN has_permission('data.view_banking'::text) THEN bank_swift
            ELSE NULL::text
        END AS bank_swift,
        CASE
            WHEN has_permission('data.view_banking'::text) THEN bank_address
            ELSE NULL::text
        END AS bank_address,
    invoice_footer_text,
    logo_path,
    updated_at,
    updated_by
   FROM company_profile;
