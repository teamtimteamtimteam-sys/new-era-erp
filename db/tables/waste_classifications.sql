-- db/tables/waste_classifications.sql
-- 受控废物分类字典(MAT-1)。Doc 1 里 Tim 用"重点物料 / 非重点物料"同时回答了
-- 合规仓储的要求与一个采购类别 —— 这个区分本来就在他脑子里,只是系统里没有。
--
-- NOTE: introduced by db/migrations/2026-08-12-mat1-waste-classification.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- 加第三种分类应当是【加一行】(与 certificate_types 同一条),所以它是表不是 CHECK。
-- check_mirrors.py 不逐行比对本表。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【本表不含的东西,写在这里因为读的人会到这里来找】
-- Basel 代码、UN 编号、HS 编码,以及法域差异 —— 那是另外几套编码体系,各有各的
-- 位数、校验规则与签发机构;而同一批货在新加坡、欧盟、中国的分类【可以不同】,
-- 所以那件事的正确形状多半是"每个法域一条分类",不是这里的一个值。
-- 两者都取决于 Tim 第一票跨境货实际走哪条路 —— 现在录进来是拿着看过底牌的样子
-- 在猜,而猜出来的编码会被下一个人当成查过的事实。落点分析见 docs/compliance-scoping.md。

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
