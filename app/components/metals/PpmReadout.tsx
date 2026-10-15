'use client'

// app/components/metals/PpmReadout.tsx — MES-6b-1(2026-10-15,F7 · MES-6b Step 0 Q18,Tim)
// 【录入框旁边的 ppm】惩罚元素(氟、氯)的含量以 % 录,而合同、化验单、人嘴里说的都是 ppm —— 打 0.005 的时候旁边就写着 50 ppm,
//   打错一位(0.05 → 500 ppm)当场看得见。只读、不提交、不改单位:框里仍然是 %,存的仍然是 %。
// 【谁带它】两张化验单的含量格、批次页的手工含量录入、合同惩罚条款的阈值框 —— scripts/check-substance-display.mjs 逐个点名,
//   少一处构建就红。品位规格与配料目标【不带】(Q18:它们仍然只用 %)。
// 换算走 lib/substances.ts 的 typingPpm(十进制字符串移小数点,不经浮点)。
import { useTranslations } from '@/lib/i18n/client'
import { typingPpm, type SubstanceRole } from '@/lib/substances'

export default function PpmReadout({ value, role }: { value: string; role: SubstanceRole | null | undefined }) {
    const t = useTranslations()
    const ppm = typingPpm(value, role)
    if (ppm === null) return null
    return (
        <span className="text-xs text-[color:var(--brand-muted-text)] whitespace-nowrap tabular-nums" data-ppm-readout={ppm} aria-live="polite">
            {t('metalContent.ppmReadout', { ppm })}
        </span>
    )
}
