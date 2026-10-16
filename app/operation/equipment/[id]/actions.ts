'use server'

// MES-7a-1(2026-10-15,MES-7a Step 0 Q6,Tim):一台机器的三组动作 —— 停机、保养维修、保养间隔 —— 从财务的资产卡搬到这里(加工的人干的活,
//   记在加工的那一页上)。码不变:module.processing.edit(仓库不加)。
//
// 【写只经函数】EQP-2d 的直连表写换成五支函数(open_ · close_ · correct_equipment_downtime · record_equipment_maintenance ·
//   save_equipment_service_interval),作废照旧 void_equipment_downtime;三张表的 INSERT 与 UPDATE 策略拿掉了。
//   于是拒绝回到本仓库通用的 `CODE|参数` 形状(equipmentErrorCodes.ts 不再按约束名认 —— known-issues 里 EQP-2d 那一条的删除条件)。
// 【拒空仍在这里先拒一次】决定排程的日期、说明与原因由动作独立拒空(AGENTS.md:提交控件禁用 + 服务端独立拒空),
//   函数里是同一组码的第二道。
// 【删一条保养间隔仍是直连 DELETE】那张表的 DELETE 策略刻意留着:删一条 = 回到「未监控」(表注写着为什么它与 ignore 不是一回事)。
//   零行不许报告成功(ALERT-1):删之前读一次,删之后问它还在不在。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeEquipmentError } from '../equipmentErrorCodes'
import { refuseFromCoded, refuseNothingChanged } from '@/lib/action-refusal'

export type ActState = { error?: string; success?: boolean }

function refresh(assetId: string) {
    revalidatePath(`/operation/equipment/${assetId}`)
    revalidatePath('/operation/equipment')
    revalidatePath('/operation/equipment/reliability')
    revalidatePath(`/finance/assets/${assetId}`)
    revalidatePath('/finance/assets')
    revalidatePath('/tools/reminders')   // 两支保养臂画在提醒页上
}

async function refuse(message: string): Promise<ActState> {
    // refuseFromCoded:PERMISSION_DENIED|<码> 由它的分支 ① 接住(本地化器没有那一支),其余交给 localizeEquipmentError。
    return { error: (await refuseFromCoded(message, localizeEquipmentError)).error }
}

// ── 记一次保养或维修(可以点名它修好的那一段停机 —— 只能是同一台机器、没有作废的)────────────────────
export async function recordMaintenance(input: {
    assetId: string
    performedOn: string
    kind: string
    description: string
    performerKind: 'employee' | 'supplier' | 'name'
    employeeId: string | null
    supplierId: string | null
    performerName: string
    downtimeId: string | null
    expenseId: string | null
    capitalised: boolean
    capitalisationReason: string
    notes: string
}): Promise<ActState> {
    if (!input.performedOn) return { error: await localizeEquipmentError('MAINT_DATE_REQUIRED') }
    if (!input.description.trim()) return { error: await localizeEquipmentError('MAINT_DESCRIPTION_REQUIRED') }
    const employee = input.performerKind === 'employee' ? (input.employeeId || null) : null
    const supplier = input.performerKind === 'supplier' ? (input.supplierId || null) : null
    const typed = input.performerKind === 'name' ? input.performerName.trim() : ''
    if (!employee && !supplier && !typed) return { error: await localizeEquipmentError('MAINT_PERFORMER_REQUIRED') }
    if (input.capitalised && !input.capitalisationReason.trim()) return { error: await localizeEquipmentError('MAINT_REASON_REQUIRED') }

    const supabase = await createClient()
    const { error } = await supabase.rpc('record_equipment_maintenance', {
        p_equipment_id: input.assetId,
        p_performed_on: input.performedOn,
        p_kind: input.kind,
        p_description: input.description.trim(),
        p_performed_by_employee_id: employee ?? undefined,
        p_performed_by_supplier_id: supplier ?? undefined,
        p_performed_by_name: typed || undefined,
        p_downtime_id: input.downtimeId || undefined,
        p_expense_id: input.expenseId || undefined,
        p_capitalised: input.capitalised,
        p_capitalisation_reason: input.capitalised ? input.capitalisationReason.trim() : undefined,
        p_notes: input.notes.trim() || undefined,
    })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    return { success: true }
}

// ── 开一段停机(原因必选 —— 类别 failure · planned · external 之一;说明仍是自由文本)────────────────────
export async function openDowntime(input: {
    assetId: string; startedAt: string; causeCode: string; reason: string; notes: string
}): Promise<ActState> {
    if (!input.startedAt) return { error: await localizeEquipmentError('DOWNTIME_START_REQUIRED') }
    if (!input.causeCode) return { error: await localizeEquipmentError('DOWNTIME_CAUSE_REQUIRED') }
    if (!input.reason.trim()) return { error: await localizeEquipmentError('DOWNTIME_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('open_equipment_downtime', {
        p_equipment_id: input.assetId,
        p_started_at: input.startedAt,
        p_cause_code: input.causeCode,
        p_reason: input.reason.trim(),
        p_notes: input.notes.trim() || undefined,
    })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    return { success: true }
}

// ── 关一段停机 ─────────────────────────────────────────────────────────────────────────────
// 【这一页说的是这台机器】函数只认 downtime_id;先读一次它是不是这台机器的,对不上就按 NOT_FOUND 说(从别处带来的 id 不改别的机器)。
async function downtimeOnThisMachine(assetId: string, downtimeId: string): Promise<ActState | null> {
    const supabase = await createClient()
    const { data: row, error } = await supabase.from('equipment_downtime')
        .select('id').eq('id', downtimeId).eq('equipment_id', assetId).maybeSingle()
    if (error) return refuse(error.message)
    if (!row) return { error: await localizeEquipmentError(`DOWNTIME_NOT_FOUND|${downtimeId}`) }
    return null
}

export async function closeDowntime(input: {
    assetId: string; downtimeId: string; endedAt: string
}): Promise<ActState> {
    if (!input.endedAt) return { error: await localizeEquipmentError('DOWNTIME_END_REQUIRED') }
    const off = await downtimeOnThisMachine(input.assetId, input.downtimeId)
    if (off) return off
    const supabase = await createClient()
    const { error } = await supabase.rpc('close_equipment_downtime', { p_downtime_id: input.downtimeId, p_ended_at: input.endedAt })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    return { success: true }
}

// ── 更正一段停机:起止时刻、原因、说明(开着的那一段结束时刻传 null —— 它只由"关上它"关)──────────────────
export async function correctDowntime(input: {
    assetId: string; downtimeId: string; startedAt: string; endedAt: string | null; causeCode: string; reason: string
}): Promise<ActState> {
    if (!input.startedAt) return { error: await localizeEquipmentError('DOWNTIME_START_REQUIRED') }
    if (input.endedAt !== null && !input.endedAt) return { error: await localizeEquipmentError('DOWNTIME_END_REQUIRED') }
    if (!input.causeCode) return { error: await localizeEquipmentError('DOWNTIME_CAUSE_REQUIRED') }
    if (!input.reason.trim()) return { error: await localizeEquipmentError('DOWNTIME_REASON_REQUIRED') }
    const off = await downtimeOnThisMachine(input.assetId, input.downtimeId)
    if (off) return off
    const supabase = await createClient()
    // 【`as unknown as string` 是量具的限制,不是一次放宽】生成的类型把每一个 timestamptz 形参写成 string,表达不了"收 NULL";
    //   而这支函数对开着的那一段【就要】NULL(= 不借更正把它关上)。断言的是类型,不是值(先例:actions.ts 的 set_asset_planned_in_service)。
    const { error } = await supabase.rpc('correct_equipment_downtime', {
        p_downtime_id: input.downtimeId,
        p_started_at: input.startedAt,
        p_ended_at: input.endedAt as unknown as string,
        p_cause_code: input.causeCode,
        p_reason: input.reason.trim(),
    })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    return { success: true }
}

// ── 作废一段【从来没有发生过】的停机(U1-B 的函数,不变)────────────────────────────────────────────
export async function voidDowntime(input: {
    assetId: string; downtimeId: string; reason: string
}): Promise<ActState> {
    if (!input.reason.trim()) return { error: await localizeEquipmentError('DOWNTIME_VOID_REASON_REQUIRED') }
    const off = await downtimeOnThisMachine(input.assetId, input.downtimeId)
    if (off) return off
    const supabase = await createClient()
    const { error } = await supabase.rpc('void_equipment_downtime', { p_downtime_id: input.downtimeId, p_reason: input.reason.trim() })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    return { success: true }
}

// ── 存一条保养间隔(新加或改)───────────────────────────────────────────────────────────────────
export async function saveServiceInterval(input: {
    assetId: string
    intervalId: string | null
    kind: string
    intervalKg: string
    leadKg: string
    intervalDays: string
    leadDays: string
    disposition: string
    notes: string
}): Promise<ActState> {
    const kg = input.intervalKg.trim() === '' ? null : Number(input.intervalKg)
    const days = input.intervalDays.trim() === '' ? null : Number(input.intervalDays)
    if (kg === null && days === null) return { error: await localizeEquipmentError('INTERVAL_NOTHING_STATED') }
    const leadKg = input.leadKg.trim() === '' ? null : Number(input.leadKg)
    const leadDays = input.leadDays.trim() === '' ? null : Number(input.leadDays)
    const supabase = await createClient()
    // 空的量度与提前量是 NULL(函数按名说"少了哪一个"),不是 0 —— 同上,断言的是类型。
    const { error } = await supabase.rpc('save_equipment_service_interval', {
        p_equipment_id: input.assetId,
        p_interval_id: (input.intervalId || null) as unknown as string,
        p_kind: input.kind,
        p_interval_kg: kg as unknown as number,
        p_lead_kg: leadKg as unknown as number,
        p_interval_days: days as unknown as number,
        p_lead_days: leadDays as unknown as number,
        p_disposition: input.disposition,
        p_notes: input.notes.trim() || undefined,
    })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    return { success: true }
}

// ── 删掉一条保养间隔 = 回到【未监控】(表上的 DELETE 策略,不经函数 —— 见本文件抬头)──────────────────────
export async function deleteServiceInterval(assetId: string, intervalId: string): Promise<ActState> {
    const supabase = await createClient()
    const { data, error } = await supabase.from('equipment_service_intervals')
        .delete().eq('id', intervalId).eq('equipment_id', assetId).select('id')
    if (error) return refuse(error.message)
    if (!data || data.length === 0) return await refuseNothingChanged('module.processing.edit')
    refresh(assetId)
    return { success: true }
}

// ── MES-7a-2(2026-10-16,MES-7a Step 0 Q12 · Q13 · Q14 · Q15):备件出给一条保养记录,与它的退回 ──────────────────────────
//   码 module.inventory.edit(函数里查;不加新码,没有审批 —— Q10)。钱在函数里过账(借 6800 / 贷 1200,退回反过来),这里一分都不算。
//   【这一页说的是这台机器】函数只认 maintenance_id / issue_id;先问一次它是不是这台机器的,对不上就按 NOT_FOUND 说。
//   【拒空在这里先拒一次】日期、数量、理由由动作独立拒空(AGENTS.md:提交控件禁用 + 服务端独立拒空),函数里是同一组码的第二道。
async function maintenanceOnThisMachine(assetId: string, maintenanceId: string): Promise<ActState | null> {
    const supabase = await createClient()
    const { data: row, error } = await supabase.from('equipment_maintenance')
        .select('id').eq('id', maintenanceId).eq('equipment_id', assetId).maybeSingle()
    if (error) return refuse(error.message)
    if (!row) return { error: await localizeEquipmentError(`MAINTENANCE_NOT_FOUND|${maintenanceId}`) }
    return null
}

export async function issueSpareParts(input: {
    assetId: string; maintenanceId: string; issuedOn: string; lines: { batchId: string; quantity: string }[]
}): Promise<ActState> {
    if (!input.issuedOn) return { error: await localizeEquipmentError('PART_ISSUE_DATE_REQUIRED') }
    const lines = input.lines.filter((l) => l.batchId)
    if (lines.length === 0) return { error: await localizeEquipmentError('PART_ISSUE_NO_LINES') }
    for (const l of lines) {
        const q = Number(l.quantity)
        if (!l.quantity.trim() || !Number.isFinite(q) || q <= 0) return { error: await localizeEquipmentError(`PART_QTY_INVALID|-|${l.quantity || '?'}`) }
    }
    const off = await maintenanceOnThisMachine(input.assetId, input.maintenanceId)
    if (off) return off
    const supabase = await createClient()
    const { error } = await supabase.rpc('issue_spare_parts', {
        p_maintenance_id: input.maintenanceId,
        p_issued_on: input.issuedOn,
        p_lines: lines.map((l) => ({ inbound_batch_id: l.batchId, quantity: Number(l.quantity) })),
    })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    revalidatePath('/inventory')
    revalidatePath('/operation/balance')
    return { success: true }
}

export async function returnSpareParts(input: {
    assetId: string; issueId: string; quantity: string; returnedOn: string; reason: string
}): Promise<ActState> {
    if (!input.reason.trim()) return { error: await localizeEquipmentError('PART_RETURN_REASON_REQUIRED') }
    if (!input.returnedOn) return { error: await localizeEquipmentError('PART_RETURN_DATE_REQUIRED') }
    const q = Number(input.quantity)
    if (!input.quantity.trim() || !Number.isFinite(q) || q <= 0) return { error: await localizeEquipmentError(`PART_QTY_INVALID|-|${input.quantity || '?'}`) }
    const supabase = await createClient()
    // 这一行出库是不是这台机器的(经它的保养记录)
    const { data: row, error: readErr } = await supabase.from('maintenance_part_issues')
        .select('id, equipment_maintenance!inner(equipment_id)').eq('id', input.issueId).eq('kind', 'issue')
        .eq('equipment_maintenance.equipment_id', input.assetId).maybeSingle()
    if (readErr) return refuse(readErr.message)
    if (!row) return { error: await localizeEquipmentError(`PART_ISSUE_NOT_FOUND|${input.issueId}`) }
    const { error } = await supabase.rpc('return_spare_parts', {
        p_issue_id: input.issueId, p_quantity: q, p_returned_on: input.returnedOn, p_reason: input.reason.trim(),
    })
    if (error) return refuse(error.message)
    refresh(input.assetId)
    revalidatePath('/inventory')
    revalidatePath('/operation/balance')
    return { success: true }
}

