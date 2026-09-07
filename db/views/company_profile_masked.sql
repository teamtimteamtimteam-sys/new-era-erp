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

-- ════════════════════════════════════════════════════════════════════════════
-- ★ COD-2b(2026-09-08):从 anon 手里收回 —— 它是【唯一一个真的在回答匿名请求】的关系 ★
-- ════════════════════════════════════════════════════════════════════════════
-- 【遮蔽是有效的,漏的是它没有遮的那十四列】bank_* 五列写成
-- CASE WHEN has_permission(…),anon 求值到那里就 42501。但其余十四列是【裸列】,
-- 而本视图是属主权限(security_invoker = off,基表 RLS 不参与)、又被默认权限
-- 自动授给了 anon —— 于是一个【不碰那五列】的窄读整个绕过去:
--     GET /rest/v1/company_profile_masked?select=legal_name,registration_no,address_lines
--     → 200,公司法定名称、UEN、地址;phone 与 email 同样出行,
--       **而那是一个具名的人的联系方式。**
--
-- 【ANON-0 为什么没看见】它逐个关系问的是 select=*,而 * 会求值到 has_permission
-- 并被拒 —— 于是这张视图被判成"被函数锁定挡住了"。
-- 抓到它的是 db/fixtures/196 的 B 臂,用的是一个坏法不一样的问法:count(*)
-- 不求值任何列表达式。**两条独立的路,而它们坏得不一样。**
--
-- 【收回是安全的,量过】本视图全仓库 6 个读者【全部】是 select('*') 且都在会话里,
-- 而 select('*') 本来就要 has_permission —— 它们不可能以 anon 成功。登录页不读它。
-- 基表的 SELECT 策略是 TO authenticated:anon 从来不是预期读者,这条授权
-- 自始至终是默认权限自动给的。反悔只要一句 GRANT。
REVOKE ALL ON public.company_profile_masked FROM anon;
