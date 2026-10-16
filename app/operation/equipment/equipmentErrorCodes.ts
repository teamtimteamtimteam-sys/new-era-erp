import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// EQP-2d:设备三张表的拒绝 → 人话。
//
// ════════════════════════════════════════════════════════════════════════════
// ★ MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):【这一支回到本仓库通用的 `CODE|参数` 形状】
//   EQP-2d 写它的时候,停机 / 保养 / 间隔三张表一个 RPC 都没有,写入走 PostgREST 直连 + RLS,于是拒绝到达浏览器时是 Postgres 的
//   【约束违反】,这一支只好按【约束名】认(十六条约束,每一条一句人话)。那是 known-issues 里 EQP-2d 登记的缓解,不是消除 ——
//   约束名成了公开契约的一半,而 NOT NULL 违反没有名字,"拒空"那一族因此两套机制并存。
//   本刀给三张表配了五支函数(open_ · close_ · correct_equipment_downtime · record_equipment_maintenance ·
//   save_equipment_service_interval),每一条拒绝都在函数里先按名 RAISE;三张表的直连 INSERT / UPDATE 策略拿掉、直连写按名拒
//   (EQUIPMENT_THROUGH_FUNCTION_ONLY)。**约束本身留着**(它们挡的是属主那条路),但屏幕不再依赖它们的名字 —— 那正是那一条的删除条件。
//   万一哪一条约束仍然够到屏幕(一次并发),它交给共用兜底:短码留在句子里,不是一串 Postgres 英文。
//   文件从 app/finance/assets/ 搬到这里,因为写设备的那一页现在是 /operation/equipment/[id];资产卡与月结仍然 import 它。
// ════════════════════════════════════════════════════════════════════════════
//
// 【加一个码 = 来这里加一个名字】check-i18n 的 equipment.errors.* 后缀集合现读下面这个 Set,所以漏了句子 npm run build 当场红。
// 【逐条从函数体数出来的】重数一遍:
//   grep -rhoE "RAISE EXCEPTION .[A-Z_]+" db/functions/open_equipment_downtime.sql db/functions/close_equipment_downtime.sql …
const EQUIPMENT_ERROR_CODES = new Set([
    // APR-9:这台资产挂着一张在等的处置申请 —— 从资产页追加成本(record_expense)按名拒
    'ASSET_DISPOSAL_REQUESTED',
    // ── 五支函数共用的两句判据(equipment_record_target · downtime_cause_check)──────────────────
    'EQUIPMENT_NOT_FOUND', 'EQUIPMENT_NOT_A_MACHINE',
    'DOWNTIME_CAUSE_REQUIRED', 'DOWNTIME_CAUSE_UNKNOWN', 'DOWNTIME_CAUSE_INACTIVE',
    // ── 停机:开 · 关 · 更正(MES-7a-1)与表上的两道(guard_downtime_cause · guard_downtime_period)──────
    'DOWNTIME_START_REQUIRED', 'DOWNTIME_END_REQUIRED', 'DOWNTIME_REASON_REQUIRED',
    'DOWNTIME_ALREADY_OPEN', 'DOWNTIME_ALREADY_CLOSED', 'DOWNTIME_END_BEFORE_START', 'DOWNTIME_CORRECT_CANNOT_CLOSE',
    'DOWNTIME_NOTHING_CHANGED', 'DOWNTIME_SOURCE_RESERVED', 'DOWNTIME_SOURCE_FIXED',
    // FIX-1:一件【发生过】的事不可能在明天发生(guard_downtime_period —— 它们要把冲突本身写进句子里)
    'DOWNTIME_START_IN_FUTURE', 'DOWNTIME_END_IN_FUTURE', 'DOWNTIME_OVERLAPS', 'ASSET_IN_SERVICE_IN_FUTURE',
    // U1-B(UNBLOCK-1 Q15):停机可以更正、可以作废,永远不硬删 —— guard_downtime_write 抛前三条,void_equipment_downtime 抛后三条。
    //   参数 {0} 是那一段的【起始时刻】(新加坡时间,YYYY-MM-DD HH24:MI),DOWNTIME_NOT_FOUND 的 {0} 是 id。
    'DOWNTIME_NEVER_DELETED', 'DOWNTIME_VOIDED', 'DOWNTIME_VOID_THROUGH_FUNCTION_ONLY',
    'DOWNTIME_NOT_FOUND', 'DOWNTIME_ALREADY_VOIDED', 'DOWNTIME_VOID_REASON_REQUIRED',
    // ── 直连写按名拒(guard_equipment_direct_write)—— {0} 表,{1} 动作 ─────────────────────────────
    'EQUIPMENT_THROUGH_FUNCTION_ONLY',
    // ── 保养维修(record_equipment_maintenance)─────────────────────────────────────────────────
    'MAINT_DATE_REQUIRED', 'MAINT_KIND_INVALID', 'MAINT_DESCRIPTION_REQUIRED', 'MAINT_PERFORMER_REQUIRED',
    'MAINT_PERFORMER_AMBIGUOUS', 'MAINT_EMPLOYEE_NOT_FOUND', 'MAINT_SUPPLIER_NOT_FOUND', 'MAINT_EXPENSE_NOT_FOUND',
    'MAINT_REASON_REQUIRED',
    'MAINTENANCE_DOWNTIME_NOT_FOUND', 'MAINTENANCE_DOWNTIME_OTHER_MACHINE', 'MAINTENANCE_DOWNTIME_VOIDED',
    // ── 保养间隔(save_equipment_service_interval)───────────────────────────────────────────────
    'INTERVAL_NOT_FOUND', 'INTERVAL_OTHER_MACHINE', 'INTERVAL_KIND_INVALID', 'INTERVAL_NOTHING_STATED',
    'INTERVAL_VALUE_INVALID', 'INTERVAL_LEAD_REQUIRED', 'INTERVAL_LEAD_NOT_BELOW', 'INTERVAL_DISPOSITION_INVALID',
    'INTERVAL_ALREADY_SET',
    // ── 可靠性(equipment_reliability)────────────────────────────────────────────────────────────
    'RELIABILITY_RANGE_INVALID',
    // ── record_expense 那一族:资本化那条路(CAPEX-1)────────────────────────────────────────────
    'ASSET_ALREADY_IN_SERVICE',
    'ASSET_IN_SERVICE_NEEDS_MAINTENANCE', 'MAINTENANCE_NOT_FOUND',
    'MAINTENANCE_ASSET_MISMATCH', 'MAINTENANCE_NOT_CAPITALISED',
    'MAINTENANCE_ALREADY_CAPITALISED', 'MAINTENANCE_NOT_APPLICABLE',
    'ASSET_LIFE_EXHAUSTED', 'DEPRECIATION_ANCHOR_IMMUTABLE',
    'ASSET_DISPOSED',
    // ── MES-7a-2(2026-10-16,MES-7a Step 0 Q12–Q15):备件出给保养与退回(issue_spare_parts · return_spare_parts)与表上的几道 ──────
    //   重数:grep -rhoE "RAISE EXCEPTION .[A-Z_]+" db/functions/issue_spare_parts.sql db/functions/return_spare_parts.sql
    //         db/functions/guard_part_issue_write.sql db/functions/guard_maintenance_movement.sql db/functions/guard_maintenance_capitalise_parts.sql
    //   另加流水上那一道质量暂扣(guard_quality_hold)与批次找不到(INBOUND_NOT_FOUND)—— 出库会撞上它们,句子要说的是"这一批"。
    'PART_ISSUE_DATE_REQUIRED', 'PART_ISSUE_DATE_IN_FUTURE', 'PART_ISSUE_CAPITALISED', 'PART_ISSUE_NO_LINES', 'PART_ISSUE_NO_BATCH',
    'PART_NOT_SPARE_PART', 'PART_QTY_INVALID', 'SPARE_PART_UNPRICED', 'PART_ISSUE_EXCEEDS_AVAILABLE',
    'PART_RETURN_REASON_REQUIRED', 'PART_RETURN_DATE_REQUIRED', 'PART_RETURN_DATE_IN_FUTURE', 'PART_ISSUE_NOT_FOUND',
    'PART_RETURN_BEFORE_ISSUE', 'PART_RETURN_BATCH_WRITTEN_OFF', 'PART_RETURN_EXCEEDS_ISSUED',
    'PART_ISSUES_THROUGH_FUNCTION_ONLY', 'PART_ISSUE_IMMUTABLE', 'MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY', 'MAINTENANCE_HAS_PARTS',
    'QUALITY_HOLD_OPEN', 'INBOUND_NOT_FOUND',
    // ── B3(2026-09-20):set_asset_planned_in_service 抛的那一条(PERMISSION_DENIED 由 refuseFromCoded 的分支 ① 在本地化器之前接住)──
    'ASSET_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeEquipmentError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    // 具名码:`CODE|参数0|参数1`
    const match = raw.match(CODE_RE)
    if (match && EQUIPMENT_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
        return t('equipment.errors.' + match[1], params)
    }

    // 认不出的交给共用兜底 lib/machine-text.ts —— 一个看不见的错比一个丑陋的错坏得多。
    return await fallbackForRawError(raw, 'localizeEquipmentError@app/operation/equipment/equipmentErrorCodes.ts')
}
