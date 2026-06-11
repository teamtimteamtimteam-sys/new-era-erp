// app/login/page.tsx
import { login } from './actions'

export default async function LoginPage({
    searchParams,
}: {
    searchParams: Promise<{ error?: string }>
}) {
    const params = await searchParams
    const hasError = params.error === 'invalid'

    return (
        <main className="min-h-screen flex items-center justify-center bg-gray-50 p-4">
            <div className="w-full max-w-md bg-white border border-gray-300 rounded-lg p-8 shadow-sm">
                <div className="mb-6 text-center">
                    <h1 className="text-2xl font-bold">登录 SWM-OS</h1>
                    <p className="text-sm text-gray-500 mt-1">锂电池回收 ERP 系统</p>
                </div>

                {hasError && (
                    <div className="mb-4 bg-red-50 border border-red-200 text-red-700 text-sm px-3 py-2 rounded">
                        邮箱或密码错误
                    </div>
                )}

                <form action={login} className="space-y-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">邮箱</label>
                        <input
                            type="email"
                            name="email"
                            required
                            placeholder="邮箱"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>

                    <div>
                        <label className="block text-sm font-medium mb-1">密码</label>
                        <input
                            type="password"
                            name="password"
                            required
                            placeholder="密码"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>

                    <button
                        type="submit"
                        className="w-full bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        登录
                    </button>
                </form>

                <p className="mt-4 text-center text-xs text-gray-500">
                    还没有账号? 联系管理员
                </p>
            </div>
        </main>
    )
}
