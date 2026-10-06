-- db/tables/ingest_data_classes.sql
-- MES-1(2026-10-06,MES-0 §3.2 · §3.5;MES-1 Step 0 Q3 · Q12,Tim):采集层的【数据类】字典。
--
-- 【一类数据 = 一行】一台设备送来的每一条消息都声明它是哪一类(weighing · discharge_module · …);
--   这一行说的是:这一类由哪一支转换函数验证并规整(transform_function),以及它最终落到哪一种正式记录(target_en,给人读的)。
-- 【transform_function 为空 = 还没有转换器】这一类的消息照收,停在收件箱里,状态 awaiting_transform,看得见、不丢
--   (MES-0 §3.2:目标还没建的类)。MES-1 只给 connection_test 一支转换器 —— 它证明分派、成功、失败、重试与丢弃;
--   其余八类各由它的刀接上(称重 MES-2 · 放电 MES-5a · 控制器与工位 MES-4a · 电表 MES-5a · 扫码 MES-3b · 在线质量 MES-6a ·
--   安全报警 MES-7b)。
-- 【INSTALL SEED,只经迁移改】(Q12)这一行【点名一支会按名字被执行的函数】,所以它不是运营改得动的配置:
--   没有写策略;check_mirrors 逐行比对(SEED_TABLES)。transform_function 的形状由 CHECK 钉成
--   transform_<类>_v<版本> —— 分派器只认 public.<这个名字>(jsonb)。一次格式改动 = 一支 _v<n+1> + 一次迁移(规格 §6.4)。
-- 【manual_entry_code】手工录入这一类要持的码。MES-1 全部为空:手工录入的整条路在 MES-2(Q14);MES-2 给 weighing 填
--   action.confirm_capture(MES-2 Step 0 Q15)。
-- 【creates_draft】(MES-2 Step 0 Q4)这一类转换成功之后要不要落一张草稿(capture_drafts)等人确认 —— 分派器读它。
--   weighing 为真;connection_test 为假(它不落任何业务记录)。之后每一类在它自己那一刀的迁移里打开它。ALTER 加的列,所以在最后。
-- 【MES-2 起 check_mirrors 真的逐行比对它】(MES-2 Step 0 Q5)—— 上面那句"逐行比对"在 MES-1 时是假的(SEED_TABLES 里没有它)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.ingest_data_classes (
    code               text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en            text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh            text NOT NULL CHECK (btrim(name_zh) <> ''),
    target_en          text NOT NULL CHECK (btrim(target_en) <> ''),
    transform_function text CHECK (transform_function ~ '^transform_[a-z0-9_]+_v[0-9]+$'),
    manual_entry_code  text REFERENCES public.permissions (code),
    is_active          boolean NOT NULL DEFAULT true,
    sort_order         integer NOT NULL,
    creates_draft      boolean NOT NULL DEFAULT false
);

COMMENT ON TABLE public.ingest_data_classes IS
    'MES-1:采集层的数据类字典(INSTALL SEED,只经迁移改)。每一条进来的消息声明它属于哪一类;transform_function 点名验证并规整它的那一支函数 public.<名>(jsonb),为空 = 这一类还没有转换器,消息停在收件箱里(awaiting_transform)。MES-1 只有 connection_test 一支转换器;其余八类各由它的刀接上。';
COMMENT ON COLUMN public.ingest_data_classes.creates_draft IS
    'MES-2:这一类转换成功之后,分派器在同一个子事务里落一张草稿(capture_drafts)等人确认。weighing 为真;connection_test 为假。';
COMMENT ON COLUMN public.ingest_data_classes.transform_function IS
    '转换函数的名字(不带参数):分派器调 public.<名>(jsonb)。形状由 CHECK 钉成 transform_<类>_v<版本>。为空 = 还没有转换器。';

INSERT INTO public.ingest_data_classes (code, name_en, name_zh, target_en, transform_function, manual_entry_code, is_active, sort_order, creates_draft) VALUES
    ('connection_test', 'Connection test', '连通测试', 'No record: proves that a device reaches the system end to end', 'transform_connection_test_v1', NULL, true, 10, false),
    ('weighing', 'Weighing', '称重', 'Weighing records', 'transform_weighing_v1', 'action.confirm_capture', true, 20, true),
    ('discharge_module', 'Discharge result per module', '逐模组放电结果', 'Per-module discharge results (MES-5a)', NULL, NULL, true, 30, false),
    ('controller_summary', 'Controller batch summary', '控制器批次汇总', 'Processing-run values (MES-4a)', NULL, NULL, true, 40, false),
    ('meter_reading', 'Meter reading', '电表读数', 'Meter readings (MES-5a)', NULL, NULL, true, 50, false),
    ('workstation_event', 'Workstation event', '工位事件', 'Processing-run events (MES-4a)', NULL, NULL, true, 60, false),
    ('scan', 'Scan', '扫码', 'Scan events (MES-3b)', NULL, NULL, true, 70, false),
    ('inline_quality', 'Inline quality reading', '在线质量读数', 'Assay indicators (MES-6a)', NULL, NULL, true, 80, false),
    ('safety_alarm', 'Safety alarm', '安全报警', 'Incidents (MES-7b)', NULL, NULL, true, 90, false);

ALTER TABLE public.ingest_data_classes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "ingest_data_classes select by permission" ON public.ingest_data_classes
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.ingest_data_classes FROM anon;
