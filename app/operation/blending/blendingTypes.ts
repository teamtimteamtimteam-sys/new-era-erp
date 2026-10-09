// MES-5b-3:配料计划的四态 → 消息键(与 db/tables/blending_plans.sql 的 CHECK 同一组值;check-i18n 现读那条 CHECK)。
export function blendingStatusKey(status: string): string {
    return 'blending.status.' + status
}
export function blendingFlagKey(flag: string): string {
    return 'blending.flag.' + flag
}
export function blendingVerdictKey(verdict: string): string {
    return 'blending.verdict.' + verdict
}
export function blendingSourceKey(source: string): string {
    return 'blending.source.' + source
}
