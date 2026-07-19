import React, { useState, useEffect } from "react";
import { supabase } from "./supabase.js";
import Login from "./Login.jsx";
import Painel from "./Painel.jsx";

// Decide o que mostrar: se ninguém está logado, a tela de Login;
// se há uma sessão ativa, o Painel de atendimento.
export default function App() {
  const [sessao, setSessao] = useState(null);
  const [carregando, setCarregando] = useState(true);

  useEffect(() => {
    // Verifica se já existe uma sessão salva.
    supabase.auth.getSession().then(({ data }) => {
      setSessao(data.session);
      setCarregando(false);
    });

    // Fica atento a login/logout para atualizar a tela.
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setSessao(s);
    });
    return () => sub.subscription.unsubscribe();
  }, []);

  if (carregando) {
    return (
      <div style={{ height: "100vh", display: "flex", alignItems: "center", justifyContent: "center", fontFamily: "'Segoe UI', Arial, sans-serif", color: "#667781" }}>
        Carregando…
      </div>
    );
  }

  return sessao ? <Painel sessao={sessao} /> : <Login />;
}
