// app/operation/calibration/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-2(2026-10-06,规格 §8.2;MES-0 Q30 · Q31 · V8;MES-2 Step 0 Q2 · Q23–Q30,Tim)· 校准
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】每一台没停用的仪器(秤 · 地磅 · 电表 · 在线仪表)今天在不在校准期内 —— 读的时候从校准记录推
//   (instrument_calibration_now):在期内 · 过期 · 没通过 · 从来没校过。"在用" = 接口不是 reserved(占位的不催)。
//   每一条记录带它自己证书上的有效期(必填);记错的作废(理由必填),不改、不删。
// 【两样设定】V8 —— 到期前多少天开始提醒(一个数,空 = "Not yet set":到期前的提醒不上牌,过期照样上牌);
//   校准规则的开关 —— 一个日期,空 = 关:关着时校准状态处处看得见、什么都不拒;开着时,【这一天及以后建的】收货单的定价与
//   销毁证书,在读数的仪器不在期内、读数没记录仪器、或收货单没挂任何一次称重时按名拒(Q26 · Q27)。
// 【门】requireFunction(FN.calibration) = module.processing.view;记 / 作废 / 改设定要 action.manage_devices。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { RecordCalibrationForm, CalibrationSettings } from './CalibrationControls'
import type { Option } from '@/app/operation/capture/captureFields'

type Row = {
    device_id: string; code: string; name: string; kind: string; station: string | null; in_use: boolean
    calibrated_on: string | null; valid_until: string | null; result: string | null; certificate_no: string | null
    calibrating_body: string | null; status: string; approaching: boolean
}

export default async function CalibrationPage() {
    const denied = await requireFunction(FN.calibration)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canManage = await can('action.manage_devices')
    const [rowsRes, setRes] = await Promise.all([
        supabase.from('instrument_calibration_now')
            .select('device_id, code, name, kind, station, in_use, calibrated_on, valid_until, result, certificate_no, calibrating_body, status, approaching')
            .order('code'),
        supabase.from('ingest_settings').select('calibration_lead_days, require_calibrated_since').maybeSingle(),
    ])
    const rows = mustRows(rowsRes, 'instrument_calibration_now') as Row[]
    const settings = mustOne(setRes, 'ingest_settings') as { calibration_lead_days: number | null; require_calibrated_since: string | null } | null
    if (!settings) throw new Error('ingest_settings has no row — the calibration settings cannot be shown')
    const instruments: Option[] = rows.map((r) => ({ id: r.device_id, label: `${r.code} — ${r.name}` }))

    const tableRows: CellRow[] = rows.map((r) => ({
        id: r.device_id,
        cells: {
            code: <Link href={`/operation/devices/${r.device_id}`} className="app-link hover:underline">{r.code}</Link>,
            name: r.name,
            kind: t('devices.kind.' + r.kind),
            inUse: r.in_use ? t('calibration.inUse') : t('calibration.reserved'),
            status: (
                <span data-calibration-status={r.status} className={r.status === 'in_calibration' ? '' : 'text-amber-700'}>
                    {t('calibration.status.' + r.status)}
                    {r.approaching && <span className="block text-xs text-amber-700">{t('calibration.approaching')}</span>}
                </span>
            ),
            calibrated: r.calibrated_on ? formatDate(r.calibrated_on, locale) : '—',
            validUntil: r.valid_until ? formatDate(r.valid_until, locale) : '—',
            certificate: [r.certificate_no, r.calibrating_body].filter(Boolean).join(' · ') || '—',
        },
    }))

    return (
        <ListPage title={t('calibration.title')} intro={t('calibration.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            <section className="mb-8">
                <CellsTable
                    columns={[
                        { key: 'code', header: t('devices.colCode'), priority: true },
                        { key: 'name', header: t('devices.colName'), priority: true },
                        { key: 'kind', header: t('devices.colKind') },
                        { key: 'inUse', header: t('calibration.colInUse') },
                        { key: 'status', header: t('calibration.colStatus'), priority: true },
                        { key: 'calibrated', header: t('calibration.colCalibratedOn') },
                        { key: 'validUntil', header: t('calibration.colValidUntil') },
                        { key: 'certificate', header: t('calibration.colCertificate') },
                    ]}
                    rows={tableRows}
                    empty={t('calibration.empty')}
                />
            </section>
            <section className="mb-8">
                <h2 className="mb-2">{t('calibration.recordTitle')}</h2>
                {instruments.length === 0
                    ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('calibration.noInstruments')}</p>
                    : <RecordCalibrationForm instruments={instruments} canManage={canManage} />}
                <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">{t('calibration.historyHint')}</p>
            </section>
            <section className="mb-8">
                <h2 className="mb-2">{t('calibration.settingsTitle')}</h2>
                <CalibrationSettings leadDays={settings.calibration_lead_days} requireSince={settings.require_calibrated_since} canManage={canManage} />
            </section>
        </ListPage>
    )
}
