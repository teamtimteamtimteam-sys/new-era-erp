'use client'
// 月度折旧执行按钮(FIN-22)。应提为 0 时禁用 —— 幂等靠算术,按钮跟着算术走。
// 数字来自 preview_depreciate_fixed_assets,与 depreciate_fixed_assets 同一份算术。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { runDepreciation } from '../month-end/actions'
import { Button } from '@/app/components/ui/button'

export default function DepreciateButton({ periodEnd, disabled }: { periodEnd: string; disabled: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<string | null>(null)
    return (
        <div>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {done && <p className="mb-3 text-sm text-green-700">{t('assets.depDone', { 0: done })}</p>}
            <Button type="button" disabled={pending || disabled}
                onClick={() => { setError(null); start(async () => {
                    const r = await runDepreciation(periodEnd)
                    if (r.error) setError(r.error)
                    else { setDone(JSON.parse(r.result ?? '{}').journal_code ?? '—'); router.refresh() }
                }) }}>
                {t('assets.depRun', { 0: periodEnd })}
            </Button>
        </div>
    )
}
