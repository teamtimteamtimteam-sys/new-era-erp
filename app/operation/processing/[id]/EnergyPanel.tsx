// MES-5a-2(2026-10-08,规格 §9;MES-0 Q26;MES-5a Step 0 Q21–Q23,Tim):【这一炉用了多少电】—— 加工单页上的一小块,只读。
//   电量 = 这一炉自己记下的 energy_kwh(参数与指标里那个字段);没记才用一张电费单分给它的 kWh(依据照印:按记下的电量 / 按运行时长)。
//   每吨 = 电量 ÷ 投入吨数。放电回收的能量另列一行,从不与耗电相抵(Q21)。分到的钱只给看得见价格的人(data.view_prices,Q30)。
//   数全是库里的视图给的(processing_run_energy · electricity_allocation_lines_masked),页面不算。
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { MaskedValue } from '@/app/components/MaskedValue'

export type RunEnergyView = {
    ownKwh: number | null
    allocatedKwh: number | null
    basis: string | null
    energyKwh: number | null
    source: string | null
    perTonne: number | null
    recoveredKwh: number | null
    allocationId: string | null
    allocationLabel: string | null
    amountText: string | null
}

export default async function EnergyPanel({ e, showPrices }: { e: RunEnergyView; showPrices: boolean }) {
    const t = await getTranslations()
    const muted = 'text-sm text-[color:var(--brand-muted-text)]'
    const basisText = e.basis === 'recorded_energy' ? t('energy.basisRecorded') : e.basis === 'run_time' ? t('energy.basisRunTime') : null
    return (
        <section className="mt-6" data-section="run-energy">
            <h2 className="mb-1">{t('energy.runTitle')}</h2>
            {e.energyKwh === null && e.recoveredKwh === null
                ? <p className={muted} data-run-energy="none">{t('energy.runNone')}</p>
                : (
                    <dl className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1 text-sm">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.runEnergy')}</dt>
                        <dd data-run-energy={e.source ?? 'none'}>
                            {e.energyKwh === null ? '—' : `${e.energyKwh} kWh`}
                            {e.source === 'recorded' && <span className={`ml-2 ${muted}`}>{t('energy.sourceRecorded')}</span>}
                            {e.source === 'allocated' && <span className={`ml-2 ${muted}`}>{t('energy.sourceAllocated')}</span>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.perTonne')}</dt>
                        <dd>{e.perTonne === null ? '—' : `${e.perTonne} kWh/t`}</dd>
                        {e.allocatedKwh !== null && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('energy.allocatedShare')}</dt>
                                <dd>
                                    {`${e.allocatedKwh} kWh`}{basisText && <span className={`ml-2 ${muted}`}>{basisText}</span>}
                                    {e.allocationId && (
                                        <> · <Link href={`/finance/electricity/${e.allocationId}`} className="app-link hover:underline">{e.allocationLabel ?? '—'}</Link></>
                                    )}
                                    {' · '}<MaskedValue value={e.amountText} canView={showPrices} fallback="—" />
                                </dd>
                            </>
                        )}
                        {e.ownKwh !== null && e.allocatedKwh !== null && e.ownKwh !== e.allocatedKwh && (
                            <dd className={`sm:col-span-2 ${muted}`}>{t('energy.ownVersusAllocated')}</dd>
                        )}
                        <dt className="text-[color:var(--brand-muted-text)]">{t('energy.recovered')}</dt>
                        <dd data-run-recovered={e.recoveredKwh === null ? 'none' : 'some'}>
                            {e.recoveredKwh === null ? '—' : `${e.recoveredKwh} kWh`}
                            <span className={`ml-2 ${muted}`}>{t('energy.recoveredNotNetted')}</span>
                        </dd>
                    </dl>
                )}
        </section>
    )
}
