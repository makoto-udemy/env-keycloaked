import { useState } from 'react'
import './App.css'

function App() {
  const [result, setResult] = useState('API未実行')

  const checkApi = async () => {
    const response = await fetch('/api/health')
    const data = (await response.json()) as { status: string }
    setResult(`/api/health -> ${data.status}`)
  }

  return (
    <main>
      <h1>env-keycloaked</h1>
      <p>Keycloak + React(Vite/TypeScript) + FastAPI テンプレート</p>

      <section>
        <h2>アクセス先</h2>
        <ul>
          <li>公開入口: http://localhost:10800</li>
          <li>Keycloak: http://localhost:10800/auth</li>
          <li>Backend Swagger: http://localhost:10800/api/docs</li>
        </ul>
      </section>

      <section>
        <h2>疎通確認</h2>
        <div className="buttons">
          <button onClick={checkApi} type="button">
            API HealthCheck
          </button>
        </div>
        <p>{result}</p>
      </section>
    </main>
  )
}

export default App
