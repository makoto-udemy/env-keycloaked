import { useState } from 'react'
import './App.css'

function App() {
  const [result, setResult] = useState('API未実行')

  const checkViaProxy = async () => {
    const response = await fetch('/api/health')
    const data = (await response.json()) as { status: string }
    setResult(`proxy /api/health -> ${data.status}`)
  }

  const checkDirect = async () => {
    const response = await fetch('http://localhost:18000/health')
    const data = (await response.json()) as { status: string }
    setResult(`direct :18000/health -> ${data.status}`)
  }

  return (
    <main>
      <h1>env-keycloaked</h1>
      <p>Keycloak + React(Vite/TypeScript) + FastAPI テンプレート</p>

      <section>
        <h2>アクセス先</h2>
        <ul>
          <li>公開入口(Reverse Proxy): http://localhost:10800</li>
          <li>認証(直アクセス): http://localhost:18080/auth</li>
          <li>フロント(直アクセス): http://localhost:15173</li>
          <li>バックエンド(直アクセス): http://localhost:18000/docs</li>
        </ul>
      </section>

      <section>
        <h2>疎通確認</h2>
        <div className="buttons">
          <button onClick={checkViaProxy} type="button">
            Proxy経由でHealthCheck
          </button>
          <button onClick={checkDirect} type="button">
            直アクセスでHealthCheck
          </button>
        </div>
        <p>{result}</p>
      </section>
    </main>
  )
}

export default App
