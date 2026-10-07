// app/components/labels/labelHtml.ts
// 一张标签的自包含 HTML —— 进料批 · 产出批 · 库位,A6(148×105mm)或 A5(210×148mm),横放。
// 标签面向司机/货代/海关/客户仓库,一律【中英双语】(中文在前),不看 UI 语言 ——
// 早期版本按 locale cookie 渲染,但默认英文用户没有该 cookie,导致标签误显中文。
//
// ★ MES-3b(2026-10-07,MES-3b Step 0 Q5 · Q9 · Q10 · Q14 · Q15,Tim):
//   · 版式只有【这一份】;模板(label_templates)只挑形状 —— 纸多大、印不印危险品那一行。一个模板永远塞不进一段标记(Q5)。
//   · 数据来自 label_print_preview / record_label_print(属主身份读 —— 仓库印出来的物料名不再是"—",Q2)。
//   · 二维码装的是短链接 <域名>/b/<批号> 或 <域名>/loc/<库位号>(Q9),由打印页在浏览器里生成(域名只有浏览器知道)。
//   · 危险品:物料选了 UN 编号 → 一行"UN3480 · 类别 Class 9"+ 联合国正式运输名称(+ 货代给的标记文字,V30);
//     电池料没选 → 一行"危险品编号未定 DG code not set"(Q15:只提示)。【这不是受监管的包装标记】(Q14),标签上也这么写。
//   · 不再自带 window.print():打印页先记下这一次(record_label_print),再由它自己调打印(Q6)。
//   · 没有 HS 编码(Q10)。
//   · 批号的字号:12 个字符的批号(IN-2026-0012)在 A6 的文字栏(148 − 2×6 边 − 62 码 − 6 间距 = 68 个 A6 毫米)里放得下一行 —— 8.5 倍;
//     旧标签是 13mm,批号在 A6 上断成两行(MES-3b 打印探针截图实测)。
// 普通模块,打印页(客户端)调用。

export type LabelPageSize = 'A6' | 'A5'

export type LabelDg = { code: string; class: string; name_en: string; name_zh: string; marking_text: string | null }

/** label_object_data 的形状(record_label_print / label_print_preview 的 data 一段) */
export type LabelData = {
    kind: 'inbound_batch' | 'output_batch' | 'storage_location'
    id: string
    code: string
    material_code?: string | null
    material_name?: string | null
    quantity?: number | null
    unit?: string | null
    detail_kind?: 'supplier' | 'purity'
    detail_value?: string | null
    dg?: LabelDg | null
    dg_missing?: boolean
    name?: string | null
    zone?: string | null
    is_quarantine?: boolean
    is_active?: boolean
}

function esc(s: string): string {
    return s
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
}

const PAGE: Record<LabelPageSize, { w: number; h: number }> = { A6: { w: 148, h: 105 }, A5: { w: 210, h: 148 } }

/** 一张标签(一份)的 HTML 片段。u = 这张纸上的 1 个"A6 毫米"(A5 放大 210/148)。 */
function labelBody(d: LabelData, qrDataUrl: string, showDg: boolean): string {
    const rows: string[] = []
    const row = (k: string, v: string) => rows.push(`<div class="row"><span class="k">${k}</span><span class="v">${v}</span></div>`)
    if (d.kind === 'storage_location') {
        row('库位 Location', esc(d.name || '—'))
        if (d.zone) row('区域 Zone', esc(d.zone))
        if (d.is_quarantine) rows.push('<div class="row quar">隔离库位 QUARANTINE LOCATION</div>')
    } else {
        row('物料 Material', esc(d.material_name || '—'))
        row('数量 Quantity', `${esc(String(d.quantity ?? ''))} ${esc(d.unit ?? '')}`)
        if (d.detail_value) row(d.detail_kind === 'supplier' ? '供应商 Supplier' : '品位 Purity', esc(d.detail_value))
        if (showDg && d.dg) {
            rows.push(`<div class="row dg"><span class="k">危险品 Dangerous goods</span><span class="v">${esc(d.dg.code)} · 类别 Class ${esc(d.dg.class)}</span>`
                + `<span class="psn">${esc(d.dg.name_en)}</span>`
                + (d.dg.marking_text ? `<span class="psn">${esc(d.dg.marking_text)}</span>` : '')
                + `<span class="note">数据,不是受监管的包装标记 · Data, not a regulated package mark</span></div>`)
        } else if (showDg && d.dg_missing) {
            rows.push('<div class="row dgmiss">危险品编号未定 DG code not set</div>')
        }
    }
    const cap = d.kind === 'storage_location' ? '扫码打开库位 Scan to open this location' : '扫码查看实时状态 Scan for live status'
    return `<div class="label">
    <div class="qr"><img src="${qrDataUrl}" alt="QR"><div class="cap">${cap}</div></div>
    <div class="info"><div class="code">${esc(d.code)}</div>${rows.join('')}</div>
  </div>`
}

export function buildLabelDocument(opts: {
    data: LabelData
    qrDataUrl: string
    pageSize: LabelPageSize
    showDg: boolean
    copies: number
}): string {
    const { data, qrDataUrl, pageSize, showDg } = opts
    const copies = Math.max(1, Math.floor(opts.copies) || 1)
    const p = PAGE[pageSize]
    const u = `${(p.w / 148).toFixed(4)}mm`
    const body = Array.from({ length: copies }, () => labelBody(data, qrDataUrl, showDg)).join('\n')
    return `<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(data.code)}</title>
<style>
  @page { size: ${p.w}mm ${p.h}mm; margin: 0; }
  :root { --u: ${u}; }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body { font-family: -apple-system, "Helvetica Neue", Arial, "PingFang SC", "Microsoft YaHei", sans-serif; color: #111; }
  .label { width: ${p.w}mm; height: ${p.h}mm; padding: calc(var(--u) * 6); display: flex; gap: calc(var(--u) * 6); align-items: center;
           overflow: hidden; page-break-after: always; break-after: page; }
  .label:last-child { page-break-after: auto; break-after: auto; }
  .qr { flex: 0 0 auto; text-align: center; width: calc(var(--u) * 62); }
  .qr img { width: calc(var(--u) * 62); height: calc(var(--u) * 62); display: block; }
  .qr .cap { font-size: calc(var(--u) * 3); line-height: 1.25; color: #333; margin-top: calc(var(--u) * 1.5); }
  .info { flex: 1 1 auto; min-width: 0; }
  .code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-weight: 800; font-size: calc(var(--u) * 8.5); line-height: 1.05; word-break: break-all; }
  .row { margin-top: calc(var(--u) * 2.6); }
  .row .k { color: #666; font-size: calc(var(--u) * 3); display: block; margin-bottom: calc(var(--u) * 0.4); }
  .row .v { font-weight: 600; font-size: calc(var(--u) * 4.8); overflow-wrap: anywhere; }
  .row.dg { border: calc(var(--u) * 0.5) solid #111; padding: calc(var(--u) * 1.5); }
  .row.dg .psn { display: block; font-size: calc(var(--u) * 2.8); line-height: 1.25; margin-top: calc(var(--u) * 0.6); }
  .row.dg .note { display: block; font-size: calc(var(--u) * 2.3); color: #555; margin-top: calc(var(--u) * 0.6); }
  .row.dgmiss, .row.quar { font-weight: 700; font-size: calc(var(--u) * 3.6); border: calc(var(--u) * 0.4) dashed #111; padding: calc(var(--u) * 1.2); }
  @media screen { body { background: #f4f4f5; } .label { background: #fff; margin: 12px auto; box-shadow: 0 1px 6px rgba(0,0,0,.15); } }
</style>
</head>
<body>
  ${body}
</body>
</html>`
}

/** 二维码里装的东西:短链接(域名由调用方给 —— 浏览器里就是 window.location.origin)。路径里的编号逐段编码。 */
export function labelQrUrl(origin: string, qrPath: string): string {
    const m = qrPath.match(/^\/(b|loc)\/(.*)$/)
    return m ? `${origin}/${m[1]}/${encodeURIComponent(m[2])}` : origin + qrPath
}
