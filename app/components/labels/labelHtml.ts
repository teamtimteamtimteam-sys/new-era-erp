// app/components/labels/labelHtml.ts
// 生成批次二维码打印标签的自包含 HTML(A6 横向 ~148×105mm)。
// 标签面向司机/货代/海关/客户仓库,一律【中英双语】(中文在前),不看 UI 语言 ——
// 早期版本按 locale cookie 渲染,但默认英文用户没有该 cookie,导致标签误显中文。
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
    code: string
    qrDataUrl: string
    materialName: string
    quantity: number
    unit: string
    detailValue: string | null // 进料:供应商;产出:品位
}): string {
    const { kind, code, qrDataUrl, materialName, quantity, unit, detailValue } = opts

    // 静态文案一律双语(中文 / English),中文在前。
    const capMaterial = '物料 Material'
    const capQty = '数量 Quantity'
    const capDetail = kind === 'inbound' ? '供应商 Supplier' : '品位 Purity'
    const capScan = '扫码查看实时状态 Scan for live status'

    return `<!DOCTYPE html>
<html lang="zh">
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
  .qr { flex: 0 0 auto; text-align: center; width: 70mm; }
  .qr img { width: 70mm; height: 70mm; display: block; }
  .qr .cap { font-size: 3mm; line-height: 1.25; color: #333; margin-top: 1.5mm; }
  .info { flex: 1 1 auto; min-width: 0; }
  .code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-weight: 800; font-size: 13mm; line-height: 1.05; word-break: break-all; }
  .row { margin-top: 3.5mm; }
  .row .k { color: #666; font-size: 3.2mm; display: block; margin-bottom: 0.5mm; }
  .row .v { font-weight: 600; font-size: 5.5mm; }
  @media screen { body { background: #f4f4f5; } .label { background: #fff; margin: 12px auto; box-shadow: 0 1px 6px rgba(0,0,0,.15); } }
</style>
</head>
<body>
  <div class="label">
    <div class="qr">
      <img src="${qrDataUrl}" alt="QR">
      <div class="cap">${capScan}</div>
    </div>
    <div class="info">
      <div class="code">${esc(code)}</div>
      <div class="row"><span class="k">${capMaterial}</span><span class="v">${esc(materialName || '—')}</span></div>
      <div class="row"><span class="k">${capQty}</span><span class="v">${esc(String(quantity))} ${esc(unit)}</span></div>
      ${detailValue ? `<div class="row"><span class="k">${capDetail}</span><span class="v">${esc(detailValue)}</span></div>` : ''}
    </div>
  </div>
  <script>window.print()</script>
</body>
</html>`
}
