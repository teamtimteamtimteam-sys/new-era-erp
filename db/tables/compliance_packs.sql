-- db/tables/compliance_packs.sql
-- MES-8b-1(2026-10-17,MES-0 Q82;MES-8 Step 0 Q14 · Q15 · Q16 · Q28,Tim):【一个月的合规包 —— 冻下来的那一份】。
--   payload 就是 compliance_pack_data(那个月) 的返回值(一份实现,两个调用方:页面预览与冻结),冻结那一刻抄下:
--     ① 那个月的物料平衡(全厂与每道工序)② 库存滚动 ③ 当月末在效的执照、月末按 NEA 类别的在库吨数与当月的上限判定
--     ④ 当月的事故(种类、要不要通报 NEA、通报与书面报告的日子 —— 【不带任何受伤的细节】,也不带任何一段人写的文字)
--     ⑤ 当月的环境监测结果与它们的限值、判词 ⑥ 当月做过的巡检与月末还开着的发现 ⑦ NEA 申报(V26)⑧ 欧盟回收效率(V27)。
--   【只有关账的月份冻得下来】(Q15):判据 locked_before > 月末,与 freeze_management_pack 的 PACK_MONTH_NOT_LOCKED 逐字同源 ——
--     月份锁上之后那些数不会再动,冻下来的才是一个承诺(COMPLIANCE_PACK_MONTH_NOT_LOCKED|<YYYY-MM>|<锁到>)。
--   编号 CPK-YYYY-MM;同一个月重出一份 = CPK-YYYY-MM-2、-3 …,要写理由,旧的那一份落 superseded_*(Q16)——
--     【旧的 payload 与它存下的字节一个字不动】;没有作废。
--   对外(NEA、审计、要求它的买家):PDF 只从 payload 渲染,存私有桶 compliance-documents,按 sha256 记在 compliance_pack_issues,
--   每一次取档重算,对不上 409。一律英文。
--   【不带钱】—— payload 里没有一个价、一笔金额或工资;它也不抄任何受伤的细节(Q14 · Q22)。
--   只追加:除了"被取代"那一步,一列都改不了;删对谁都按名拒(trg_compliance_packs_write)。唯一写入口 freeze_compliance_pack()。
--
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.compliance_packs (
    id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                     text NOT NULL UNIQUE CHECK (code ~ '^CPK-[0-9]{4}-[0-9]{2}(-[0-9]+)?$'),
    period_month             date NOT NULL CHECK (period_month = date_trunc('month', period_month)::date),
    period_start             date NOT NULL,
    period_end               date NOT NULL,
    locked_before_at_freeze  date NOT NULL,
    payload                  jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    notes                    text,
    frozen_at                timestamptz NOT NULL DEFAULT now(),
    frozen_by                uuid,
    superseded_at            timestamptz,
    superseded_by            uuid REFERENCES public.compliance_packs (id) DEFERRABLE INITIALLY DEFERRED,   -- 旧的那一份先落 superseded、新的那一行随后才插(一个月只许一份在册),所以这条引用在事务末尾才查
    superseded_reason        text,
    CONSTRAINT compliance_packs_period CHECK (period_start = period_month AND period_end = (period_month + INTERVAL '1 month - 1 day')::date),
    CONSTRAINT compliance_packs_locked CHECK (locked_before_at_freeze > period_end),
    CONSTRAINT compliance_packs_superseded_whole CHECK ((superseded_at IS NULL) = (superseded_by IS NULL)
                                                         AND (superseded_at IS NULL) = (superseded_reason IS NULL))
);

COMMENT ON TABLE public.compliance_packs IS
    'MES-8b-1:一个月的合规包(CPK-YYYY-MM;重出 -2、-3 …,带理由取代旧的)。payload = compliance_pack_data(那个月) 在冻结那一刻的返回值:物料平衡 · 库存滚动 · 执照与 NEA 类别的在库与上限判定 · 事故(不带受伤细节)· 环境监测 · 巡检与开着的发现 · V26 · V27。只有关账的月份冻得下来。不带钱。PDF 只从 payload 渲染,字节在私有桶 compliance-documents、哈希在 compliance_pack_issues。只追加;唯一写入口 freeze_compliance_pack()。';

-- 一个月只许有一份在册(取代时旧的那一份【先】落 superseded —— freeze_management_pack 的同一个顺序)
CREATE UNIQUE INDEX idx_compliance_packs_live_month ON public.compliance_packs (period_month) WHERE superseded_at IS NULL;

CREATE TRIGGER trg_compliance_packs_write
    BEFORE UPDATE OR DELETE ON public.compliance_packs
    FOR EACH ROW EXECUTE FUNCTION public.guard_compliance_pack_write();

ALTER TABLE public.compliance_packs ENABLE ROW LEVEL SECURITY;
-- 读:合规的查看码(清单、包页、PDF)。写只经函数。
CREATE POLICY "compliance_packs select by permission" ON public.compliance_packs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.compliance.view'::text)));
GRANT SELECT ON public.compliance_packs TO authenticated;
REVOKE ALL ON public.compliance_packs FROM anon;
