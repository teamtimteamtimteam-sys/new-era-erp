-- db/tables/certificate_types.sql
-- 证书/资质类型(CMP-1)。RUNTIME CONFIG:引导播种默认值,操作员在界面上增改 ——
-- 加一种证书是编辑一行,不是跑一次迁移(与 leave_types 同一形状,check_mirrors
-- 不逐行比对)。disposition(block/warn/ignore)决定过期后果:收货闸门与看板臂
-- 都从这里现读 —— 改一行数据即改变行为,不改代码。
-- 播种的默认值哪些是【默认】哪些是【决定】,行内 notes 写明。
-- NOTE: introduced by db/migrations/2026-08-09-cmp1-certificate-types-and-compliance-framework.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.certificate_types (
    code           text PRIMARY KEY,
    name_en        text NOT NULL,
    name_zh        text NOT NULL,
    -- block:过期即挡收货;warn:只提醒;ignore:不提醒不挡
    disposition    text NOT NULL CHECK (disposition IN ('block', 'warn', 'ignore')),
    -- 到期前多少天开始上看板
    warn_lead_days integer NOT NULL DEFAULT 90 CHECK (warn_lead_days >= 0),
    is_active      boolean NOT NULL DEFAULT true,
    sort_order     integer NOT NULL DEFAULT 0,
    notes          text
);

COMMENT ON TABLE public.certificate_types IS
    '证书/资质类型(CMP-1)。RUNTIME CONFIG:引导播种默认值,操作员在界面上增改 —— 加一种证书是编辑一行,不是跑一次迁移。disposition 决定过期后果(block 挡收货 / warn 只提醒 / ignore),warn_lead_days 决定到期前多少天上看板。下面播种的默认值哪些是【默认】哪些是【决定】,行内 notes 写明。';

ALTER TABLE public.certificate_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "certificate_types select all"
    ON public.certificate_types
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (true);   -- 类型目录不敏感:与 leave_types/currencies 同一处置
CREATE POLICY "certificate_types insert by permission"
    ON public.certificate_types
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.suppliers.edit'::text));
CREATE POLICY "certificate_types update by permission"
    ON public.certificate_types
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.suppliers.edit'::text))
    WITH CHECK (has_permission('module.suppliers.edit'::text));

-- 【默认值的理由写在行上,读的人才分得清"默认"与"决定"】——
-- Basel / Article 18 / TFS / NEA / GWDF 是【处理或移动受控废物的法定前置条件】,
-- 缺了它交易本身违法 → block;ISO 一类管理体系认证是【商业保证】,过期是商务
-- 瑕疵不是违法 → warn。Tim 改任何一条 = 在界面上编辑那一行。
INSERT INTO public.certificate_types (code, name_en, name_zh, disposition, warn_lead_days, sort_order, notes) VALUES
    ('basel',      'Basel Convention',  '巴塞尔公约',        'block', 90, 1, '默认 block:跨境转移受控废物的法定前置。这是默认值,不是决定 —— 要改就改本行'),
    ('article_18', 'Article 18',        '第 18 条',          'block', 90, 2, '默认 block:同上,法定前置'),
    ('tfs',        'TFS Document',      'TFS 文件',          'block', 90, 3, '默认 block:跨境废物运输文件'),
    ('nea_import', 'NEA Import Permit', 'NEA 进口许可',      'block', 90, 4, '默认 block:新加坡国家环境局进口许可,缺了不能收'),
    ('gwdf',       'GWDF Licence',      'GWDF 执照',         'block', 90, 5, '默认 block:一般废物处置设施执照'),
    -- CMPL-1(2026-08-30):样本显示 NEA 还有一类【一般废物收集商执照】。
    -- ★加一类就是加一行★ —— 这正是本表作为 RUNTIME CONFIG 的意义,不加列、不动 schema。
    -- disposition 取 block,与 gwdf/basel/tfs/nea_import 同档(过期了就不该再收货);
    -- 到期提醒因此【自动继承】warn_lead_days,不需要另写一支臂。
    -- 【这是一个【类别】,不是样本上的任何一个【值】】—— 执照号码、设施、限额一个都没有进来。
    ('gwc',        'GWC Licence',       '一般废物收集商执照',   'block', 90, 6, '默认 block:一般废物收集商执照'),
    ('iso',        'ISO Certification', 'ISO 认证',          'warn',  60, 6, '默认 warn:管理体系认证是商业保证,过期是瑕疵不是违法'),
    ('other',      'Other',             '其他',              'warn',  30, 7, '默认 warn:未归类的证书先提醒,归了类再定处置'),
    -- ★ CONTRACT-1(2026-08-30):保险【就是一种证书】,不是第二套到期机制 ★
    --   保单有签发方、有号码、有有效期、过期要提醒 —— 这四件事这张机制已经在做,
    --   而且已经有两个消费方(operations_now 的看板臂、supplier_receiving_blocked
    --   的收货闸)。给保险再造一套,就是把那两样又写一遍。
    --   **默认 warn 而不是 block**:一份过期的保单是一个必须立刻处理的问题,
    --   但"挡住收货"是一个【经营决定】—— 谁来决定停不停工,不是本刀能替人裁的。
    --   而 disposition 是 RUNTIME CONFIG:真要改成 block,在界面上改一行就行,
    --   不用跑迁移。**这一行是【默认值】,不是【决定】。**
    ('insurance',  'Insurance Policy',  '保险单',            'warn',  60, 8, '默认 warn 是【默认值】不是决定:过期保单要立刻处理,但"停不停收货"是经营决定,disposition 在界面上改得动');
