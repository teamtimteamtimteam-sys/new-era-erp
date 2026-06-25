import { cookies } from 'next/headers'
import { DEFAULT_LOCALE, LOCALE_COOKIE, MESSAGES, isLocale, type Locale } from './config'

// Server Component / Server Action 里读取当前语言（来自 cookie）
export async function getLocale(): Promise<Locale> {
    const cookieStore = await cookies()
    const value = cookieStore.get(LOCALE_COOKIE)?.value
    return isLocale(value) ? value : DEFAULT_LOCALE
}

export async function getTranslations() {
    const locale = await getLocale()
    const messages = MESSAGES[locale]
    return (key: string): string => {
        const parts = key.split('.')
        let current: unknown = messages
        for (const part of parts) {
            if (current && typeof current === 'object' && part in current) {
                current = (current as Record<string, unknown>)[part]
            } else {
                return key
            }
        }
        return typeof current === 'string' ? current : key
    }
}
