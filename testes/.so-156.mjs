// PROVA DA PONTE — o `index.js` de verdade, contra um Supabase e uma Uazapi
// de mentira que falam o mesmo protocolo.
import { spawn } from "node:child_process";
import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import { subirFalsoSupabase, subirFalsaUazapi, subirFalsoVantoro } from "./falso-supabase.mjs";

let falhas = 0, feitas = 0;
const ok = (nome, cond, det = "") => {
  feitas++;
  if (cond) console.log(`  ok   ${nome}`);
  else { falhas++; console.log(`  FALHA ${nome}${det ? " — " + det : ""}`); }
};
const espera = (ms) => new Promise((r) => setTimeout(r, ms));

// UMA PORTA LIVRE DE VERDADE, pedida ao sistema.
//
// Antes isto era `3000 + Math.floor(Math.random() * 900)`, e sorteio não é
// escolha: duas provas podiam tirar a mesma porta, e aí a segunda ponte não
// subia — mas `subirTudo` devolvia a porta assim mesmo, e a prova falhava lá
// adiante, longe da causa.
//
// Pior: 3659 está na LISTA DE PORTAS BLOQUEADAS da especificação do `fetch`,
// que o Node aplica. Caindo nela, o `fetch` recusa com "bad port" antes de
// tentar conectar. Como o sorteio mudava a cada rodada, o estouro aparecia num
// bloco diferente a cada vez e passava por instabilidade da máquina.
//
// Pedir a porta ao sistema (`listen(0)`) resolve os dois: ele só oferece porta
// livre, e nunca uma da lista bloqueada.
async function portaLivre() {
  return new Promise((resolve, reject) => {
    const s = http.createServer();
    s.on("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
}

const TELEFONE = { id: "adv-1", nome: "Comercial", numero: "5567900000001",
                   token: "tok-uazapi", servidor: null, ativo: true, departamento_id: 1 };

async function subirTudo(env = {}, { tabelas = {}, vantoro = null, quebrar, semColunas, semTabelas, uazapi = {}, contas = null, bilhetesQueFalham = 0, authNoChao = false, jwksAssimetrico = false, rpcs = {}, deposito = {}, aoGravar } = {}) {
  const uaz = await subirFalsaUazapi(uazapi);
  TELEFONE.servidor = uaz.url;
  const van = vantoro ? await subirFalsoVantoro(vantoro) : null;
  const sb = await subirFalsoSupabase({
    quebrar, semColunas, semTabelas, bilhetesQueFalham, rpcs, deposito, aoGravar,
    tabelas: {
      advogados: [{ ...TELEFONE }],
      departamentos: [{ id: 1, nome: "Comercial", slug: "comercial", ordem: 1, ativo: true }],
      usuarios: [], contatos: [], conversas: [], mensagens: [], fila_envio: [],
      permissoes: [], conversa_tags: [], notas: [], eventos_recebidos: [],
      ...tabelas,
    },
    // As contas do Auth. Separadas da tabela `usuarios` de propósito: são duas
    // coisas diferentes no Supabase de verdade, e a entrada mexe nas duas.
    usuarios: contas || [{ id: "u1", email: "rodrigo@x", jwt: "jwt-bom", user_metadata: { nome: "Rodrigo" } }],
    authNoChao, jwksAssimetrico,
  });
  const porta = await portaLivre();
  // O caminho sai DESTE arquivo, e não do diretório de onde se chamou. Com
  // "../index.js" solto, `npm test` a partir da raiz procurava a ponte um nível
  // acima do projeto e nada subia — o teste só funcionava quando rodado de
  // dentro de `testes/`, o que ninguém adivinha.
  const PONTE = new URL("../index.js", import.meta.url).pathname;
  const filho = spawn("node", [PONTE], {
    env: { ...process.env, PORT: String(porta),
           SUPABASE_URL: sb.url, SUPABASE_SERVICE_KEY: "chave-de-mentira",
           VANTORO_API_URL: van ? van.url : "", VANTORO_API_TOKEN: van ? "tok-vantoro" : "",
           // O RESGATE DEPOIS DE SUBIR fica para daqui a uma hora, e não para
           // daqui a um minuto: uma prova longa veria, no meio dela, a ponte
           // indo atrás de um anexo vazio que a própria prova plantou — e a
           // conta de pedidos dela mudaria de assunto. A seção 72, que é a
           // dele, encurta.
           RESGATE_AO_SUBIR_MS: "3600000",
           // O RESGATE DO HISTÓRICO, pelo mesmo motivo: ele lê a caixa de
           // entrada e `zorvin_sementes` uma vez, e no meio de outra prova
           // essas leituras mudariam a conta de pedidos dela. A seção 77, que
           // é a dele, encurta.
           RESGATE_DO_HISTORICO_MS: "3600000",
           // A TRANSCRIÇÃO AUTOMÁTICA, pelo mesmo motivo: numa prova que liga a
           // chave do Groq para o CLIQUE (seção 56), a rodada pegaria sozinha
           // os áudios da cena e a conta de idas ao Groq mudaria de assunto. A
           // seção 84, que é a dela, encurta.
           TRANSCRICAO_PRIMEIRA_MS: "3600000",
           TRANSCRICAO_INTERVALO_MS: "3600000",
           // A IA QUE MOVE O FUNIL, pelo mesmo motivo: numa prova que liga a
           // chave da Anthropic para o copiloto, a rodada perguntaria ao banco
           // quem ler e mudaria a conta de pedidos dela. A seção 92, que é a
           // dela, encurta.
           FUNIL_IA_PRIMEIRA_MS: "3600000",
           FUNIL_IA_INTERVALO_MS: "3600000",
           // O ACOMPANHAMENTO POR ETAPA, pelo mesmo motivo: a rodada chama uma
           // função do banco, e no meio de outra prova esse pedido mudaria a
           // conta dela. A seção 94, que é a dela, encurta.
           ACOMPANHAMENTO_PRIMEIRA_MS: "3600000",
           ACOMPANHAMENTO_INTERVALO_MS: "3600000",
           // O COPILOTO QUE APRENDE, pelo mesmo motivo: numa prova que liga a
           // chave da Anthropic para o copiloto, a rodada perguntaria ao banco
           // quem tem o que aprender e mudaria a conta de pedidos dela. A
           // seção 102, que é a dela, encurta.
           COPILOTO_APRENDER_PRIMEIRA_MS: "3600000",
           COPILOTO_APRENDER_INTERVALO_MS: "3600000",
           // O QUAZAR À NOITE, pelo mesmo motivo: a rodada apaga as linhas
           // presas e pergunta ao banco quem espera, e isso mudaria a conta de
           // pedidos de outra prova. A seção 111, que é a dela, encurta.
           QUAZAR_NOITE_PRIMEIRA_MS: "3600000",
           QUAZAR_NOITE_INTERVALO_MS: "3600000",
           // O QUAZAR DE DIA, pelo mesmo motivo. A seção 123 encurta.
           QUAZAR_DIA_PRIMEIRA_MS: "3600000",
           QUAZAR_DIA_INTERVALO_MS: "3600000",
           // A FAXINA DO QUAZAR, pelo mesmo motivo: ela chama funções do banco
           // e grava "Já tratei". A seção 133 encurta.
           FAXINA_PRIMEIRA_MS: "3600000",
           FAXINA_INTERVALO_MS: "3600000",
           // QUEM PEDE ATENÇÃO (066), pelo mesmo motivo: a rodada pergunta ao
           // Vantoro e grava a lista no banco. A seção 136 encurta.
           ATENCAO_PRIMEIRA_MS: "3600000",
           ATENCAO_INTERVALO_MS: "3600000",
           // AS ETIQUETAS DO VANTORO (075), pelo mesmo motivo. A seção 156 encurta.
           ETIQUETAS_PRIMEIRA_MS: "3600000",
           ETIQUETAS_INTERVALO_MS: "3600000",
           // O AVISO À EQUIPE DE QUEM PEDE ATENÇÃO (068), pelo mesmo motivo: a
           // rodada chama uma função do banco. A seção 139 encurta.
           ATENCAO_AVISOS_PRIMEIRA_MS: "3600000",
           ATENCAO_AVISOS_INTERVALO_MS: "3600000",
           // O QUAZAR QUE RESPONDE QUEM ESPERA (069), pelo mesmo motivo: a rodada
           // chama duas funções do banco e põe mensagens na fila. A seção 141
           // encurta.
           QUAZAR_RESPONDE_PRIMEIRA_MS: "3600000",
           QUAZAR_RESPONDE_INTERVALO_MS: "3600000",
           // A IDENTIFICAÇÃO PELO CPF EM SEGUNDO PLANO (26/11): a rodada lê as
           // mensagens de cliente e pergunta ao Vantoro. A seção 154 encurta.
           IDENTIFICAR_PRIMEIRA_MS: "3600000",
           IDENTIFICAR_INTERVALO_MS: "3600000",
           ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const registro = [];
  filho.stdout.on("data", (d) => registro.push(String(d)));
  filho.stderr.on("data", (d) => registro.push(String(d)));
  // Espera a porta responder — E RECLAMA SE NUNCA RESPONDER.
  //
  // Antes o laço desistia calado e `subirTudo` devolvia a porta assim mesmo. A
  // ponte que não subiu só era percebida na primeira conferência que a usasse,
  // com uma mensagem que não menciona a ponte — e o que ela mostrava era o
  // ASSUNTO daquela conferência, não a causa. Ficar sem subir é falha da
  // bancada, e falha de bancada tem de dizer o próprio nome.
  let subiu = false;
  for (let i = 0; i < 60; i++) {
    try { await fetch(`http://127.0.0.1:${porta}/ping`); subiu = true; break; }
    catch (_) { await espera(120); }
  }
  if (!subiu) {
    filho.kill(); await sb.parar(); await uaz.parar(); if (van) await van.parar();
    throw new Error(`a ponte não subiu na porta ${porta} em 7s. Log dela:\n`
                    + registro.join("").slice(-2000));
  }
  // `filho` VAI JUNTO, e não é detalhe de encanamento: o desligamento com calma
  // só se prova mandando o sinal de verdade (SIGTERM) e esperando o processo
  // sair. Sem o processo em mãos, a única forma seria chamar uma função
  // exportada só para o teste — que provaria a função, e não o sistema.
  return { sb, uaz, van, porta, registro, filho,
           /** Espera o processo sair e devolve o código. `null` se demorar. */
           esperarSair: (ms = 30000) => new Promise((resolve) => {
             if (filho.exitCode !== null) return resolve(filho.exitCode);
             const relogio = setTimeout(() => resolve(null), ms);
             filho.on('exit', (codigo) => { clearTimeout(relogio); resolve(codigo ?? 0); });
           }),
           parar: async () => {
             filho.kill(); await sb.parar(); await uaz.parar();
             if (van) await van.parar();
           } };
}

// A rodada de sincronização sai 20 segundos depois de a ponte subir, e daí em
// diante a cada 3 minutos. Esperar por ela é o preço de exercitar a rotina de
// verdade, pela porta por onde ela roda em produção — em vez de chamar uma
// função exportada só para o teste, que provaria a função e não o sistema.
async function esperarARodada(t) {
  for (let i = 0; i < 120; i++) {
    await espera(500);
    if (t.van && t.van.recebidas.some((c) => c.caminho === "/usuarios")) { await espera(1500); return true; }
  }
  return false;
}

/** Uma mensagem recebida, no formato que a Uazapi manda. */
const mensagemDaUazapi = (texto, id) => ({
  EventType: "messages",
  owner: TELEFONE.numero,
  message: {
    id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
    sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
    messageType: "conversation", text: texto, content: texto,
    messageTimestamp: Date.now(), wasSentByApi: false,
    senderName: "Cliente Teste",
  },
});
// ============================================================
//  156. AS ETIQUETAS QUE VÊM DO VANTORO — a rodada da ponte e a rota (27/11)
// ============================================================
{
  console.log("\n156. As etiquetas que vêm do Vantoro — a rodada da ponte e a rota");
  const esperaAte = async (f, ms = 6000) => { const fim = Date.now() + ms; while (!f() && Date.now() < fim) await espera(60); return f(); };
  const LISTA = [
    { id: 901, blindagem: "parcial", subsidios: ["SUBSÍDIO EMENDA"], telefones: ["71988881111"] },
    { id: 902, blindagem: null, subsidios: ["SUBSÍDIO CCR"], telefones: ["21977776666"] },
  ];
  function banco({ marca = null, semFuncao = false } = {}) {
    const trocas = [];
    const rpcs = {
      zorvin_etiquetas_do_vantoro: (json, dados) => {
        if (semFuncao) return { status: 404, corpo: { code: "PGRST202", message: "Could not find the function public.zorvin_etiquetas_do_vantoro" } };
        trocas.push(json);
        dados.zorvin_etiquetas_marca = [{ id: true, trocada_em: new Date().toISOString() }];
        return { corpo: { trocada: true, antes: 0, clientes: 2, conversas: 3, postas: 3, tiradas: 1, etiquetas_criadas: 1,
                          etiquetas_que_sumiram: 0, por_etiqueta: { "SUBSÍDIO EMENDA": 2, "Blindagem parcial": 1 } } };
      },
    };
    return { rpcs, trocas, tabelas: { zorvin_etiquetas_marca: marca ? [{ id: true, trocada_em: marca }] : [] } };
  }
  const rapido = { ETIQUETAS_PRIMEIRA_MS: "200", ETIQUETAS_INTERVALO_MS: String(30 * 60 * 1000) };
  const pedidos = (t) => t.van.recebidas.filter((r) => r.caminho === "/clientes/etiquetas");

  // ---- 156a. traz e troca ----
  {
    const b = banco();
    const t = await subirTudo(rapido, { tabelas: b.tabelas, rpcs: b.rpcs, vantoro: { etiquetas: LISTA } });
    await esperaAte(() => b.trocas.length >= 1);
    ok("156a a ponte pergunta a lista ao Vantoro, com o token", pedidos(t).length === 1
       && pedidos(t)[0].autorizacao === "Bearer tok-vantoro", JSON.stringify(pedidos(t)));
    ok("e troca as etiquetas com a lista como veio", b.trocas.length === 1
       && JSON.stringify(b.trocas[0].p_clientes) === JSON.stringify(LISTA), JSON.stringify(b.trocas));
    await esperaAte(() => /etiquetas do Vantoro: 2 cliente/.test(t.registro.join("")), 2000);
    ok("o log diz os números e as etiquetas", /2 cliente\(s\) em 3 conversa\(s\); 3 posta\(s\), 1 tirada\(s\), 1 etiqueta\(s\) nova\(s\), 0 que sumiram \(Blindagem parcial: 1, SUBSÍDIO EMENDA: 2\)/
       .test(t.registro.join("")), t.registro.join("").slice(-500));
    ok("e nenhum telefone vai para o log", !/71988881111|21977776666/.test(t.registro.join("")));
    await t.parar();
  }
  // ---- 156b. a lista de há pouco: não pergunta ----
  {
    const b = banco({ marca: new Date(Date.now() - 5 * 60e3).toISOString() });
    const t = await subirTudo(rapido, { tabelas: b.tabelas, rpcs: b.rpcs, vantoro: { etiquetas: LISTA } });
    await espera(1200);
    ok("156b com a lista de 5 minutos, a ponte não pergunta", pedidos(t).length === 0 && b.trocas.length === 0, JSON.stringify(pedidos(t)));
    await t.parar();
  }
  // ---- 156c. o Vantoro de antes, e a lista sem formato ----
  {
    const b = banco();
    const t = await subirTudo(rapido, { tabelas: b.tabelas, rpcs: b.rpcs, vantoro: {} });
    await esperaAte(() => /etiquetas do Vantoro: o Vantoro ainda não tem a lista/.test(t.registro.join("")), 3000);
    ok("156c o Vantoro de antes (404) é dito, e nada é trocado", /\/clientes\/etiquetas respondeu 404/.test(t.registro.join("")) && b.trocas.length === 0,
       t.registro.join("").slice(-400));
    await t.parar();
    const b2 = banco();
    const t2 = await subirTudo(rapido, { tabelas: b2.tabelas, rpcs: b2.rpcs, vantoro: { etiquetas: () => ({ status: 200, corpo: { ok: true } }) } });
    await esperaAte(() => /resposta sem a lista/.test(t2.registro.join("")), 3000);
    ok("e a resposta sem a lista não troca nada", /resposta sem a lista/.test(t2.registro.join("")) && b2.trocas.length === 0);
    await t2.parar();
  }
  // ---- 156d. sem o 075 ----
  {
    const b = banco({ semFuncao: true });
    const t = await subirTudo(rapido, { tabelas: b.tabelas, rpcs: b.rpcs, vantoro: { etiquetas: LISTA } });
    await esperaAte(() => /zorvin_etiquetas_do_vantoro" não existe/.test(t.registro.join("")), 3000);
    ok("156d sem a função, diz qual script falta", /075-as-etiquetas-do-vantoro\.sql/.test(t.registro.join("")), t.registro.join("").slice(-400));
    await t.parar();
    const t2 = await subirTudo(rapido, { tabelas: {}, semTabelas: ["zorvin_etiquetas_marca"], vantoro: { etiquetas: LISTA } });
    await esperaAte(() => /zorvin_etiquetas_marca" não existe/.test(t2.registro.join("")), 3000);
    ok("e sem a tabela também, sem perguntar ao Vantoro", /zorvin_etiquetas_marca" não existe/.test(t2.registro.join("")) && pedidos(t2).length === 0,
       t2.registro.join("").slice(-400));
    await t2.parar();
  }
  // ---- 156e. a rota recusa a etiqueta automática ----
  {
    const t = await subirTudo({}, { tabelas: {
      advogados: [{ ...TELEFONE }],
      contatos: [{ id: 700, numero: "5511999998888", nome: "Cliente" }],
      conversas: [{ id: 701, advogado_id: "adv-1", contato_id: 700 }],
      tags: [{ id: 9, nome: "Urgente", automatica: null }, { id: 10, nome: "Blindagem parcial", automatica: "blindagem:parcial" }],
      conversa_tags: [],
    } });
    const etiquetar = (corpo) => fetch(`http://127.0.0.1:${t.porta}/etiqueta/contato`, { method: "POST",
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" }, body: JSON.stringify(corpo) })
      .then(async (x) => ({ status: x.status, corpo: await x.json().catch(() => null) }));
    const r1 = await etiquetar({ contato_id: 700, tag_id: 10 });
    ok("156e pôr a automática pela rota é recusado (409), e nada entra", r1.status === 409 && /vem do Vantoro/.test(String(r1.corpo && r1.corpo.erro))
       && t.sb.dados.conversa_tags.length === 0, JSON.stringify(r1));
    const r2 = await etiquetar({ contato_id: 700, tag_id: 10, aplicar: false });
    ok("e tirar também", r2.status === 409, JSON.stringify(r2));
    const r3 = await etiquetar({ contato_id: 700, tag_id: 9 });
    ok("a manual continua", r3.status === 200 && t.sb.dados.conversa_tags.length === 1, JSON.stringify(r3));
    await t.parar();
  }
}

console.log(`\n${feitas - falhas}/${feitas} conferências passaram`);
process.exit(falhas ? 1 : 0);
