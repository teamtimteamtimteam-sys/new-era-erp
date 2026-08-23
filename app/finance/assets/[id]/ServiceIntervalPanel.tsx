'use client'

// EQP-2d(P4):这台机器的保养间隔,以及【它的读数说了多少、没说多少】。
//
// ════════════════════════════════════════════════════════════════════════════
// 【这块屏幕最难的一件,是把 EQP-2c 的诚实【搬上来】,而不是把它埋掉】
//
// equipment_service_status 的视图注释里写着两条事实:
//   ① 从未保养过的机器,基线是【取得日】—— 它做过的一切;
//   ② 归属只在 commit_processing_run 那一刻写,加工日早于取得日一律按名拒 ——
//      **系统里没有任何一条路能把一炉跑完的加工事后归给机器**。
// 于是【一个低读数有两种意思:磨损得少,和磨损我们看不见】。
//
// **那两条事实写在数据库的注释里,而看这块屏幕的人不会去读数据库的注释。**
// 所以它们要在这里说成人话,而且要说在【那个数字旁边】。
//
// 【判据有两个,不是一个 —— 这是本刀 grill 出来最要紧的一处】
//   * `unattributed_runs_in_window` 量的是【窗口之内】的洞:这段时间里有几炉
//     加工谁都没归属。它是 EQP-2c 做进视图的那一列。
//   * **它量不到窗口【左边】的历史。** 而 FA-2026-0001 恰恰全部落在左边:
//     取得日 2026-08-21,而全库十三炉的日期是 6-10 到 8-16 —— 每一炉都在它左边,
//     于是这一列读 **0**,而盲区恰恰是最大的。
//     **只按 `unattributed_runs_in_window > 0` 出诚实提示,对着这台机器会一句话
//     都不说** —— 而它正是第一个会有人来看的机器。
//   所以第二个数由页面另查一次:取得日【之前】、谁都没归属的在册加工有几炉
//   (runsBeforeAcquisition)。两个洞,两句话,各说各的。
//
// 【为什么第二个数只在 never_serviced 时才说】保养过一次之后,基线是那一次保养,
// 取得日之前的加工根本不进 kg_since 的窗口 —— 那时它不是这个读数的洞。
// 只有"从未保养过"时,kg_since 才等于【这台机器的一生】,而取得日左边的历史
// 正是那一生里缺掉的部分。
// ════════════════════════════════════════════════════════════════════════════
//
// 【三个状态,屏幕上要看得出是三个】没有间隔行 =【未监控】(不是"未到期");
// disposition='ignore' =【盯着,不吵】;'warn' = 上看板。删行与改 disposition
// 是两件不同的事,按钮上各说各的。
//
// 【提前量与"至少一个"【不在这里再校验一遍】】lead < interval 与 at-least-one
// 都是表上的 CHECK。在 TS 里再写一遍就是第二份实现 —— 让库拒,句子由
// localizeEquipmentError 按约束名翻。W1 正面走这两条。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveServiceInterval, deleteServiceInterval } from './actions'

export type IntervalRow = {
    interval_id: string | null
    monitored: boolean
    service_kind: string | null
    disposition: string | null
    interval_kg: number | null
    lead_kg: number | null
    interval_days: number | null
    lead_days: number | null
    last_service_date: string | null
    never_serviced: boolean | null
    baseline_date: string | null
    kg_since: number | null
    days_since: number | null
    unattributed_runs_in_window: number | null
    is_due: boolean | null
    due_reason: string | null
    is_approaching: boolean | null
    approaching_reason: string | null
}

const num = (n: number | null) =>
    n === null || n === undefined ? '—' : Number(n).toLocaleString('en-US')

export default function ServiceIntervalPanel({
    assetId, rows, acquisitionDate, runsBeforeAcquisition, kgSinceAcquisition, canEdit,
}: {
    assetId: string
    rows: IntervalRow[]
    acquisitionDate: string
    // 【窗口【左边】那个洞的大小】—— 取得日之前、谁都没归属的在册加工炉数。
    // 视图量不到它(它只量窗口之内),所以页面另查一次。见抬头。
    runsBeforeAcquisition: number
    // FIX-2(A):取得日以来这台机器吃进去多少公斤 —— 未监控时也要说得出来。
    kgSinceAcquisition: number
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [editing, setEditing] = useState<string | null>(null)   // interval_id | 'new'
    const [f, setF] = useState({
        kind: 'service', intervalKg: '', leadKg: '', intervalDays: '', leadDays: '',
        disposition: 'warn', notes: '',
    })

    const monitored = rows.filter((r) => r.monitored)

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            setEditing(null); router.refresh()
        })
    }

    function openNew() {
        setF({ kind: 'service', intervalKg: '', leadKg: '', intervalDays: '', leadDays: '',
               disposition: 'warn', notes: '' })
        setEditing('new')
    }
    function openEdit(r: IntervalRow) {
        setF({
            kind: r.service_kind ?? 'service',
            intervalKg: r.interval_kg === null ? '' : String(r.interval_kg),
            leadKg: r.lead_kg === null ? '' : String(r.lead_kg),
            intervalDays: r.interval_days === null ? '' : String(r.interval_days),
            leadDays: r.lead_days === null ? '' : String(r.lead_days),
            disposition: r.disposition ?? 'warn',
            notes: '',
        })
        setEditing(r.interval_id)
    }

    // ── 一行读数的【诚实那一句】—— 三选一,而且【总有一句】 ──────────────────
    // 「什么都不说」是这块屏幕最不该有的状态:一个没有注解的 0,读起来就是
    // "查过了,没磨损"。
    // 【FIX-2(A):这一句跟着【机器】,不跟着间隔行】
    // 它此前只在有间隔行时才画得出来 —— 而**没人监控的时候正是它最要紧的时候**:
    // 那一刻屏幕上说着"没有人在看这台机器",却对"已经看不见的磨损"一个字不提。
    // r 可以为空(未监控):那时没有窗口,只有"取得日之前那个洞"这一支。
    // **同一个函数、同一批 i18n 键** —— 不写第二份那句话。
    function honesty(r: IntervalRow | null): { tone: string; text: string } {
        if ((r?.unattributed_runs_in_window ?? 0) > 0) {
            return { tone: 'amber', text: t('equipment.intervals.honestyInWindow',
                { n: String(r!.unattributed_runs_in_window) }) }
        }
        if ((r === null || r.never_serviced) && runsBeforeAcquisition > 0) {
            return { tone: 'amber', text: t('equipment.intervals.honestyNeverAttributable',
                { n: String(runsBeforeAcquisition), date: acquisitionDate }) }
        }
        return { tone: 'gray', text: t('equipment.intervals.honestyComplete',
            { date: r?.baseline_date ?? acquisitionDate }) }
    }

    return (
        <div className="mb-8">
            <div className="flex items-baseline gap-3 mb-2">
                <h2 className="text-lg font-medium">{t('equipment.intervals.title')}</h2>
                {canEdit && (
                    <button type="button" onClick={openNew} disabled={pending}
                            className="border border-gray-400 px-2 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                        {t('equipment.intervals.add')}
                    </button>
                )}
            </div>
            {!canEdit && <p className="text-xs text-gray-500 mb-2">{t('equipment.needsProcessingEdit')}</p>}
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            {monitored.length === 0 ? (
                /* ── 【未监控】是一个有名字的状态,不是一张空表 ────────────────
                   「没有间隔行」≠「不到期」。屏幕上必须说出是哪一种 —— 这与
                   SS-1 那条"安全库存阈值为 NULL 的物料永不出现"、与 METAL-1 的
                   no_reference 是同一课。 */
                <div className="border border-gray-300 rounded p-3 mb-2 bg-gray-50">
                    <p className="text-sm font-medium">{t('equipment.intervals.notMonitored')}</p>
                    <p className="text-xs text-gray-600 mt-1">{t('equipment.intervals.notMonitoredWhy')}</p>
                    {/* FIX-2(A):**读数与那句诚实话属于【机器】,不属于间隔行。**
                        没人监控的时候正是它们最要紧的时候 —— 否则这块屏幕
                        一边说"没有人在看这台机器",一边对已经看不见的磨损闭口不谈。
                        取得日以来的公斤数来自 equipment_usage(加工炉只能从取得日起
                        归属给机器,所以它就是"取得日以来"),句子来自同一个 honesty()。 */}
                    <p className="text-xs text-gray-700 mt-2">
                        {t('equipment.intervals.sinceAcquisition',
                           { kg: num(kgSinceAcquisition), date: acquisitionDate })}
                    </p>
                    {(() => {
                        const h = honesty(null)
                        return <p className={'text-xs mt-1 ' +
                            (h.tone === 'amber' ? 'text-amber-700' : 'text-gray-500')}>{h.text}</p>
                    })()}
                </div>
            ) : (
                <div className="space-y-3 mb-2">
                    {monitored.map((r) => {
                        const h = honesty(r)
                        const state = r.is_due ? 'due' : r.is_approaching ? 'approaching' : 'ok'
                        const reason = r.is_due ? r.due_reason : r.is_approaching ? r.approaching_reason : null
                        return (
                            <div key={r.interval_id ?? 'x'} className="border border-gray-300 rounded p-3">
                                <div className="flex flex-wrap items-baseline gap-2 mb-1">
                                    <span className="font-medium text-sm">
                                        {t('equipment.kind.' + (r.service_kind ?? 'service'))}
                                    </span>
                                    {/* 到期 / 将到期 / 未到期 —— 三个词,三种颜色,不合并 */}
                                    <span className={
                                        'text-xs px-2 py-0.5 rounded ' +
                                        (state === 'due' ? 'bg-red-100 text-red-800'
                                         : state === 'approaching' ? 'bg-amber-100 text-amber-800'
                                         : 'bg-gray-100 text-gray-600')}>
                                        {/* 【三个状态、三个原因,都写成【静态】的键】
                                            due_reason 的取值里有 'kg+days' —— 一个带
                                            加号的键既难查也进不了 check-i18n 的后缀集合。
                                            更要紧的是:静态键【一眼看得出漏没漏】,
                                            而拼出来的键漏了会在屏幕上印出键名本身
                                            (check-i18n 存在的全部理由)。 */}
                                        {state === 'due' ? t('equipment.intervals.stateDue')
                                            : state === 'approaching' ? t('equipment.intervals.stateApproaching')
                                            : t('equipment.intervals.stateOk')}
                                        {reason === 'kg' ? ' · ' + t('equipment.intervals.reasonKg')
                                            : reason === 'days' ? ' · ' + t('equipment.intervals.reasonDays')
                                            : reason === 'kg+days' ? ' · ' + t('equipment.intervals.reasonBoth')
                                            : ''}
                                    </span>
                                    {r.disposition === 'ignore' && (
                                        <span className="text-xs px-2 py-0.5 rounded bg-gray-100 text-gray-600">
                                            {t('equipment.intervals.ignored')}
                                        </span>
                                    )}
                                </div>

                                {/* ── 两个量度:走了多少 / 每多少一轮 ───────────────── */}
                                <div className="grid grid-cols-2 gap-x-6 gap-y-1 text-sm mb-2">
                                    {/* FIX-2(E):**不把"未填"塞进数值槽。**
                                        此前 every 槽会被填进「未填」,于是屏幕上出现
                                        "0 kg since the baseline · every not stated" ——
                                        一个状态词被当成数字念。而【只填天数不填公斤】
                                        是完全合法的,所以这句话天天都会出现。
                                        改成【换一句话】,不是换一个词。 */}
                                    <p>{r.interval_kg === null
                                        ? t('equipment.intervals.kgLineNoInterval', { since: num(r.kg_since) })
                                        : t('equipment.intervals.kgLine', {
                                            since: num(r.kg_since), every: num(r.interval_kg) })}</p>
                                    <p>{r.interval_days === null
                                        ? t('equipment.intervals.daysLineNoInterval', { since: num(r.days_since) })
                                        : t('equipment.intervals.daysLine', {
                                            since: num(r.days_since), every: num(r.interval_days) })}</p>
                                </div>

                                {/* ── 基线:从哪一天算起,以及为什么是那一天 ────────── */}
                                <p className="text-xs text-gray-700">
                                    {r.never_serviced
                                        ? t('equipment.intervals.baselineNever', { date: r.baseline_date ?? acquisitionDate })
                                        : t('equipment.intervals.baselineLast', { date: r.last_service_date ?? '—' })}
                                </p>

                                {/* ── 【诚实那一句】—— 总是有一句,见本文件抬头 ────── */}
                                <p className={'text-xs mt-1 ' + (h.tone === 'amber' ? 'text-amber-700' : 'text-gray-500')}>
                                    {h.text}
                                </p>

                                {canEdit && (
                                    <div className="flex gap-2 mt-2">
                                        <button type="button" disabled={pending} onClick={() => openEdit(r)}
                                                className="border border-gray-400 px-2 py-0.5 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                                            {t('equipment.intervals.edit')}
                                        </button>
                                        <button type="button" disabled={pending}
                                                onClick={() => { if (confirm(t('equipment.intervals.stopConfirm'))) run(() => deleteServiceInterval(assetId, r.interval_id as string)) }}
                                                className="border border-gray-400 px-2 py-0.5 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                                            {t('equipment.intervals.stop')}
                                        </button>
                                    </div>
                                )}
                            </div>
                        )
                    })}
                </div>
            )}

            {editing && canEdit && (
                <div className="border border-gray-400 rounded p-3 text-sm space-y-2 max-w-2xl">
                    <div className="flex flex-wrap gap-3 items-end">
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.intervals.kind')}</span>
                            <select value={f.kind} onChange={(e) => setF({ ...f, kind: e.target.value })}
                                    className="border border-gray-400 rounded px-2 py-1 text-sm">
                                <option value="service">{t('equipment.kind.service')}</option>
                                <option value="repair">{t('equipment.kind.repair')}</option>
                            </select>
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.intervals.disposition')}</span>
                            <select value={f.disposition} onChange={(e) => setF({ ...f, disposition: e.target.value })}
                                    className="border border-gray-400 rounded px-2 py-1 text-sm">
                                <option value="warn">{t('equipment.intervals.dispWarn')}</option>
                                <option value="ignore">{t('equipment.intervals.dispIgnore')}</option>
                            </select>
                        </label>
                    </div>
                    <div className="grid grid-cols-2 gap-3 max-w-xl">
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.intervals.intervalKg')}</span>
                            <input value={f.intervalKg} onChange={(e) => setF({ ...f, intervalKg: e.target.value })}
                                   inputMode="decimal" className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.intervals.leadKg')}</span>
                            <input value={f.leadKg} onChange={(e) => setF({ ...f, leadKg: e.target.value })}
                                   inputMode="decimal" className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.intervals.intervalDays')}</span>
                            <input value={f.intervalDays} onChange={(e) => setF({ ...f, intervalDays: e.target.value })}
                                   inputMode="numeric" className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                        </label>
                        <label className="block">
                            <span className="text-xs text-gray-600 block">{t('equipment.intervals.leadDays')}</span>
                            <input value={f.leadDays} onChange={(e) => setF({ ...f, leadDays: e.target.value })}
                                   inputMode="numeric" className="border border-gray-400 rounded px-2 py-1 text-sm w-full" />
                        </label>
                    </div>
                    {/* 【两条规矩说出来,但【不在这里执行】】执行它们的是表上的 CHECK。
                        在 TS 里再判一遍就是第二份实现,而两份实现必然漂开。 */}
                    <p className="text-xs text-gray-600">{t('equipment.intervals.atLeastOneHint')}</p>
                    <p className="text-xs text-gray-600">{t('equipment.intervals.leadHint')}</p>
                    <div className="flex gap-2">
                        <button type="button" disabled={pending}
                                onClick={() => run(() => saveServiceInterval({
                                    assetId, intervalId: editing === 'new' ? null : editing, ...f,
                                }))}
                                className="border border-gray-600 bg-gray-800 text-white px-3 py-1 rounded text-xs disabled:opacity-50">
                            {t('common.save')}
                        </button>
                        <button type="button" disabled={pending} onClick={() => { setEditing(null); setError(null) }}
                                className="border border-gray-400 px-3 py-1 rounded text-xs hover:bg-gray-50 disabled:opacity-50">
                            {t('common.cancel')}
                        </button>
                    </div>
                </div>
            )}
        </div>
    )
}
