-- db/functions/floor_board_arms.sql
-- MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):【车间大屏画哪几支 —— 一份闭合的清单】。大屏「只有计数,来自 operations_now 的加工、安全与库存那几支」。
--   判据(fixture 273 BOARD 按它逐支核对 operations_arms_all,多一支少一支都红):
--     ① 门是 module.processing.view · module.safety.view · module.inventory.view 的【每一支】(加工 13 · 安全 4 · 库存 2);
--     ② 外加四支车间上的事、门却是别的码:capture_draft_pending(采集的确认队列,门 action.confirm_capture —— 加工那一侧的采集)、
--        stocktake_open(开着的盘点,门 module.stocktakes.view)、safety_state_dwell 与 quarantine_required(库存安全 —— 鼓包 / 漏液的批
--        还不在隔离库位、一条安全状态待过了 V3,门按批是进料 / 产出的查看码;它们画在 /inventory/storage-safety 上)。
--   一共二十三支。【只给计数】:floor_board() 按支数行,不吐 subject、item_code、名字、钱或健康信息。
--   V28 的 tiles 只能从这里挑(set_floor_board_settings 按名拒)。纯函数,不读任何表。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b2-wall-display.sql.
CREATE OR REPLACE FUNCTION public.floor_board_arms()
 RETURNS TABLE(item_type text, section text, sort_order integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT a.item_type, a.section, a.sort_order FROM (VALUES
        ('work_order_overdue',                 'processing', 10),
        ('work_order_variance_beyond',         'processing', 20),
        ('processing_balance_unclosed',        'processing', 30),
        ('contamination_check_missing',        'processing', 40),
        ('discharge_unverified',               'processing', 50),
        ('discharge_quarantine_pending',       'processing', 60),
        ('capture_draft_pending',              'processing', 70),
        ('capture_inbox_failed',               'processing', 80),
        ('gateway_silent',                     'processing', 90),
        ('equipment_service_due',              'processing', 100),
        ('equipment_service_approaching',      'processing', 110),
        ('instrument_calibration_due',         'processing', 120),
        ('instrument_calibration_approaching', 'processing', 130),
        ('allocation_stale',                   'processing', 140),
        ('incident_nea_notify_due',            'safety',     210),
        ('incident_report_due',                'safety',     220),
        ('inspection_due',                     'safety',     230),
        ('inspection_finding_open',            'safety',     240),
        ('quarantine_required',                'inventory',  310),
        ('safety_state_dwell',                 'inventory',  320),
        ('storage_ceiling_exceeded',           'inventory',  330),
        ('safety_stock_below',                 'inventory',  340),
        ('stocktake_open',                     'inventory',  350)
    ) a(item_type, section, sort_order);
$function$;
