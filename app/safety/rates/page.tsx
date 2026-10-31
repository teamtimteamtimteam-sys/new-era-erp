// app/safety/rates/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// ESG-2(Tim 2026-10-30 SYSTEM-MAP-4 Q1 · 2026-10-31 Q4 · Q5 · Q6 · Q7)· ESG › 安全率 —— 每个月的误工事故、误工天数、工时与误工事故频率(LTIFR),
//   外加年初至今。
// 【一份实现】每一个数都来自 esg_safety_rates(p_year)(库里):误工事故 = 种类 injury、受伤的是员工、误工天数(最后一次更正)> 0;
//   非员工受伤另数、不进率;工时 = (在职工作日 − 批准的请假)× 标准日工时 + 加班;LTIFR = 事故 × 1,000,000 ÷ 工时(MOM 口径)。这一页不算任何东西。
// 【算不出时说出为什么】一个月没有考勤期 / 考勤没记全(n / m)/ 标准日工时没设 → 那个月没有工时、没有率;年初至今只有每个月都齐才有(Q4)。
// 【门】注册表 /safety/rates = module.safety.view;误工事故、误工天数、非员工受伤与率另要 data.view_health —— 不持的人那几格画「受限」(库给的是空)。
// 【手机(390px)】ListPage + CellsTable(phone: columns,月份、工时、率留在手机上)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { businessToday } from '@/lib/format'
import { formatMonth } from '@/lib/dates'
import { num } from '@/lib/massFormat'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xNum, xDate } from '@/lib/export/cells'
import StandardHoursPanel from './StandardHoursPanel'

type RateRow = {
    month: string | null; hours_state: string; lines_recorded: number; lines_total: number; hours_worked: number | string | null
    injury_visible: boolean; lti: number | null; days_lost: number | string | null; nonemployee_injuries: number | null; ltifr: number | string | null
}

const fmt = (v: number | null, digits = 0) => (v === null ? '—' : new Intl.NumberFormat('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits }).format(v))

export default async function SafetyRatesPage({ searchParams }: { searchParams: Promise<{ year?: string }> }) {
    const denied = await requireFunction(FN.esgRates)
    if (denied) return denied
    const sp = await searchParams
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const thisYear = Number(businessToday().slice(0, 4))
    const asked = Number(sp.year)
    const year = Number.isInteger(asked) && asked >= 2000 && asked <= thisYear ? asked : thisYear

    const [rateRes, setRes, canManage] = await Promise.all([
        supabase.rpc('esg_safety_rates', { p_year: year }),   // unpaged-ok: 至多 13 行(12 个月 + 年初至今)
        supabase.from('esg_settings').select('standard_hours_per_day').maybeSingle(),
        can('action.manage_esg'),
    ])
    const rows = mustRows(rateRes, 'esg_safety_rates') as RateRow[]
    if (setRes.error) throw new Error(`查询失败(esg_settings): ${setRes.error.message}`)
    const std = setRes.data?.standard_hours_per_day == null ? null : Number(setRes.data.standard_hours_per_day)
    const months = rows.filter((r) => r.month !== null)
    const ytd = rows.find((r) => r.month === null) ?? null
    const restricted = t('common.restricted')

    const stateText = (r: RateRow) =>
        r.hours_state === 'no_period' ? t('esg.rates.state.no_period')
        : r.hours_state === 'incomplete' ? t('esg.rates.state.incomplete', { n: r.lines_recorded, m: r.lines_total })
        : r.hours_state === 'hours_not_set' ? t('esg.rates.state.hours_not_set')
        : t('esg.rates.state.complete')
    const cell = (r: RateRow, v: number | null, digits = 0) => (!r.injury_visible ? restricted : fmt(v, digits))
    const xcell = (r: RateRow, v: number | null) => (!r.injury_visible ? xText(restricted) : xNum(v, 'qty'))

    const tableRows: CellRow[] = months.map((r) => {
        const k = String(r.month).slice(0, 10)
        const hours = num(r.hours_worked)
        const rate = num(r.ltifr)
        return {
            id: k,
            cells: {
                month: formatMonth(k, locale),
                state: <span data-hours-state={r.hours_state}>{stateText(r)}</span>,
                hours: hours === null ? '—' : fmt(hours, 1),
                lti: cell(r, r.lti),
                days: cell(r, num(r.days_lost), 1),
                nonemp: cell(r, r.nonemployee_injuries),
                ltifr: !r.injury_visible ? restricted : rate === null ? '—' : fmt(rate, 2),
            },
            exports: {
                month: xDate(k),
                state: xText(stateText(r)),
                hours: xNum(hours, 'qty'),
                lti: xcell(r, r.lti),
                days: xcell(r, num(r.days_lost)),
                nonemp: xcell(r, r.nonemployee_injuries),
                ltifr: !r.injury_visible ? xText(restricted) : xNum(rate, 'qty'),
            },
        }
    })

    const ytdLine = ytd === null ? null
        : !ytd.injury_visible ? t('esg.rates.ytdRestricted', { year, hours: ytd.hours_state === 'complete' ? fmt(num(ytd.hours_worked), 1) : t('esg.rates.ytdHoursIncomplete') })
        : ytd.hours_state !== 'complete' ? t('esg.rates.ytdNoRate', { year, lti: fmt(ytd.lti), days: fmt(num(ytd.days_lost), 1), non: fmt(ytd.nonemployee_injuries) })
        : t('esg.rates.ytdLine', { year, lti: fmt(ytd.lti), days: fmt(num(ytd.days_lost), 1), non: fmt(ytd.nonemployee_injuries), hours: fmt(num(ytd.hours_worked), 1), rate: fmt(num(ytd.ltifr), 2) })

    return (
        <ListPage title={t('esg.rates.title')} intro={t('esg.rates.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            <p className="text-sm mb-2 flex flex-wrap gap-x-4">
                {year > 2000 && <Link href={`?year=${year - 1}`} className="app-link hover:underline">{t('esg.energy.prevYear', { year: year - 1 })}</Link>}
                {year < thisYear && <Link href={`?year=${year + 1}`} className="app-link hover:underline">{t('esg.energy.nextYear', { year: year + 1 })}</Link>}
            </p>
            {ytdLine && <p className="text-sm font-medium mb-3" data-rates-ytd={ytd?.hours_state}>{ytdLine}</p>}
            <CellsTable
                columns={[
                    { key: 'month', header: t('esg.rates.colMonth'), priority: true },
                    { key: 'state', header: t('esg.rates.colAttendance') },
                    { key: 'hours', header: t('esg.rates.colHours'), align: 'right', priority: true },
                    { key: 'lti', header: t('esg.rates.colLti'), align: 'right' },
                    { key: 'days', header: t('esg.rates.colDays'), align: 'right' },
                    { key: 'nonemp', header: t('esg.rates.colNonEmployee'), align: 'right' },
                    { key: 'ltifr', header: t('esg.rates.colLtifr'), align: 'right', priority: true },
                ]}
                rows={tableRows}
                empty={t('esg.rates.none')}
                sorting="client"
                exportSpec={{ name: `esg-safety-rates-${year}`, title: t('esg.rates.titleYear', { year }) }}
            />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4 max-w-3xl">{t('esg.rates.basis')}</p>
            <StandardHoursPanel current={std} canManage={canManage} />
        </ListPage>
    )
}
