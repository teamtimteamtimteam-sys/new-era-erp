'use client'

// 按【批次当前已录含量】重新计价 —— 给"含量是手工改的、没有化验单"的情况用。
// 先算后交:点一下先看到完整明细与影响,确认无误再提交。价格自始至终由服务端产生,
// 客户端从不提交价格。
//
// 【FIN-27:试算与提交读同一份承诺条款】两侧都走 committed_terms_price ——
// 预览按活公式、提交按承诺副本,会让面板展示一个数、落账另一个数。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import AssayImpactPreview from '../assays/AssayImpactPreview'
import {
    previewRepriceFromCommittedTerms,
    repriceFromCurrentContent,
    type PreviewState,
} from '../assays/actions'

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

export default function RepriceFromContentPanel({ batchId }: { batchId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [preview, setPreview] = useState<PreviewState>({})
    const [open, setOpen] = useState(false)
    const [error, setError] = useState('')

    const date = todayIsoLocal()

    function onPreview() {
        setError('')
        startTransition(async () => {
            const res = await previewRepriceFromCommittedTerms(batchId, date)
            setPreview(res)
            setOpen(true)
        })
    }

    function onCommit() {
        setError('')
        startTransition(async () => {
            const res = await repriceFromCurrentContent(batchId, date)
            if (res.error) setError(res.error)
            else {
                setOpen(false)
                setPreview({})
                router.refresh()
            }
        })
    }

    return (
        <div className="mb-4">
            <button
                type="button"
                onClick={onPreview}
                disabled={isPending}
                className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm disabled:text-gray-400"
            >
                {t('assay.repriceFromFormula')}
            </button>
            {error && <p className="text-sm text-red-600 mt-2">{error}</p>}
            {preview.error && <p className="text-sm text-red-600 mt-2">{preview.error}</p>}

            {open && preview.result && (
                <div className="mt-3 border border-gray-300 rounded p-4">
                    <AssayImpactPreview res={preview.result} impact={preview.impact} />
                    <div className="flex gap-2 mt-4">
                        <button
                            type="button"
                            onClick={onCommit}
                            disabled={isPending}
                            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400 text-sm"
                        >
                            {isPending ? t('common.saving') : t('inbound.pricing.submit')}
                        </button>
                        <button
                            type="button"
                            onClick={() => setOpen(false)}
                            className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50 text-sm"
                        >
                            {t('common.cancel')}
                        </button>
                    </div>
                </div>
            )}
        </div>
    )
}
