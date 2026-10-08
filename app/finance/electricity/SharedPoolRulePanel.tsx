'use client'

// MES-5a-2(2026-10-08,MES-0 §5.1 V25;MES-5a Step 0 Q25 · Q32,Tim):V25 —— 共用池的电怎么摊,一句话写下来。
//   空 = "Not yet set":不计量的电与共用池电表量到的电,在每一次分摊里都留在间接费用 6200。
//   ★ 写下之后本版本【仍然】不按它摊 —— 按它摊的那一步跟着规则一起建。这一块把这句话照直说出来,不让"已设"读成"已生效"。
//   码:module.finance.edit(看得见、按不下去、说出码 —— DBLOCK-1)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { setSharedPoolRule } from './actions'

export default function SharedPoolRulePanel({ rule, canEdit, poolMeters }: { rule: string | null; canEdit: boolean; poolMeters: number | null }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [v, setV] = useState(rule ?? '')
    const [error, setError] = useState<string | null>(null)
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'
    return (
        <section className="mt-8" data-section="shared-pool-rule">
            <h2 className="mb-1">{t('energy.v25Title')}</h2>
            <p className="text-sm mb-2" data-v25={rule ? 'set' : 'not-set'}>
                {rule ? <><strong>{t('energy.v25Current')}</strong> {rule}</> : <span className="text-amber-700">{t('energy.v25NotSet')}</span>}
            </p>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('energy.v25Explain')}</p>
            {poolMeters !== null && <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('energy.v25PoolMeters', { n: String(poolMeters) })}</p>}
            {error && <p className="mb-2 text-sm text-red-700" role="alert">{error}</p>}
            <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <div className="flex flex-wrap items-end gap-3">
                    <label className="block flex-1 min-w-[12rem]">
                        <span className={lbl}>{t('energy.v25Label')}</span>
                        <input type="text" value={v} onChange={(e) => setV(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                    </label>
                    <Button type="button" disabled={pending || v.trim() === (rule ?? '')}
                            onClick={() => { setError(null); start(async () => {
                                const r = await setSharedPoolRule(v)
                                if (r.error) { setError(r.error); return }
                                router.refresh()
                            }) }}>
                        {v.trim() === '' ? t('energy.v25Clear') : t('energy.v25Save')}
                    </Button>
                </div>
            </PermissionGate>
        </section>
    )
}
