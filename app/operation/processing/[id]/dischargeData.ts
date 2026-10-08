// MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q5–Q13,Tim):放电那一炉页面的读取 —— 服务端把行压平成字符串与布尔值,面板只画。
//   【读的都是带门的读法】discharge_status_by_batch · discharge_module_rows(加工 / 进料 / 产出查看码任一)、两张放电表(同一组码)、
//   devices(加工查看码 —— 这一页本来就要它)。库位要库存查看码:读不到时说「受限」,不把 RLS 的零行说成「没有隔离库位」。
//   新批的批号要产出查看码:读不到时说「受限」(同一条)。
//   【核实与否不在这里算】进度与"此刻是否开着已放电并核实"都是视图给的;一批在视图里没有行(这一炉回滚了、也没有模组数与结果)→ null,画成「—」。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'
import type { DischargeBatchView, DischargeResultView, DischargeChannelView, DischargeSplitView } from './DischargePanel'

type Opt = { value: string; label: string }
type InputLeg = {
    inbound_batches: { id: string; code: string } | null
    output_batches: { id: string; code: string } | null
}
type StatusRow = {
    batch_id: string; module_count: number | null; modules_recorded: number; passed: number; failed_redischarge: number
    failed_quarantine: number; split_out: number; contradictions: number; currently_verified: boolean
}
type LatestRow = { batch_id: string; module_ref: string; verdict: string; disposition: string | null; split_out: boolean }
type ResultRow = {
    id: number; batch_kind: string; batch_id: string; batch_code: string | null; module_ref: string; channel_no: number | null
    outlet_voltage_v: number; start_voltage_v: number | null; verdict: string; verdict_at: string; disposition: string | null
    duration_min: number | null; energy_recovered_wh: number | null; pass_voltage_v_at: number | null; contradicts_pass_voltage: boolean | null
    device_id: string | null; photo_path: string | null; notes: string | null; corrects_id: number | null; correction_reason: string | null
    is_latest: boolean; split_out: boolean
}
type ChannelRow = {
    id: number; inbound_batch_id: string | null; output_batch_id: string | null; channel_no: number; module_ref: string
    withdrawn: boolean; corrects_id: number | null; correction_reason: string | null
}
type SplitRow = {
    split_run_id: string; discharge_run_id: string; inbound_batch_id: string | null; output_batch_id: string | null
    module_ref: string; new_output_batch_id: string
}

const kindOf = (inbound: string | null): 'inbound' | 'output' => (inbound ? 'inbound' : 'output')
const n = (v: number | string | null) => (v === null ? null : Number(v))

export async function loadDischargePanel(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>,
    { runId, inputs, fmtStamp, shifts }: {
        runId: string; inputs: InputLeg[]
        fmtStamp: (iso: string | null) => string
        shifts: Opt[]
    },
) {
    const t = await getTranslations()
    const legs = inputs
        .map((l) => (l.inbound_batches ? { kind: 'inbound' as const, ...l.inbound_batches }
            : l.output_batches ? { kind: 'output' as const, ...l.output_batches } : null))
        .filter((x): x is { kind: 'inbound' | 'output'; id: string; code: string } => x !== null)
    const ids = legs.map((b) => b.id)
    const [locationsVisible, outputVisible] = await Promise.all([can('module.inventory.view'), can('module.output.view')])

    const [statusRes, latestRes, rowsRes, chanRes, splitRes, devRes, locRes] = await Promise.all([
        supabase.from('discharge_status_by_batch')
            .select('batch_id, module_count, modules_recorded, passed, failed_redischarge, failed_quarantine, split_out, contradictions, currently_verified')
            .in('batch_id', ids),
        supabase.from('discharge_module_rows').select('batch_id, module_ref, verdict, disposition, split_out')
            .in('batch_id', ids).eq('is_latest', true),
        supabase.from('discharge_module_rows')
            .select('id, batch_kind, batch_id, batch_code, module_ref, channel_no, outlet_voltage_v, start_voltage_v, verdict, verdict_at, disposition, duration_min, energy_recovered_wh, pass_voltage_v_at, contradicts_pass_voltage, device_id, photo_path, notes, corrects_id, correction_reason, is_latest, split_out')
            .eq('run_id', runId).order('id'),
        supabase.from('discharge_channel_assignments')
            .select('id, inbound_batch_id, output_batch_id, channel_no, module_ref, withdrawn, corrects_id, correction_reason')
            .eq('run_id', runId).order('id'),
        supabase.from('discharge_module_splits')
            .select('split_run_id, discharge_run_id, inbound_batch_id, output_batch_id, module_ref, new_output_batch_id')
            .eq('discharge_run_id', runId).order('id'),
        supabase.from('devices').select('id, code, name').eq('kind', 'discharge_cabinet').is('retired_at', null).order('code'),
        locationsVisible
            ? supabase.from('storage_locations').select('id, code, name').eq('is_active', true).eq('is_quarantine', true).order('code')
            : Promise.resolve({ data: [], error: null }),
    ])
    const status = new Map((mustRows(statusRes, 'discharge_status_by_batch') as unknown as StatusRow[]).map((s) => [s.batch_id, s]))
    const latest = mustRows(latestRes, 'discharge_module_rows') as unknown as LatestRow[]
    const devices = mustRows(devRes, 'devices') as unknown as { id: string; code: string; name: string }[]
    const deviceLabel = new Map(devices.map((d) => [d.id, `${d.code} — ${d.name}`]))
    const codeOf = new Map(legs.map((b) => [b.id, b.code]))

    const batches: DischargeBatchView[] = legs.map((b): DischargeBatchView => {
        const s = status.get(b.id)
        const mine = latest.filter((r) => r.batch_id === b.id)
        return {
            kind: b.kind, id: b.id, code: b.code, href: b.kind === 'inbound' ? `/inbound/${b.id}/edit` : `/output/${b.id}/edit`,
            moduleCount: s?.module_count ?? null,
            recorded: Number(s?.modules_recorded ?? 0), passed: Number(s?.passed ?? 0),
            failedRedischarge: Number(s?.failed_redischarge ?? 0), failedQuarantine: Number(s?.failed_quarantine ?? 0),
            splitOut: Number(s?.split_out ?? 0), contradictions: Number(s?.contradictions ?? 0),
            verified: s ? s.currently_verified : null,
            quarantineCandidates: mine.filter((r) => r.verdict === 'fail' && r.disposition === 'quarantine' && !r.split_out)
                .map((r) => r.module_ref).sort(),
            knownModules: mine.map((r) => r.module_ref).sort(),
        }
    })

    // 结果:更正链的末端(没有别的行指着它)
    const allRows = mustRows(rowsRes, 'discharge_module_rows') as unknown as ResultRow[]
    const supersededR = new Set(allRows.map((r) => r.corrects_id).filter((x): x is number => x !== null))
    const results: DischargeResultView[] = allRows.filter((r) => !supersededR.has(r.id)).map((r): DischargeResultView => ({
        id: r.id, kind: r.batch_kind === 'output' ? 'output' : 'inbound', batchId: r.batch_id, batchCode: r.batch_code ?? '—',
        moduleRef: r.module_ref, channelNo: r.channel_no, outletV: Number(r.outlet_voltage_v), startV: n(r.start_voltage_v),
        verdict: r.verdict === 'fail' ? 'fail' : 'pass',
        disposition: r.disposition === 'quarantine' ? 'quarantine' : r.disposition === 're_discharge' ? 're_discharge' : null,
        verdictAtIso: r.verdict_at, verdictAt: fmtStamp(r.verdict_at),
        durationMin: n(r.duration_min), energyWh: n(r.energy_recovered_wh),
        passVAt: n(r.pass_voltage_v_at), contradicts: r.contradicts_pass_voltage,
        deviceId: r.device_id, deviceLabel: r.device_id ? (deviceLabel.get(r.device_id) ?? r.device_id) : null,
        photoPath: r.photo_path, notes: r.notes, corrected: r.corrects_id !== null, correctionReason: r.correction_reason,
        isLatest: r.is_latest, splitOut: r.split_out,
    })).sort((a, b) => a.batchCode.localeCompare(b.batchCode) || a.moduleRef.localeCompare(b.moduleRef))

    // 通道:链的末端,撤下的不画
    const chans = mustRows(chanRes, 'discharge_channel_assignments') as unknown as ChannelRow[]
    const supersededC = new Set(chans.map((c) => c.corrects_id).filter((x): x is number => x !== null))
    const channels: DischargeChannelView[] = chans.filter((c) => !supersededC.has(c.id) && !c.withdrawn).map((c): DischargeChannelView => {
        const bid = (c.inbound_batch_id ?? c.output_batch_id) as string
        return {
            id: c.id, kind: kindOf(c.inbound_batch_id), batchId: bid, batchCode: codeOf.get(bid) ?? '—',
            channelNo: c.channel_no, moduleRef: c.module_ref, corrected: c.corrects_id !== null, correctionReason: c.correction_reason,
        }
    }).sort((a, b) => a.channelNo - b.channelNo)

    // 从这一炉拆出去的:按拆分那一炉归组
    const splitRows = mustRows(splitRes, 'discharge_module_splits') as unknown as SplitRow[]
    const splitRunIds = [...new Set(splitRows.map((s) => s.split_run_id))]
    const newIds = [...new Set(splitRows.map((s) => s.new_output_batch_id))]
    const [splitRunRes, newBatchRes] = await Promise.all([
        splitRunIds.length > 0
            ? supabase.from('processing_runs_masked').select('id, code').in('id', splitRunIds)
            : Promise.resolve({ data: [], error: null }),
        outputVisible && newIds.length > 0
            ? supabase.from('output_batches').select('id, code').in('id', newIds)
            : Promise.resolve({ data: [], error: null }),
    ])
    const splitRunCode = new Map((mustRows(splitRunRes, 'processing_runs_masked') as unknown as { id: string; code: string }[]).map((r) => [r.id, r.code]))
    const newCode = new Map((mustRows(newBatchRes, 'output_batches') as unknown as { id: string; code: string }[]).map((r) => [r.id, r.code]))
    const splits: DischargeSplitView[] = splitRunIds.map((sid) => {
        const mine = splitRows.filter((s) => s.split_run_id === sid)
        const parent = (mine[0].inbound_batch_id ?? mine[0].output_batch_id) as string
        return {
            splitRunId: sid, splitRunCode: splitRunCode.get(sid) ?? '—', batchCode: codeOf.get(parent) ?? '—',
            newBatchId: mine[0].new_output_batch_id,
            newBatchCode: outputVisible ? (newCode.get(mine[0].new_output_batch_id) ?? '—') : t('common.restricted'),
            modules: mine.map((s) => s.module_ref).sort(),
        }
    })

    const locations = (mustRows(locRes, 'storage_locations') as unknown as { id: string; code: string; name: string }[])
        .map((l) => ({ value: l.id, label: `${l.code} — ${l.name}` }))
    return {
        batches, results, channels, splits, locations, locationsVisible, shifts,
        devices: devices.map((d) => ({ value: d.id, label: `${d.code} — ${d.name}` })),
    }
}

/** 拆去隔离那一炉:它从哪一炉、哪几个模组来(页面上一句话 + 一个链接)。 */
export async function loadSplitOrigin(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>, runId: string,
) {
    const rows = mustRows(await supabase.from('discharge_module_splits')
        .select('discharge_run_id, module_ref').eq('split_run_id', runId).order('id'), 'discharge_module_splits') as unknown as
        { discharge_run_id: string; module_ref: string }[]
    if (rows.length === 0) return null
    const dischargeRunId = rows[0].discharge_run_id
    const runRow = mustRows(await supabase.from('processing_runs_masked').select('id, code').eq('id', dischargeRunId), 'processing_runs_masked') as unknown as
        { id: string; code: string }[]
    return { dischargeRunId, dischargeRunCode: runRow[0]?.code ?? null, modules: rows.map((r) => r.module_ref).sort() }
}
