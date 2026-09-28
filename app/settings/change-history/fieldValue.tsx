// app/settings/change-history/fieldValue.tsx
// HISTORY-1:变更记录里【一个值】怎么画 —— 三种状态,三种样子。
//   受限({"$restricted": true},库里 change_log_restrict 换的)→ 「受限」药丸(与 MaskedValue 同一句 common.restricted);
//   本来就空(JSON null / 缺这个键)→ 留白的占位,不画成 0、不画成「—」以外的任何字;
//   其余 → 原样(对象与数组按 JSON 显示)。
// ★ 判据只认那个标记,不认 null —— null 在这里【有主】:它是"这个值本来就是空的"。
import { getTranslations } from '@/lib/i18n/server'
import { Refusal } from '@/app/components/ui/refusal'

export function isRestricted(v: unknown): boolean {
    return typeof v === 'object' && v !== null && !Array.isArray(v) && (v as Record<string, unknown>)['$restricted'] === true
}

export async function FieldValue({ value }: { value: unknown }) {
    if (isRestricted(value)) {
        const t = await getTranslations()
        return <Refusal>{t('common.restricted')}</Refusal>
    }
    if (value === null || value === undefined) return <span className="text-gray-400">∅</span>
    const text = typeof value === 'object' ? JSON.stringify(value) : String(value)
    return <span className="break-all">{text}</span>
}

/** 主键 → 一行字:`id=…` 或 `role_id=… · permission_code=…`。 */
export function rowKeyLabel(key: Record<string, unknown> | null): string {
    if (!key) return '—'
    return Object.entries(key)
        .map(([k, v]) => `${k}=${v === null ? '∅' : String(v)}`)
        .join(' · ')
}
