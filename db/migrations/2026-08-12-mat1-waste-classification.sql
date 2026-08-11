-- MAT-1(2026-08-12):物料的【受控废物分类】—— 一个字段,到此为止
--
-- Doc 1 里 Tim 用"重点物料 / 非重点物料"同时回答了两件事:合规仓储的要求,
-- 与一个采购类别。也就是说这个区分【已经在他脑子里】,而系统里没有。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么是一张表,不是一个 CHECK】(certificate_types 的形状,RUNTIME CONFIG)
-- 第三种分类应当是【加一行】,不是跑一次迁移。而"第三种"不是假想:受控废物的
-- 分级在不同法域下本来就不止两档,Tim 今天说得出的是这两个。
--
-- 【既有物料一律 NULL,而 NULL 是【第三种状态】】
-- NULL 的意思是"没有人分过类",【不是】"非受控"的同义词。给一条没人记录过的
-- 分类硬指一个值就是伪造 —— 而这里是【承重的】伪造:一个合规判断会踩在它上面。
-- 这个仓库已经三次遇到同一个形状,答案每次都一样:
--     no_reference(METAL-1)——"没有可比的对象",不是"比过、没问题"
--     「无检查记录」(METAL-1)——"当时还没有这项检查",不是"检查通过"
--     price_index IS NULL(METAL-2)——"没人说过它来自哪个市场",不是"来自 LME"
-- fixture 53 的 A 臂就是钉这一条:【没分类】与【分类为非受控】必须分得开,
-- 而一个把 NULL 当成非受控的实现,能通过其它每一条断言。
--
-- 【本刀不做的事,写在这里因为读的人会到这里来找】
--   * Basel 代码、UN 编号、HS 编码 —— 那是【另外几套编码体系】,不是这一个字段的
--     取值。它们各自有各自的位数、校验规则与签发机构,挤进一列会得到一个
--     "有时是这个有时是那个"的字段。
--   * 法域差异 —— 同一批货在新加坡、欧盟、中国的分类【可以不同】,所以正确的形状
--     多半是"每个法域一条分类",而不是物料上的一个值。
--   * 这两件都取决于 Tim 第一票跨境货【实际走哪条路】。现在录进来,是拿着一副
--     已经看过底牌的样子在猜 —— 而猜出来的编码会被下一个人当成查过的事实。
--   完整的落点分析在 docs/compliance-scoping.md,那里已经把它们按"事务范围 /
--   主数据范围 / 日历范围"分过类;本刀只落主数据范围里最小的那一格。
--
-- 【与既有 category / chemistry 不重复,已核对】(见迁移末尾的说明)
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE TABLE public.waste_classifications (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    -- 【是否属于受控废物】—— 这一列才是合规逻辑将来会读的那个布尔量,
    -- 而 code 是给人看的。分类名可以增删改,"受不受控"是它的语义。
    is_controlled boolean NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.waste_classifications IS
    'MAT-1:受控废物分类字典(RUNTIME CONFIG,certificate_types 的形状)。加第三种分类是加一行,不是跑一次迁移。【本表不含 Basel 代码 / UN 编号 / HS 编码,也不含法域差异】—— 那些是另外几套编码体系,各有各的位数与签发机构,而同一批货在不同法域下的分类可以不同;真要做,形状多半是"每个法域一条",不是这里的一个值。见 docs/compliance-scoping.md。';

COMMENT ON COLUMN public.waste_classifications.is_controlled IS
    'MAT-1:这一类【是不是受控废物】。合规逻辑将来读的是它,不是 code —— 分类的名字会增删改,而"受不受控"是它的语义。';

CREATE TRIGGER trg_waste_classifications_updated_at
    BEFORE UPDATE ON public.waste_classifications
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.waste_classifications ENABLE ROW LEVEL SECURITY;
-- 读:人人可读(物料主数据本身就是 module.materials.view;分类是它的一个属性)
CREATE POLICY "waste_classifications select"
    ON public.waste_classifications AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "waste_classifications write by permission"
    ON public.waste_classifications AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.materials.edit'))
    WITH CHECK (has_permission('module.materials.edit'));

-- ── 引导:Tim 点名的两个,理由写在行上 ──────────────────────────────────────
INSERT INTO public.waste_classifications (code, name_en, name_zh, is_controlled, sort_order, notes) VALUES
    ('focused', 'Focused material', '重点物料', true, 1,
     'Doc 1 里 Tim 用这个词同时回答了【合规仓储的要求】与【一个采购类别】—— 它指的是需要受控处置与受控存放的那一类。is_controlled = true 是这个词的语义,不是一个默认值。'),
    ('non_focused', 'Non-focused material', '非重点物料', false, 2,
     '与上一条相对:不需要受控处置的那一类。【它不是"未分类"的同义词】—— 未分类是 materials.waste_classification_code IS NULL,意思是没有人分过类,而这一行的意思是【有人分过,结论是不受控】。两者在合规判断上不是一回事。');

-- ── 物料上的那一列 ──────────────────────────────────────────────────────────
ALTER TABLE public.materials
    ADD COLUMN waste_classification_code text REFERENCES public.waste_classifications (code);

COMMENT ON COLUMN public.materials.waste_classification_code IS
$$MAT-1:这个物料的受控废物分类。

【NULL = 没有人分过类,不是"非受控"】既有物料全部是 NULL,而且【不回填】:
给一条没人记录过的分类硬指一个值就是伪造,并且是【承重的】伪造 —— 一个合规判断
会踩在它上面。同一个形状这个仓库已经遇到过三次(METAL-1 的 no_reference 与
「无检查记录」、METAL-2 的 price_index IS NULL),答案每次都一样。

【与 category / chemistry 不重复,已核对】category 说的是"它在我们的流程里是哪一种
东西"(进料-电池 / 产出-黑粉 / 耗材辅料),chemistry 说的是正极化学体系
(NMC / LFP / …)。两者都是【我们怎么看这批货】;本列说的是【监管怎么看它】,
是一个法规属性。三者会同时成立而互不蕴含:一种非受控的进料电池,与一种受控的
进料电池,category 与 chemistry 可以一模一样。$$;

COMMIT;
