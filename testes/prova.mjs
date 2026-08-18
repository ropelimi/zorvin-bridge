// PROVA DA PONTE — o `index.js` de verdade, contra um Supabase e uma Uazapi
// de mentira que falam o mesmo protocolo.
import { spawn } from "node:child_process";
import { subirFalsoSupabase, subirFalsaUazapi, subirFalsoVantoro } from "./falso-supabase.mjs";

let falhas = 0, feitas = 0;
const ok = (nome, cond, det = "") => {
  feitas++;
  if (cond) console.log(`  ok   ${nome}`);
  else { falhas++; console.log(`  FALHA ${nome}${det ? " — " + det : ""}`); }
};
const espera = (ms) => new Promise((r) => setTimeout(r, ms));

const TELEFONE = { id: "adv-1", nome: "Comercial", numero: "5567900000001",
                   token: "tok-uazapi", servidor: null, ativo: true, departamento_id: 1 };

async function subirTudo(env = {}, { tabelas = {}, vantoro = null, quebrar } = {}) {
  const uaz = await subirFalsaUazapi();
  TELEFONE.servidor = uaz.url;
  const van = vantoro ? await subirFalsoVantoro(vantoro) : null;
  const sb = await subirFalsoSupabase({
    quebrar,
    tabelas: {
      advogados: [{ ...TELEFONE }],
      departamentos: [{ id: 1, nome: "Comercial", slug: "comercial", ordem: 1, ativo: true }],
      usuarios: [], contatos: [], conversas: [], mensagens: [], fila_envio: [],
      permissoes: [], conversa_tags: [], notas: [],
      ...tabelas,
    },
    usuarios: [{ id: "u1", email: "rodrigo@x", jwt: "jwt-bom", user_metadata: { nome: "Rodrigo" } }],
  });
  const porta = 3000 + Math.floor(Math.random() * 900);
  const filho = spawn("node", ["../index.js"], {
    env: { ...process.env, PORT: String(porta),
           SUPABASE_URL: sb.url, SUPABASE_SERVICE_KEY: "chave-de-mentira",
           VANTORO_API_URL: van ? van.url : "", VANTORO_API_TOKEN: van ? "tok-vantoro" : "",
           ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const registro = [];
  filho.stdout.on("data", (d) => registro.push(String(d)));
  filho.stderr.on("data", (d) => registro.push(String(d)));
  // Espera a porta responder.
  for (let i = 0; i < 60; i++) {
    try { await fetch(`http://127.0.0.1:${porta}/ping`); break; } catch (_) { await espera(120); }
  }
  return { sb, uaz, van, porta, registro,
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

// ==================================================================
//  1. O WEBHOOK
// ==================================================================
{
  console.log("\n1. O webhook");
  const t = await subirTudo();
  const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Bom dia, preciso de ajuda", "msg-1")),
  });
  await espera(700);
  ok("responde 200 rápido (a Uazapi não reenvia)", r.status === 200);
  ok("cria o contato", t.sb.dados.contatos.length === 1,
     JSON.stringify(t.sb.dados.contatos));
  ok("cria a conversa", t.sb.dados.conversas.length === 1);
  ok("grava a mensagem", t.sb.dados.mensagens.length === 1,
     JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));
  ok("a mensagem entra como recebida",
     t.sb.dados.mensagens[0]?.origem === "contato", t.sb.dados.mensagens[0]?.origem);

  // A MESMA MENSAGEM DE NOVO não pode virar duas: a Uazapi reenvia quando
  // desconfia que não entregou.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Bom dia, preciso de ajuda", "msg-1")),
  });
  await espera(600);
  ok("a mesma mensagem reenviada não duplica", t.sb.dados.mensagens.length === 1,
     `ficaram ${t.sb.dados.mensagens.length}`);

  await t.parar();
}

// ==================================================================
//  2. QUEM PODE MANDAR MENSAGEM PARA DENTRO DO ESCRITÓRIO?
// ==================================================================
//
// O endereço do webhook não pedia nada. Qualquer um que descobrisse a URL podia
// mandar um POST e a mensagem entrava no banco como se tivesse vindo do
// cliente — aparecia na conversa, contava no Painel, ficava no histórico.
//
// A trava é um segredo, e ela liga em duas etapas de propósito: enquanto
// `WEBHOOK_TOKEN` não existir, tudo passa. Ligar a exigência antes de o
// endereço na Uazapi ter o segredo faria as mensagens dos clientes pararem de
// chegar, em silêncio.
{
  console.log("\n2. Quem pode escrever no webhook");

  // ---- 2a. sem o segredo configurado: nada muda (é a rede de segurança) ----
  {
    const t = await subirTudo();
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Antes de configurar", "a-1")),
    });
    await espera(700);
    ok("sem WEBHOOK_TOKEN, as mensagens continuam entrando",
       t.sb.dados.mensagens.length === 1, `entraram ${t.sb.dados.mensagens.length}`);
    ok("mas a ponte avisa no log que está sem segredo",
       t.registro.join("").includes("SEM segredo"),
       t.registro.join("").slice(-200));
    await t.parar();
  }

  // ---- 2b. com o segredo: forjada de fora não entra ----
  {
    const t = await subirTudo({ WEBHOOK_TOKEN: "segredo-do-escritorio" });
    const r = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Mensagem forjada por um estranho", "forjada-1")),
    });
    await espera(700);
    ok("sem o segredo, o webhook recusa", r.status === 403, `veio ${r.status}`);
    ok("e nada entra no banco", t.sb.dados.mensagens.length === 0,
       JSON.stringify(t.sb.dados.mensagens.map((m) => m.texto)));

    const errado = await fetch(`http://127.0.0.1:${t.porta}/webhook?token=chute`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Chute", "forjada-2")),
    });
    ok("com o segredo errado, recusa também", errado.status === 403, `veio ${errado.status}`);

    // ---- 2c. com o segredo certo, na URL e no cabeçalho ----
    const naUrl = await fetch(`http://127.0.0.1:${t.porta}/webhook?token=segredo-do-escritorio`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(mensagemDaUazapi("Mensagem de verdade", "boa-1")),
    });
    await espera(700);
    ok("com o segredo na URL, entra", naUrl.status === 200 && t.sb.dados.mensagens.length === 1,
       `status ${naUrl.status}, ${t.sb.dados.mensagens.length} mensagens`);

    const noCabecalho = await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-webhook-token": "segredo-do-escritorio" },
      body: JSON.stringify(mensagemDaUazapi("Pelo cabeçalho", "boa-2")),
    });
    await espera(700);
    ok("com o segredo no cabeçalho, também entra",
       noCabecalho.status === 200 && t.sb.dados.mensagens.length === 2,
       `status ${noCabecalho.status}, ${t.sb.dados.mensagens.length} mensagens`);
    await t.parar();
  }
}

// ==================================================================
//  3. A FILA DE ENVIO
// ==================================================================
{
  console.log("\n3. A fila de envio");
  const t = await subirTudo();
  t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente Teste" });
  t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
  t.sb.dados.fila_envio.push({
    id: 1, conversa_id: 1, tipo: "texto", texto: "Olá!", status: "pendente",
    tentativas: 0, criado_em: new Date().toISOString(),
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(1200);
  ok("manda a mensagem para a Uazapi", t.uaz.recebidas.length === 1,
     JSON.stringify(t.uaz.recebidas));
  ok("marca o item da fila como enviada",
     t.sb.dados.fila_envio[0]?.status === "enviada", t.sb.dados.fila_envio[0]?.status);

  // O ITEM VELHO QUE ESTÁ SENDO ENVIADO AGORA.
  //
  // A recuperação de itens travados olhava `criado_em` — quando o item foi
  // CRIADO —, e não quando ele foi reivindicado. Um item que ficou 6 minutos na
  // fila e acabou de ser pego para envio se encaixa nessa regra: ele volta para
  // "pendente" no meio do envio, e o cliente recebe a mesma mensagem duas vezes.
  t.uaz.recebidas.length = 0;
  t.sb.dados.fila_envio.push({
    id: 2, conversa_id: 1, tipo: "texto", texto: "Segunda", status: "enviando",
    tentativas: 1, criado_em: new Date(Date.now() - 10 * 60 * 1000).toISOString(),
    enviando_em: new Date().toISOString(),   // reivindicado AGORA
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(1200);
  ok("item reivindicado agora NÃO é reenviado, mesmo sendo antigo",
     t.uaz.recebidas.length === 0,
     `a Uazapi recebeu ${t.uaz.recebidas.length} — o cliente veria a mesma mensagem duas vezes`);

  // O item DE VERDADE travado (reivindicado há muito) tem de voltar.
  t.sb.dados.fila_envio.push({
    id: 3, conversa_id: 1, tipo: "texto", texto: "Terceira", status: "enviando",
    tentativas: 1, criado_em: new Date(Date.now() - 30 * 60 * 1000).toISOString(),
    enviando_em: new Date(Date.now() - 30 * 60 * 1000).toISOString(),
  });
  await fetch(`http://127.0.0.1:${t.porta}/ping`);
  await espera(1400);
  ok("item preso de verdade volta para a fila e sai",
     t.uaz.recebidas.some((x) => JSON.stringify(x.corpo).includes("Terceira")),
     JSON.stringify(t.uaz.recebidas));

  await t.parar();
}

// ==================================================================
//  4. AS ROTAS PROTEGIDAS
// ==================================================================
{
  console.log("\n4. As rotas protegidas");
  const t = await subirTudo();
  const semLogin = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`);
  ok("sem login, /permissoes/atendentes recusa", semLogin.status === 401, `veio ${semLogin.status}`);
  const jwtRuim = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
    { headers: { Authorization: "Bearer jwt-inventado" } });
  ok("com sessão inválida, recusa", jwtRuim.status === 401, `veio ${jwtRuim.status}`);
  const semToken = await fetch(`http://127.0.0.1:${t.porta}/importar-historico?advogado=1&contato=2`);
  ok("importar histórico sem senha recusa", semToken.status === 403, `veio ${semToken.status}`);
  await t.parar();
}

// ==================================================================
//  5. A SESSÃO NÃO É CONFERIDA A CADA CHAMADA
// ==================================================================
// `auth.getUser` é uma ida à API do Supabase, e ela acontecia em TODA chamada
// do painel — abrir a ficha do cliente são duas, digitar na busca é mais uma a
// cada pausa. A mesma sessão, conferida cinco vezes em dez segundos, dá cinco
// vezes a mesma resposta.
{
  console.log("\n5. A sessão conferida uma vez");
  const t = await subirTudo();
  const conta = () => t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
  const antes = conta();
  for (let i = 0; i < 6; i++) {
    await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
      { headers: { Authorization: "Bearer jwt-bom" } });
  }
  const idas = conta() - antes;
  console.log(`     6 chamadas do painel → ${idas} ida(s) à autenticação`);
  ok("seis chamadas seguidas conferem a sessão uma vez só", idas === 1, `foram ${idas}`);

  // Sessão ruim não pode ser lembrada: quem entra de novo tem de passar na hora.
  const ruim = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
    { headers: { Authorization: "Bearer jwt-podre" } });
  t.sb.contas.push({ id: "u9", email: "novo@x", jwt: "jwt-podre", user_metadata: {} });
  const agoraVale = await fetch(`http://127.0.0.1:${t.porta}/permissoes/atendentes`,
    { headers: { Authorization: "Bearer jwt-podre" } });
  ok("sessão recusada não fica lembrada como recusada",
     ruim.status === 401 && agoraVale.status !== 401,
     `antes ${ruim.status}, depois ${agoraVale.status}`);
  await t.parar();
}

// ==================================================================
//  6. A CÓPIA DA PERMISSÃO DO VANTORO
// ==================================================================
//
// Quem pode ver o quê é decidido no Vantoro. A ponte copia essa decisão para
// dentro do Zorvin de três em três minutos, para quem já está com o painel
// aberto passar a enxergar sem sair e entrar de novo.
//
// Esta é a rotina mais delicada do arquivo: ela APAGA a permissão de alguém e
// grava de novo. Tudo o que acontecer entre uma coisa e outra, a pessoa passa
// sem ver conversa nenhuma.
{
  console.log("\n6. A cópia da permissão do Vantoro");

  // 1103 pessoas espelhadas: as três primeiras logo no começo, e a quarta lá
  // atrás, depois da milésima linha. O PostgREST corta em mil e não avisa.
  const espelhados = [
    { id: "ana",   login: "ana",   email: "ana@x",   nome: "Ana",   ativo: true },
    { id: "bruno", login: "bruno", email: "bruno@x", nome: "Bruno", ativo: true },
    { id: "carla", login: "carla", email: "carla@x", nome: "Carla", ativo: true },
  ];
  // Mais quarenta pessoas de verdade, para a rodada ter tamanho: é com elas que
  // dá para ver se o custo cresce por pessoa ou não.
  const turma = [];
  for (let i = 0; i < 40; i++) turma.push(`turma${i}`);
  for (const t of turma) espelhados.push({ id: t, login: t, email: `${t}@x`, ativo: true });
  for (let i = 0; i < 1100; i++) {
    espelhados.push({ id: `enche-${i}`, login: `enche${i}`, email: `enche${i}@x`, ativo: true });
  }
  espelhados.push({ id: "davi", login: "davi", email: "davi@x", nome: "Davi", ativo: true });

  const doVantoro = [
    // Departamento — o corte normal.
    { login: "ana", email: "ana@x", nome: "Ana", admin: false,
      zorvin_definido: true, zorvin: ["comercial"] },
    // Só um telefone, escrito como gente escreve: com parênteses e traço.
    { login: "bruno", email: "bruno@x", nome: "Bruno", admin: false,
      zorvin_definido: true, zorvin_so_telefones: true,
      zorvin_telefones: ["(67) 90000-0001"] },
    // Ninguém definiu ainda: não pode virar "não vê nada".
    { login: "carla", email: "carla@x", nome: "Carla", admin: false,
      zorvin_definido: false },
    // Igual à Ana — mas espelhada depois da milésima linha.
    { login: "davi", email: "davi@x", nome: "Davi", admin: false,
      zorvin_definido: true, zorvin: ["comercial"] },
    ...turma.map((t) => ({ login: t, email: `${t}@x`, nome: t, admin: false,
                           zorvin_definido: true, zorvin: ["comercial"] })),
  ];

  // ---- 6a. a rodada normal ----
  {
    const t = await subirTudo({}, {
      vantoro: { usuarios: doVantoro },
      tabelas: {
        usuarios: espelhados.map((u) => ({ ...u })),
        // A Ana JÁ TEM a permissão certa. A rodada não deveria mexer em nada.
        // A Carla também já tem — e ninguém definiu nada para ela no Vantoro,
        // então a rodada não pode tirar o que ela tem.
        permissoes: [
          { id: 1, usuario_id: "ana", departamento_id: 1 },
          { id: 2, usuario_id: "carla", departamento_id: 1 },
        ],
      },
    });
    const chegou = await esperarARodada(t);
    ok("a rodada de permissões acontece sozinha", chegou);

    const de = (quem) => t.sb.dados.permissoes.filter((p) => p.usuario_id === quem);

    ok("quem tem departamento marcado recebe o departamento",
       de("ana").length === 1 && de("ana")[0].departamento_id === 1,
       JSON.stringify(de("ana")));

    ok("telefone escrito com parênteses e traço encontra o número",
       de("bruno").length === 1 && de("bruno")[0].telefone_id === TELEFONE.id,
       JSON.stringify(de("bruno")) + " — log: "
         + (t.registro.join("").match(/não tem os telefones.*/) || [""])[0]);

    ok("quem ninguém definiu no Vantoro não perde o que já tinha",
       de("carla").length === 1,
       `a Carla ficou com ${de("carla").length} — o Vantoro não diz nada sobre ela, `
       + "e 'ninguém definiu' não é a mesma coisa que 'não pode ver nada'");

    // O TETO DE MIL LINHAS.
    ok("a pessoa espelhada depois da milésima linha também recebe permissão",
       de("davi").length === 1 && de("davi")[0].departamento_id === 1,
       `o Davi ficou com ${de("davi").length} linha(s) — se ficou com zero, `
       + "a leitura de `usuarios` parou em mil e ele nunca é encontrado");

    // A JANELA CEGA.
    //
    // A permissão da Ana já estava certa antes da rodada. Apagá-la e gravar a
    // mesma coisa de volta não muda nada no fim — mas entre o apagar e o
    // gravar ela fica sem permissão nenhuma, e quem estiver carregando as
    // conversas nesse instante não vê nada. Três em três minutos, para cada
    // pessoa do escritório.
    const escritas = t.sb.chamadas.filter(
      (c) => c.caminho === "/rest/v1/permissoes" && c.metodo !== "GET"
             && (String(c.busca || "") + JSON.stringify(c.corpo || "")).includes("ana"));
    ok("permissão que não mudou não é reescrita",
       escritas.length === 0,
       `houve ${escritas.length} escrita(s) na permissão da Ana sem nada ter mudado: `
       + escritas.map((c) => c.metodo).join(", "));

    // O CUSTO DA RODADA NÃO PODE CRESCER POR PESSOA.
    //
    // A lista de telefones e a de departamentos são as MESMAS para todo mundo,
    // e a rotina relia as duas para cada pessoa: quarenta e três pessoas, mais
    // de quarenta consultas idênticas, de três em três minutos, para sempre.
    const releituras = t.sb.chamadas.filter(
      (c) => c.metodo === "GET"
             && (c.caminho === "/rest/v1/advogados" || c.caminho === "/rest/v1/departamentos")).length;
    console.log(`     43 pessoas na rodada → ${releituras} leitura(s) de telefones/departamentos`);
    ok("a rodada não relê telefones e departamentos uma vez por pessoa",
       releituras <= 10,
       `foram ${releituras} para 43 pessoas — deveria ser um punhado, não uma por pessoa`);

    await t.parar();
  }

  // ---- 6b. quando a gravação falha no meio ----
  //
  // A rotina apaga e depois grava. Se a gravação falhar — a rede caiu, o banco
  // recusou —, o apagar já aconteceu: a pessoa fica cega até a próxima rodada
  // dar certo. E se o defeito for permanente (uma constraint, uma coluna que
  // sumiu), ela fica cega para sempre, com a tela do Vantoro mostrando a
  // permissão marcada, certinha.
  {
    const t = await subirTudo({}, {
      vantoro: { usuarios: [
        { login: "elias", email: "elias@x", nome: "Elias", admin: false,
          zorvin_definido: true, zorvin: ["comercial", "financeiro"] },
      ] },
      tabelas: {
        usuarios: [{ id: "elias", login: "elias", email: "elias@x", ativo: true }],
        departamentos: [
          { id: 1, nome: "Comercial", slug: "comercial", ordem: 1, ativo: true },
          { id: 2, nome: "Financeiro", slug: "financeiro", ordem: 2, ativo: true },
        ],
        permissoes: [{ id: 1, usuario_id: "elias", departamento_id: 1 }],
      },
      quebrar: (metodo, tabela) =>
        (metodo === "POST" && tabela === "permissoes") ? "a rede caiu na hora de gravar" : null,
    });
    await esperarARodada(t);

    const dele = t.sb.dados.permissoes.filter((p) => p.usuario_id === "elias");
    ok("gravação que falha não deixa a pessoa sem ver nada",
       dele.length >= 1,
       `o Elias ficou com ${dele.length} permissão(ões) — ele TINHA o comercial antes, `
       + "e a única coisa que falhou foi acrescentar o financeiro");
    ok("e o que ele já tinha continua valendo",
       dele.some((p) => p.departamento_id === 1),
       JSON.stringify(dele));

    await t.parar();
  }
}

console.log(`\n${feitas - falhas}/${feitas} conferências passaram`);
process.exit(falhas ? 1 : 0);
