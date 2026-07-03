// app/components/labels/labelHtml.ts
// 生成批次二维码打印标签的自包含 HTML(A6 横向 ~148×105mm)。
// 这是打印产物,不接入 app 的 i18n;静态文案按 locale 内联中英双语。
// 普通模块,由 label 路由处理器(服务端)调用。

function esc(s: string): string {
    return s
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
}

export function buildLabelHtml(opts: {
    kind: 'inbound' | 'output'
    locale: 'en' | 'zh'
    code: string
    qrDataUrl: string
    materialName: string
    quantity: number
    unit: string
    detailValue: string | null // 进料:供应商;产出:纯度
}): string {
    const { kind, locale, code, qrDataUrl, materialName, quantity, unit, detailValue } = opts
    const L =
        locale === 'zh'
            ? { scan: '扫码查看实时状态', material: '物料', qty: '数量', detail: kind === 'inbound' ? '供应商' : '纯度' }
            : { scan: 'Scan for live status', material: 'Material', qty: 'Quantity', detail: kind === 'inbound' ? 'Supplier' : 'Purity' }

    return `<!DOCTYPE html>
<html lang="${locale}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(code)}</title>
<style>
  @page { size: 148mm 105mm; margin: 0; }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body { font-family: -apple-system, "Helvetica Neue", Arial, "PingFang SC", "Microsoft YaHei", sans-serif; color: #111; }
  .label { width: 148mm; height: 105mm; padding: 6mm; display: flex; gap: 6mm; align-items: center; }
  .qr { flex: 0 0 auto; text-align: center; }
  .qr img { width: 70mm; height: 70mm; display: block; }
  .qr .cap { font-size: 3.4mm; color: #333; margin-top: 1.5mm; }
  .info { flex: 1 1 auto; min-width: 0; }
  .code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-weight: 800; font-size: 13mm; line-height: 1.05; word-break: break-all; }
  .row { margin-top: 3.5mm; }
  .row .k { color: #666; font-size: 3.6mm; display: block; margin-bottom: 0.5mm; }
  .row .v { font-weight: 600; font-size: 5.5mm; }
  @media screen { body { background: #f4f4f5; } .label { background: #fff; margin: 12px auto; box-shadow: 0 1px 6px rgba(0,0,0,.15); } }
</style>
</head>
<body>
  <div class="label">
    <div class="qr">
      <img src="${qrDataUrl}" alt="QR">
      <div class="cap">${L.scan}</div>
    </div>
    <div class="info">
      <div class="code">${esc(code)}</div>
      <div class="row"><span class="k">${L.material}</span><span class="v">${esc(materialName || '—')}</span></div>
      <div class="row"><span class="k">${L.qty}</span><span class="v">${esc(String(quantity))} ${esc(unit)}</span></div>
      ${detailValue ? `<div class="row"><span class="k">${L.detail}</span><span class="v">${esc(detailValue)}</span></div>` : ''}
    </div>
  </div>
  <script>window.print()</script>
</body>
</html>`
}
