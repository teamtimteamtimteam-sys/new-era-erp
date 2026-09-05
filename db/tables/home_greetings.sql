-- db/tables/home_greetings.sql
-- 首页那一行问候语的 72 句原文。六个时段 × 十二句。
--
-- NOTE: introduced by db/migrations/2026-09-05-ui1b-home-greeting-and-festival-doodles.sql.
-- First-run script (plain CREATEs).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【运行期配置 / RUNTIME CONFIG —— 下面的种子是"全新安装的默认值",不是线上快照】
-- ★ 这张表存在的【全部理由】就是:改一句问候语不该需要一次部署。★
--   messages/en.ts 有 7,393 行,是编译进包里的;改它一个字就是一次构建加一次
--   部署。所以 72 句住在库里 —— 与 public_holidays 同一类。
--   **线上与本文件不一致是正常的,不是漂移**,check_mirrors.py 不逐行比对它。
-- ═══════════════════════════════════════════════════════════════════════════
--
-- 【时段边界,与 lib/homeGreetingCore.ts:slotFor 逐字相同 —— 两处必须同改】
--   06:00–08:59 early_morning · 09:00–11:29 morning   · 11:30–13:29 midday
--   13:30–17:29 afternoon     · 17:30–21:59 evening   · 22:00–05:59 late_night
--   ★ 时段按【新加坡】的钟算,不按服务器的 ★ —— 一行写着「Good morning」的字
--   在一台 TZ=UTC 的机器上会在新加坡的下午四点出现。判据整段在那个文件抬头。

CREATE TABLE public.home_greetings (
    -- ★【id 是【可读的自然键】,不是 uuid】★ 它会被写进浏览器的 cookie
    --   (上一句是哪一句),而 uuid 每次重建都不一样 —— 那会让一份从仓库重建
    --   出来的库与线上对同一句话给出不同的 id。`morning-04` 重建一万次都一样,
    --   而且在 cookie 里、在 data-home-greeting 属性里都读得懂。
    id          text PRIMARY KEY CHECK (id ~ '^[a-z_]+-[0-9]{2}$'),
    slot        text NOT NULL CHECK (slot IN ('early_morning','morning','midday','afternoon','evening','late_night')),
    -- ★★【只有英文,而这是【裁定】,不是漏了 —— 不许"顺手补上中文"】★★
    --   Tim 的裁定(UI-1b,2026-09-05):**一个 zh 语言的读者看到英文问候语,
    --   那就是预期状态。** 先例是 kpi_score_rubric:band_en/band_zh 成对,而
    --   evidence_standard_en / management_action_en / veto_rule_en /
    --   review_cadence_en 【只有英文】,因为原始文本就是英文的。
    --   **也不许加一个空的 line_zh 列"留着以后填"** —— Tim 的原话:
    --   一个空列是一句 schema 替没人许下的承诺。
    --   真要中文,那是一次带着 72 句译文的裁定,不是一次列变更。
    line_en     text NOT NULL CHECK (btrim(line_en) <> ''),
    -- ★【没有 {name} 的一句话,是一句谁也没问候到的话】★ 而它不会报错,
    --   只会安静地少一个人名 —— 所以这条约束在库里,不在代码里。
    CONSTRAINT home_greetings_names_someone CHECK (line_en LIKE '%{name}%'),
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_home_greetings_slot ON public.home_greetings (slot) WHERE is_active;

CREATE TRIGGER trg_home_greetings_updated_at
    BEFORE UPDATE ON public.home_greetings
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.home_greetings ENABLE ROW LEVEL SECURITY;
-- 【任何登录用户可读】首页每个人都会打开,而问候语是说给他听的。
-- 与 public_holidays / kpi_score_rubric 同一条判据。
CREATE POLICY "home_greetings select all"
    ON public.home_greetings AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 【写入归设置】改一句问候语是一次系统文案调整,不属于任何业务模块。
CREATE POLICY "home_greetings insert by permission"
    ON public.home_greetings AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "home_greetings update by permission"
    ON public.home_greetings AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('action.manage_permissions')) WITH CHECK (has_permission('action.manage_permissions'));
CREATE POLICY "home_greetings delete by permission"
    ON public.home_greetings AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('action.manage_permissions'));

-- ── 种子:Tim 批准的 72 句原文 ──────────────────────────────────────────
INSERT INTO public.home_greetings (id, slot, line_en) VALUES
    ('early_morning-01', 'early_morning', 'Good morning, {name}.'),
    ('early_morning-02', 'early_morning', 'Early start, {name}.'),
    ('early_morning-03', 'early_morning', 'Morning, {name} — the plant is waking up.'),
    ('early_morning-04', 'early_morning', 'First one in, {name}?'),
    ('early_morning-05', 'early_morning', 'Morning, {name}. Coffee first.'),
    ('early_morning-06', 'early_morning', 'A quiet hour, {name}. Use it well.'),
    ('early_morning-07', 'early_morning', 'Good morning, {name}. Fresh page today.'),
    ('early_morning-08', 'early_morning', 'Morning, {name} — nothing has gone wrong yet.'),
    ('early_morning-09', 'early_morning', 'Up early, {name}. That counts for something.'),
    ('early_morning-10', 'early_morning', 'Morning, {name}. Let''s see what today brings.'),
    ('early_morning-11', 'early_morning', 'Good morning, {name}. Take it steady.'),
    ('early_morning-12', 'early_morning', 'Early light, {name}.'),
    ('morning-01', 'morning', 'Good morning, {name}.'),
    ('morning-02', 'morning', 'Morning, {name}. Deep in it already?'),
    ('morning-03', 'morning', 'Hello, {name}. Good hour for the hard thing.'),
    ('morning-04', 'morning', 'Morning, {name} — this is when the day is most yours.'),
    ('morning-05', 'morning', 'Hi, {name}. One thing at a time.'),
    ('morning-06', 'morning', 'Good morning, {name}. The quiet part is over.'),
    ('morning-07', 'morning', 'Morning, {name}. Still plenty of day left.'),
    ('morning-08', 'morning', 'Hello, {name}. Pick the difficult one first.'),
    ('morning-09', 'morning', 'Morning, {name} — you''re ahead of the afternoon.'),
    ('morning-10', 'morning', 'Hi, {name}. Steady progress counts.'),
    ('morning-11', 'morning', 'Good morning, {name}. No rush.'),
    ('morning-12', 'morning', 'Morning, {name}.'),
    ('midday-01', 'midday', 'Lunch, {name}? The work will wait.'),
    ('midday-02', 'midday', 'Midday, {name}. Eat something.'),
    ('midday-03', 'midday', 'Hello, {name}. Take the break.'),
    ('midday-04', 'midday', '{name}, the batches can spare you an hour.'),
    ('midday-05', 'midday', 'Half the day done, {name}.'),
    ('midday-06', 'midday', 'Lunchtime, {name}. Step away from the screen.'),
    ('midday-07', 'midday', 'Hi, {name}. Don''t skip it again.'),
    ('midday-08', 'midday', 'Midday, {name}. Food, then the rest.'),
    ('midday-09', 'midday', '{name}, even the plant stops for lunch.'),
    ('midday-10', 'midday', 'Halfway, {name}. Refuel.'),
    ('midday-11', 'midday', 'Hello, {name}. Eat first, decide after.'),
    ('midday-12', 'midday', 'Lunch break, {name}.'),
    ('afternoon-01', 'afternoon', 'Good afternoon, {name}.'),
    ('afternoon-02', 'afternoon', 'Afternoon, {name}. The long stretch.'),
    ('afternoon-03', 'afternoon', 'Hello, {name}. Still going?'),
    ('afternoon-04', 'afternoon', 'Afternoon, {name} — a good time to finish things, not start them.'),
    ('afternoon-05', 'afternoon', 'Hi, {name}. Clear one thing off the list.'),
    ('afternoon-06', 'afternoon', 'Good afternoon, {name}. Nearly through.'),
    ('afternoon-07', 'afternoon', 'Afternoon, {name}. Water helps.'),
    ('afternoon-08', 'afternoon', 'Hello, {name}. The quiet stretch before the end.'),
    ('afternoon-09', 'afternoon', 'Afternoon, {name} — small things add up now.'),
    ('afternoon-10', 'afternoon', 'Hi, {name}. Keep it moving.'),
    ('afternoon-11', 'afternoon', 'Good afternoon, {name}. Almost there.'),
    ('afternoon-12', 'afternoon', 'Afternoon, {name}.'),
    ('evening-01', 'evening', 'Good evening, {name}.'),
    ('evening-02', 'evening', 'Evening, {name}. Winding down?'),
    ('evening-03', 'evening', 'Hello, {name}. Long enough for one day.'),
    ('evening-04', 'evening', 'Evening, {name} — tomorrow will still be there.'),
    ('evening-05', 'evening', 'Hi, {name}. Finish the one, leave the rest.'),
    ('evening-06', 'evening', 'Good evening, {name}. You''ve done enough.'),
    ('evening-07', 'evening', 'Evening, {name}. Time to close the laptop soon.'),
    ('evening-08', 'evening', 'Hello, {name}. The day is nearly yours again.'),
    ('evening-09', 'evening', 'Evening, {name} — go home at some point.'),
    ('evening-10', 'evening', 'Hi, {name}. Last stretch.'),
    ('evening-11', 'evening', 'Good evening, {name}. Wrap it up gently.'),
    ('evening-12', 'evening', 'Evening, {name}.'),
    ('late_night-01', 'late_night', 'Still up, {name}?'),
    ('late_night-02', 'late_night', 'Late, {name}. It can wait until morning.'),
    ('late_night-03', 'late_night', 'Hello, {name}. Nothing here is urgent enough for this hour.'),
    ('late_night-04', 'late_night', '{name}, sleep is also part of the work.'),
    ('late_night-05', 'late_night', 'Late night, {name}. Be kind to tomorrow.'),
    ('late_night-06', 'late_night', 'Still here, {name}. Don''t make it a habit.'),
    ('late_night-07', 'late_night', 'Hello, {name}. Save it and go to bed.'),
    ('late_night-08', 'late_night', '{name}, the plant is asleep. You could be too.'),
    ('late_night-09', 'late_night', 'Late, {name}. Tomorrow-you will thank you.'),
    ('late_night-10', 'late_night', 'Still working, {name}? One more, then stop.'),
    ('late_night-11', 'late_night', 'Hello, {name}. This will look easier at nine.'),
    ('late_night-12', 'late_night', 'Late, {name}. Go rest.');
