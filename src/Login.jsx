import React, { useState } from "react";
import { supabase } from "./supabase.js";
import { MessageSquare } from "lucide-react";

// Tela de entrada do Zorvin. O atendente entra com e-mail e senha.
// Os usuários são criados no painel do Supabase (Authentication → Users).
export default function Login() {
  const [email, setEmail] = useState("");
  const [senha, setSenha] = useState("");
  const [erro, setErro] = useState("");
  const [entrando, setEntrando] = useState(false);

  async function entrar(e) {
    e.preventDefault();
    setErro("");
    setEntrando(true);
    const { error } = await supabase.auth.signInWithPassword({ email, password: senha });
    if (error) {
      setErro("E-mail ou senha incorretos.");
      setEntrando(false);
    }
    // Se der certo, o App detecta a sessão e troca para o painel sozinho.
  }

  return (
    <div style={{ height: "100vh", display: "flex", alignItems: "center", justifyContent: "center", background: "#f0f2f5", fontFamily: "'Segoe UI', Arial, sans-serif" }}>
      <div style={{ width: 360, background: "#fff", borderRadius: 12, boxShadow: "0 4px 24px rgba(0,0,0,.08)", padding: 32 }}>
        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", marginBottom: 24 }}>
          <div style={{ width: 52, height: 52, borderRadius: 12, background: "#00a884", display: "flex", alignItems: "center", justifyContent: "center", marginBottom: 12 }}>
            <MessageSquare size={26} color="#fff" />
          </div>
          <div style={{ fontSize: 22, fontWeight: 700, color: "#111b21" }}>Zorvin</div>
          <div style={{ fontSize: 13, color: "#667781", marginTop: 2 }}>Central de atendimento</div>
        </div>

        <form onSubmit={entrar}>
          <label style={{ fontSize: 13, color: "#667781", display: "block", marginBottom: 4 }}>E-mail</label>
          <input
            type="email" value={email} onChange={(e) => setEmail(e.target.value)} required
            style={inputEstilo}
          />
          <label style={{ fontSize: 13, color: "#667781", display: "block", margin: "14px 0 4px" }}>Senha</label>
          <input
            type="password" value={senha} onChange={(e) => setSenha(e.target.value)} required
            style={inputEstilo}
          />

          {erro && <div style={{ color: "#e53935", fontSize: 13, marginTop: 12 }}>{erro}</div>}

          <button
            type="submit" disabled={entrando}
            style={{ width: "100%", marginTop: 20, padding: "11px", background: "#00a884", color: "#fff", border: "none", borderRadius: 8, fontSize: 15, fontWeight: 600, cursor: entrando ? "default" : "pointer", opacity: entrando ? 0.7 : 1 }}
          >
            {entrando ? "Entrando…" : "Entrar"}
          </button>
        </form>
      </div>
    </div>
  );
}

const inputEstilo = {
  width: "100%", boxSizing: "border-box", padding: "10px 12px",
  border: "1px solid #e9edef", borderRadius: 8, fontSize: 14, outline: "none",
};
