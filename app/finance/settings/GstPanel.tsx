'use client'

// GST-3:注册开关的控件。**打开是一次刻意的动作,不是一个 toggle。**
//
// 【为什么后果写在按钮【上面】,而不是按完之后】销售单那条信用额度提示立的先例:
// 把话说在【做决定的地方】。一个按下去才告诉你发生了什么的开关,
// 是在让人用一次真实的状态变更去阅读说明书。
//
// 【为什么不是 checkbox onChange】那会在人读完那三行字之前就把状态改掉。
import { useState, useTransition } from 'react'
import { setGstRegistration } from './gstActions'
import { useTranslations } from '@/lib/i18n/client'

export default function GstPanel({
    registered,
    registrationNo,
}: {
    registered: boolean
    registrationNo: string | null
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [regNo, setRegNo] = useState(registrationNo ?? '')

    function submit(on: boolean, confirmKey: string) {
        if (!window.confirm(t(confirmKey))) return
        startTransition(async () => {
            const result = await setGstRegistration(on, regNo)
            if (result?.error) alert(result.error)
        })
    }

    const regNoBlank = regNo.trim() === ''

    return (
        <section className="border border-gray-300 rounded p-4 mb-6">
            <h2 className="font-semibold mb-1">{t('finance.gstSwitch.title')}</h2>

            {/* 【状态是一句话,不是一个空白】与 /finance/gst 那条横幅同一个措辞族 */}
            <p className={'text-sm mb-3 inline-block px-3 py-2 rounded border ' +
                (registered ? 'bg-green-50 border-green-300 text-green-900'
                            : 'bg-amber-50 border-amber-300 text-amber-900')}>
                {registered
                    ? t('finance.gstSwitch.isOn', { no: registrationNo ?? '—' })
                    : t('finance.gstSwitch.isOff')}
            </p>

            {!registered ? (
                <>
                    {/* ★【后果写在动作【之前】】★ 三件事,都是开关一翻就立刻成立的 */}
                    <div className="text-sm bg-blue-50 border border-blue-200 rounded px-3 py-2 mb-3">
                        <p className="font-medium mb-1">{t('finance.gstSwitch.beforeYouTurnItOn')}</p>
                        <ul className="list-disc ml-5 space-y-1">
                            <li>{t('finance.gstSwitch.consequenceDocuments')}</li>
                            <li>{t('finance.gstSwitch.consequenceF5')}</li>
                            <li>{t('finance.gstSwitch.consequenceDefaults')}</li>
                        </ul>
                    </div>

                    <div className="flex flex-wrap items-end gap-3">
                        <div>
                            <label className="block text-sm font-medium mb-1">
                                {t('finance.gstSwitch.regNo')} <span className="text-red-600">*</span>
                            </label>
                            <input
                                type="text"
                                value={regNo}
                                onChange={(e) => setRegNo(e.target.value)}
                                placeholder={t('finance.gstSwitch.regNoPlaceholder')}
                                className="border border-gray-300 px-3 py-2 rounded font-mono"
                            />
                        </div>
                        <button
                            onClick={() => submit(true, 'finance.gstSwitch.confirmOn')}
                            disabled={isPending || regNoBlank}
                            className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                        >
                            {t('finance.gstSwitch.turnOn')}
                        </button>
                    </div>
                    {/* 【禁用必须说出为什么】CMP-2:每个禁钮条件都有紧邻的一行字 */}
                    {regNoBlank && (
                        <p className="text-sm text-amber-700 mt-2">{t('finance.gstSwitch.regNoWhy')}</p>
                    )}
                </>
            ) : (
                <>
                    {/* 关的那一侧:先说清楚它【可能关不掉】,以及为什么 */}
                    <p className="text-sm text-gray-600 mb-3">{t('finance.gstSwitch.turningOffHint')}</p>
                    <button
                        onClick={() => submit(false, 'finance.gstSwitch.confirmOff')}
                        disabled={isPending}
                        className="border border-gray-400 px-4 py-2 rounded hover:bg-gray-50 disabled:text-gray-400"
                    >
                        {t('finance.gstSwitch.turnOff')}
                    </button>
                </>
            )}

            {/* 【那个死掉的标量列】—— 一个看起来像设置、实际什么都不做的东西,
                正是下一个人"把税率设成 9%"然后什么都没发生的地方 */}
            <p className="text-xs text-gray-500 mt-4">{t('finance.gstSwitch.rateLivesElsewhere')}</p>
        </section>
    )
}
