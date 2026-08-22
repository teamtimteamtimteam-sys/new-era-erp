-- db/tables/materials.sql
-- 物料主档。
--
-- 【PROC-1(2026-08-21):category 已退役,换成 material_kinds 这张字典。】
-- 退役的依据是量出来的(docs/proc-reality.md N10/F1/F3):视图 0 处、函数 0 处、
-- fixture 只有一处读它(53 的 A 臂,已改读 kind_code 且因此更强),
-- 唯一的读者是物料列表的筛选下拉,而它的合法取值住在【第三个地方】
-- (app/materials/options.ts,已随本刀移除 CATEGORY_OPTIONS)。
-- 也就是说【没有任何一处拿它做决定】,而它的取值已经与数据矛盾:
-- MAT-2026-0001 标着「进料-电池」却有 10 个产出批 —— 方向不是物料的属性。
--
-- code 'MAT-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,
-- 主档无审计连号要求)。软删除 deleted_at;status 自由文本。
-- 注意线上【没有】updated_at 触发器(建表早期漏挂,updated_at 靠应用层写)——
-- 镜像忠实于线上;要补触发器请走迁移,别只改这里。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.material_code_seq;

CREATE TABLE public.materials (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code       text NOT NULL UNIQUE,  -- 'MAT-YYYY-NNNN',触发器取号
    name       text NOT NULL,
    chemistry  text REFERENCES public.battery_chemistries (code),
    unit       text NOT NULL DEFAULT 'kg',
    spec       text,
    notes      text,
    status     text NOT NULL DEFAULT 'draft',
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    created_by uuid,
    updated_at timestamptz NOT NULL DEFAULT now(),
    updated_by uuid,
    -- ── MAT-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 受控废物分类。【NULL = 没有人分过类,不是"非受控"】—— 既有物料全部是 NULL
    -- 且【不回填】:给一条没人记录过的分类硬指一个值是伪造,而且是承重的伪造。
    -- 与 category(它在我们流程里是哪一种东西)、chemistry(正极化学体系)不重复:
    -- 那两个是【我们怎么看】,这个是【监管怎么看】,三者同时成立而互不蕴含。
    waste_classification_code text REFERENCES public.waste_classifications (code),
    -- ── SS-1 追加(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────────────
    -- 安全库存阈值。【NULL = 不监控 = 还没有人做过这个决定】,绝不等于"阈值为零":
    -- 告警对 NULL 一次都不响,而那个"不响"【不可以被读成"查过了,没问题"】——
    -- METAL-1 的 no_reference 那一课。物料列表因此把"未监控"明写出来,不留空。
    -- CHECK 只允许 NULL 或 > 0:阈值 0 是把"不监控"写成一个看起来像监控的数字,
    -- 而"不监控"的唯一写法是留空。
    safety_stock_qty numeric,
    CONSTRAINT materials_safety_stock_qty_positive
        CHECK (safety_stock_qty IS NULL OR safety_stock_qty > 0),
    -- ── PROC-1 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────
    -- 【为什么不是 NOT NULL】D2 要 NOT NULL,而"不许为满足约束编造值"同时成立;
    -- 八行既有物料【每一行都被批次引用着】,删不掉(删物料要一路串进总账)。
    -- 于是用 materials_kind_stated 那条 NOT VALID 的 CHECK:新行必拦,旧行留空。
    -- 本表自己的先例:waste_classification_code(MAT-1,既有行全 NULL 不回填)。
    kind_code        text REFERENCES public.material_kinds (code),
    may_be_processed boolean,
    -- ── PROC-2 追加的三条【状态轴】(ALTER 加的列排在末尾)───────────────────
    -- 【有条件适用,而条件本身是数据】适用与否由 material_kinds.has_condition_axes
    -- 与 material_forms.implies_dismantling 回答,由 guard_material_condition_axes
    -- 两个方向都执行(该填没填要拦,不适用却填了也要拦)。
    form_code        text REFERENCES public.material_forms (code),
    source_code      text REFERENCES public.material_sources (code),
    size_format_code text REFERENCES public.material_size_formats (code)
);

-- 【NOT VALID 必须【单独一条 ALTER】,不能写进 CREATE TABLE 里】
-- 实测:写在 CREATE TABLE 的列约束里,PostgreSQL 收下它但把约束标成 valid ——
-- 于是线上 convalidated = false、重建 = true,两边的 pg_get_constraintdef 一个带
-- 「NOT VALID」一个不带,check_mirrors 当场红。
-- 【而且这不是为了绕过检查】重建库里【也必须】是 NOT VALID:生产就是一次重建,
-- 而这条约束的语义就是"对新行强制、不回头校验" —— 那个语义要跟着重建走。
-- 先例三处:containers_code_format / inventory_movements_business_date_required /
-- inbound_batch_metals_content_source_required,全部是这个写法。
ALTER TABLE public.materials
    ADD CONSTRAINT materials_kind_stated
    CHECK (kind_code IS NOT NULL AND may_be_processed IS NOT NULL) NOT VALID;

CREATE OR REPLACE FUNCTION public.generate_material_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'MAT-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('material_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_material_code
    BEFORE INSERT ON public.materials
    FOR EACH ROW EXECUTE FUNCTION generate_material_code();

ALTER TABLE public.materials ENABLE ROW LEVEL SECURITY;
CREATE POLICY "materials select by permission"
    ON public.materials
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view'::text));

CREATE POLICY "materials insert by permission"
    ON public.materials
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));

CREATE POLICY "materials update by permission"
    ON public.materials
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text)) WITH CHECK (has_permission('module.materials.edit'::text));

CREATE POLICY "materials delete by permission"
    ON public.materials
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.materials.edit'::text));

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

COMMENT ON COLUMN public.materials.safety_stock_qty IS
    'SS-1:安全库存阈值(按物料的计量单位)。【NULL = 不监控 = 还没有人做过这个决定】,绝不等于"阈值为零":告警对 NULL 一次都不响,而这个"不响"【不可以被读成"查过了,没问题"】—— 那是 METAL-1 的 no_reference 那一课(一个不会响的检查比没有检查更坏,因为人以为系统在替他盯着)。所以物料列表把"未监控"明写出来,不留空。CHECK 只允许 NULL 或 > 0:阈值 0 是把"不监控"写成一个看起来像监控的数字,而"不监控"的唯一写法是留空。告警是【采购信号】—— 低于阈值不拦任何销售、投料或收货。';

-- NTF-1:分类【改变】的那一刻,已经躺在库位上的存量可能就此违规 ——
-- IOD-2 的闸只在货落地那一刻查,而那批货不会再落地一次给它机会。
CREATE TRIGGER trg_materials_notify_reclassified
    AFTER UPDATE ON public.materials
    FOR EACH ROW
    WHEN (OLD.waste_classification_code IS DISTINCT FROM NEW.waste_classification_code)
    EXECUTE FUNCTION public.trg_notify_material_reclassified();

COMMENT ON COLUMN public.material_kinds.may_ever_be_processed IS
'PROC-1:这一类东西【有没有可能】被一炉加工吃掉。

【它与 materials.may_be_processed 是两个问题,不是一个】
本列说的是【这一类】(耗材永远不可能是投料);那一列说的是【这一件】
(某一种电池料,我们决定不投它)。前者是一条规则,后者是一次判断。
两者的关系由 guard_material_kind_processable 执行:
**这一列为 false 时,那一列不许为 true。反之【不】强制** ——
一件可以被投料的东西,我们完全可能决定不投它。';

COMMENT ON COLUMN public.materials.kind_code IS
'PROC-1:这一种物料【是什么】—— 指向 material_kinds。

【为什么不是 NOT NULL,而这【不是】一次退让】D2 要的是 NOT NULL,而 D7 同时
禁止"为了满足约束而编造值"。两者在今天【互相矛盾】,因为 materials 的八行
(四在册 + 四软删)**每一行都被批次引用着**,删不掉:MAT-2026-0001 有 9 进
10 出,连 ZZ-SMOKE-PROBE 上都挂着一张在册的 IN-2026-0180(100,000 kg,
AGENTS.md 点名"不要删")。真正的 NOT NULL 必须为这八行编造八个值。
**处置:materials_kind_stated 那条 CHECK ... NOT VALID** —— 新行必须说出来,
旧行留空不动,而【留空的意思就是"没有人决定过"，那是真话】。
本表自己的先例:MAT-1 的 waste_classification_code(既有物料全部 NULL,不回填);
同族先例:FIN-32 的 business_date。**清库发生在切换那一天,不是本刀。**

【NOT VALID 在 UPDATE 上也拦,而那是【想要的】】改一行既有物料时,
它会要求你顺手把种类说出来 —— 也就是说这八行【在有人决定它们是什么之前改不动】。
屏幕上必须把这句话说成人话(物料表单已接),而不是漏一条裸约束名出去。';

COMMENT ON COLUMN public.materials.may_be_processed IS
'PROC-1:这一种物料【可不可以被一炉加工吃掉】—— 加工那道闸唯一读的就是这一列。

【它与 material_kinds.may_ever_be_processed 是两个问题】那一列说【这一类】
有没有可能(耗材永远不可能);本列说【这一件】要不要。前者是规则,后者是判断。

【为什么"这里产的"不是一列】黑粉既买进来也自己产 —— 而"它是不是这里产的"
的答案是"它有没有产出批",不是它身上的一个布尔。线上两个真实物料【都】同时
有进料批与产出批,所以任何按功能切一刀的单值分区今天就不成立。';

COMMENT ON CONSTRAINT materials_kind_stated ON public.materials IS
'PROC-1:一行物料必须【同时】说出它是什么、以及能不能投料。
NOT VALID:对 INSERT 与 UPDATE 生效,而八行历史留空不动 ——
它们【本来就是"没有人决定过"】,回填等于发明一个没人记录过的事实
(MAT-1 在本表上做过同样的决定,FIN-32 在 business_date 上做过同样的决定)。';

-- ── PROC-1:两列不许互相矛盾(跨表规矩 → 触发器,CHECK 看不见另一张表)──
CREATE OR REPLACE FUNCTION public.guard_material_kind_processable()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_allowed boolean;
    v_zh      text;
BEGIN
    -- 种类还没说 → 不是本守卫的事,交给 materials_kind_stated 那条 CHECK。
    -- 【八行历史行正落在这里】它们 kind_code 为空,本守卫对它们一言不发。
    IF NEW.kind_code IS NULL OR NEW.may_be_processed IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT mk.may_ever_be_processed, mk.name_zh INTO v_allowed, v_zh
      FROM material_kinds mk WHERE mk.code = NEW.kind_code;
    -- 外键保证查得到;查不到只可能是外键被绕过,那要响,不要静默放行。
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATERIAL_KIND_NOT_FOUND|%', NEW.kind_code;
    END IF;
    IF NEW.may_be_processed AND NOT v_allowed THEN
        RAISE EXCEPTION 'MATERIAL_KIND_NOT_PROCESSABLE|%|%', NEW.kind_code, v_zh
          USING HINT = '这一类东西不可能被投料;要改的是它的种类,或者那一类的规则。';
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_material_kind_processable() FROM PUBLIC, anon;

COMMENT ON FUNCTION public.guard_material_kind_processable() IS
'PROC-1:materials.may_be_processed 不许越过它那一类的 may_ever_be_processed。

════════════════════════════════════════════════════════════════════════════
【它【挡不住】什么 —— 写在这里,因为本仓库最常犯的缺陷是守卫的名字比它的射程宽】

它挡住的是【不可能】:一个 consumable / packaging / spare_part 被标成可投料。
**它挡不住【一个本该可投料的 battery_material 被建成 may_be_processed = false】**
—— 那是一个业务判断,schema 看不见,而且它的症状是【沉默】:
有人想投料,发现投不了,而那一刻离建卡那一刻可能隔着几个月。

**那一半由两处负责,都不是这个守卫:**
  1. **物料表单把这个选择【明说出来】**(PROC-1 同刀),不给默认值 ——
     一个预设某一侧的勾选框就是一个没人做过的决定,从表单进来而不是从 NULL 进来;
  2. **物料列表上一个筛选**:kind_code = ''battery_material'' 且
     may_be_processed = false 的行。**它【不该】做成看板的一支臂** ——
     那不是"等着人处理的事",它可能完全正确(确实有不该被加工的电池料)。
     与 EQP-2d 记下的「哪些机器没人在盯」同一个形状、同一条判据。
════════════════════════════════════════════════════════════════════════════';

CREATE TRIGGER trg_materials_kind_processable
    BEFORE INSERT OR UPDATE ON public.materials
    FOR EACH ROW EXECUTE FUNCTION public.guard_material_kind_processable();

COMMENT ON COLUMN public.materials.form_code IS
'PROC-2:这一种物料是什么形态 —— 决定货进哪一条链。
【只对带状态轴的种类成立】适用条件是 material_kinds.has_condition_axes;
不适用时留空【是"不适用"】,不是"没人决定过"。那个区别由那一列回答。';

COMMENT ON COLUMN public.materials.source_code IS
'PROC-2:这一种物料从哪来 —— 决定废物代码,以及"要不要放电"这个问题成不成立。
【与供应商类型互相独立】理由(三条,都量过)写在 material_sources 的表注上。';

COMMENT ON COLUMN public.materials.size_format_code IS
'PROC-2:来自哪一类应用 —— 决定拆解工作量与搬运方式。
【适用条件是 material_forms.implies_dismantling】黑粉与极片废料没有拆解可言,
所以它们这一列留空【是"不适用"】。**这是本刀里第二处"空有两种意思"的地方,
而两处都由数据回答,不由读的人猜。**';

-- ── PROC-2:状态轴的有条件必填(跨表 → 触发器)──────────────────────────
CREATE OR REPLACE FUNCTION public.guard_material_condition_axes()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_needs boolean;
    v_dismantle boolean;
BEGIN
    -- 种类还没说 → 不是本守卫的事(materials_kind_stated 管那一条)。
    -- 【八行历史物料正落在这里】它们 kind_code 为空,本守卫对它们一言不发。
    IF NEW.kind_code IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT mk.has_condition_axes INTO v_needs FROM material_kinds mk WHERE mk.code = NEW.kind_code;
    IF NOT COALESCE(v_needs, false) THEN
        -- 【这一类没有状态轴 —— 那三列必须【空着】,不许填】
        -- 允许填,就等于允许"一箱吨袋是整包形态"这种句子存在。
        IF NEW.form_code IS NOT NULL OR NEW.source_code IS NOT NULL OR NEW.size_format_code IS NOT NULL THEN
            RAISE EXCEPTION 'MATERIAL_KIND_HAS_NO_CONDITION_AXES|%', NEW.kind_code
              USING HINT = '这一类物料没有形态/来源/规格尺寸可言;要填这三列,先改它的种类。';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.form_code IS NULL OR NEW.source_code IS NULL THEN
        RAISE EXCEPTION 'MATERIAL_CONDITION_AXES_REQUIRED|%', NEW.kind_code
          USING HINT = '这一类物料要说出形态与来源 —— 两者都永远不会替你填。';
    END IF;
    SELECT mf.implies_dismantling INTO v_dismantle FROM material_forms mf WHERE mf.code = NEW.form_code;
    IF v_dismantle THEN
        IF NEW.size_format_code IS NULL THEN
            RAISE EXCEPTION 'MATERIAL_SIZE_FORMAT_REQUIRED|%', NEW.form_code
              USING HINT = '这个形态需要拆解,所以要说出它来自哪一类应用(拆解工作量由它决定)。';
        END IF;
    ELSE
        -- 【不拆解的形态不许有规格尺寸】黑粉没有"来自哪一类应用"可言 ——
        -- 允许填,那一列就会长出一堆没人能依据的值,而空与非空再也分不清含义。
        IF NEW.size_format_code IS NOT NULL THEN
            RAISE EXCEPTION 'MATERIAL_SIZE_FORMAT_NOT_APPLICABLE|%', NEW.form_code
              USING HINT = '这个形态不需要拆解(黑粉、极片废料),规格尺寸对它不适用。';
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_material_condition_axes() FROM PUBLIC, anon;

COMMENT ON FUNCTION public.guard_material_condition_axes() IS
'PROC-2:三条物料级状态轴的【有条件必填】,以及它的反面【不适用就不许填】。

【为什么两个方向都要拦】只拦"该填没填",那一列就会在不适用的行上长出值,
于是"空"再也不只有一种意思 —— 而把空的两种意思分开,正是这三条轴存在的理由之一。

【它管不到什么】它保证这三列【被回答了】,保证不了【答对了】:
一批实际是模组的料被登记成整包,schema 看不见。那一半靠收货的人与走查。

【适用条件全部是【数据】,不是写死的 code】
  * 哪些种类要回答 → material_kinds.has_condition_axes
  * 哪些形态要说规格尺寸 → material_forms.implies_dismantling
改一行数据就改行为,而这正是 PROC-1 把 CHECK 换成字典换来的东西。';

CREATE TRIGGER trg_materials_condition_axes
    BEFORE INSERT OR UPDATE ON public.materials
    FOR EACH ROW EXECUTE FUNCTION public.guard_material_condition_axes();

COMMENT ON COLUMN public.materials.chemistry IS
'PROC-5:指向 battery_chemistries 那张字典(外键 materials_chemistry_fkey,已验证)。

【留空 = 没有人记过】它【不是】"不适用" —— 后者由 material_kinds.has_condition_axes
回答(一箱吨袋没有化学体系可言)。PROC-2 的 G18 把这个区别记了下来,
PROC-5 据此把「不适用」这个取值退役了:同一个问题有两个答案,两个答案会不一致。

【本刀把一行占位串置成了 NULL,而那不是丢信息】
MAT-2026-0002 原本存着「Special Chemistry Structure」—— 一个从旧自由文本口进来的
占位串。它不是化学体系信息;置空之后,"**没有人说过这批料到底是什么**"
变成一件读得出来的事。原值记在迁移文件里,复原只要一行 UPDATE ——
但复原之前得先有人说出它是什么。

【自由文本口关上了】从前这一列会静静收下任何字符串(线上就长出过一个)。
现在加一种化学体系 = 往字典里加一行,门槛是 module.materials.edit。';
