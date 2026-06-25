import en from '@/messages/en'
import zh from '@/messages/zh'

export const LOCALES = ['en', 'zh'] as const
export type Locale = (typeof LOCALES)[number]
export const DEFAULT_LOCALE: Locale = 'en'
export const LOCALE_COOKIE = 'NEXT_LOCALE'

// 把 en 的结构作为基准，但把每个文案值放宽成 string
// （否则 as const 会把值锁成具体英文字面量，导致 zh 的中文不匹配）
type DeepStringify<T> = {
    [K in keyof T]: T[K] extends string ? string : DeepStringify<T[K]>
}
export type Messages = DeepStringify<typeof en>

export const MESSAGES: Record<Locale, Messages> = {
    en,
    zh,
}

export function isLocale(value: string | undefined): value is Locale {
    return value === 'en' || value === 'zh'
}
