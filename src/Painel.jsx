import React, { useState, useRef, useEffect, useCallback } from "react";
import { supabase } from "./supabase.js";
import {
  Search, Send, Paperclip, Smile, MoreVertical, ChevronDown,
  MessageSquare, Mic, Play, CheckCheck, Settings, LogOut, Phone, ArrowLeft, Sun, Moon
} from "lucide-react";

// ============================================================
//  ZORVIN by Ropelimi — Painel real (conectado ao Supabase)
//  Lê advogados, conversas e mensagens reais; recebe novidades
//  em tempo real (Realtime); envia gravando na fila_envio.
// ============================================================

const TEMAS = {
  claro: {
    rail: "#202c33", headerBar: "#f0f2f5", panel: "#ffffff", listActive: "#f0f2f5",
    chatBg: "#efeae2", bubbleIn: "#ffffff", bubbleOut: "#d9fdd3", green: "#00a884",
    greenDark: "#008069", textPrimary: "#111b21", textSecondary: "#667781",
    divider: "#e9edef", unread: "#25d366", inputBg: "#ffffff", searchBg: "#f0f2f5",
    placeholderCircle: "#dfe5e7",
  },
  escuro: {
    rail: "#161717", headerBar: "#202c33", panel: "#111b21", listActive: "#2a3942",
    chatBg: "#0b141a", bubbleIn: "#202c33", bubbleOut: "#005c4b", green: "#00a884",
    greenDark: "#025144", textPrimary: "#e9edef", textSecondary: "#8696a0",
    divider: "#222d34", unread: "#00a884", inputBg: "#2a3942", searchBg: "#202c33",
    placeholderCircle: "#202c33",
  },
};

// Cor de avatar estável a partir do texto (mesmo nome = mesma cor).
const CORES = ["#0288d1", "#f57c00", "#7cb342", "#8e24aa", "#5e35b1", "#00acc1", "#d81b60", "#6a5acd", "#00897b", "#c2185b"];
function corDe(txt) {
  let h = 0;
  for (let i = 0; i < (txt || "").length; i++) h = (h * 31 + txt.charCodeAt(i)) % CORES.length;
  return CORES[h];
}

function horaDe(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  const hoje = new Date();
  const mesmoDia = d.toDateString() === hoje.toDateString();
  if (mesmoDia) return d.toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
  return d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit" });
}

function Avatar({ nome, size = 40 }) {
  const inicial = (nome || "?").trim().charAt(0).toUpperCase();
  return (
    <div style={{ width: size, height: size, borderRadius: "50%", background: corDe(nome), color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 600, fontSize: size * 0.42, flexShrink: 0 }}>
      {inicial}
    </div>
  );
}

function BolhaAudio({ C, saida, url }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 200 }}>
      {url ? (
        <audio controls src={url} style={{ height: 32, maxWidth: 220 }} />
      ) : (
        <>
          <div style={{ width: 34, height: 34, borderRadius: "50%", background: saida ? C.greenDark : C.green, display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
            <Play size={16} color="#fff" fill="#fff" />
          </div>
          <span style={{ fontSize: 12, color: C.textSecondary }}>Áudio</span>
        </>
      )}
    </div>
  );
}

export default function Painel({ sessao }) {
  const [modo, setModo] = useState("claro");
  const [advogados, setAdvogados] = useState([]);
  const [advogadoId, setAdvogadoId] = useState(null);
  const [conversas, setConversas] = useState([]);
  const [conversaId, setConversaId] = useState(null);
  const [mensagens, setMensagens] = useState([]);
  const [seletorAberto, setSeletorAberto] = useState(false);
  const [busca, setBusca] = useState("");
  const [rascunho, setRascunho] = useState("");
  const fimRef = useRef(null);

  const C = TEMAS[modo];
  const advogado = advogados.find((a) => a.id === advogadoId) || null;
  const conversa = conversas.find((c) => c.id === conversaId) || null;

  // ---- Carrega os advogados (uma vez) ----
  useEffect(() => {
    supabase.from("advogados").select("id, nome, numero").eq("ativo", true).order("nome")
      .then(({ data }) => {
        setAdvogados(data || []);
        if (data && data.length) setAdvogadoId(data[0].id);
      });
  }, []);

  // ---- Carrega as conversas do advogado selecionado ----
  const carregarConversas = useCallback(async (advId) => {
    if (!advId) return;
    const { data } = await supabase
      .from("conversas")
      .select("id, ultima_mensagem, ultima_atividade, nao_lidas, contato:contato_id (nome, numero)")
      .eq("advogado_id", advId)
      .order("ultima_atividade", { ascending: false });
    setConversas(data || []);
  }, []);

  useEffect(() => { carregarConversas(advogadoId); }, [advogadoId, carregarConversas]);

  // ---- Carrega as mensagens da conversa aberta ----
  const carregarMensagens = useCallback(async (convId) => {
    if (!convId) { setMensagens([]); return; }
    const { data } = await supabase
      .from("mensagens")
      .select("id, origem, tipo, texto, midia_url, criado_em")
      .eq("conversa_id", convId)
      .order("criado_em", { ascending: true });
    setMensagens(data || []);
    // Zera o contador de não lidas desta conversa.
    await supabase.from("conversas").update({ nao_lidas: 0 }).eq("id", convId);
  }, []);

  useEffect(() => { carregarMensagens(conversaId); }, [conversaId, carregarMensagens]);

  // ---- Realtime: novas mensagens e conversas atualizadas ----
  useEffect(() => {
    const canal = supabase
      .channel("zorvin-realtime")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "mensagens" }, (payload) => {
        const nova = payload.new;
        if (nova.conversa_id === conversaId) {
          setMensagens((prev) => (prev.some((m) => m.id === nova.id) ? prev : [...prev, nova]));
        }
        // Atualiza a lista de conversas (prévia / ordem / não lidas).
        carregarConversas(advogadoId);
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "conversas" }, () => {
        carregarConversas(advogadoId);
      })
      .subscribe();
    return () => { supabase.removeChannel(canal); };
  }, [conversaId, advogadoId, carregarConversas]);

  useEffect(() => { fimRef.current?.scrollIntoView({ behavior: "smooth" }); }, [mensagens.length, conversaId]);

  function trocarAdvogado(id) { setAdvogadoId(id); setConversaId(null); setSeletorAberto(false); setBusca(""); }

  async function enviar() {
    const t = rascunho.trim();
    if (!t || !conversaId) return;
    setRascunho("");
    // Coloca na fila de envio; a ponte processa e manda pela Uazapi.
    await supabase.from("fila_envio").insert({ conversa_id: conversaId, texto: t });
  }

  async function sair() { await supabase.auth.signOut(); }

  const conversasFiltradas = conversas.filter((c) =>
    (c.contato?.nome || c.contato?.numero || "").toLowerCase().includes(busca.toLowerCase())
  );

  return (
    <div style={{ display: "flex", height: "100vh", fontFamily: "'Segoe UI', Helvetica, Arial, sans-serif", background: C.headerBar, color: C.textPrimary }}>
      {/* Barra lateral */}
      <div style={{ width: 60, background: C.rail, display: "flex", flexDirection: "column", alignItems: "center", paddingTop: 16, gap: 8 }}>
        <div style={{ width: 34, height: 34, borderRadius: 8, background: C.green, display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 700, color: "#fff", marginBottom: 12 }}>Z</div>
        <RailIcon ativo><MessageSquare size={20} /></RailIcon>
        <RailIcon><Phone size={20} /></RailIcon>
        <div style={{ flex: 1 }} />
        <div onClick={() => setModo((m) => (m === "claro" ? "escuro" : "claro"))} title="Alternar tema"
          style={{ width: 40, height: 40, borderRadius: 8, display: "flex", alignItems: "center", justifyContent: "center", color: "#aebac1", cursor: "pointer" }}>
          {modo === "claro" ? <Moon size={20} /> : <Sun size={20} />}
        </div>
        <RailIcon><Settings size={20} /></RailIcon>
        <div onClick={sair} title="Sair" style={{ width: 40, height: 40, borderRadius: 8, display: "flex", alignItems: "center", justifyContent: "center", color: "#aebac1", cursor: "pointer" }}>
          <LogOut size={20} />
        </div>
        <div style={{ height: 16 }} />
      </div>

      {/* Lista de conversas */}
      <div style={{ width: 380, borderRight: `1px solid ${C.divider}`, display: "flex", flexDirection: "column", background: C.panel }}>
        <div style={{ background: C.headerBar, padding: "10px 16px", position: "relative" }}>
          <div style={{ fontSize: 12, color: C.textSecondary, marginBottom: 6, fontWeight: 600, letterSpacing: 0.3 }}>ATENDENDO COMO</div>
          <button onClick={() => setSeletorAberto((v) => !v)} style={{ width: "100%", display: "flex", alignItems: "center", gap: 10, background: C.panel, border: `1px solid ${C.divider}`, borderRadius: 8, padding: "8px 12px", cursor: "pointer", color: C.textPrimary }}>
            {advogado ? <Avatar nome={advogado.nome} size={34} /> : <div style={{ width: 34 }} />}
            <div style={{ flex: 1, textAlign: "left" }}>
              <div style={{ fontSize: 14, fontWeight: 600 }}>{advogado ? advogado.nome : "—"}</div>
              <div style={{ fontSize: 12, color: C.textSecondary }}>{advogado ? "+" + advogado.numero : "Nenhum advogado"}</div>
            </div>
            <ChevronDown size={18} color={C.textSecondary} style={{ transform: seletorAberto ? "rotate(180deg)" : "none", transition: "transform .15s" }} />
          </button>
          {seletorAberto && (
            <div style={{ position: "absolute", top: "100%", left: 16, right: 16, background: C.panel, border: `1px solid ${C.divider}`, borderRadius: 8, boxShadow: "0 6px 20px rgba(0,0,0,.25)", zIndex: 20, overflow: "hidden", maxHeight: 320, overflowY: "auto" }}>
              {advogados.map((a) => (
                <button key={a.id} onClick={() => trocarAdvogado(a.id)} style={{ width: "100%", display: "flex", alignItems: "center", gap: 10, padding: "10px 12px", background: a.id === advogadoId ? C.listActive : C.panel, border: "none", cursor: "pointer", textAlign: "left", color: C.textPrimary }}>
                  <Avatar nome={a.nome} size={30} />
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 13, fontWeight: 600 }}>{a.nome}</div>
                    <div style={{ fontSize: 11, color: C.textSecondary }}>+{a.numero}</div>
                  </div>
                </button>
              ))}
            </div>
          )}
        </div>

        <div style={{ padding: "8px 12px", background: C.panel }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8, background: C.searchBg, borderRadius: 8, padding: "6px 12px" }}>
            <Search size={16} color={C.textSecondary} />
            <input value={busca} onChange={(e) => setBusca(e.target.value)} placeholder="Buscar conversa" style={{ border: "none", outline: "none", background: "transparent", fontSize: 14, flex: 1, color: C.textPrimary }} />
          </div>
        </div>

        <div style={{ flex: 1, overflowY: "auto" }}>
          {conversasFiltradas.length === 0 && (
            <div style={{ padding: 24, textAlign: "center", color: C.textSecondary, fontSize: 13 }}>Nenhuma conversa ainda.</div>
          )}
          {conversasFiltradas.map((c) => {
            const nome = c.contato?.nome || ("+" + (c.contato?.numero || ""));
            return (
              <button key={c.id} onClick={() => setConversaId(c.id)} style={{ width: "100%", display: "flex", alignItems: "center", gap: 12, padding: "10px 14px", background: c.id === conversaId ? C.listActive : C.panel, border: "none", borderBottom: `1px solid ${C.divider}`, cursor: "pointer", textAlign: "left", color: C.textPrimary }}>
                <Avatar nome={nome} size={48} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                    <span style={{ fontSize: 15, fontWeight: 500, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{nome}</span>
                    <span style={{ fontSize: 11, color: c.nao_lidas ? C.green : C.textSecondary }}>{horaDe(c.ultima_atividade)}</span>
                  </div>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 2 }}>
                    <span style={{ fontSize: 13, color: C.textSecondary, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", maxWidth: 250 }}>{c.ultima_mensagem || ""}</span>
                    {c.nao_lidas > 0 && <span style={{ background: C.unread, color: "#fff", borderRadius: 12, fontSize: 11, minWidth: 18, height: 18, display: "flex", alignItems: "center", justifyContent: "center", padding: "0 5px" }}>{c.nao_lidas}</span>}
                  </div>
                </div>
              </button>
            );
          })}
        </div>
      </div>

      {/* Conversa */}
      <div style={{ flex: 1, display: "flex", flexDirection: "column", background: C.chatBg }}>
        {!conversa ? (
          <div style={{ flex: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", color: C.textSecondary, gap: 16 }}>
            <div style={{ width: 90, height: 90, borderRadius: "50%", background: C.placeholderCircle, display: "flex", alignItems: "center", justifyContent: "center" }}>
              <MessageSquare size={44} color={C.textSecondary} />
            </div>
            <div style={{ fontSize: 22, color: C.textPrimary, fontWeight: 300 }}>Zorvin</div>
            <div style={{ fontSize: 14, maxWidth: 380, textAlign: "center", lineHeight: 1.5 }}>
              Selecione uma conversa à esquerda para começar a atender{advogado ? <> as conversas de <b>{advogado.nome}</b></> : ""}.
            </div>
          </div>
        ) : (
          <>
            <div style={{ background: C.headerBar, padding: "10px 16px", display: "flex", alignItems: "center", gap: 12, borderBottom: `1px solid ${C.divider}` }}>
              <button onClick={() => setConversaId(null)} style={{ border: "none", background: "transparent", cursor: "pointer", display: "flex" }}>
                <ArrowLeft size={20} color={C.textSecondary} />
              </button>
              <Avatar nome={conversa.contato?.nome || conversa.contato?.numero} size={40} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 15, fontWeight: 600 }}>{conversa.contato?.nome || ("+" + conversa.contato?.numero)}</div>
                <div style={{ fontSize: 12, color: C.textSecondary }}>via {advogado?.nome}</div>
              </div>
              <MoreVertical size={20} color={C.textSecondary} />
            </div>

            <div style={{ flex: 1, overflowY: "auto", padding: "20px 8%", display: "flex", flexDirection: "column", gap: 6 }}>
              {mensagens.map((m) => {
                const saida = m.origem === "advogado";
                return (
                  <div key={m.id} style={{ display: "flex", justifyContent: saida ? "flex-end" : "flex-start" }}>
                    <div style={{ maxWidth: "65%", background: saida ? C.bubbleOut : C.bubbleIn, color: C.textPrimary, borderRadius: 8, padding: m.tipo === "imagem" ? 4 : "6px 9px 8px", boxShadow: "0 1px 0.5px rgba(0,0,0,.15)" }}>
                      {m.tipo === "imagem" && m.midia_url && (
                        <img src={m.midia_url} alt="imagem" style={{ maxWidth: 240, borderRadius: 6, display: "block" }} />
                      )}
                      {m.tipo === "audio" && <BolhaAudio C={C} saida={saida} url={m.midia_url} />}
                      {m.texto && <div style={{ fontSize: 14.2, lineHeight: 1.35, paddingRight: 42, marginTop: m.tipo !== "texto" ? 4 : 0 }}>{m.texto}</div>}
                      <div style={{ fontSize: 11, color: C.textSecondary, textAlign: "right", marginTop: 2, display: "flex", alignItems: "center", justifyContent: "flex-end", gap: 3 }}>
                        {horaDe(m.criado_em)}{saida && <CheckCheck size={15} color="#53bdeb" />}
                      </div>
                    </div>
                  </div>
                );
              })}
              <div ref={fimRef} />
            </div>

            <div style={{ background: C.headerBar, padding: "10px 16px", display: "flex", alignItems: "center", gap: 10 }}>
              <Smile size={24} color={C.textSecondary} />
              <Paperclip size={22} color={C.textSecondary} />
              <input value={rascunho} onChange={(e) => setRascunho(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") enviar(); }} placeholder="Digite uma mensagem" style={{ flex: 1, border: "none", outline: "none", background: C.inputBg, color: C.textPrimary, borderRadius: 8, padding: "10px 14px", fontSize: 14.5 }} />
              {rascunho.trim() ? (
                <button onClick={enviar} style={{ border: "none", background: "transparent", cursor: "pointer", display: "flex" }}><Send size={24} color={C.green} /></button>
              ) : (
                <Mic size={24} color={C.textSecondary} />
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function RailIcon({ children, ativo }) {
  return (
    <div style={{ width: 40, height: 40, borderRadius: 8, display: "flex", alignItems: "center", justifyContent: "center", color: ativo ? "#fff" : "#aebac1", background: ativo ? "rgba(255,255,255,.12)" : "transparent", cursor: "pointer" }}>
      {children}
    </div>
  );
}
