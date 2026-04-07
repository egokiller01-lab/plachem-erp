'use client';

import { useState } from 'react';
import { supabase } from '@/lib/supabase';
import { useRouter } from 'next/navigation';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const useRouterHook = useRouter();

  const handleLogin = async () => {
    if (!email || !password) return;
    setLoading(true);
    setError(null);

    const { error: loginError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    if (loginError) {
      setError(loginError.message);
      setLoading(false);
    } else {
      useRouterHook.push('/');
    }
  };

  const handleSignUp = async () => {
    if (!email || !password) return;
    setLoading(true);
    setError(null);

    const { error: signUpError } = await supabase.auth.signUp({
      email,
      password,
    });

    if (signUpError) {
      setError(signUpError.message);
      setLoading(false);
    } else {
      useRouterHook.push('/');
    }
  };

  return (
    <div style={{
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      minHeight: '100vh',
      backgroundColor: 'var(--bg-app)'
    }}>
      <div className="card" style={{ width: '100%', maxWidth: '400px' }}>
        <h1 style={{ marginBottom: '8px', fontSize: '24px' }}>Plachem ERP</h1>
        <p style={{ color: 'var(--text-muted)', marginBottom: '32px' }}>
          계정에 로그인하여 업무를 시작하세요.
        </p>

        <form onSubmit={(e) => e.preventDefault()}>
          <div className="form-group">
            <label className="form-label">이메일</label>
            <input
              type="email"
              className="form-control"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              placeholder="name@company.com"
            />
          </div>

          <div className="form-group">
            <label className="form-label">비밀번호</label>
            <input
              type="password"
              className="form-control"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              placeholder="••••••••"
            />
          </div>

          {error && (
            <div style={{
              padding: '12px',
              backgroundColor: '#fee2e2',
              color: '#991b1b',
              borderRadius: '4px',
              fontSize: '14px',
              marginBottom: '24px'
            }}>
              {error}
            </div>
          )}

          <div style={{ display: 'flex', gap: '8px' }}>
            <button
              onClick={handleLogin}
              type="button"
              className="btn btn-primary"
              style={{ flex: 1, justifyContent: 'center' }}
              disabled={loading}
            >
              로그인
            </button>
            <button
              onClick={handleSignUp}
              type="button"
              className="btn btn-secondary"
              style={{ flex: 1, justifyContent: 'center', backgroundColor: '#e2e8f0', color: '#1e293b' }}
              disabled={loading}
            >
              회원가입
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
