// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(2026-10-22)· 一格导出值 —— 【带类型】,不是屏幕上画出来的那串字
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-22 的裁定(Step 0,全文见 docs/table-export.md):
//   ★ Excel 的格子要有类型:金额与数量是【数】,日期是【真日期】,不是文字(硬规矩)。
//   ★ Q3 受限的列留在文件里,每一格写「Restricted / 受限」,与屏幕一样;绝不留空。
//   ★ Q7 时刻按新加坡时间,写成真的 Excel 日期格。
//
// 【为什么每一列要自己声明 exportAs,而不是从 render 里抠】DataTable 的列只有 header 与
//   render(返回 JSX),页面递进来的行多半已经格式化好(`createdLabel: formatAuditStamp(…)`)。
//   从那里抠出来的是【文字】—— 正是 lib/dates.ts:210-216 记着的「显示用的日期被当成数据」。
//   所以每一列带一个返回 ExportCell 的函数,读【原始值】。
//
// 本文件同构(浏览器与服务端都可用),不引任何库。
// ════════════════════════════════════════════════════════════════════════════

/** 数的显示档位 —— 只决定 Excel 里的数字格式,值本身永远是原样的 number。 */
export type NumberKind = 'money' | 'qty' | 'int' | 'pct' | 'rate'

export type ExportCell =
    | { t: 'text'; v: string | null }
    /**
     * `suffix`:屏幕上【跟在这个数旁边】的那个词 —— 金额的币种(formatAmount 的 "1,234.56 USD")或数量的单位("12 kg")。
     * 一张表里各行可以不同(采购单各按各的币种;一列重量里有 kg 也有 pcs),一个光秃秃的数字会把它丢掉 ——
     * 那是 CCY-1 那一族的谎:一个 USD 的数穿着别的名字,一个「件」的数被加进了公斤。
     * Excel 里它仍是一个数(数字格式带着那个词,照样能加总),CSV 里写成「1234.56 USD」。
     */
    | { t: 'number'; v: number | null; kind: NumberKind; suffix?: string | null }
    /** 一个日历日,`YYYY-MM-DD`。没有时区。 */
    | { t: 'date'; v: string | null }
    /** 一个时刻(ISO 字符串,带时区)。写出时换成新加坡时间(Q7)。 */
    | { t: 'datetime'; v: string | null }
    /** 读者没有权限看的那一格(Q3)。写出时是「Restricted / 受限」,不是空。 */
    | { t: 'restricted' }

/** 一列【不导出】—— 只给画控件的那几列(删除 / 撤回 / 勾选之类),它们不是数据。 */
export type NoExport = false

export const xText = (v: string | null | undefined): ExportCell => ({ t: 'text', v: v ?? null })
/** 一个数。屏幕上数字旁边写着单位的(「12 kg」),把那个单位一起给(第三个参数)。 */
export const xNum = (v: number | string | null | undefined, kind: NumberKind = 'qty', unit?: string | null): ExportCell => ({
    t: 'number',
    v: toNumber(v),
    kind,
    suffix: unit ?? null,
})
/** 金额。屏幕上数字旁边写着币种的,把那个币种一起给(第二个参数)—— 不给就只剩一个数。 */
export const xMoney = (v: number | string | null | undefined, ccy?: string | null): ExportCell =>
    ({ t: 'number', v: toNumber(v), kind: 'money', suffix: ccy ?? null })
export const xInt = (v: number | string | null | undefined): ExportCell => xNum(v, 'int')
export const xDate = (v: string | null | undefined): ExportCell => ({ t: 'date', v: v ? v.slice(0, 10) : null })
export const xTime = (v: string | null | undefined): ExportCell => ({ t: 'datetime', v: v ?? null })
export const xBool = (v: boolean | null | undefined, yes: string, no: string): ExportCell =>
    xText(v == null ? null : v ? yes : no)
export const xRestricted: ExportCell = { t: 'restricted' }

/**
 * ★ 与 `<MaskedValue>` 同一条判据(app/components/MaskedValue.tsx:33-40):
 *   没有权限且值是 NULL → 受限;否则照常。有权限而值是 NULL → 空格(「没有值」本来就是一个合法状态)。
 */
export function xMasked(
    value: number | string | null | undefined,
    canView: boolean,
    cell: (v: number | string | null | undefined) => ExportCell,
): ExportCell {
    if (!canView && (value === null || value === undefined)) return xRestricted
    return cell(value)
}

/**
 * Postgres 的 numeric 经 PostgREST 来时可能是字符串。空串、非数一律 NULL —— **不是 0**
 * (一个编出来的 0 与「受限」是同一种谎,AGENTS.md「0.00 and 受限 are not the same thing」)。
 */
function toNumber(v: number | string | null | undefined): number | null {
    if (v === null || v === undefined || v === '') return null
    const n = typeof v === 'number' ? v : Number(v)
    return Number.isFinite(n) ? n : null
}
