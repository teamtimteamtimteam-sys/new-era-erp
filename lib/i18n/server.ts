import { cookies } from 'next/headers'
import { DEFAULT_LOCALE, LOCALE_COOKIE, MESSAGES, isLocale, type Locale } from './config'

// Server Component / Server Action 里读取当前语言（来自 cookie）
export async function getLocale(): Promise<Locale> {
    const cookieStore = await cookies()
    const value = cookieStore.get(LOCALE_COOKIE)?.value
    return isLocale(value) ? value : DEFAULT_LOCALE
}

export async function getTranslations() {
    return translatorFor(await getLocale())
}

// FIN-CHAIN-1(Tim d2 #12,2026-10-20):【一份语言被钉死的翻译器】—— 对外单据一律英文,不跟随界面语言。
//   名字里带着 locale 参数,是要让调用点看得见"这里的语言是选定的",而不是"忘了国际化"(noSignatureEn 同一条)。
export function translatorFor(locale: Locale) {
    const messages = MESSAGES[locale]
    return (key: string, params?: Record<string, string | number>): string => {
        const parts = key.split('.')
        let current: unknown = messages
        for (const part of parts) {
            if (current && typeof current === 'object' && part in current) {
                current = (current as Record<string, unknown>)[part]
            } else {
                return key
            }
        }
        if (typeof current !== 'string') return key
        if (!params) return current
        return current.replace(/\{(\w+)\}/g, (_, name) =>
            name in params ? String(params[name]) : `{${name}}`
        )
    }
}
