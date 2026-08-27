-- db/functions/aging_bucket.sql
-- AGING-1(2026-08-27):AP/AR 账龄档位边界的【唯一一处】定义。
--
-- 【为什么它值得是一支函数】抽出来之前这四条边界在库里写了【三遍】——
-- ap_open_items 一遍、ar_open_items 的两支各一遍;本刀的两支 as-at 函数会让它
-- 变成五遍。「同一条规矩两份实现」是这个仓库反复付账的那个形状,所以先收成一处,
-- 再让五个消费方全部引用它。db/fixtures/135 的 G 臂是目录断言:
-- 那四个对象的定义里【必须】都出现 aging_bucket —— 有人把 CASE 抄回去就当场变红。
--
-- 【EXECUTE 要留给 authenticated】它被两张【属主权限】视图在体内调用,而
-- AGENTS.md 记着:属主权限替得了表,替不了函数的 EXECUTE —— 那仍按当前用户判。
-- 收掉它,两页会当场 42501。它是纯算术、不读任何数据,授出去不泄露任何东西。
--
-- NOTE: introduced by db/migrations/2026-08-27-aging1-as-at-a-date.sql.

CREATE OR REPLACE FUNCTION public.aging_bucket(p_days integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 账龄档位的【唯一】定义。改这里,ap_open_items / ar_open_items 两支 /
    -- ap_aging_asof / ar_aging_asof 五处一起改 —— 这正是抽出它的全部理由。
    -- 天数为 NULL 时返回 NULL:一个算不出来的档位不是 'b90_plus'。
    SELECT CASE
        WHEN p_days IS NULL THEN NULL
        WHEN p_days <= 30 THEN 'b0_30'
        WHEN p_days <= 60 THEN 'b31_60'
        WHEN p_days <= 90 THEN 'b61_90'
        ELSE 'b90_plus'
    END::text;
$function$;

COMMENT ON FUNCTION public.aging_bucket(integer) IS
    'AGING-1:AP/AR 账龄档位边界的【唯一一处】定义(b0_30 / b31_60 / b61_90 / b90_plus)。五个消费方:ap_open_items、ar_open_items 的两支、ap_aging_asof、ar_aging_asof。抽出来之前这四条边界在库里写了三遍,本刀会写成五遍 —— 那正是本仓库反复付账的「同一条规矩两份实现」。天数为 NULL 返回 NULL:算不出来的档位不是 90 天以上。';