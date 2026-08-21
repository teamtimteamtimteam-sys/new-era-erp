'use server'

// EQP-2d:机器那一页上的三组动作 —— 保养、停机、保养间隔。
//
// 【守卫在库里,这里只做两件事】翻错误、刷页面 —— 与 month-end/actions.ts 同形。
// **唯一的例外是"拒空"**:决定期间/排程的日期、以及描述与理由,由动作【独立】
// 拒一次(AGENTS.md:提交控件禁用 + 服务端独立拒空,两层都是机制,UI 上的
// required 是第三层不算数)。表上的 NOT NULL 是第四层兜底,而它的消息里没有
// 约束名、按名认不出来 —— 所以这里抛具名码。
//
// 【为什么是直连表而不是 RPC】EQP-2a/2b/2c 建的是表 + RLS,没有任何 RPC。
// 改写入路径是一次设计变更,不是一次上屏 —— 记在 docs/known-issues.md。
// 于是这里每一处 insert/update 撞上的都是【约束违反】,由
// localizeEquipmentError 按【约束名】翻(见那支文件的抬头,它与其余
// *ErrorCodes.ts 不是同一种东西)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeEquipmentError } from '../equipmentErrorCodes'

export type ActState = { error?: string; success?: boolean }

function refresh(assetId: string) {
    revalidatePath(`/finance/assets/${assetId}`)
    revalidatePath('/finance/assets')
    revalidatePath('/')          // 两支臂就画在首页上
}

// ── P1/P2:记一次保养或维修 ─────────────────────────────────────────────────
export async function recordMaintenance(input: {
    assetId: string
    performedOn: string
    kind: string
    description: string
    performerKind: 'employee' | 'supplier' | 'name'
    employeeId: string | null
    supplierId: string | null
    performerName: string
    expenseId: string | null
    capitalised: boolean
    capitalisationReason: string
    notes: string
}): Promise<ActState> {
    // 【拒空,独立于表单】—— 空着的日期若被默默补成今天,整条保养排程会往后挪,
    // 而没有任何东西看得出来(equipment_maintenance.performed_on 的列注释写着这句)。
    if (!input.performedOn) return { error: await localizeEquipmentError('MAINT_DATE_REQUIRED') }
    if (!input.description.trim()) return { error: await localizeEquipmentError('MAINT_DESCRIPTION_REQUIRED') }

    const employee = input.performerKind === 'employee' ? (input.employeeId || null) : null
    const supplier = input.performerKind === 'supplier' ? (input.supplierId || null) : null
    const typed = input.performerKind === 'name' ? input.performerName.trim() : ''
    // 【三选一,而且必须选中一个】表上那条 performer_shape 说的就是这件事;
    // 这里先拒一次,好让消息说的是"你还没选人",而不是一句约束名。
    if (!employee && !supplier && !typed) {
        return { error: await localizeEquipmentError('MAINT_PERFORMER_REQUIRED') }
    }

    const supabase = await createClient()
    const { error } = await supabase.from('equipment_maintenance').insert({
        equipment_id: input.assetId,
        performed_on: input.performedOn,
        kind: input.kind,
        description: input.description.trim(),
        performed_by_employee_id: employee,
        performed_by_supplier_id: supplier,
        performed_by_name: typed || null,
        expense_id: input.expenseId || null,
        capitalised: input.capitalised,
        // 【理由留空就留 NULL,不要写空串】表上那条 CHECK 用的是
        // COALESCE(btrim(reason),'') <> '' —— 空串与 NULL 它都拒,而存一个空串
        // 会让"有理由但是空的"这种读法变得可能。
        capitalisation_reason: input.capitalisationReason.trim() || null,
        notes: input.notes.trim() || null,
    } as never)
    if (error) return { error: await localizeEquipmentError(error.message) }
    refresh(input.assetId)
    return { success: true }
}

// ── P3:开一段停机 ─────────────────────────────────────────────────────────
export async function openDowntime(input: {
    assetId: string; startedAt: string; reason: string; notes: string
}): Promise<ActState> {
    if (!input.startedAt) return { error: await localizeEquipmentError('DOWNTIME_START_REQUIRED') }
    if (!input.reason.trim()) return { error: await localizeEquipmentError('DOWNTIME_REASON_REQUIRED') }
    const supabase = await createClient()
    // 【ended_at 留空 = 这一段还开着】uq_equipment_downtime_open 只盖住 ended_at
    // 为空的行,所以第二段开口会撞上它 —— 那条拒绝正是 P3 要让人看见的那一句。
    const { error } = await supabase.from('equipment_downtime').insert({
        equipment_id: input.assetId,
        started_at: input.startedAt,
        ended_at: null,
        reason: input.reason.trim(),
        notes: input.notes.trim() || null,
    } as never)
    if (error) return { error: await localizeEquipmentError(error.message) }
    refresh(input.assetId)
    return { success: true }
}

// ── P3:关一段停机 ─────────────────────────────────────────────────────────
export async function closeDowntime(input: {
    assetId: string; downtimeId: string; endedAt: string
}): Promise<ActState> {
    if (!input.endedAt) return { error: await localizeEquipmentError('DOWNTIME_END_REQUIRED') }
    const supabase = await createClient()
    // 【不在这里比 ended_at >= started_at】那是表上 equipment_downtime_period_order
    // 的活。在 TS 里再比一遍就是同一条规矩的第二份实现,而本仓库为"两份实现必然
    // 漂开"付过很多次账 —— 让库来拒,句子由约束名翻。
    const { error } = await supabase.from('equipment_downtime')
        .update({ ended_at: input.endedAt } as never)
        .eq('id', input.downtimeId)
    if (error) return { error: await localizeEquipmentError(error.message) }
    refresh(input.assetId)
    return { success: true }
}

// ── P4:存一条保养间隔(新增或改) ───────────────────────────────────────────
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
    // 【两个都空就当场拒】表上那条 at_least_one 也会拒,而这一句先说人话。
    // 【提前量【不】在这里校验】lead < interval 是表上 lead_*_shape 的活 ——
    // 在 TS 里再写一遍就是第二份实现。让库拒,句子由约束名翻(W1 正面走它)。
    if (kg === null && days === null) {
        return { error: await localizeEquipmentError('INTERVAL_NOTHING_STATED') }
    }
    const row = {
        equipment_id: input.assetId,
        kind: input.kind,
        interval_kg: kg,
        // 【提前量与它的量度成对】量度为空时提前量必须也为空,否则表上那条
        // shape CHECK 会拒 —— 这一处不是"再实现一遍规则",是把表单里那个
        // 用不上的输入框归零,免得一个看不见的旧值跟着提交。
        lead_kg: kg === null ? null : (input.leadKg.trim() === '' ? null : Number(input.leadKg)),
        interval_days: days,
        lead_days: days === null ? null : (input.leadDays.trim() === '' ? null : Number(input.leadDays)),
        disposition: input.disposition,
        notes: input.notes.trim() || null,
        updated_at: new Date().toISOString(),
    }
    const supabase = await createClient()
    const { error } = input.intervalId
        ? await supabase.from('equipment_service_intervals').update(row as never).eq('id', input.intervalId)
        : await supabase.from('equipment_service_intervals').insert(row as never)
    if (error) return { error: await localizeEquipmentError(error.message) }
    refresh(input.assetId)
    return { success: true }
}

// ── P4:删掉一条保养间隔 = 回到【未监控】 ────────────────────────────────────
// 【它与 disposition='ignore' 不是一回事】删行 = 我们不再盯这台机器的这一种活;
// ignore = 照旧算得出到期,只是不上看板。表注把这两个状态分开写着,屏幕上也要
// 分开 —— 用删行去"关灯",会把"不想被打扰"记成"从来没决定过"。
export async function deleteServiceInterval(assetId: string, intervalId: string): Promise<ActState> {
    const supabase = await createClient()
    const { error } = await supabase.from('equipment_service_intervals').delete().eq('id', intervalId)
    if (error) return { error: await localizeEquipmentError(error.message) }
    refresh(assetId)
    return { success: true }
}
