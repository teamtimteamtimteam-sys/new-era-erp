import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import TopNav from "@/app/components/TopNav";
import IdleWatcher from "@/app/components/IdleWatcher";
import { I18nProvider } from "@/lib/i18n/client";
import { getLocale } from "@/lib/i18n/server";
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
  return (
    <html
      lang={locale}
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">
        <I18nProvider locale={locale}>
          {/* IDLE-DRAFT:空闲超时的浏览器那一半。挂在根布局,因为预警
              【必须出现在人真正所在的那一页上】,而不是某个他没在看的地方。
              它自己不渲染任何东西,除非真的到了要说话的时候。 */}
          <IdleWatcher />
          <TopNav />
          {children}
        </I18nProvider>
      </body>
    </html>
  );
}
