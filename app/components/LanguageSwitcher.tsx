'use client'

import { useTransition } from 'react'
import { useLocale } from '@/lib/i18n/client'
import { setLocale } from '@/lib/i18n/actions'

export default function LanguageSwitcher() {
    const locale = useLocale()
    const [isPending, startTransition] = useTransition()

    function toggle() {
        const next = locale === 'en' ? 'zh' : 'en'
        startTransition(() => {
            setLocale(next)
        })
    }

    return (
        <button
            type="button"
            onClick={toggle}
            disabled={isPending}
            className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50"
            title={locale === 'en' ? '切换到中文' : 'Switch to English'}
        >
            {locale === 'en' ? '中' : 'EN'}
        </button>
    )
}
