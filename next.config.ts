import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // 发票 PDF 的中文字体是在运行时用 fs 从 assets/fonts/ 读的(见 InvoiceDocument.tsx),
  // 不是 import 进来的 —— 打包器的静态分析看不见它。标准构建下没问题(文件就在项目里),
  // 但一旦切到 output: 'standalone' 或部署到 serverless,字体不会被 trace 进产物,
  // PDF 路由就会在运行时炸。在这里显式声明,免得哪天加了 standalone 才发现。
  outputFileTracingIncludes: {
    "/finance/invoices/[id]/pdf": ["./assets/fonts/*.subset.ttf"],
    // IMPORT-1:导入模板的列是【请求时】从 lib/database.types.ts 读出来的
    // (见 lib/importTables.ts 的抬头:为什么是它、为什么不在构建时查库)。
    // 那是一次 fs 读源文件,打包器的静态分析同样看不见 —— 与上面字体那条
    // 一模一样的坑,而且后果一样:本地全绿,线上这条路由炸。
    "/settings/import/template/[table]": ["./lib/database.types.ts"],
  },
};

export default nextConfig;
