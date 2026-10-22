// app/operation/equipment/reliability/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q5 · Q19,Tim)· 设备可靠性 —— 每一台机器多久坏一次(MTBF)、坏了多久修好(MTTR)
// ════════════════════════════════════════════════════════════════════════════
// 【数从哪里来】一行一台设备类资产(Q7),全部由 equipment_reliability(p_from, p_to) 算 —— 页面不算一个数。
//   运转小时 = 已提交未冲销的加工单 [开始, 结束) 的并集(重叠的只数一次);一次故障 = 未作废、原因属于 failure 类、开始落在区间里的停机;
//   MTBF = 小时 ÷ 次数;MTTR = 已关上的故障的平均时长。只数停机,不数加工单里的停机事件(Q19)。不算可用率,不算 OEE。
// 【区间】页面上选(开始日 · 结束日,新加坡时间,结束日含当天);不选 = 每一台机器【自己的】整段记录(取得日到此刻)—— 不发明一个窗口。
// 【分母要说出来】每一行旁边一句"这个小时数是怎么来的",以及区间里有几张单没有机器、没有时刻 —— 今天线上 0 张加工单记了机器,
//   所以每一台都读作"没有记录到运转小时";那不是一台没坏过的机器,是一个还没有分母的读数。
// 【门】requireModule(MOD.processing);函数自己再问 module.processing.view,不持就按名拒(不是零行)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { Refusal } from '@/app/components/ui/refusal'
import CellsTable, { type CellRow } from '../CellsTable'
import { xText, xInt, xNum } from '@/lib/export/cells'
import { hours, reliabilityWords, type ReliabilityRow } from '../reliability'
import { localizeEquipmentError } from '../equipmentErrorCodes'

const DAY = /^\d{4}-\d{2}-\d{2}$/

/** 新加坡那一天的零点;结束日【含当天】,所以结束取第二天零点。读不懂的日期不是"没给",是一句拒绝。 */
function bound(day: string | undefined, end: boolean): { ok: true; at: string | null } | { ok: false } {
    if (!day) return { ok: true, at: null }
    if (!DAY.test(day) || Number.isNaN(Date.parse(day))) return { ok: false }
    const d = new Date(`${day}T00:00:00+08:00`)
    if (end) d.setUTCDate(d.getUTCDate() + 1)
    return { ok: true, at: d.toISOString() }
}

export default async function ReliabilityPage({ searchParams }: { searchParams: Promise<{ from?: string; to?: string }> }) {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied
    const t = await getTranslations()
    const sp = await searchParams
    const from = bound(sp.from, false)
    const to = bound(sp.to, true)

    const supabase = await createClient()
    let rows: ReliabilityRow[] = []
    let refusal: string | null = null
    if (!from.ok || !to.ok) {
        refusal = t('equipment.rel.badDate')
    } else {
        const res = await supabase.rpc('equipment_reliability', {
            p_from: from.at ?? undefined, p_to: to.at ?? undefined,
        })
        // 区间倒着走是一句具名拒绝(RELIABILITY_RANGE_INVALID),不是一张空表;别的失败照常抛
        if (res.error && /RELIABILITY_RANGE_INVALID/.test(res.error.message)) refusal = await localizeEquipmentError(res.error.message)
        else rows = mustRows(res, 'equipment_reliability') as unknown as ReliabilityRow[]
    }

    const tableRows: CellRow[] = rows.map((r) => {
        const w = reliabilityWords(r, t)
        return {
            id: r.equipment_id,
            cells: {
                machine: (
                    <span className="block">
                        <Link href={`/operation/equipment/${r.equipment_id}`} className="app-link hover:underline">{r.equipment_code}</Link>
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{r.equipment_description ?? ''}</span>
                    </span>
                ),
                hours: <span data-rel="hours">{r.mtbf_state === 'no_hours' ? t('equipment.rel.noHoursShort') : `${hours(r.operating_hours)} h`}</span>,
                failures: <span data-rel="failures">{String(r.failures)}</span>,
                mtbf: <span data-rel="mtbf">{w.mtbf}</span>,
                mttr: <span data-rel="mttr">{w.mttr}</span>,
                basis: (
                    <span className="block text-xs">
                        <span className="block text-[color:var(--brand-muted-text)]">{w.denominator}</span>
                        {w.gaps && <span className="block text-amber-700" data-rel="gaps">{w.gaps}</span>}
                    </span>
                ),
            },
            // TABLE-EXPORT-1:有数的那几格导出【数】(小时);没有数的那几句(没有运转小时 / 没有故障 / 没有修复)照屏幕写成那句话
            exports: {
                machine: xText([r.equipment_code, r.equipment_description].filter(Boolean).join(' · ')),
                hours: r.mtbf_state === 'no_hours' ? xText(t('equipment.rel.noHoursShort')) : xNum(r.operating_hours, 'qty'),
                failures: xInt(r.failures),
                // TABLE-EXPORT-1:MTBF / MTTR 的列头不说单位,屏幕上那一句里说「… h」—— 用本页「运转小时」那一格同一个 'h' 一起写;
                //   运转小时那一列的列头已经说了是小时,照旧不带
                mtbf: r.mtbf_state === 'value' ? xNum(r.mtbf_hours, 'qty', t('units.hour')) : xText(w.mtbf),
                mttr: r.mttr_hours === null ? xText(w.mttr) : xNum(r.mttr_hours, 'qty', t('units.hour')),
                basis: xText([w.denominator, w.gaps].filter(Boolean).join(' ')),
            },
        }
    })

    return (
        <ListPage
            maxWidth="max-w-6xl"
            breadcrumb={<Link href="/operation/equipment" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={t('equipment.rel.pageTitle')}
            intro={t('equipment.rel.pageIntro')}
            state={{ kind: 'ok' }}
        >
            <form method="get" className="flex flex-wrap items-end gap-3 my-4">
                <div>
                    <label className="block mb-1">{t('equipment.rel.from')}</label>
                    <DatePicker name="from" defaultValue={sp.from ?? ''} />
                </div>
                <div>
                    <label className="block mb-1">{t('equipment.rel.to')}</label>
                    <DatePicker name="to" defaultValue={sp.to ?? ''} />
                </div>
                <Button type="submit" variant="secondary">{t('equipment.rel.apply')}</Button>
                {(sp.from || sp.to) && (
                    <Link href="/operation/equipment/reliability" className="app-link hover:underline text-sm">{t('equipment.rel.wholeRecord')}</Link>
                )}
            </form>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">
                {sp.from || sp.to ? t('equipment.rel.rangeNote') : t('equipment.rel.defaultRangeNote')}
            </p>
            {refusal ? (
                <Refusal>{refusal}</Refusal>
            ) : (
                <CellsTable
                    columns={[
                        { key: 'machine', header: t('equipment.page.colCode'), priority: true },
                        { key: 'hours', header: t('equipment.rel.colHours'), align: 'right' },
                        { key: 'failures', header: t('equipment.rel.colFailures'), align: 'right' },
                        { key: 'mtbf', header: t('equipment.rel.colMtbf'), priority: true },
                        { key: 'mttr', header: t('equipment.rel.colMttr') },
                        { key: 'basis', header: t('equipment.rel.colBasis') },
                    ]}
                    rows={tableRows}
                    empty={t('equipment.page.empty')}
                    exportSpec={{ name: 'operation-equipment-reliability', title: t('equipment.rel.pageTitle') }}
                />
            )}
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-4">{t('equipment.rel.notAvailability')}</p>
        </ListPage>
    )
}
