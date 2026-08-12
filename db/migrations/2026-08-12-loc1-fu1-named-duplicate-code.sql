-- db/migrations/2026-08-12-loc1-fu1-named-duplicate-code.sql
-- LOC-1 续:重复的库位号要【自报姓名】,而不是丢一个 23505 出来
--
-- `storage_locations.code` 上有 UNIQUE 约束,所以"不会有两个同号库位"这件事
-- 从第一天起就是真的。缺的不是保证,是【说法】:唯一约束违例给出的是
--   duplicate key value violates unique constraint "storage_locations_code_key"
-- —— 一句关于索引的话,不是一句关于业务的话。界面要么原样把它摔给用户,
-- 要么在应用层按字符串去猜它是哪一种冲突,而按错误文本分支正是这个仓库
-- 反复付过账的形状。
--
-- 【两层,各司其职,不要把其中一层读成多余的】
--   * 触发器给【名字】:正常路径上先撞到它,抛 LOC_CODE_EXISTS|<code>,
--     界面照着码翻译成一句人话,fixture 也断言得了这个码;
--   * UNIQUE 给【保证】:两个并发插入可以同时通过触发器里的 EXISTS
--     (它们互相看不见对方未提交的行),这时挡住第二个的是唯一索引。
-- 所以触发器【不能】取代 UNIQUE,UNIQUE 也【不能】取代触发器 —— 一个负责
-- 在竞态下仍然为真,一个负责在人看得见的那条路上说人话。
--
-- 镜像:db/tables/storage_locations.sql、
--       db/functions/guard_storage_location_code_unique.sql;
-- 行为断言:fixture 55 的 D 臂(先注入故障看它红,再断言)。

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_storage_location_code_unique()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- 只在【别的行】已经占了这个号时拒绝 —— 改名(code 不变)不该撞自己。
    IF EXISTS (
        SELECT 1 FROM public.storage_locations
        WHERE code = NEW.code AND id <> NEW.id
    ) THEN
        RAISE EXCEPTION 'LOC_CODE_EXISTS|%', NEW.code;
    END IF;
    RETURN NEW;
END;
$function$;

-- UPDATE OF code:改名字、改 zone、停用都不必跑这一趟。
CREATE TRIGGER trg_storage_locations_code_named
    BEFORE INSERT OR UPDATE OF code ON public.storage_locations
    FOR EACH ROW EXECUTE FUNCTION public.guard_storage_location_code_unique();

COMMIT;
