'use client'

// MES-3b(2026-10-07,MES-0 Q38 · Q39 · V31 · V35;MES-3b Step 0 Q12 · Q15 · Q17,Tim):这个物料的危险品 UN 编号与 HS 编码。
//   UN 编号【由人选】—— 从化学、形态都推不出来(锂离子还是锂金属、装没装在设备里,这里都没有记)。"not set" 是一个要选的选项:
//   没人选过;电池料没选时标签与发货单上提示,不拒(V35)。字典从 /settings/dictionaries 来(UN3480 · UN3481 · UN3090 · UN3091,第 9 类)。
//   HS 编码:可空(V31,报关行给);6–12 位数字,可带点 —— 形状由数据库判(materials_hs_code_shape),这里只说出规矩。
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DG_NOT_SET, type DgCode } from './dgOptions'

export default function DgHsFields({ codes, dgDefault, hsDefault, locale }: {
    codes: DgCode[]
    dgDefault: string | null
    hsDefault: string | null
    locale: string
}) {
    const t = useTranslations()
    return (
        <>
            <div>
                <label className="block mb-1">{t('materials.form.dgCode')}</label>
                <select name="dg_code" defaultValue={dgDefault ?? DG_NOT_SET} className={`${CONTROL_SELECT} w-full`}>
                    <option value={DG_NOT_SET}>{t('materials.form.dgNotSet')}</option>
                    {codes.map((c) => (
                        <option key={c.code} value={c.code}>{c.code} · {t('materials.form.dgClass', { cls: c.dg_class })} · {locale === 'zh' ? c.name_zh : c.name_en}</option>
                    ))}
                </select>
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('materials.form.dgHint')}</p>
            </div>
            <div>
                <label className="block mb-1">{t('materials.form.hsCode')}</label>
                <input name="hs_code" defaultValue={hsDefault ?? ''} inputMode="decimal" autoComplete="off" spellCheck={false}
                       className={`${CONTROL_INPUT} w-full`} />
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('materials.form.hsHint')}</p>
            </div>
        </>
    )
}
