import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import TopNav from "@/app/components/TopNav";
import Breadcrumbs from "@/app/components/nav/Breadcrumbs";
import DockRail from "@/app/components/nav/DockRail";
import IdleWatcher from "@/app/components/IdleWatcher";
import { I18nProvider } from "@/lib/i18n/client";
import { getLocale } from "@/lib/i18n/server";
import { isPublicPath } from "@/lib/loginRoute";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "EVoltrya OS",
  description: "Lithium battery recycling ERP",
};

export default async function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  const locale = await getLocale();

  // ══════════════════════════════════════════════════════════════════════════
  // 【应用外壳不套在「还没进系统」的那一屏上】(LOGIN-1-fu1,2026-09-02)
  //
  // 实测的缺陷:/login 顶上画着顶栏 —— 产品名、当前登录的邮箱、通知铃、
  // 语言切换、登出按钮,以及整条模块导航(供应商 / 采购 / 客户 / 物料 … 物流)。
  // **/login 是「任何人都还没进来」的那个状态**,它不该有导航、不该有通知、
  // 不该有登出、不该有模块清单。
  //
  // 【为什么以前会画出来】TopNav 自己【已经】写着「确立地没登录 → 不画」,
  // 所以对一个真正登出的人它本来就是空的。它之所以出现,是因为那个人
  // **其实是登录着的** —— 也就是同一次报告里的第二个缺陷。两个缺陷同一个根。
  // 但「因为不会发生,所以不用管」不是一条结构:认证【判断不出】时 TopNav 会画
  // 一条说明用的横幅,那一条在 /login 上同样不该出现;而重定向哪天回归了,
  // 外壳也不该跟着回来。所以两道都做:那边重定向,这里【结构性地排除】。
  //
  // pathname 由中间件放进 x-pathname(服务端组件拿不到当前路径 —— 没有这个 API)。
  // 判据 isPublicPath 与中间件放行用的是【同一个函数】,不是抄的第二份。
  //
  // 【影响面】PUBLIC_PATHS 今天只有 /login,所以这一行只改这一页;
  // /set-password 与 /welcome 不在其中,它们照旧有外壳(那是对的:那两页
  // 的人已经有会话了)。对登出状态的人来说屏幕上没有任何变化 ——
  // TopNav 本来就返回 null。真正变掉的只有两种:登录着的人(现在根本到不了)
  // 与认证判断不出的人(不再在登录页上看到那条横幅)。
  // ══════════════════════════════════════════════════════════════════════════
  const pathname = (await headers()).get("x-pathname") ?? "";
  const bare = isPublicPath(pathname);

  return (
    <html
      lang={locale}
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        <I18nProvider locale={locale}>
          {/* IDLE-DRAFT:空闲超时的浏览器那一半。挂在根布局,因为预警
              【必须出现在人真正所在的那一页上】,而不是某个他没在看的地方。
              它自己不渲染任何东西,除非真的到了要说话的时候。
              【登录页不挂它】:那里没有会话可以超时,而它要监视的「还有两分钟」
              在一张登录表单上没有意义。草稿的清理由 /login 自己的
              ClearRestrictedDrafts 负责,与这一个无关。 */}
          {!bare && <IdleWatcher />}
          {!bare && <TopNav />}
          {/* ★【CHART-0 ④:dock 与页面主体是同一个 flex 行里的两个兄弟】★
              Tim:桌面上 dock 坐在模块导航底下,读起来像【第三层菜单】,
              而不是"我的快捷方式";而且它吃掉整整一行横向空间。
              于是桌面上它成为【左边一条竖栏】—— 一条管结构(顶栏),
              一条管个人(dock),两者在屏幕上就不再像同一套东西的两级。

              【手机上这一行不产生任何影响】手机形态的 dock 是 `fixed bottom-0`,
              脱离文档流,所以它在这个 flex 行里【不占宽度】;
              正文给它让出的位置仍然是 globals.css 里那条 body 的 padding-bottom。

              `min-w-0` 是必须的:没有它,flex 项的默认 min-width:auto 会让
              一张宽表把【整行】撑开,于是竖栏被推出视口 —— 那正是这一行要防的。 */}
          <div className={bare ? undefined : "flex min-h-0 flex-1"}>
            {!bare && <DockRail />}
            <div className={bare ? undefined : "flex min-w-0 flex-1 flex-col"}>
              {/* IA-BUILD-1 / Tim 的 D4:面包屑【只在 23 条深路由上】出现。
                  判据是算出来的(scripts/gen-deep-routes.mjs),不是一份手写清单 ——
                  手写的那种会在下一次加页时静默漏掉,而没有任何东西会说出来。
                  浅路由上这个组件返回 null,一个字节都不画。 */}
              {!bare && <Breadcrumbs />}
              {children}
            </div>
          </div>
        </I18nProvider>
      </body>
    </html>
  );
}
