'use client'
// app/tools/converter/ConverterForm.tsx — 三档换算的表单。
//
// 【为什么是客户端组件】换算器要边敲边出数;每敲一个字符打一次服务器
// 既慢又没必要。所以:**定义性的算术在客户端当场算**(吨/公斤/磅、品位),
// 而**决定钱的那一档(湿转干)按一次按钮走服务器**,调库里那两支基元
// —— 与结算同一份实现。两者的分界写在 page.tsx 的抬头里。
//
// ★【每一档都把【算式】印出来,不只印答案】★(TOOLS-1 ④ 的要求)
// 这是一个给人核对工作的工具:一个只给答案的换算器,使用者没法判断
// 自己有没有选错档、有没有把水分填成 8 而不是 0.08。
import { useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import {
    convertMass, pctToGramsPerTonne, gramsPerTonneToPct,
    KG_PER_TONNE, KG_PER_POUND, GRAMS_PER_TONNE_PER_PERCENT, SETTLEMENT_ROUND_DP,
    type MassUnit,
} from '@/lib/convert'
import { convertBasis } from './actions'
import { Button } from '@/app/components/ui/button'

// 【它同时是 check-i18n 的真源】—— 加一个单位,两个语言少一句话就构建变红。
const UNITS = ['tonne', 'kg', 'pound'] as const satisfies readonly MassUnit[]

/** 显示用:去掉浮点噪音,又不假装精度。**算术里不 round**(见 lib/convert.ts)。 */
function show(n: number): string {
    if (!Number.isFinite(n)) return '—'
    const a = Math.abs(n)
    const dp = a === 0 ? 0 : a < 0.001 ? 8 : a < 1 ? 6 : 4
    return Number(n.toFixed(dp)).toString()
}

export default function ConverterForm() {
    const t = useTranslations()

    // ── ① 质量 ──────────────────────────────────────────────────────────────
    const [massIn, setMassIn] = useState('1')
    const [from, setFrom] = useState<MassUnit>('tonne')
    const [to, setTo] = useState<MassUnit>('kg')
    const massVal = Number(massIn)
    const massOk = massIn.trim() !== '' && Number.isFinite(massVal)

    // ── ② 品位 ──────────────────────────────────────────────────────────────
    const [pct, setPct] = useState('1')
    const [gpt, setGpt] = useState('10000')

    // ── ③ 湿转干(走服务器)───────────────────────────────────────────────
    const [w, setW] = useState('1000')
    const [g, setG] = useState('10')
    const [m, setM] = useState('8')
    const [dir, setDir] = useState<'as_received:dry' | 'dry:as_received'>('as_received:dry')
    const [busy, setBusy] = useState(false)
    const [res, setRes] = useState<{ weight: number | null; grade: number | null } | null>(null)
    const [err, setErr] = useState<string | null>(null)

    const runBasis = async () => {
        setBusy(true); setErr(null); setRes(null)
        const [f, tgt] = dir.split(':') as ['as_received' | 'dry', 'as_received' | 'dry']
        const out = await convertBasis({
            weight: w.trim() === '' ? null : Number(w),
            gradePct: g.trim() === '' ? null : Number(g),
            moisturePct: Number(m), from: f, to: tgt,
        })
        setBusy(false)
        if (out.ok) setRes({ weight: out.weight, grade: out.grade })
        else setErr(out.error)
    }

    const card = 'rounded border p-4 mb-6'
    const cardStyle = { borderColor: 'var(--brand-border)', background: 'var(--brand-surface)' }
    const inp = 'border rounded px-2 py-1 w-32'
    const formulaStyle = { background: 'var(--brand-muted)', color: 'var(--brand-text)' }

    return (
        <div>
            {/* ══ ① 吨 / 公斤 / 磅 ═══════════════════════════════════════════ */}
            <section className={card} style={cardStyle}>
                <h2 className="font-semibold mb-2">{t('converter.mass.title')}</h2>
                <div className="flex flex-wrap items-center gap-2 mb-3">
                    <input className={inp} value={massIn} onChange={(e) => setMassIn(e.target.value)}
                           inputMode="decimal" aria-label={t('converter.mass.value')} />
                    <select className="border rounded px-2 py-1" value={from}
                            onChange={(e) => setFrom(e.target.value as MassUnit)}
                            aria-label={t('converter.mass.from')}>
                        {UNITS.map((u) => <option key={u} value={u}>{t('converter.unit.' + u)}</option>)}
                    </select>
                    <span aria-hidden="true">→</span>
                    <select className="border rounded px-2 py-1" value={to}
                            onChange={(e) => setTo(e.target.value as MassUnit)}
                            aria-label={t('converter.mass.to')}>
                        {UNITS.map((u) => <option key={u} value={u}>{t('converter.unit.' + u)}</option>)}
                    </select>
                    <span className="font-mono font-semibold ml-2">
                        = {massOk ? show(convertMass(massVal, from, to)) : '—'}
                    </span>
                </div>
                {/* 【算式 + 常数的出处】—— 不只给答案 */}
                <p className="rounded px-2 py-1 text-xs font-mono" style={formulaStyle}>
                    {t('converter.mass.formula')}
                </p>
                <p className="text-xs mt-2" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('converter.mass.sources', {
                        kgPerTonne: String(KG_PER_TONNE), kgPerPound: String(KG_PER_POUND),
                    })}
                </p>
            </section>

            {/* ══ ② 品位 ════════════════════════════════════════════════════ */}
            <section className={card} style={cardStyle}>
                <h2 className="font-semibold mb-2">{t('converter.grade.title')}</h2>
                <div className="flex flex-wrap items-center gap-2 mb-3">
                    <input className={inp} value={pct} inputMode="decimal"
                           aria-label={t('converter.grade.pct')}
                           onChange={(e) => {
                               setPct(e.target.value)
                               const v = Number(e.target.value)
                               setGpt(e.target.value.trim() === '' || !Number.isFinite(v) ? '' : show(pctToGramsPerTonne(v)))
                           }} />
                    <span>%</span>
                    <span aria-hidden="true">↔</span>
                    <input className={inp} value={gpt} inputMode="decimal"
                           aria-label={t('converter.grade.gpt')}
                           onChange={(e) => {
                               setGpt(e.target.value)
                               const v = Number(e.target.value)
                               setPct(e.target.value.trim() === '' || !Number.isFinite(v) ? '' : show(gramsPerTonneToPct(v)))
                           }} />
                    <span>g/t</span>
                </div>
                <p className="rounded px-2 py-1 text-xs font-mono" style={formulaStyle}>
                    {t('converter.grade.formula', { k: String(GRAMS_PER_TONNE_PER_PERCENT) })}
                </p>
                <p className="text-xs mt-2" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('converter.grade.sources')}
                </p>
            </section>

            {/* ══ ③ 湿基 ↔ 干基 —— 这一档决定钱 ═══════════════════════════════ */}
            <section className={card} style={{ ...cardStyle, borderColor: 'var(--brand-ocean)' }}>
                <h2 className="font-semibold mb-1">{t('converter.basis.title')}</h2>
                <p className="text-xs mb-3" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('converter.basis.why')}
                </p>
                <div className="flex flex-wrap items-end gap-3 mb-3">
                    <label className="text-sm">{t('converter.basis.weight')}
                        <input className={inp + ' block mt-1'} value={w} inputMode="decimal"
                               onChange={(e) => setW(e.target.value)} />
                    </label>
                    <label className="text-sm">{t('converter.basis.grade')}
                        <input className={inp + ' block mt-1'} value={g} inputMode="decimal"
                               onChange={(e) => setG(e.target.value)} />
                    </label>
                    <label className="text-sm">{t('converter.basis.moisture')}
                        <input className={inp + ' block mt-1'} value={m} inputMode="decimal"
                               onChange={(e) => setM(e.target.value)} />
                    </label>
                    <select className="border rounded px-2 py-1" value={dir}
                            onChange={(e) => setDir(e.target.value as typeof dir)}
                            aria-label={t('converter.basis.direction')}>
                        <option value="as_received:dry">{t('converter.basis.arToDry')}</option>
                        <option value="dry:as_received">{t('converter.basis.dryToAr')}</option>
                    </select>
                    <Button type="button" onClick={runBasis} disabled={busy}>
                        {busy ? t('common.saving') : t('converter.basis.run')}
                    </Button>
                </div>

                {err && (
                    <p className="rounded px-3 py-2 text-sm mb-2" data-converter-error="1"
                       style={{ background: 'var(--brand-accent)', color: 'var(--brand-destructive)' }}>
                        {err}
                    </p>
                )}
                {res && (
                    <p className="rounded px-3 py-2 text-sm font-mono mb-2" data-converter-result="1"
                       style={{ background: 'var(--brand-accent)' }}>
                        {t('converter.basis.weight')}: {res.weight === null ? '—' : show(res.weight)}
                        {'   '}
                        {t('converter.basis.grade')}: {res.grade === null ? '—' : show(res.grade)}
                    </p>
                )}

                <p className="rounded px-2 py-1 text-xs font-mono" style={formulaStyle}>
                    {t('converter.basis.formula')}
                </p>
                <p className="text-xs mt-2" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('converter.basis.sources', { dp: String(SETTLEMENT_ROUND_DP) })}
                </p>
            </section>
        </div>
    )
}
