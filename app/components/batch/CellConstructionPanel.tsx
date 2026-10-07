'use client'

// MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q4–Q7,Tim):批次页上的电芯结构 —— 卷绕 / 叠片 / 未知,或没记。
//   【只对装电芯的形态摆出来】页面只在 carries 不为 false 时渲染它(与库里的守卫同一个判据)。
//   【只读的人】控件看得见、按不动,旁边说出缺哪个码(PermissionGate,DBLOCK-1):进料批要进料编辑码或加工提交码,产出批要产出编辑码或加工提交码。
//   【锁】喂过一张已提交的加工单之后改不了 —— 由库里判(CELL_CONSTRUCTION_LOCKED,句子点名那一张单),这里不重算。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import type { CellConstructionOption } from '@/app/inbound/cellConstructionQuery'
import { setBatchCellConstruction } from './cellConstructionActions'

export default function CellConstructionPanel({ kind, batchId, current, options, canEdit, gateCode, required, locale }: {
    kind: 'inbound' | 'output'
    batchId: string
    current: string | null
    options: CellConstructionOption[]
    canEdit: boolean
    /** 缺码时点名的那个码(模块编辑码 —— 另一个能改它的是 action.processing_commit) */
    gateCode: string
    /** 这一批将要喂的工序要求结构时提醒一句(没有确定的结构,极片分离收不下它) */
    required: boolean
    locale: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [value, setValue] = useState(current ?? '')
    const [error, setError] = useState<string | null>(null)
    const name = (o: CellConstructionOption) => (locale === 'zh' ? o.name_zh : o.name_en)
    const cur = options.find((o) => o.code === current)
    const determined = cur?.is_determined === true

    return (
        <section className="mb-8" data-section="cell-construction">
            <h2 className="mb-2">{t('cellConstruction.title')}</h2>
            <div className="border border-gray-300 rounded p-3 max-w-2xl">
                <p className="text-sm mb-2">
                    {t('cellConstruction.current')}: <strong>{cur ? name(cur) : t('cellConstruction.notRecorded')}</strong>
                </p>
                {required && !determined && (
                    <p className="text-sm text-amber-700 mb-2" data-warning="cell-construction">{t('cellConstruction.neededForSeparation')}</p>
                )}
                <PermissionGate code={gateCode} allowed={canEdit}>
                    <div className="flex flex-wrap items-end gap-3">
                        <label className="block">
                            <span className="block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1">{t('cellConstruction.label')}</span>
                            <select value={value} onChange={(e) => setValue(e.target.value)} className={CONTROL_SELECT}>
                                <option value="">{t('cellConstruction.notRecorded')}</option>
                                {options.map((o) => <option key={o.code} value={o.code}>{name(o)}</option>)}
                            </select>
                        </label>
                        <Button type="button" disabled={pending || value === (current ?? '')}
                                onClick={() => {
                                    setError(null)
                                    start(async () => {
                                        const r = await setBatchCellConstruction(kind, batchId, value)
                                        if (r.error) { setError(r.error); return }
                                        router.refresh()
                                    })
                                }}>
                            {t('common.save')}
                        </Button>
                    </div>
                </PermissionGate>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('cellConstruction.pageHint')}</p>
                {error && <p className="mt-2 text-sm text-red-700">{error}</p>}
            </div>
        </section>
    )
}
