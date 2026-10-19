-- db/tables/floor_board_settings.sql
-- MES-8b-2(2026-10-17,MES-0 §5.1 V28 · Q83;MES-8 Step 0 Q20,Tim):【车间大屏的待补的值 —— 单行】。
--   V28  refresh_seconds · tiles   大屏多久自己刷新一次、画哪几块牌子(按什么顺序)。两样一起给,一起清(CHECK)。
--   【引导一律为空】:没有人说过大屏挂在哪儿、要看什么、多久刷新 —— 不猜一个间隔,也不替人挑牌子。
--   为空时大屏画全部车间支(floor_board_arms() 的二十三支,按加工 · 安全 · 库存分节),顶上写「refreshed at hh:mm」与一颗刷新钮,
--   【不自动刷新】(Q20)。给了之后只画 tiles 里那几块(按 tiles 的顺序),并每 refresh_seconds 秒自己刷新一次。
--   tiles 只能是 floor_board_arms() 里的支(set_floor_board_settings 按名拒);改它只改大屏画什么,不改任何一支的计数。
--   由 action.manage_permissions(建大屏账号的那个人,admin)经 set_floor_board_settings 改;修改史在变更记录里(本刀不加审计主语,Q22)。
--   RUNTIME CONFIG:Tim 设一次,线上就与本文件不同 —— 那是系统在正常工作(compliance_settings 的先例)。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.floor_board_settings (
    id              boolean PRIMARY KEY DEFAULT true CHECK (id),
    refresh_seconds integer CHECK (refresh_seconds IS NULL OR refresh_seconds > 0),
    tiles           text[] CHECK (tiles IS NULL OR cardinality(tiles) > 0),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),
    CONSTRAINT floor_board_settings_pair CHECK ((refresh_seconds IS NULL) = (tiles IS NULL))
);

COMMENT ON TABLE public.floor_board_settings IS
    'MES-8b-2:车间大屏的设定(单行)。V28 = refresh_seconds · tiles(自己刷新的间隔与画哪几块牌子),一起给一起清。引导为空:画全部车间支、不自动刷新(Q20)。action.manage_permissions 经 set_floor_board_settings 改。';
COMMENT ON COLUMN public.floor_board_settings.refresh_seconds IS
    'V28:大屏每隔多少秒自己刷新一次。空 = Not yet set(大屏只有「refreshed at」与刷新钮,不自动刷新 —— 不猜一个间隔)。';
COMMENT ON COLUMN public.floor_board_settings.tiles IS
    'V28:大屏画哪几块牌子,按这个顺序 —— 每一项是 floor_board_arms() 里的一支(operations_arms_all 的 item_type)。空 = Not yet set(画全部车间支)。';

INSERT INTO public.floor_board_settings (id) VALUES (true);

CREATE TRIGGER trg_floor_board_settings_updated_at
    BEFORE UPDATE ON public.floor_board_settings
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

ALTER TABLE public.floor_board_settings ENABLE ROW LEVEL SECURITY;
-- 读:大屏的码(大屏自己经 floor_board() 读,不直接读表)或 action.manage_permissions(设它的人)。写只经函数。
CREATE POLICY "floor_board_settings select by permission" ON public.floor_board_settings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('data.view_floor_board'::text) OR has_permission('action.manage_permissions'::text));
GRANT SELECT ON public.floor_board_settings TO authenticated;
REVOKE ALL ON public.floor_board_settings FROM anon;
