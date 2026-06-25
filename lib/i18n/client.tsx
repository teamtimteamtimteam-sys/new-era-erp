'use client'

import { createContext, useContext } from 'react'
import { MESSAGES, type Locale, type Messages } from './config'

type I18nContextValue = {
    locale: Locale
    messages: Messages
}

const I18nContext = createContext<I18nContextValue | null>(null)

export function I18nProvider({
    locale,
    children,
}: {
    locale: Locale
    children: React.ReactNode
}) {
    return (
        <I18nContext.Provider value={{ locale, messages: MESSAGES[locale] }}>
            {children}
        </I18nContext.Provider>
    )
}

// 点路径取文案，例如 t('nav.suppliers')；支持 {var} 插值：t('key', { count: 5 })
function resolve(
    messages: Messages,
    key: string,
    params?: Record<string, string | number>
): string {
    const parts = key.split('.')
    let current: unknown = messages
    for (const part of parts) {
        if (current && typeof current === 'object' && part in current) {
            current = (current as Record<string, unknown>)[part]
        } else {
            return key // 找不到就原样返回 key，方便发现漏翻
        }
    }
    if (typeof current !== 'string') return key
    if (!params) return current
    return current.replace(/\{(\w+)\}/g, (_, name) =>
        name in params ? String(params[name]) : `{${name}}`
    )
}

export function useTranslations() {
    const ctx = useContext(I18nContext)
    if (!ctx) {
        throw new Error('useTranslations must be used within I18nProvider')
    }
    return (key: string, params?: Record<string, string | number>) =>
        resolve(ctx.messages, key, params)
}

export function useLocale(): Locale {
    const ctx = useContext(I18nContext)
    if (!ctx) {
        throw new Error('useLocale must be used within I18nProvider')
    }
    return ctx.locale
}
