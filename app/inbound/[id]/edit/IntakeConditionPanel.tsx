'use client'

// PROC-2b(P3):这一批货【到货时是什么状态】—— 安全状态(多值)与化学体系确定度。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这一块【也】在批次自己的页面上 —— PROC-2b 的结论,PROC-2c 之后仍然成立】
//
// **安全状态不是一个"收货那一刻"的事实。** 一批货【到的时候带电,后来才被放电
// 并核验】。只在建批次时记一次,那个【转变】就永远记不下来 —— 而 PROC-3 那道闸
// 要拦的正是"未放电",它要能被满足,靠的就是有人能把"现在已经放过电了"记上去。
// **只在收货时记,等于让那道闸永远无法被满足。**
//
// 【PROC-2c 加的是另一半,不是替换】门口已经知道的事,在门口就记下来 ——
// 建批次的两条路现在都收这两轴(create_inbound_batch / receive_inbound_batch_against_po
// 各多了两个尾参)。**两块屏幕共用同一份控件**(IntakeConditionFields),
// 因为它们真正承重的是那几句话,而两份实现的字迟早会各说各的。
//
// 【PROC-2c 关掉的那扇窗】PROC-2b 这里是"先删后插",两步之间失败会留下一个
// 【空集】—— 而空集的意思是"没有人记过",与真相(有人记过、只是没存上)不一样。
// 现在整组写走 set_inbound_safety_states 这一个 RPC:**一个函数体对调用方是原子的**,
// 要么整组换成新的,要么原样不动。fixture 114 的 F3 臂把那个旧缺陷【当场造出来】
// 再断言新写法补上了它。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { setIntakeCondition } from './intakeConditionActions'
import IntakeConditionFields, {
    CERTAINTY_UNCHOSEN, type SafetyState, type Certainty,
} from '@/app/inbound/IntakeConditionFields'
import { Button } from '@/app/components/ui/button'

export { CERTAINTY_UNCHOSEN }
export type { SafetyState, Certainty }

export default function IntakeConditionPanel({
    batchId, states, certainties, currentStates, currentCertainty, canEdit, locale,
}: {
    batchId: string
    states: SafetyState[]
    certainties: Certainty[]
    currentStates: string[]
    currentCertainty: string | null
    canEdit: boolean
    locale: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [picked, setPicked] = useState<string[]>(currentStates)
    const [certainty, setCertainty] = useState<string>(currentCertainty ?? CERTAINTY_UNCHOSEN)

    function toggle(code: string) {
        setPicked((p) => (p.includes(code) ? p.filter((c) => c !== code) : [...p, code]))
    }
    function save() {
        setError(null)
        start(async () => {
            const r = await setIntakeCondition({ batchId, safetyStates: picked, certainty })
            if (r.error) { setError(r.error); return }
            router.refresh()
        })
    }

    return (
        <div className="mb-8">
            <h2 className="text-sm font-medium text-gray-700 mb-2">{t('inbound.condition.title')}</h2>
            {!canEdit && <p className="text-xs text-gray-500 mb-2">{t('inbound.condition.needsEdit')}</p>}
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            <div className="border border-gray-300 rounded p-3 max-w-2xl space-y-4">
                <IntakeConditionFields
                    states={states} certainties={certainties}
                    picked={picked} certainty={certainty}
                    onToggle={toggle} onCertainty={setCertainty}
                    disabled={!canEdit} locale={locale}
                    everRecordedCertainty={currentCertainty !== null}
                />

                {canEdit && (
                    <div className="flex gap-2 items-center">
                        <Button size="xs" type="button" disabled={pending} onClick={save}>
                            {t('common.save')}
                        </Button>
                        <span className="text-xs text-gray-500">{t('inbound.condition.saveHint')}</span>
                    </div>
                )}
            </div>
        </div>
    )
}
