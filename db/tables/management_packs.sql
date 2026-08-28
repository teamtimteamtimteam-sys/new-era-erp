-- db/tables/management_packs.sql
-- GLEXPORT-1:**冻下来的月度管理报表包。**
--
-- ★★【一份存下来的包意味着一件事,而这句话就是本表存在的全部理由】★★
--
--     **它被产出的那一刻,那个月已经关账了。**
--
--   所以本表【不存】开放月份的包。要看当月,屏幕上有实时预览、也导得出 CSV,
--   两者都盖着"本月尚未关账"的戳 —— 但它们【不落库】。
--
-- ★【为什么"冻结但注明是临时的"是两个念头穿一件衣服】★
--   仓库已经为"什么时候该冻"裁过三次,而三次的触发点是同一件事 ——
--   **有东西离开了这栋楼**,不是有人按了「计算」:
--     · gst_return_boxes  —— 冻在【申报】那一刻(草稿冻不下来);
--     · customer_statements —— 冻在【签发】那一刻(寄给客户了);
--     · bank_reconciliations —— 冻的是一次【发生过的对账事件】。
--   照这三条,一个开放月份的包还没有承诺任何事:它是一次计算,不是一次交付。
--   而"一份永久、不可改、且人人都知道当时是错的记录",是一样不值得造出来的东西。
--   于是 locked_before 在这里有了真活干,不再只是一个标签
--   (CHECK management_packs_month_was_locked 把它钉死在表上)。
--
-- ★【重出一份 = 新的一行 + 旧行 superseded + 必填理由】★
--   与 customer_statements / bank_reconciliations 逐字同一条:更正是一个
--   新事件,不是一次编辑。已关账的月份【仍然可能】重出一份(比如重开期间补了
--   一笔再关上),所以这条路必须留着,而它必须留下痕迹。
--
-- 【payload 是整包 jsonb,不是拆成几十张表】包的内容是【那一刻算出来的那些数】,
--   它的形状会随报表演进而变;拆成列意味着每次报表加一行就要改表结构,
--   而旧包还得按旧形状读。gst_return_boxes 拆了行是因为它有【固定的九格】;
--   这里没有固定的格。同一条理由,相反的结论。
--
-- 写入只走 freeze_management_pack(SECURITY DEFINER);这里只开 SELECT。
--
-- NOTE: introduced by db/migrations/2026-08-28-glexport1-general-ledger-export-and-the-monthly-pack.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.management_packs (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                        text NOT NULL UNIQUE,      -- 'PACK-2026-07';重出为 'PACK-2026-07-2'
    period_month                date NOT NULL,             -- 当月 1 号
    period_start                date NOT NULL,
    period_end                  date NOT NULL,
    -- ★ 证据,不是标签:产出那一刻的 locked_before。
    --   CHECK 要求它【严格大于】期末 —— 也就是"那个月的每一天都已经不能再过账"。
    locked_before_at_production date NOT NULL,
    base_currency               text NOT NULL REFERENCES public.currencies (code),
    -- 冻下来的整包(management_pack_data 的返回值,原样)。
    payload                     jsonb NOT NULL,
    notes                       text,
    produced_at                 timestamptz NOT NULL DEFAULT now(),
    produced_by                 uuid DEFAULT auth.uid(),
    superseded_at               timestamptz,
    -- ★【DEFERRABLE INITIALLY DEFERRED,而这是探针逼出来的】★
    --   一个月只许有一份在册(idx_management_packs_live_month,部分唯一索引),
    --   所以重出时必须【先】把旧行标成 superseded、再插新行 —— 否则那一瞬间
    --   同一个月有两份在册,撞唯一索引。而"先标旧行"要指向【还没插进去的】新行,
    --   于是这条外键必须延迟到提交时才检查。两条约束互相把对方逼到了唯一可行的
    --   那个顺序上;写在这里免得下一个人把 DEFERRABLE 当成多余的装饰摘掉。
    superseded_by               uuid REFERENCES public.management_packs (id)
                                DEFERRABLE INITIALLY DEFERRED,
    superseded_reason           text,
    CONSTRAINT management_packs_month_is_first
        CHECK (period_month = date_trunc('month', period_month)::date),
    CONSTRAINT management_packs_window CHECK (period_end >= period_start),
    -- ★【本表的核心不变量】★ 存下来的包,那个月当时必定已经关账。
    CONSTRAINT management_packs_month_was_locked
        CHECK (locked_before_at_production > period_end),
    -- 【被取代的行必须说出为什么】—— 一次没有理由的重出,日后无从交代。
    CONSTRAINT management_packs_superseded_shape CHECK (
        (superseded_at IS NULL     AND superseded_reason IS NULL)
     OR (superseded_at IS NOT NULL AND superseded_reason IS NOT NULL))
);

-- 一个月只有一份【在册】的包;被取代的旧行不占这个位置。
CREATE UNIQUE INDEX idx_management_packs_live_month
    ON public.management_packs (period_month) WHERE superseded_at IS NULL;
CREATE INDEX idx_management_packs_month ON public.management_packs (period_month);

-- 只可追加:一个包是一件产出过的东西。放行的【只有】那一次 superseded 转移,
-- 其余列逐列锁死 —— 与 payments / collection_chases 的守卫同形。
CREATE OR REPLACE FUNCTION public.guard_management_pack_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'PACK_IMMUTABLE|%', OLD.code;
    END IF;
    IF NEW.id          IS DISTINCT FROM OLD.id
       OR NEW.code        IS DISTINCT FROM OLD.code
       OR NEW.period_month IS DISTINCT FROM OLD.period_month
       OR NEW.period_start IS DISTINCT FROM OLD.period_start
       OR NEW.period_end   IS DISTINCT FROM OLD.period_end
       OR NEW.locked_before_at_production IS DISTINCT FROM OLD.locked_before_at_production
       OR NEW.base_currency IS DISTINCT FROM OLD.base_currency
       OR NEW.payload     IS DISTINCT FROM OLD.payload
       OR NEW.notes       IS DISTINCT FROM OLD.notes
       OR NEW.produced_at IS DISTINCT FROM OLD.produced_at
       OR NEW.produced_by IS DISTINCT FROM OLD.produced_by
    THEN
        RAISE EXCEPTION 'PACK_IMMUTABLE|%', OLD.code;
    END IF;
    IF NOT (OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL) THEN
        RAISE EXCEPTION 'PACK_IMMUTABLE|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_management_packs_immutable
    BEFORE UPDATE OR DELETE ON public.management_packs
    FOR EACH ROW EXECUTE FUNCTION public.guard_management_pack_mutation();

ALTER TABLE public.management_packs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "management_packs select by permission"
    ON public.management_packs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

COMMENT ON TABLE public.management_packs IS
    'GLEXPORT-1:冻下来的月度管理报表包。**一份存下来的包意味着一件事:它被产出的那一刻,那个月已经关账了**(CHECK management_packs_month_was_locked)。开放月份看得到实时预览、导得出 CSV,但【不落库】—— 仓库为"什么时候该冻"裁过三次,三次的触发点都是「有东西离开了这栋楼」,而不是有人按了计算。重出一份 = 新行 + 旧行 superseded + 必填理由。';

COMMENT ON COLUMN public.management_packs.locked_before_at_production IS
    '产出那一刻 finance_settings.locked_before 的值。**它是证据,不是标签** —— 表上的 CHECK 要求它严格大于 period_end,于是"这份包产出时那个月已经关账"是一件由数据库保证的事,不是一句写在别处的说明。';
