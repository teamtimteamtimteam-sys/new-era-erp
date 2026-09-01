'use client'

// RECV-SOURCE-1:收货表单的【来源】段 —— 两条建批表单(直接收货 / 对单收货)共用。
//
// R1:一张收货必须说得出它从哪来 —— 采购行,或字典理由,永远不许两者皆无。
//   · 选了采购行 → 理由是【可选的】(对着采购单又附送样品是现实,不该拒);
//   · 没选采购行 → 理由【必填】。
// R3:requiresExplanation 的理由(播种时只有 other)必须带一句书面说明 ——
//   说明框只在需要时出现,并标必填。
// R5:这里的 required 只是【提前把答案说出来】;真正的拒绝在库里
//   (guard_receipt_source_stated),绕过表单也一样被按名拒。

import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import type { SourceReasonOption } from './sourceReasonQuery'

export default function SourceReasonFields({
    reasons,
    hasPoLine,
    fieldError,
}: {
    reasons: SourceReasonOption[]
    // 表单当前选没选采购行 —— 决定理由是不是必填
    hasPoLine: boolean
    fieldError?: string
}) {
    const t = useTranslations()
    const [code, setCode] = useState('')
    const selected = reasons.find((r) => r.code === code)
    const needsNote = selected?.requiresExplanation ?? false

    return (
        <div>
            <label className="block text-sm font-medium mb-1">
                {t('inbound.source.field')}{' '}
                {!hasPoLine && <span className="text-red-600">*</span>}
            </label>
            <select
                name="source_reason_code"
                required={!hasPoLine}
                value={code}
                onChange={(e) => setCode(e.target.value)}
                className="w-full border border-gray-300 px-3 py-2 rounded"
            >
                {/* 选了采购行时,空选项的意思是"来路就是那张采购行" */}
                <option value="">
                    {hasPoLine ? t('inbound.source.fromPoLine') : t('inbound.source.select')}
                </option>
                {reasons.map((r) => (
                    <option key={r.code} value={r.code}>
                        {r.label}
                    </option>
                ))}
            </select>
            <p className="text-xs text-gray-500 mt-1">{t('inbound.source.hint')}</p>
            {fieldError && <p className="text-red-600 text-xs mt-1">{fieldError}</p>}
            {needsNote && (
                <div className="mt-2">
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.source.noteField')} <span className="text-red-600">*</span>
                    </label>
                    <textarea
                        name="source_reason_note"
                        required
                        rows={2}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                        placeholder={t('inbound.source.notePlaceholder')}
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('inbound.source.noteHint')}</p>
                </div>
            )}
        </div>
    )
}
