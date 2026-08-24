// PROVA DA PONTE — o `index.js` de verdade, contra um Supabase e uma Uazapi
// de mentira que falam o mesmo protocolo.
import { spawn } from "node:child_process";
import http from "node:http";
import crypto from "node:crypto";
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

async function subirTudo(env = {}, { tabelas = {}, vantoro = null, quebrar, uazapi = {}, contas = null, bilhetesQueFalham = 0, authNoChao = false, jwksAssimetrico = false } = {}) {
  const uaz = await subirFalsaUazapi(uazapi);
  TELEFONE.servidor = uaz.url;
  const van = vantoro ? await subirFalsoVantoro(vantoro) : null;
  const sb = await subirFalsoSupabase({
    quebrar, bilhetesQueFalham,
    tabelas: {
      advogados: [{ ...TELEFONE }],
      departamentos: [{ id: 1, nome: "Comercial", slug: "comercial", ordem: 1, ativo: true }],
      usuarios: [], contatos: [], conversas: [], mensagens: [], fila_envio: [],
      permissoes: [], conversa_tags: [], notas: [],
      ...tabelas,
    },
    // As contas do Auth. Separadas da tabela `usuarios` de propósito: são duas
    // coisas diferentes no Supabase de verdade, e a entrada mexe nas duas.
    usuarios: contas || [{ id: "u1", email: "rodrigo@x", jwt: "jwt-bom", user_metadata: { nome: "Rodrigo" } }],
    authNoChao, jwksAssimetrico,
  });
  const porta = 3000 + Math.floor(Math.random() * 900);
  // O caminho sai DESTE arquivo, e não do diretório de onde se chamou. Com
  // "../index.js" solto, `npm test` a partir da raiz procurava a ponte um nível
  // acima do projeto e nada subia — o teste só funcionava quando rodado de
  // dentro de `testes/`, o que ninguém adivinha.
  const PONTE = new URL("../index.js", import.meta.url).pathname;
  const filho = spawn("node", [PONTE], {
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

    // ---- O QUE O LOG CONTA DA RODADA ----
    //
    // Ele dizia `Permissões: reaplicadas para 44 usuário(s).` — e o número
    // contava quem a rotina VISITOU, não quem teve permissão mexida. Como ela
    // foi consertada justamente para não escrever quando nada mudou, a frase
    // anunciava um trabalho que na maioria das rodadas não acontecia.
    const registro = t.registro.join("");
    ok("o log não fala mais em 'reaplicadas'",
       !/reaplicad/i.test(registro),
       (registro.match(/.*reaplicad.*/) || [""])[0]);

    const linha = (registro.match(/Permissões: mudei.*/) || [""])[0];
    ok("mas conta que mudou alguma coisa, porque aqui mudou mesmo", !!linha,
       "não saiu linha nenhuma");
    // NOMEAR É O PONTO. "mudei 42" não responde à pergunta que quem administra
    // faz depois: "a fulana parou de ver o departamento, quando foi isso?".
    ok("dizendo de QUEM", /\bbruno\b/.test(linha), `dizia: "${linha}"`);
    ok("e quanto entrou e quanto saiu", /bruno \(\+1\)/.test(linha), `dizia: "${linha}"`);
    // A Ana já estava certa. Nomeá-la seria dizer que houve escrita onde não
    // houve — o mesmo defeito da frase velha, só que com nome próprio.
    // O `!!linha` não é redundância: sem ele, esta conferência passa de graça
    // quando não sai linha nenhuma — uma frase vazia de fato não nomeia a Ana.
    // Foi o que aconteceu ao rodar contra o código velho: a única das novas que
    // ficou verde, e pelo motivo errado.
    ok("e sem nomear quem não mudou", !!linha && !/\bana\b/.test(linha),
       `dizia: "${linha}"`);
    // Quarenta e duas pessoas mudaram de uma vez, que é o que acontece na
    // primeira rodada depois de uma implantação. A linha não pode virar um
    // parágrafo.
    ok("com teto de nomes, para a linha não virar parágrafo",
       /e mais \d+/.test(linha) && linha.length < 300,
       `tinha ${linha.length} caracteres: "${linha}"`);
    ok("e ainda dizendo quantas foram conferidas", /de \d+ conferido/.test(linha),
       `dizia: "${linha}"`);

    await t.parar();
  }

  // ---- 6c. a rodada em que nada mudou ----
  //
  // ESTE É O CASO DE QUASE TODA RODADA, e o motivo de a mudança existir. Ela
  // sai de três em três minutos: quase quinhentas vezes por dia. Uma linha
  // dizendo "reaplicadas" em cada uma delas enterra o que de fato aconteceu —
  // uma linha caída, um webhook recusado — debaixo de centenas de linhas
  // iguais que não noticiam nada.
  {
    const t = await subirTudo({}, {
      vantoro: { usuarios: [
        { login: "ana", email: "ana@x", nome: "Ana", admin: false,
          zorvin_definido: true, zorvin: ["comercial"] },
      ] },
      tabelas: {
        usuarios: [{ id: "ana", login: "ana", email: "ana@x", ativo: true }],
        // Já está exatamente como o Vantoro manda. Não há o que escrever.
        permissoes: [{ id: 1, usuario_id: "ana", departamento_id: 1 }],
      },
    });
    ok("a rodada aconteceu", await esperarARodada(t));

    // A conferência de que ela REALMENTE rodou e não escreveu. Sem isto, o
    // silêncio de baixo passaria de graça numa rodada que nem chegou a começar
    // — um teste verde provando nada, que é pior do que teste nenhum.
    const escritas = t.sb.chamadas.filter(
      (c) => c.caminho === "/rest/v1/permissoes" && c.metodo !== "GET");
    ok("e não escreveu nada, porque não havia o que escrever",
       escritas.length === 0, `houve ${escritas.length} escrita(s)`);

    const registro = t.registro.join("");
    ok("então o log fica calado sobre permissões",
       !/Permissões: (mudei|reaplicad)/i.test(registro),
       (registro.match(/.*Permissões: (mudei|reaplicad).*/) || [""])[0]);

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

// ==================================================================
//  7. A IMPORTAÇÃO DE HISTÓRICO
// ==================================================================
//
// Quando um número entra no Zorvin, a conversa começa vazia: tudo o que o
// cliente e o escritório trocaram antes fica só no celular. A importação puxa
// esse passado da Uazapi. É uso manual e administrativo, e a única resposta que
// ela dá é uma frase com um número — então o número precisa ser verdade.
{
  console.log("\n7. A importação de histórico");

  const ONTEM = Date.now() - 24 * 60 * 60 * 1000;
  const historico = [
    { messageid: "h-1", fromMe: false, text: "Bom dia, doutor",
      messageTimestamp: Math.floor(ONTEM / 1000), messageType: "conversation" },
    { messageid: "h-2", fromMe: true, text: "Bom dia! Pode falar",
      messageTimestamp: Math.floor((ONTEM + 60000) / 1000), messageType: "conversation" },
    { messageid: "h-3", fromMe: false, caption: "Segue o documento",
      messageTimestamp: Math.floor((ONTEM + 120000) / 1000), messageType: "image",
      fileURL: "https://mmg.whatsapp.net/expira-em-pouco-tempo.enc" },
  ];

  const comHistorico = (extra = {}) => ({
    uazapi: { historico },
    tabelas: {
      contatos: [], conversas: [], mensagens: [],
      // Uma conversa que já existe, com mensagem nova por ler.
      ...(extra.tabelas || {}),
    },
    ...(extra.quebrar ? { quebrar: extra.quebrar } : {}),
  });

  const importar = (porta, extra = "") =>
    fetch(`http://127.0.0.1:${porta}/importar-historico?token=senha-do-escritorio`
          + `&advogado=${TELEFONE.numero}&contato=5511999998888${extra}`);

  // ---- 7a. traz o passado, com a data do passado ----
  {
    const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, comHistorico());
    const r = await importar(t.porta);
    const frase = await r.text();
    ok("a importação responde 200", r.status === 200, `veio ${r.status}: ${frase.slice(0, 200)}`);
    ok("traz as três mensagens do histórico", t.sb.dados.mensagens.length === 3,
       `vieram ${t.sb.dados.mensagens.length}`);

    const primeira = t.sb.dados.mensagens.find((m) => m.id_uazapi === "h-1");
    ok("com o horário original, e não a hora da importação",
       primeira && new Date(primeira.criado_em).getTime() < Date.now() - 20 * 60 * 60 * 1000,
       primeira && primeira.criado_em);
    ok("quem mandou cada uma é preservado",
       t.sb.dados.mensagens.find((m) => m.id_uazapi === "h-2")?.origem === "advogado");

    // A FOTO DO HISTÓRICO.
    //
    // O endereço que a Uazapi devolve aponta para o servidor do WhatsApp, é
    // temporário e vem cifrado. Guardá-lo na mensagem faz a foto aparecer hoje
    // — se aparecer — e virar bolha quebrada depois, sem nada explicando.
    // O caminho do webhook já baixa o arquivo e guarda no Storage; a
    // importação precisa fazer o mesmo, senão importa fotos que não abrem.
    const foto = t.sb.dados.mensagens.find((m) => m.id_uazapi === "h-3");
    ok("a foto do histórico é guardada no Storage, não deixada no link que expira",
       foto && String(foto.midia_url || "").includes("/storage/"),
       `ficou apontando para: ${foto && foto.midia_url}`);

    // ---- 7b. rodar de novo não duplica — e não mente no número ----
    const r2 = await importar(t.porta);
    const frase2 = await r2.text();
    ok("rodar de novo não duplica nada", t.sb.dados.mensagens.length === 3,
       `ficaram ${t.sb.dados.mensagens.length}`);
    ok("e a frase final não diz que importou o que já estava lá",
       /Importei 0 /.test(frase2) || /nenhuma mensagem nova/i.test(frase2),
       `disse: "${frase2.trim()}"`);

    await t.parar();
  }

  // ---- 7c. quando o banco recusa, a resposta precisa ser compreensível ----
  //
  // Quem roda isto é uma pessoa, num navegador, e o que ela recebe é uma frase.
  // "Cannot read properties of null (reading 'id')" não é uma frase — é o
  // sintoma de um erro que não foi conferido, mostrado a quem não pode fazer
  // nada com ele.
  {
    const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, comHistorico({
      quebrar: (metodo, tabela) =>
        (metodo === "POST" && tabela === "contatos") ? "o banco recusou" : null,
    }));
    const r = await importar(t.porta);
    const frase = await r.text();
    ok("banco recusando dá uma frase em português, não o erro cru",
       !/Cannot read|undefined|null \(reading/.test(frase),
       `respondeu: "${frase.trim().slice(0, 160)}"`);
    await t.parar();
  }

  // ---- 7d. importar o passado não apaga o aviso de mensagem nova ----
  {
    const t = await subirTudo({ IMPORT_TOKEN: "senha-do-escritorio" }, {
      uazapi: { historico },
      tabelas: {
        contatos: [{ id: 1, numero: "5511999998888", nome: "Cliente" }],
        conversas: [{ id: 1, advogado_id: TELEFONE.id, contato_id: 1, nao_lidas: 3,
                      ultima_atividade: new Date().toISOString() }],
        mensagens: [{ id: 90, conversa_id: 1, origem: "contato", tipo: "texto",
                      texto: "Chegou agora, ninguém leu", id_uazapi: "nova-1",
                      criado_em: new Date().toISOString() }],
      },
    });
    await importar(t.porta);
    const conversa = t.sb.dados.conversas.find((c) => c.id === 1);
    ok("importar o passado não zera as mensagens por ler",
       conversa && conversa.nao_lidas === 3,
       `o selo foi para ${conversa && conversa.nao_lidas} — havia 3 mensagens novas por ler, `
       + "e nenhuma delas foi lida por causa de uma importação de histórico");
    await t.parar();
  }
}

// ==================================================================
//  8. A MÍDIA QUE CHEGA
// ==================================================================
{
  console.log("\n8. A mídia que chega");

  const fotoDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511999998888@s.whatsapp.net",
      sender: "5511999998888@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "image", type: "media", mediaType: "image",
      caption: "olha só", messageTimestamp: Date.now(), senderName: "Cliente Teste",
      content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJh" },
    },
  });

  // A rota que funciona nesta "versão" da Uazapi é a TERCEIRA da lista que a
  // ponte tenta. É o pior caso, e é o caso que revela o desperdício.
  const t = await subirTudo({}, { uazapi: { rotaDeDownload: "/downloadmedia" } });

  for (const id of ["f-1", "f-2", "f-3"]) {
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(fotoDaUazapi(id)),
    });
    await espera(900);
  }

  ok("a foto vira mensagem", t.sb.dados.mensagens.length === 3,
     `vieram ${t.sb.dados.mensagens.length}`);
  ok("e o arquivo é guardado no Storage", t.sb.arquivos.size === 3,
     `foram ${t.sb.arquivos.size} arquivo(s)`);
  ok("a mensagem aponta para o Storage, e não para a miniatura",
     t.sb.dados.mensagens.every((m) => String(m.midia_url || "").includes("/storage/")),
     JSON.stringify(t.sb.dados.mensagens.map((m) => String(m.midia_url || "").slice(0, 40))));

  // O DESPERDÍCIO.
  //
  // A ponte tenta três rotas de download, sempre na mesma ordem, e nunca
  // guarda qual funcionou. Se a que serve é a terceira, cada foto que chega
  // custa duas tentativas jogadas fora — e uma delas pode esperar 20 segundos
  // se o servidor não responder, com a mensagem parada até lá.
  const perdidas = t.uaz.recebidas.filter(
    (c) => c.caminho === "/message/downloadmedia" || c.caminho === "/message/download").length;
  console.log(`     3 fotos → ${perdidas} tentativa(s) de rota jogada(s) fora`);
  ok("a ponte lembra qual rota de download funciona",
     perdidas <= 2,
     `foram ${perdidas} para 3 fotos — a rota certa é descoberta na primeira e `
     + "não deveria ser procurada de novo a cada mídia");

  // O SIGILO NO LOG.
  //
  // Havia uma linha de diagnóstico que despejava o conteúdo de toda mídia
  // recebida no log — legenda, nome de arquivo, miniatura. Num escritório de
  // advocacia, log é lugar onde muita gente entra e nada se apaga.
  ok("o conteúdo da mídia não é despejado no log quando dá tudo certo",
     !t.registro.join("").includes("Mídia recebida (content)"),
     "o log traz o conteúdo da mensagem do cliente");

  await t.parar();
}

// ---- 8b. download impossível não pode perder a mensagem ----
{
  const t = await subirTudo({}, { uazapi: { rotaDeDownload: "/nenhuma" } });
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      EventType: "messages", owner: TELEFONE.numero,
      message: {
        id: "sem-download", messageid: "sem-download",
        chatid: "5511999998888@s.whatsapp.net", sender: "5511999998888@s.whatsapp.net",
        fromMe: false, messageType: "image", mediaType: "image", caption: "tenta essa",
        messageTimestamp: Date.now(), senderName: "Cliente",
        content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJh" },
      },
    }),
  });
  await espera(1200);
  const m = t.sb.dados.mensagens[0];
  ok("download que falha não faz a mensagem sumir", t.sb.dados.mensagens.length === 1,
     `ficaram ${t.sb.dados.mensagens.length}`);
  ok("e sobra a miniatura para a bolha não nascer vazia",
     m && String(m.midia_url || "").startsWith("data:image/jpeg"),
     m && String(m.midia_url || "").slice(0, 40));
  await t.parar();
}

// ==================================================================
//  9. POR QUE A MENSAGEM NÃO SAIU
// ==================================================================
//
// A bolha vermelha na tela dizia só "não enviado". Quem atende ficava sem saber
// se o número está errado, se o cliente não tem WhatsApp, se a linha do
// escritório caiu ou se foi coisa de um minuto — e cada um desses casos pede
// uma ação diferente. Sem o motivo, a única ação possível era clicar em
// reenviar e torcer.
{
  console.log("\n9. Por que a mensagem não saiu");

  /** Põe uma mensagem na fila, deixa a Uazapi recusar, e devolve a linha. */
  async function tentarEnviar(falharEnvio) {
    const t = await subirTudo({}, { uazapi: { falharEnvio } });
    t.sb.dados.contatos.push({ id: 1, numero: "5511999998888", nome: "Cliente" });
    t.sb.dados.conversas.push({ id: 1, advogado_id: TELEFONE.id, contato_id: 1 });
    t.sb.dados.fila_envio.push({
      id: 1, conversa_id: 1, tipo: "texto", texto: "Bom dia", status: "pendente",
      tentativas: 0, criado_em: new Date().toISOString(),
    });
    await fetch(`http://127.0.0.1:${t.porta}/ping`);
    await espera(1600);
    const linha = t.sb.dados.fila_envio.find((f) => f.id === 1);
    const registro = t.registro.join("");
    await t.parar();
    return { linha, registro };
  }

  // ---- 9a. número que não tem WhatsApp ----
  {
    const { linha } = await tentarEnviar({ status: 400, corpo: { error: "number not exists" } });
    ok("a falha vira erro na fila", linha?.status === "erro", `ficou ${linha?.status}`);
    ok("o motivo é dito em português, e diz o que fazer",
       /WhatsApp|escrito errado|Confira o número/i.test(linha?.erro_motivo || ""),
       `veio: ${JSON.stringify(linha?.erro_motivo)}`);
    ok("e o texto técnico continua guardado à parte",
       /number not exists/.test(linha?.erro_detalhe || ""),
       `veio: ${JSON.stringify(linha?.erro_detalhe)}`);
  }

  // ---- 9b. a linha do escritório desconectada ----
  //
  // Aqui há DUAS pessoas para avisar, e elas precisam de coisas diferentes: a
  // atendente lê a frase na bolha vermelha; quem administra precisa saber POR
  // QUAL TELEFONE nada mais sai. Em 19/08 o log trazia só o código do item —
  // "Falha ao enviar (7dbc4b7e-3fdc-…)" — e para descobrir qual linha tinha
  // caído era preciso ir ao banco.
  {
    const { linha, registro } = await tentarEnviar({
      status: 503, corpo: { error: true, message: "WhatsApp disconnected: session is not reconnectable" } });
    ok("linha desconectada diz que é preciso reconectar",
       /desconectada|reconectar/i.test(linha?.erro_motivo || ""),
       `veio: ${JSON.stringify(linha?.erro_motivo)}`);
    ok("e o log diz qual telefone do escritório caiu",
       new RegExp(TELEFONE.numero).test(registro), registro.slice(-400));
    ok("com o nome dele, para quem não decora número",
       new RegExp(TELEFONE.nome).test(registro), registro.slice(-400));
    ok("e para quem a mensagem ia",
       /5511999998888/.test(registro), registro.slice(-400));
    // O AVISO ALTO, separado da falha da mensagem: não é uma mensagem que deu
    // errado, é um telefone fora do ar.
    ok("e grita que NADA MAIS SAI por aquela linha",
       /LINHA DESCONECTADA/.test(registro) && /NADA MAIS SAI/.test(registro),
       registro.slice(-500));
    ok("dizendo o conserto — reconectar o aparelho",
       /reconectar o aparelho na Uazapi/.test(registro), registro.slice(-500));
  }

  // ---- 9b-bis. um erro comum NÃO vira aviso de linha caída ----
  //
  // Gritar "LINHA DESCONECTADA" por um número errado faria quem administra ir
  // reconectar um aparelho que está de pé. Aviso que grita à toa é aviso que
  // se aprende a ignorar.
  {
    const { registro } = await tentarEnviar({ status: 400, corpo: { error: "number not exists" } });
    ok("número inexistente não grita linha caída",
       !/LINHA DESCONECTADA/.test(registro), registro.slice(-300));
  }

  // ---- 9c. a Uazapi fora do ar ----
  {
    const { linha } = await tentarEnviar({ status: 502, corpo: { error: "bad gateway" } });
    ok("servidor fora do ar manda tentar de novo daqui a pouco",
       /daqui a pouco|reenviar/i.test(linha?.erro_motivo || ""),
       `veio: ${JSON.stringify(linha?.erro_motivo)}`);
  }

  // ---- 9d. um erro que a ponte NÃO conhece ----
  //
  // É o caso que mais importa. Frase genérica no lugar de um motivo
  // desconhecido seria pior do que nada: pareceria resposta, e quem lesse
  // pararia de procurar. Então `erro_motivo` fica vazio de propósito, a tela
  // mostra o texto cru, e o log grita — é assim que a lista de motivos cresce a
  // partir de casos reais em vez de adivinhação.
  {
    const { linha, registro } = await tentarEnviar({
      status: 418, corpo: { error: "sou um bule de cha" } });
    ok("erro desconhecido NÃO vira frase genérica",
       !linha?.erro_motivo,
       `inventou: ${JSON.stringify(linha?.erro_motivo)}`);
    ok("o texto cru é preservado para a tela mostrar",
       /bule de cha/.test(linha?.erro_detalhe || ""),
       `veio: ${JSON.stringify(linha?.erro_detalhe)}`);
    ok("e o log avisa que apareceu um motivo novo",
       /MOTIVO DE ERRO NÃO RECONHECIDO/.test(registro),
       "sem esse aviso, a lista de motivos nunca aprende com o uso");
  }
}

// ============================================================
//  10. A FOTO DO CONTATO EM TAMANHO CHEIO
//
//  A foto guardada era a MINIATURA, porque `imagePreview` vinha na frente da
//  lista de campos do webhook. Corrigida a ordem, as novas chegam cheias; as
//  já guardadas só melhorariam quando o contato voltasse a escrever — um
//  cliente calado há um mês ficaria com a miniatura para sempre.
//
//  Esta rota vai buscar de novo, sob demanda. E, como no download de mídia, a
//  rota da Uazapi varia com a versão: o que se prova aqui é que ela PROCURA,
//  que LEMBRA a que serviu, e que quando nenhuma serve ela diz isso em vez de
//  falhar calada.
// ============================================================
console.log("\n10. A foto do contato em tamanho cheio");
{
  const CONTATO = { id: "ct-1", numero: "5567988887777", nome: "MARIA", foto_url: "https://falsa/mini.jpg" };
  const CONVERSA = { id: "cv-1", advogado_id: "adv-1", contato_id: "ct-1", nao_lidas: 0 };

  const pedirFoto = async (t, corpo = { conversa_id: "cv-1" }) => {
    const r = await fetch(`http://127.0.0.1:${t.porta}/contato/foto`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: "Bearer jwt-bom" },
      body: JSON.stringify(corpo),
    });
    return { status: r.status, corpo: await r.json().catch(() => ({})) };
  };

  // ---- 10a. acha a cheia, e não a miniatura ----
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
      uazapi: { rotaDeFoto: "/chat/details" },
    });
    const { corpo } = await pedirFoto(t);
    ok("traz a foto cheia, e não a miniatura",
       corpo.ok && /cheia/.test(corpo.foto_url || ""),
       `veio: ${JSON.stringify(corpo)}`);
    ok("e grava no contato, para valer da próxima vez também",
       /cheia/.test((t.sb.dados.contatos[0] || {}).foto_url || ""),
       `ficou: ${JSON.stringify((t.sb.dados.contatos[0] || {}).foto_url)}`);
    await t.parar();
  }

  // ---- 10b. a rota que serve é lembrada ----
  //
  // Sem lembrar, cada pedido recomeça pelas 404 — e o preço não é só tempo: é
  // uma sequência de erros no log do servidor da Uazapi a cada foto.
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
      uazapi: { rotaDeFoto: "/contact/picture" },   // a ÚLTIMA da lista
    });
    await pedirFoto(t);
    const antes = t.uaz.recebidas.filter((c) => /chat|contact/.test(c.caminho)).length;
    await pedirFoto(t);
    const depois = t.uaz.recebidas.filter((c) => /chat|contact/.test(c.caminho)).length;
    ok("o segundo pedido vai direto na rota que serviu",
       depois - antes === 1,
       `o primeiro tentou ${antes}, o segundo tentou ${depois - antes}`);
    await t.parar();
  }

  // ---- 10c. nenhuma rota serve ----
  //
  // O caso que mais importa: o servidor pode não ter NENHUMA dessas rotas.
  // Falhar calada deixaria o botão girando para sempre; o log tem de dizer o
  // que foi tentado, para uma linha na lista resolver quando se souber a certa.
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
      uazapi: { rotaDeFoto: null },
    });
    const { status, corpo } = await pedirFoto(t);
    ok("sem rota que sirva, responde em português", status >= 400 && /não consegui/i.test(corpo.erro || ""),
       `veio: ${status} ${JSON.stringify(corpo)}`);
    ok("e a foto que já existia NÃO é apagada",
       (t.sb.dados.contatos[0] || {}).foto_url === "https://falsa/mini.jpg",
       "meia foto é melhor do que nenhuma");
    await espera(300);
    ok("e o log diz o que foi tentado",
       /nenhuma rota serviu/.test(t.registro.join("")),
       "sem isso, descobrir a rota certa exige adivinhação");
    await t.parar();
  }

  // ---- 10d. grupo não tem foto de perfil ----
  {
    const t = await subirTudo({}, {
      tabelas: {
        contatos: [{ id: "ct-g", numero: "grupo:12036@g.us", nome: "GRUPO", foto_url: null }],
        conversas: [{ id: "cv-g", advogado_id: "adv-1", contato_id: "ct-g", nao_lidas: 0 }],
      },
    });
    const { status } = await pedirFoto(t, { conversa_id: "cv-g" });
    ok("grupo recusa antes de sair perguntando", status === 400);
    await t.parar();
  }

  // ---- 10e. sem login ----
  {
    const t = await subirTudo({}, {
      tabelas: { contatos: [{ ...CONTATO }], conversas: [{ ...CONVERSA }] },
    });
    const r = await fetch(`http://127.0.0.1:${t.porta}/contato/foto`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ conversa_id: "cv-1" }),
    });
    ok("sem login, não passa", r.status === 401, `veio ${r.status}`);
    await t.parar();
  }
}

// ============================================================
//  11. UMA VARIÁVEL MAL COLADA NÃO PODE DERRUBAR A ENTRADA
//
//  Aconteceu numa manhã de expediente: `PAINEL_ORIGEM` foi preenchida com uma
//  quebra de linha invisível no fim. O Node recusa pôr "\n" num cabeçalho e
//  lança `ERR_INVALID_CHAR` — DENTRO da rota, que morre antes de responder. O
//  navegador vê a conexão falhar e escreve "Load failed"; o log mostra uma
//  pilha de erro que não menciona a variável. Ninguém do escritório entrou.
//
//  O que se prova aqui é que a entrada RESPONDE mesmo com a variável torta.
// ============================================================
console.log("\n11. PAINEL_ORIGEM torta não derruba a entrada");
{
  const pedirPermissao = async (t) => {
    const r = await fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
      method: "OPTIONS",
      headers: { Origin: "https://zorvin.exemplo.com.br" },
    });
    return { status: r.status, origem: r.headers.get("access-control-allow-origin") };
  };

  // ---- 11a. com quebra de linha no fim — o caso real ----
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "https://zorvin.exemplo.com.br\n" });
    const { status, origem } = await pedirPermissao(t);
    ok("com quebra de linha, o pedido de permissão ainda responde", status === 204,
       `veio ${status} — antes a rota estourava e o navegador dizia "Load failed"`);
    ok("e o cabeçalho sai limpo", origem === "https://zorvin.exemplo.com.br",
       `veio: ${JSON.stringify(origem)}`);
    await espera(200);
    ok("e o log conta o que arrumou", /PAINEL_ORIGEM tinha espaço/.test(t.registro.join("")),
       "consertar calado esconde a configuração errada");
    await t.parar();
  }

  // ---- 11b. com barra no fim — o engano mais comum ----
  //
  // A barra não estoura, mas não CASA: o navegador compara letra por letra e
  // descarta a resposta. Falha silenciosa, do tipo que ninguém acha.
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "https://zorvin.exemplo.com.br/" });
    const { origem } = await pedirPermissao(t);
    ok("a barra no fim é tirada", origem === "https://zorvin.exemplo.com.br",
       `veio: ${JSON.stringify(origem)}`);
    await t.parar();
  }

  // ---- 11c. valor que não é endereço nenhum ----
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "sim" });
    const { status, origem } = await pedirPermissao(t);
    ok("valor sem sentido não derruba nada", status === 204);
    ok("e cai no padrão de aceitar qualquer origem", origem === "*",
       `veio: ${JSON.stringify(origem)} — degradar avisando é melhor do que parar`);
    await espera(200);
    ok("dizendo no log o que a variável deveria ser",
       /PAINEL_ORIGEM não parece um endereço/.test(t.registro.join("")));
    await t.parar();
  }

  // ---- 11d. e a entrada de verdade continua respondendo ----
  {
    const t = await subirTudo({ PAINEL_ORIGEM: "https://zorvin.exemplo.com.br\n" });
    const r = await fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Origin: "https://zorvin.exemplo.com.br" },
      body: JSON.stringify({ login: "alguem", senha: "x" }),
    });
    ok("a entrada responde em vez de estourar", r.status < 500 || r.status === 503,
       `veio ${r.status}`);
    ok("com o cabeçalho de origem no lugar",
       r.headers.get("access-control-allow-origin") === "https://zorvin.exemplo.com.br");
    await t.parar();
  }
}

// ============================================================
//  12. UM PASSO DA ENTRADA QUE TRAVA NÃO TRAVA A ENTRADA
//
//  O caso real: o log dizia "tentativa de rodrigo.sousa" e depois SILÊNCIO. A
//  entrada é uma fila de cinco idas à rede e só a primeira tinha prazo; as
//  outras, travando, penduravam tudo. A tela esperou 75 segundos e desistiu,
//  sem que ninguém pudesse dizer qual passo estava parado.
//
//  Aqui o Vantoro de mentira simplesmente não responde. Antes, a entrada ficava
//  pendurada junto; agora ela desiste, diz QUAL passo e devolve o botão.
// ============================================================
console.log("\n12. Um passo travado não pendura a entrada");
{
  // Um Vantoro que aceita a conexão e nunca responde — o pior tipo de falha,
  // porque não dá erro: só não volta.
  const mudo = http.createServer(() => { /* nunca responde */ });
  await new Promise((r) => mudo.listen(0, "127.0.0.1", r));
  const urlMudo = `http://127.0.0.1:${mudo.address().port}`;

  const t = await subirTudo({ VANTORO_API_URL: urlMudo, VANTORO_API_TOKEN: "tok" });
  const comecou = Date.now();
  const r = await fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ login: "rodrigo.sousa", senha: "x" }),
  });
  const levou = Date.now() - comecou;
  const corpo = await r.json().catch(() => ({}));

  ok("a entrada responde em vez de ficar pendurada", r.status >= 400 && r.status < 600,
     `veio ${r.status} depois de ${levou}ms`);
  ok("e responde antes dos 75 segundos que a tela espera", levou < 40000,
     `levou ${levou}ms`);
  ok("dizendo qual passo não respondeu", /não respondeu/.test(corpo.erro || ""),
     `veio: ${JSON.stringify(corpo.erro)}`);
  await espera(300);
  ok("e o log marca o passo e o tempo",
     /entrada · perguntar ao Vantoro: FALHOU/.test(t.registro.join("")),
     "sem isso, 'não entrou' continua sendo tudo o que se sabe");

  await t.parar();
  await new Promise((r) => mudo.close(r));
}

// ============================================================
//  13. QUEM JÁ ENTROU UMA VEZ NÃO PASSA MAIS PELO AUTH
//
//  A entrada chamava `createUser` A CADA LOGIN, contando com o erro "já
//  registrado" para descobrir que a conta existe. Uma ESCRITA na API de
//  administração do Auth por login de cada pessoa, para responder o que o
//  banco responde num piscar.
//
//  No dia em que essa API ficou lenta: entrada de 6 minutos e meio, e depois
//  nem isso. O escritório inteiro na porta, e o passo que travava era a
//  criação de contas que existiam há meses.
// ============================================================
console.log("\n13. Quem já entrou não passa mais pelo Auth");
{
  const VANTORO = { usuarios: [{ login: "rodrigo.sousa", nome: "Rodrigo Sousa",
                                 email: "rodrigo.sousa@x", admin: true }] };
  const entrar = (t) => fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ login: "rodrigo.sousa", senha: "certa" }),
  });

  // ---- 13a. já está em `usuarios`: nem toca no Auth ----
  {
    const t = await subirTudo({}, {
      vantoro: VANTORO,
      tabelas: { usuarios: [{ id: "11111111-1111-1111-1111-111111111111", login: "rodrigo.sousa",
                              nome: "Rodrigo Sousa", email: "rodrigo.sousa@x", admin: true }] },
      // A conta no Auth existe, como existe em produção para quem já entrou.
      contas: [{ id: "11111111-1111-1111-1111-111111111111", email: "rodrigo.sousa@x", jwt: "jwt-bom",
                 user_metadata: { nome: "Rodrigo Sousa" } }],
    });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("entra", r.status === 200 && corpo.ok, `veio ${r.status} ${JSON.stringify(corpo.erro)}`);

    const criacoes = t.sb.chamadas.filter(
      (c) => c.caminho === "/auth/v1/admin/users" && c.metodo === "POST").length;
    ok("sem criar conta nenhuma no Auth", criacoes === 0,
       `bateu ${criacoes}× na criação de contas — era uma escrita por login de cada pessoa`);
    await t.parar();
  }

  // ---- 13b. primeira entrada da vida: o caminho antigo continua ----
  //
  // Quem nunca entrou não está em `usuarios`, e a conta precisa nascer. Se
  // esta parte quebrasse, ninguém novo entraria nunca — e isso só apareceria
  // no dia da contratação.
  {
    const t = await subirTudo({}, { vantoro: VANTORO, tabelas: { usuarios: [] } });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("quem nunca entrou continua entrando", r.status === 200 && corpo.ok,
       `veio ${r.status} ${JSON.stringify(corpo.erro)}`);
    ok("e fica gravado para a próxima ser barata",
       (t.sb.dados.usuarios || []).some((u) => u.email === "rodrigo.sousa@x"),
       JSON.stringify(t.sb.dados.usuarios));
    await t.parar();
  }
}

// ============================================================
//  14. QUANDO O AUTH NÃO DÁ O BILHETE, A PONTE ASSINA
//
//  Medido em produção em 19/08: "gerar o bilhete: FALHOU depois de 20002ms",
//  três vezes seguidas, e o log com uma página do Cloudflare dizendo
//  "Error 521". O banco respondia em 168ms na MESMA chamada. Metade do
//  projeto de pé, metade no chão — e a metade no chão era a porta de entrada.
//
//  Havia uma segunda tentativa aqui, e ela saiu: ela existia porque desistir
//  era não entrar. Hoje desistir é entrar pelo outro caminho.
// ============================================================
console.log("\n14. Sem o Auth, a ponte assina a sessão");
{
  const SEGREDO = "um-segredo-de-teste-com-tamanho-suficiente";
  const PESSOA = { id: "11111111-1111-1111-1111-111111111111", login: "rodrigo.sousa",
                   nome: "Rodrigo Sousa", email: "rodrigo.sousa@x", admin: true };
  const base = {
    vantoro: { usuarios: [{ login: "rodrigo.sousa", nome: "Rodrigo Sousa",
                            email: "rodrigo.sousa@x", admin: true }] },
    tabelas: { usuarios: [PESSOA] },
    contas: [{ id: PESSOA.id, email: "rodrigo.sousa@x", jwt: "jwt-bom",
               user_metadata: { nome: "Rodrigo Sousa" } }],
  };
  const entrar = (t) => fetch(`http://127.0.0.1:${t.porta}/auth/login`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ login: "rodrigo.sousa", senha: "x" }),
  });

  /** Lê o miolo de um bilhete sem conferir nada — é o teste olhando. */
  const miolo = (jwt) => JSON.parse(
    Buffer.from(String(jwt).split(".")[1], "base64url").toString("utf8"));

  // ---- 14a. com o Auth de pé: os DOIS caminhos vêm na resposta ----
  //
  // O de sempre continua primeiro, porque a sessão que sai dele se renova
  // sozinha. O assinado vem junto, no bolso, para o caso de o `verifyOtp` do
  // painel falhar depois de o `generateLink` daqui ter dado certo — são duas
  // chamadas ao mesmo serviço doente, e elas falham separadas.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, base);
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    ok("entra", corpo.ok === true, JSON.stringify(corpo.erro));
    ok("com o bilhete do Auth", !!corpo.token_hash);
    ok("e com a sessão assinada aqui, junto", !!(corpo.sessao && corpo.sessao.access_token));
    await t.parar();
  }

  // ---- 14b. com o Auth no chão: entra do mesmo jeito ----
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, { ...base, authNoChao: true });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("com o Auth fora do ar, a pessoa AINDA ENTRA", r.status === 200 && corpo.ok === true,
       `veio ${r.status} ${JSON.stringify(corpo.erro)} — era esta a manhã de 19/08`);
    ok("sem bilhete do Auth, porque ele não respondeu", !corpo.token_hash);
    ok("e com a sessão assinada pela ponte", !!(corpo.sessao && corpo.sessao.access_token));

    const c = corpo.sessao ? miolo(corpo.sessao.access_token) : {};
    // `sub` é de onde sai `auth.uid()`, e é `auth.uid()` que decide quais
    // conversas a pessoa abre. Errar isto seria dar a sessão de outra pessoa.
    ok("o bilhete diz QUEM é a pessoa", c.sub === PESSOA.id, `dizia sub=${c.sub}`);
    ok("com o papel que o banco espera", c.role === "authenticated" && c.aud === "authenticated");
    ok("e o e-mail dela", c.email === "rodrigo.sousa@x", `dizia ${c.email}`);
    // Doze horas: mais do que um expediente, porque não há como renovar.
    const horas = (c.exp - c.iat) / 3600;
    ok("valendo por um expediente inteiro", horas >= 8 && horas <= 24, `valia ${horas}h`);

    ok("e o log conta que foi por aí",
       /assinando a sessão aqui mesmo/.test(t.registro.join("")));
    await t.parar();
  }

  // ---- 14c. o bilhete assinado ABRE AS PORTAS, sem perguntar ao Auth ----
  //
  // Era o segundo lugar em que a entrada dependia do Auth, e o menos óbvio:
  // `exigirLogin` chamava `auth.getUser` a cada pedido do painel. Com o Auth
  // fora, quem já estava logado ia perdendo a Ficha e o Histórico à medida
  // que a lembrança de 60 segundos vencia — e as mensagens continuavam
  // chegando, o que fazia a coisa parecer defeito da tela.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, { ...base, authNoChao: true });
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    const bilhete = corpo.sessao && corpo.sessao.access_token;
    ok("tem bilhete para usar", !!bilhete);

    const antes = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ab`, {
      headers: { Authorization: `Bearer ${bilhete}` },
    });
    ok("o painel passa pela porta com ele", r.status !== 401,
       `veio ${r.status} — 401 é a ponte dizendo "faça login"`);
    const depois = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    ok("e a ponte não foi perguntar ao Auth", depois === antes,
       `foi ${depois - antes}× — com o Auth no chão, perguntar é não entrar`);
    await t.parar();
  }

  // ---- 14d. bilhete mexido não passa ----
  //
  // O que separa "assinar a própria sessão" de "qualquer um assinar a sessão
  // de qualquer um" é exatamente esta conferência.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, base);
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    const bom = corpo.sessao.access_token;
    const [cab, mio, ass] = bom.split(".");

    // (1) trocar a pessoa mantendo a assinatura
    const outroMiolo = Buffer.from(JSON.stringify({ ...miolo(bom), sub: "99999999-9999-9999-9999-999999999999" }))
      .toString("base64url");
    const trocado = `${cab}.${outroMiolo}.${ass}`;
    // (2) mexer só na assinatura
    const rabiscado = `${cab}.${mio}.${ass.slice(0, -3)}xyz`;
    // (3) assinar com OUTRO segredo — é o caso de quem tem o formato mas não
    //     tem a chave, que é o atacante realista
    const outro = crypto.createHmac("sha256", "um-segredo-completamente-diferente-aqui")
      .update(`${cab}.${mio}`).digest("base64url");
    const forjado = `${cab}.${mio}.${outro}`;
    // (4) vencido: assinado com o segredo CERTO, mas com o prazo no passado
    const passado = Math.floor(Date.now() / 1000) - 60;
    const velhoMiolo = Buffer.from(JSON.stringify({ ...miolo(bom), exp: passado }))
      .toString("base64url");
    const velhoAss = crypto.createHmac("sha256", SEGREDO)
      .update(`${cab}.${velhoMiolo}`).digest("base64url");
    const vencido = `${cab}.${velhoMiolo}.${velhoAss}`;

    for (const [nome, jwt] of [["com outra pessoa dentro", trocado],
                               ["com a assinatura rabiscada", rabiscado],
                               ["assinado com outro segredo", forjado],
                               ["com o prazo vencido", vencido]]) {
      const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ab`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      ok(`bilhete ${nome}: recusado`, r.status === 401, `veio ${r.status}`);
    }
    await t.parar();
  }

  // ---- 14e. sem o segredo configurado, nada muda ----
  //
  // É o que torna esta mudança segura de soltar: onde a variável não estiver
  // posta, a entrada é exatamente a de antes. Ela não pode quebrar nada por
  // si só — só entra em cena onde foi ligada.
  {
    const t = await subirTudo({}, base);
    const corpo = await (await entrar(t)).json().catch(() => ({}));
    ok("sem segredo, entra pelo caminho de sempre", corpo.ok === true);
    ok("com o bilhete do Auth", !!corpo.token_hash);
    ok("e sem sessão assinada nenhuma", !corpo.sessao);

    // E a conferência de sessão volta a ser a ida ao Supabase.
    const antes = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/buscar?q=ab`, {
      headers: { Authorization: "Bearer jwt-bom" },
    });
    const depois = t.sb.chamadas.filter((c) => c.caminho === "/auth/v1/user").length;
    ok("e a sessão continua sendo conferida com o Supabase", depois > antes);
    await t.parar();
  }

  // ---- 14f. sem segredo E com o Auth no chão: a mensagem é honesta ----
  {
    const t = await subirTudo({}, { ...base, authNoChao: true });
    const r = await entrar(t);
    const corpo = await r.json().catch(() => ({}));
    ok("não entra, que é a verdade", r.status >= 400 && !corpo.ok, `veio ${r.status}`);
    ok("e o log diz o que falta configurar",
       /SUPABASE_JWT_SECRET/.test(t.registro.join("")),
       "quem administra precisa saber que existe conserto");
    await t.parar();
  }
}

// ============================================================
//  15. AO SUBIR, A PONTE DIZ COMO ESTÁ A ENTRADA
//
//  A saída para o Auth fora do ar só aparece no dia em que o Auth cair. Até
//  lá, ligada ou desligada, a ponte se comporta igual — e quem configurou a
//  variável não teria como saber se acertou. Descobrir no dia seria descobrir
//  do pior jeito possível.
// ============================================================
console.log("\n15. O log conta se a ponte sabe assinar");
{
  const SEGREDO = "um-segredo-de-teste-com-tamanho-suficiente";

  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, {});
    await espera(800);
    const log = t.registro.join("");
    ok("com a variável posta, o log diz que sabe", /sei assinar a sessão/.test(log), log.slice(-300));
    await t.parar();
  }

  {
    const t = await subirTudo({}, {});
    await espera(800);
    const log = t.registro.join("");
    ok("sem ela, o log diz o que falta", /SUPABASE_JWT_SECRET não está configurada/.test(log),
       log.slice(-300));
    ok("e onde achar o valor", /JWT Keys/.test(log), log.slice(-300));
    await t.parar();
  }

  // O PROJETO QUE MIGROU PARA CHAVE ASSIMÉTRICA. O Supabase oferece isso num
  // botão; depois dele, o banco recusa os bilhetes HS256 que a ponte assina, e
  // a saída deixaria de funcionar EM SILÊNCIO até o dia em que fosse precisa.
  {
    const t = await subirTudo({ SUPABASE_JWT_SECRET: SEGREDO }, { jwksAssimetrico: true });
    await espera(1200);
    const log = t.registro.join("");
    ok("migrando para chave assimétrica, o log avisa em letras grandes",
       /passou a assinar com chave assimétrica/.test(log), log.slice(-400));
    await t.parar();
  }
}

// ============================================================
//  16. O LOG DIZ DE QUEM ERA O WEBHOOK RECUSADO
//
//  Em 19/08 apareceram vinte "Webhook recusado: segredo ausente ou errado."
//  em vinte minutos, e a linha não dizia de quem. Dois casos opostos se
//  escreviam igual: um telefone do escritório cadastrado sem o `?token=` na
//  Uazapi — e aí são mensagens de cliente sendo jogadas fora, sem ninguém
//  perceber — ou alguém varrendo a internet, e aí recusar é o certo.
// ============================================================
console.log("\n16. Um webhook recusado diz de quem era");
{
  const t = await subirTudo({ WEBHOOK_TOKEN: "segredo-certo" }, {});
  const bater = (busca, corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook${busca}`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });

  // (1) sem segredo nenhum: o caso do telefone mal cadastrado
  const r1 = await bater("", { EventType: "messages", owner: "5511976378160" });
  ok("recusa quem não traz segredo", r1.status === 403);
  await espera(200);
  let log = t.registro.join("");
  ok("dizendo qual telefone era", /5511976378160/.test(log), log.slice(-300));
  ok("e que veio sem segredo nenhum", /sem segredo nenhum/.test(log), log.slice(-300));
  ok("e apontando o conserto, com o risco escrito",
     /\?token=/.test(log) && /PERDIDAS/.test(log), log.slice(-400));

  // (2) segredo errado: outra coisa, e a linha tem de separar
  const r2 = await bater("?token=chute", { EventType: "messages", owner: "5511900000000" });
  ok("recusa quem traz o segredo errado", r2.status === 403);
  await espera(200);
  log = t.registro.join("");
  ok("chamando isso de segredo ERRADO, e não de ausente", /segredo ERRADO/.test(log),
     log.slice(-300));

  // (3) O SEGREDO NUNCA VAI PARA O LOG. Nem o certo, nem o que tentaram.
  ok("e o segredo não aparece em lugar nenhum do log",
     !/segredo-certo/.test(log) && !/token=chute/.test(log),
     "log de escritório de advocacia é lugar onde muita gente entra e nada se apaga");

  // (4) VINTE IGUAIS NÃO VIRAM VINTE LINHAS. Senão o próprio volume empurra
  //     para fora do log o que a gente foi ali procurar.
  const antes = t.registro.join("").split("Webhook recusado").length - 1;
  for (let i = 0; i < 12; i += 1) await bater("", { EventType: "messages", owner: "5511976378160" });
  await espera(300);
  const depois = t.registro.join("").split("Webhook recusado").length - 1;
  ok("doze recusas iguais não viram doze linhas", depois - antes <= 1,
     `viraram ${depois - antes}`);

  await t.parar();
}

// ============================================================
//  17. O ENDEREÇO DE ARQUIVO APARECE NO LOG — E SEM A PARTE ASSINADA
//
//  Esta seção nasceu quando o endereço era JOGADO FORA e a pergunta era se
//  daria para aproveitá-lo. Deu (ver a seção 18), e o que sobra aqui continua
//  valendo: quem lê o log precisa ver o id da mensagem inteiro, para cruzar
//  com um download que falhou — e não precisa ver a assinatura do endereço,
//  que dá acesso ao arquivo e não ajuda em nada.
// ============================================================
console.log("\n17. O endereço de arquivo aparece no log, sem a parte assinada");
{
  const t = await subirTudo({}, {});
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      EventType: "messages_update",
      event: {
        Chat: "558199043770@s.whatsapp.net",
        FileURL: "https://novaera.uazapi.com/files/abc123.pdf?assinatura=xyz",
        MessageIDs: ["A55DC78559D9CE9881F208"],
        Type: "Delivered",
      },
    }),
  });
  await espera(500);
  const log = t.registro.join("");
  ok("o log conta que veio um endereço de arquivo",
     /Endereço de arquivo recebido/.test(log), log.slice(-400));
  ok("com o id da mensagem inteiro, para cruzar com o download que falhou",
     /A55DC78559D9CE9881F208/.test(log), log.slice(-400));
  ok("e sem a parte assinada do endereço, que dá acesso e não ajuda",
     /abc123\.pdf/.test(log) && !/assinatura=xyz/.test(log), log.slice(-400));
  await t.parar();
}

// ============================================================
//  18. O ANEXO QUE FICARIA VAZIO
//
//  Do log de 19/08, com um segundo de diferença:
//
//    Anexo (documento) sem arquivo: o download falhou.
//    Mensagem A5F59D4D… fica sem mídia.
//    Evento não tratado: messages_update {…"FileURL":"https://…jpg"…
//
//  Alguém abriu essa conversa e viu um anexo em branco — um documento que o
//  cliente mandou e o escritório não tem. E o endereço do arquivo chegou um
//  segundo depois, indo direto para o balde dos eventos ignorados.
//
//  O casamento é pelo id EXATO da mensagem, e a prova mais importante desta
//  seção é a que confere que ele NÃO acontece quando o id não bate.
// ============================================================
console.log("\n18. O anexo não fica vazio");
{
  const CHAT = "5511999998888@s.whatsapp.net";
  const midiaDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: CHAT, sender: CHAT, fromMe: false, isGroup: false,
      messageType: "documentMessage", mimetype: "application/pdf",
      content: { mimetype: "application/pdf", fileName: "peticao.pdf" },
      messageTimestamp: Date.now(), wasSentByApi: false, senderName: "Cliente",
    },
  });
  const enderecoDoArquivo = (t, ids) => ({
    BaseUrl: t.uaz.url,
    EventType: "messages_update",
    event: { Chat: CHAT, FileURL: `${t.uaz.url}/files/abc.pdf?assinatura=xyz`,
             MessageIDs: ids, Type: "Delivered" },
  });
  const mandar = (t, corpo) => fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const mensagemDe = (t, id) => (t.sb.dados.mensagens || []).find((m) => m.id_uazapi === id);

  // ---- 18a. o endereço chega DEPOIS — o caso exato do log ----
  {
    // `rotaDeDownload: null` é o servidor em que NENHUMA rota de download
    // serve: é assim que se reproduz o "o download falhou" sem depender de
    // uma Uazapi de verdade tendo um dia ruim.
    const t = await subirTudo({}, { uazapi: { rotaDeDownload: null } });
    await mandar(t, midiaDaUazapi("MSG-VAZIA"));
    await espera(900);

    const antes = mensagemDe(t, "MSG-VAZIA");
    ok("a mensagem entra mesmo sem o arquivo", !!antes,
       "perder a bolha inteira seria pior: ninguém saberia que veio algo");
    ok("e entra vazia, como entrou em 19/08", antes && !antes.midia_url,
       `veio ${antes && antes.midia_url}`);

    await mandar(t, enderecoDoArquivo(t, ["MSG-VAZIA"]));
    await espera(1200);

    const depois = mensagemDe(t, "MSG-VAZIA");
    ok("o endereço que chega depois preenche o anexo", !!(depois && depois.midia_url),
       "era o documento do cliente que ficava faltando");
    ok("e o log conta o resgate",
       /Anexo resgatado/.test(t.registro.join("")), t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- 18b. o endereço chega ANTES ----
  //
  // Acontece sempre que o evento do arquivo vem na frente da mensagem — foi o
  // que o log mostrou nas duas vezes seguintes. Aí não há o que resgatar: o
  // endereço guardado é usado na hora em que o download falha.
  {
    const t = await subirTudo({}, { uazapi: { rotaDeDownload: null } });
    await mandar(t, enderecoDoArquivo(t, ["MSG-ANTES"]));
    await espera(400);
    await mandar(t, midiaDaUazapi("MSG-ANTES"));
    await espera(1200);

    const m = mensagemDe(t, "MSG-ANTES");
    ok("a mensagem já nasce com o arquivo", !!(m && m.midia_url), `veio ${m && m.midia_url}`);
    ok("e o log diz por onde veio",
       /endereço que a Uazapi mandou à parte/.test(t.registro.join("")),
       t.registro.join("").slice(-300));
    await t.parar();
  }

  // ---- 18c. UM ANEXO QUE JÁ CHEGOU NUNCA É SOBRESCRITO ----
  //
  // Esta é a que separa um resgate de um estrago. Se o endereço que chega
  // pudesse passar por cima do arquivo que já está lá, um evento repetido
  // trocaria o documento de um cliente pelo de outro.
  {
    const t = await subirTudo({}, {});   // aqui o download FUNCIONA
    await mandar(t, midiaDaUazapi("MSG-CHEIA"));
    await espera(900);
    const original = mensagemDe(t, "MSG-CHEIA");
    ok("a mensagem chegou com arquivo", !!(original && original.midia_url));

    await mandar(t, enderecoDoArquivo(t, ["MSG-CHEIA"]));
    await espera(1000);
    const agora = mensagemDe(t, "MSG-CHEIA");
    ok("o endereço que chega depois NÃO troca o arquivo que já existe",
       agora && agora.midia_url === original.midia_url,
       `era ${original && original.midia_url}, virou ${agora && agora.midia_url}`);
    await t.parar();
  }

  // ---- 18d. id que não existe não escreve em ninguém ----
  {
    const t = await subirTudo({}, {});
    await mandar(t, midiaDaUazapi("MSG-OUTRA"));
    await espera(900);
    const antes = mensagemDe(t, "MSG-OUTRA");

    await mandar(t, enderecoDoArquivo(t, ["ID-QUE-NAO-EXISTE"]));
    await espera(900);
    const depois = mensagemDe(t, "MSG-OUTRA");
    ok("um endereço de id desconhecido não encosta em mensagem nenhuma",
       depois && depois.midia_url === antes.midia_url,
       "casar por id exato é o que separa um resgate de um estrago");
    ok("e nada estoura por causa disso",
       !/uncaughtException|unhandledRejection/.test(t.registro.join("")));
    await t.parar();
  }

  // ---- 18e. o endereço que já não serve mais ----
  {
    // Um resgate tardio: a Uazapi apagou o arquivo. Tem de falhar quieto, sem
    // derrubar nada e sem gravar um endereço quebrado na mensagem.
    const t = await subirTudo({}, { uazapi: { rotaDeDownload: null, arquivoPorEndereco: null } });
    await mandar(t, midiaDaUazapi("MSG-TARDE"));
    await espera(900);
    await mandar(t, enderecoDoArquivo(t, ["MSG-TARDE"]));
    await espera(1200);

    const m = mensagemDe(t, "MSG-TARDE");
    ok("a mensagem continua sem arquivo, e não com um endereço quebrado",
       m && !m.midia_url, `veio ${m && m.midia_url}`);
    ok("e o log diz que não deu",
       /não consegui resgatar|também não serviu/i.test(t.registro.join("")),
       t.registro.join("").slice(-300));
    await t.parar();
  }
}


// ==================================================================
//  19. A BOLHA NÃO ESPERA O ARQUIVO
//
//  Relato de quem usa: "ao enviar ou receber algum arquivo, está demorando
//  para aparecer o arquivo na conversa".
//
//  O caminho de recebimento fazia tudo em fila indiana, e só no fim gravava:
//
//     webhook chega
//       → /message/downloadmedia na Uazapi   (até 20s, e até 3 rotas)
//       → baixa o arquivo                     (uma foto de celular são MBs)
//       → sobe para o Storage do Supabase
//       → SÓ ENTÃO insere a mensagem no banco
//       → só então o tempo real acende a bolha na tela
//
//  Enquanto isso a conversa fica VAZIA. Não é o arquivo que demora a aparecer:
//  é a mensagem inteira que não existe ainda. Quem está do outro lado vê o
//  cliente dizer "te mandei a foto" e não vê foto nenhuma.
//
//  E o mais irônico: a miniatura que vem embutida no próprio webhook — que o
//  código já lia, e cujo comentário dizia "prévia imediata" — era calculada e
//  depois jogada fora, porque a gravação esperava o arquivo grande de todo
//  jeito. A prévia imediata nunca foi imediata.
//
//  ESTA PROVA MEDE. Ela põe a Uazapi para demorar 1,2s no download (o que é
//  otimista para uma foto de verdade) e cronometra quanto tempo passa entre o
//  webhook chegar e a mensagem existir no banco.
// ==================================================================
{
  console.log("\n19. A bolha não espera o arquivo");

  const DEMORA = 1200;

  const fotoDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511977776666@s.whatsapp.net",
      sender: "5511977776666@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "image", type: "media", mediaType: "image",
      caption: "segue o documento", messageTimestamp: Date.now(), senderName: "Cliente Lento",
      content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJhLWRlLW1lbnRpcmE=" },
    },
  });

  const t = await subirTudo({}, { uazapi: { demoraDoDownload: DEMORA } });

  /** Espera a mensagem existir no banco e devolve quanto tempo levou. */
  async function quandoNasceABolha(id, limite = 15000) {
    const comeco = Date.now();
    for (;;) {
      const linha = t.sb.dados.mensagens.find((m) => m.id_uazapi === id);
      if (linha) return { ms: Date.now() - comeco, linha };
      if (Date.now() - comeco > limite) return { ms: Infinity, linha: null };
      await espera(25);
    }
  }

  // Dispara o webhook SEM esperar: a medição começa agora.
  fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(fotoDaUazapi("lento-1")),
  }).catch(() => {});

  const nascimento = await quandoNasceABolha("lento-1");
  console.log(`     download demorando ${DEMORA}ms → bolha nasceu em ${nascimento.ms}ms`);

  ok("a mensagem chega a existir", !!nascimento.linha);

  // O CORAÇÃO DA PROVA. A bolha tem de nascer ANTES do download terminar, e
  // não depois. A margem é generosa de propósito: subir a ponte e falar com o
  // falso Supabase custa alguma coisa, e não é isso que está sendo medido.
  ok("a bolha nasce sem esperar o download",
     nascimento.ms < DEMORA,
     `levou ${nascimento.ms}ms com o download demorando ${DEMORA}ms — `
     + "a conversa fica vazia esse tempo todo, e é isso que quem usa relata");

  // E ela não nasce vazia: a miniatura do próprio webhook é o que a pessoa vê
  // enquanto o arquivo grande não chega.
  ok("e já nasce com a miniatura, para não ser uma bolha em branco",
     String(nascimento.linha && nascimento.linha.midia_url || "").startsWith("data:image/"),
     `midia_url nasceu como "${String(nascimento.linha && nascimento.linha.midia_url || "").slice(0, 40)}"`);

  ok("com a legenda que o cliente escreveu",
     nascimento.linha && nascimento.linha.texto === "segue o documento",
     `texto: ${JSON.stringify(nascimento.linha && nascimento.linha.texto)}`);

  // E DEPOIS o arquivo de verdade substitui a miniatura, sem bolha nova.
  let trocou = null;
  for (let i = 0; i < 80; i++) {
    const linha = t.sb.dados.mensagens.find((m) => m.id_uazapi === "lento-1");
    if (linha && String(linha.midia_url || "").includes("/storage/")) { trocou = linha; break; }
    await espera(100);
  }
  ok("e o arquivo de verdade entra no lugar da miniatura", !!trocou,
     `midia_url ficou "${String((t.sb.dados.mensagens.find((m) => m.id_uazapi === "lento-1") || {}).midia_url || "").slice(0, 50)}"`);

  ok("sem criar uma segunda bolha",
     t.sb.dados.mensagens.filter((m) => m.id_uazapi === "lento-1").length === 1,
     `ficaram ${t.sb.dados.mensagens.filter((m) => m.id_uazapi === "lento-1").length} mensagens com o mesmo id`);

  ok("e o arquivo foi mesmo parar no Storage", t.sb.arquivos.size >= 1,
     `foram ${t.sb.arquivos.size} arquivo(s)`);

  await t.parar();
}

// ==================================================================
//  20. AO SUBIR, A PONTE DIZ QUAL VERSÃO ELA É
//
//  Em 20/08 uma correção ficou pronta, mesclada, e NÃO estava rodando. A
//  Render não publicou, e o repositório dizia uma coisa enquanto o serviço
//  fazia outra — sem nenhuma diferença visível.
//
//  Só descobrimos por ACIDENTE: uma frase de log tinha mudado, e a antiga
//  continuava aparecendo em produção. Sem essa coincidência, a correção da
//  lentidão do anexo teria ficado parada com todo mundo achando que estava no
//  ar. Esta seção existe para que a próxima vez não dependa de sorte.
// ==================================================================
{
  console.log("\n20. A versão no ar aparece no log");

  {
    const t = await subirTudo({ RENDER_GIT_COMMIT: "abc1234def5678", RENDER_GIT_BRANCH: "main" });
    await espera(600);
    const log = t.registro.join("");
    const linha = (log.split("\n").find((l) => l.includes("versão no ar")) || "").trim();

    ok("a ponte anuncia a versão ao subir", !!linha, `o log não tem a linha`);
    // O COMMIT ENCURTADO, e não inteiro: oito letras bastam para comparar com
    // o que está no GitHub, e a linha continua legível de relance no meio de
    // um log corrido.
    ok("dizendo o commit", /abc1234d/.test(linha), `dizia: "${linha}"`);
    ok("e o ramo", /main/.test(linha), `dizia: "${linha}"`);
    // A DATA DO ARQUIVO VAI JUNTO. É ela que denuncia um deploy velho mesmo
    // onde o commit não vier — e é o caso de qualquer lugar que não seja a
    // Render.
    ok("e a data em que o arquivo foi escrito",
       /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(linha), `dizia: "${linha}"`);
    await t.parar();
  }

  {
    // SEM AS VARIÁVEIS DA RENDER a linha não pode sumir: ela ainda responde
    // "de quando é este arquivo?", que já separa um deploy de hoje de um de
    // três meses atrás. Uma linha que só aparece na Render deixaria de
    // funcionar exatamente onde se costuma investigar — na máquina de quem
    // está procurando o defeito.
    const t = await subirTudo({ RENDER_GIT_COMMIT: "", RENDER_GIT_BRANCH: "" });
    await espera(600);
    const linha = (t.registro.join("").split("\n")
      .find((l) => l.includes("versão no ar")) || "").trim();
    ok("sem as variáveis da Render, a linha continua saindo", !!linha);
    ok("e ainda diz de quando é o arquivo",
       /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(linha), `dizia: "${linha}"`);
    ok("sem inventar um commit que não sabe", !/commit /.test(linha),
       `dizia: "${linha}"`);
    await t.parar();
  }
}

// ==================================================================
//  O TELEFONE QUE MANDA E NÃO ESTÁ CADASTRADO
// ==================================================================
//
//  Relatado em 21/08: "acreditamos que o telefone 3857 esteja com uma
//  interferência, pois as mensagens que enviamos são recebidas pelos clientes,
//  porém eles não nos retornam. Pelo 1932 eles respondem em seguida."
//
//  Não era interferência. O telefone não estava na tabela `advogados`, e a
//  ponte descartava tudo o que chegava por ele — com um `console.log` de duas
//  palavras no meio de milhares de linhas. O ENVIO continua funcionando (sai
//  por outro caminho), e é isso que faz o sintoma parecer do cliente.
//
//  O descarte está certo: sem advogado não há conversa em que pôr a mensagem.
//  O que estava errado era o silêncio.
{
  console.log("\nO telefone que manda e não está cadastrado");
  const t = await subirTudo();

  const deOutroTelefone = { ...mensagemDaUazapi("Oi, respondendo", "m-x"),
                            owner: "5567900003857" };
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(deOutroTelefone),
  });
  await espera(700);

  ok("a mensagem de telefone não cadastrado não é gravada",
     t.sb.dados.mensagens.length === 0, `ficaram ${t.sb.dados.mensagens.length}`);

  const log = t.registro.join("");
  ok("mas o aviso DIZ que é mensagem de cliente sendo perdida",
     /MENSAGEM DE CLIENTE PERDIDA/.test(log));
  ok("e diz QUAL telefone", /5567900003857/.test(log));
  ok("e diz o que fazer (cadastrar em advogados)",
     /não está na tabela "advogados"/.test(log) && /Cadastre o número/.test(log));
  ok("e avisa que o envio continua funcionando — que é o que confunde",
     /envio POR este telefone continua funcionando/i.test(log));

  // SEM PRECISAR CAÇAR NO LOG. Quem atende não entra na Render.
  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  ok("o /webhook/desconhecidos lista o telefone",
     d.telefones.some((x) => x.numero === "5567900003857"), JSON.stringify(d));
  ok("com a contagem do que foi descartado",
     d.telefones[0]?.eventos_descartados === 1, JSON.stringify(d.telefones));

  // O TELEFONE CADASTRADO CONTINUA ENTRANDO — a correção não pode fechar a porta boa.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Do telefone certo", "m-ok")),
  });
  await espera(700);
  ok("o telefone cadastrado continua entrando normalmente",
     t.sb.dados.mensagens.length === 1, `ficaram ${t.sb.dados.mensagens.length}`);

  // NÃO PODE VIRAR ENXURRADA: um telefone movimentado empurraria para fora do
  // log tudo o que interessa, inclusive isto.
  for (let i = 0; i < 5; i++) {
    await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ ...deOutroTelefone,
        message: { ...deOutroTelefone.message, id: `m-y${i}`, messageid: `m-y${i}` } }),
    });
  }
  await espera(800);
  const quantosAvisos = (t.registro.join("").match(/MENSAGEM DE CLIENTE PERDIDA/g) || []).length;
  ok("seis eventos do mesmo telefone não viram seis avisos", quantosAvisos === 1,
     `saíram ${quantosAvisos}`);

  const d2 = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  ok("mas a contagem soma todos os descartados",
     d2.telefones.find((x) => x.numero === "5567900003857")?.eventos_descartados === 6,
     JSON.stringify(d2.telefones));

  await t.parar();
}

// ==================================================================
//  QUANDO O VANTORO NÃO RESPONDE JSON
// ==================================================================
//
//  Relatado em 21/08, com a tela mostrando "Resposta inválida do Vantoro" e,
//  logo abaixo, "verifique se a ponte está configurada com VANTORO_API_URL e
//  VANTORO_API_TOKEN".
//
//  A dica estava errada, e errada de um jeito específico: se aquelas duas
//  variáveis faltassem, a ponte teria parado antes, com outra mensagem. Chegar
//  ali PROVA que as duas existem. A causa real era o serviço do Vantoro fora do
//  ar — workspace suspenso por consumo —, devolvendo a página de suspensão em
//  HTML no lugar dos dados.
{
  console.log("\nQuando o Vantoro não responde JSON");

  // Serviço suspenso/fora do ar: HTML com 503.
  {
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 503 } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("diz o código que veio (503)", /503/.test(c.erro || ""), c.erro);
    ok("diz que veio uma página em vez dos dados", /página HTML/i.test(c.erro || ""), c.erro);
    ok("e diz na cara que NÃO é a configuração da ponte",
       /não é a configuração da ponte/i.test(c.erro || ""), c.erro);
    ok("não some com a evidência numa frase genérica",
       !/^Resposta inválida do Vantoro\.$/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // Endereço apontando para um caminho que não existe.
  {
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 404 } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("404 aponta para o ENDEREÇO, não para o token",
       /VANTORO_API_URL/.test(c.erro || "") && !/TOKEN/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // Recusa sem JSON: aí sim é token.
  {
    const t = await subirTudo({}, { vantoro: { naoJson: { status: 401 } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("401 sem JSON aponta para o TOKEN", /VANTORO_API_TOKEN/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // Texto solto do servidor: mostrar o texto resolve mais que qualquer frase minha.
  {
    const t = await subirTudo({}, { vantoro: {
      naoJson: { status: 500, tipo: "text/plain", corpo: "upstream connect error" } } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("mostra o texto que o servidor mandou",
       /upstream connect error/.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // E o caminho bom continua bom.
  {
    const t = await subirTudo({}, { vantoro: {} });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    ok("com o Vantoro no ar, a ficha responde normalmente", r.status === 200, `veio ${r.status}`);
    await t.parar();
  }
}

// ==================================================================
//  O VANTORO HIBERNANDO NÃO PODE VIRAR ERRO NA CARA DE QUEM ATENDE
// ==================================================================
//
//  No plano gratuito da Render o serviço hiberna. A primeira chamada depois
//  disso NÃO ESPERA: a Render responde na hora, com uma página de erro, e só
//  então acorda o Django por baixo.
//
//  Do lado de quem atende isso aparecia como a ficha do cliente falhando sem
//  motivo e voltando sozinha minutos depois. É o relato de 21/08.
{
  console.log("\nO Vantoro hibernando não vira erro na cara de quem atende");

  // Dorme na PRIMEIRA chamada, acorda na segunda — exatamente como a Render.
  {
    // JANELA FECHADA de propósito: com ela aberta, o ping de manutenção
    // absorve a primeira resposta "dormindo" e o reenvio nunca é exercitado.
    // (Foi o que aconteceu na primeira rodada — o que prova que os dois
    // mecanismos se cobrem, mas cada um precisa da sua própria conferência.)
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 1 } });
    const comeco = Date.now();
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const levou = Date.now() - comeco;
    console.log(`     serviço dormindo → a ficha respondeu ${r.status} em ${levou}ms`);

    ok("a ficha responde certo mesmo com o serviço dormindo", r.status === 200,
       `veio ${r.status} — quem atende veria a ficha falhar sem motivo`);
    ok("e esperou o serviço acordar antes de responder", levou >= 6000,
       `respondeu em ${levou}ms; a espera de 6s não aconteceu`);
    ok("e o log diz que foi sono, não defeito",
       /parece serviço hibernando/.test(t.registro.join("")));
    await t.parar();
  }

  // DORMINDO DE VERDADE (não acorda nunca): tem de desistir com a mensagem que
  // explica, e não ficar tentando para sempre.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 99 } });
    const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                          { headers: { Authorization: "Bearer jwt-bom" } });
    const c = await r.json();
    ok("serviço que não acorda desiste, com o motivo",
       /502|fora do ar|dormindo|suspenso/i.test(c.erro || ""), c.erro);
    await t.parar();
  }

  // O ENVIO NÃO É REPETIDO. Se o Vantoro chegou a receber o cadastro antes de a
  // Render cortar, repetir criaria DOIS clientes — e um cadastro duplicado é
  // pior do que um erro na tela, porque ninguém percebe na hora.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { dormeAsPrimeiras: 1 } });
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente`, {
      method: "POST",
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
      body: JSON.stringify({ nome: "Fulano", telefone: "5511999998888" }),
    });
    // TODOS os POSTs que o Vantoro recebeu, e não os de um caminho escolhido a
    // dedo: a ponte chama "/clientes" lá dentro, não "/vantoro/cliente" (esse é
    // o endereço DELA). Filtrando pelo caminho errado, a conta dava zero e a
    // conferência passava sem olhar nada — foi assim na primeira rodada, e só
    // apareceu porque a sabotagem correspondente NÃO derrubou nada.
    const posts = t.van.recebidas.filter((x) => x.metodo === "POST");
    ok("um cadastro que falhou NÃO é reenviado", posts.length <= 1,
       `o Vantoro recebeu ${posts.length} POSTs — cria cliente duplicado`);
    await t.parar();
  }

  // RESPOSTA LENTA NÃO É SONO. Serviço no ar e sobrecarregado responde devagar;
  // insistir nesse caso só piora, e ainda dobra a espera de quem está olhando.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: { naoJson: { status: 503 }, demora: 5500 } });
    const comeco = Date.now();
    await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente?telefone=5511999998888`,
                { headers: { Authorization: "Bearer jwt-bom" } });
    const levou = Date.now() - comeco;
    ok("resposta lenta não é tratada como sono (não tenta de novo)",
       levou < 11000, `levou ${levou}ms — dobrou a espera de quem está olhando`);
    await t.parar();
  }
}

// ==================================================================
//  A JANELA EM QUE O VANTORO É MANTIDO ACORDADO
// ==================================================================
//
//  Acordado 24 horas, cada serviço consome ~730 h/mês. São DOIS serviços, e o
//  plano gratuito dá 750 h para o workspace inteiro — manter os dois de pé o
//  tempo todo estoura a franquia e troca o problema do sono pelo da conta.
//
//  Por isso a batida que mantém o Vantoro acordado tem hora para começar e
//  para acabar. Estas conferências olham o que o Vantoro RECEBE, que é a única
//  coisa que decide se a franquia vai ser gasta ou não.
{
  console.log("\nA janela em que o Vantoro é mantido acordado");

  // Janela escancarada: o ping tem de sair assim que a ponte sobe.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_DE: "0", VANTORO_ACORDADO_ATE: "24",
                                VANTORO_ACORDADO_SABADO: "1" }, { vantoro: {} });
    await espera(900);
    const pings = t.van.recebidas.filter((x) => x.caminho === "/ping");
    ok("dentro da janela, a ponte bate no /ping do Vantoro", pings.length >= 1,
       `bateu ${pings.length} vez(es)`);
    await t.parar();
  }

  // Janela fechada: NADA pode sair. É esta linha que protege a franquia de
  // horas — sem ela, o Vantoro ficaria de pé 24h e a conta estouraria no fim
  // do mês, sem nada apontando para a causa.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_DE: "0", VANTORO_ACORDADO_ATE: "0" },
                              { vantoro: {} });
    await espera(900);
    const pings = t.van.recebidas.filter((x) => x.caminho === "/ping");
    ok("fora da janela, NÃO bate", pings.length === 0,
       `bateu ${pings.length} vez(es) — o serviço ficaria de pé 24h`);
    await t.parar();
  }

  // O PING NÃO LEVA O TOKEN. Ele não precisa — do outro lado é 200 vazio, sem
  // banco e sem sessão. Mandar o token numa chamada que não pede é espalhá-lo
  // por mais um lugar sem ganhar nada.
  {
    const t = await subirTudo({ VANTORO_ACORDADO_DE: "0", VANTORO_ACORDADO_ATE: "24" },
                              { vantoro: {} });
    await espera(900);
    const ping = t.van.recebidas.find((x) => x.caminho === "/ping");
    ok("e o ping não leva o token junto", !!ping && !ping.autorizacao,
       JSON.stringify(ping || null));
    await t.parar();
  }
}


// ==================================================================
//  O ARQUIVO SOBE COM CACHE LONGO
// ==================================================================
//
//  A biblioteca do Supabase manda `max-age=3600` quando ninguém diz nada — uma
//  hora. De hora em hora, cada atendente que abre uma conversa BAIXA DE NOVO
//  todas as fotos, áudios e vídeos dela.
//
//  Com oito pessoas rolando conversas o dia inteiro e mais de 1 GB de mídia
//  guardada, é assim que a franquia de banda vira zero. Em 21/08 o workspace
//  foi suspenso por consumo e o atendimento parou — a ficha do cliente deixou
//  de responder, porque serviço suspenso devolve página, não dados.
//
//  Este é o único ponto do código que decide isso, e ele não estava dizendo
//  nada.
{
  console.log("\nO arquivo sobe com cache longo");

  const fotoDaUazapi = (id) => ({
    EventType: "messages",
    owner: TELEFONE.numero,
    message: {
      id, messageid: id, chatid: "5511977776666@s.whatsapp.net",
      sender: "5511977776666@s.whatsapp.net", fromMe: false, isGroup: false,
      messageType: "image", type: "media", mediaType: "image",
      caption: "uma foto", messageTimestamp: Date.now(), senderName: "Cliente",
      content: { mimetype: "image/jpeg", JPEGThumbnail: "bWluaWF0dXJh" },
    },
  });

  const t = await subirTudo();
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(fotoDaUazapi("foto-cache-1")),
  });

  // Espera o arquivo chegar ao Storage (o download é assíncrono de propósito —
  // a bolha nasce antes dele, e isso já tem conferência própria).
  for (let i = 0; i < 80 && t.sb.cabecalhosDeUpload.size === 0; i++) await espera(50);

  const enviados = [...t.sb.cabecalhosDeUpload.entries()];
  ok("o arquivo chega ao Storage", enviados.length === 1,
     JSON.stringify(enviados));

  const cache = (enviados[0] || [])[1] || "";
  ok("e sobe com cache-control", !!cache, `veio "${cache}"`);

  // O CORAÇÃO DA PROVA. Uma hora é o padrão da biblioteca e é o que quebrou o
  // escritório. Qualquer coisa acima de um mês já muda a natureza do problema.
  const segundos = Number((cache.match(/max-age=(\d+)/) || [])[1] || 0);
  ok("com prazo longo, e não a hora que a biblioteca usa por padrão",
     segundos >= 2592000,
     `veio max-age=${segundos} (${Math.round(segundos / 3600)}h) — `
     + "com isso cada atendente rebaixa a conversa inteira nesse intervalo");

  // `immutable` é o que faz o navegador nem PERGUNTAR se mudou. Sem ele ainda
  // sai uma ida à rede por arquivo para receber "304, continua igual" — pouco
  // tráfego, mas uma chamada por imagem por atendente, e é o que deixa a
  // conversa lenta ao abrir.
  ok("e marcado como imutável, para o navegador nem perguntar",
     /immutable/.test(cache), `veio "${cache}"`);

  // O CAMINHO É QUE AUTORIZA O CACHE LONGO. Guardar por um ano só é seguro
  // porque aquele endereço nunca vai apontar para outro conteúdo. Se o caminho
  // passasse a ser reaproveitado, o cache longo viraria defeito — e esta linha
  // é o que avisa.
  const caminho = (enviados[0] || [])[0] || "";
  ok("e o caminho carrega o id da mensagem, que não se repete",
     caminho.includes("foto-cache-1"), `caminho "${caminho}"`);

  await t.parar();
}

// ==================================================================
//  O TELEFONE CADASTRADO DUAS VEZES
// ==================================================================
//
//  O SEGUNDO caminho silencioso, e o pior dos dois.
//
//  A busca usava `maybeSingle()`, que devolve ERRO quando acha mais de uma
//  linha. Um telefone cadastrado duas vezes em `advogados` — coisa que
//  acontece, alguém cadastra de novo achando que faltava — fazia TODA mensagem
//  daquele número ser descartada, com um `console.error` que não dizia que
//  eram mensagens de cliente.
//
//  É pior do que o "não cadastrado" porque o telefone ESTÁ lá: quem for
//  conferir vai achar tudo certo. Foi assim que este defeito escapou uma vez —
//  a explicação "não está cadastrado" batia com o sintoma e estava errada.
{
  console.log("\nO telefone cadastrado duas vezes");

  const DOIS = [
    { id: "adv-1", nome: "Comercial", numero: "5567900000001", token: "tok-a",
      servidor: null, ativo: true, departamento_id: 1 },
    { id: "adv-2", nome: "Comercial (repetido)", numero: "5567900000001", token: "tok-b",
      servidor: null, ativo: true, departamento_id: 1 },
  ];
  const t = await subirTudo({}, { tabelas: { advogados: DOIS } });

  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Oi, respondendo", "dup-1")),
  });
  await espera(900);

  // O CORAÇÃO DA PROVA. Cadastro repetido é problema de cadastro, e não pode
  // custar as mensagens dos clientes enquanto ninguém arruma.
  ok("a mensagem ENTRA mesmo com o telefone cadastrado duas vezes",
     t.sb.dados.mensagens.length === 1,
     `ficaram ${t.sb.dados.mensagens.length} — o cliente respondeu e sumiu`);

  ok("e a duplicidade é avisada",
     /CADASTRO REPETIDO/.test(t.registro.join("")));
  ok("dizendo qual telefone", /5567900000001/.test(t.registro.join("")));

  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  ok("e o /webhook/desconhecidos lista o cadastro repetido",
     (d.cadastros_repetidos || []).includes("5567900000001"), JSON.stringify(d));

  await t.parar();
}

// ==================================================================
//  A BUSCA DO ADVOGADO FALHANDO
// ==================================================================
//
//  Banco fora do ar, coluna que não existe, o que for. Antes era um
//  `console.error` genérico e a mensagem ia embora sem nada dizer que era
//  mensagem de cliente — e sem aparecer em lugar nenhum que alguém consultasse.
{
  console.log("\nA busca do advogado falhando");
  const t = await subirTudo({}, {
    quebrar: (metodo, tabela) => (metodo === "GET" && tabela.startsWith("advogados"))
      ? "banco fora do ar" : null,
  });

  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify(mensagemDaUazapi("Oi", "falha-1")),
  });
  await espera(900);

  const log = t.registro.join("");
  ok("o aviso diz que é mensagem de cliente sendo perdida",
     /MENSAGEM DE CLIENTE PERDIDA/.test(log));
  ok("e aponta o cadastro repetido como causa mais comum",
     /DUAS VEZES/.test(log), log.slice(-400));

  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/desconhecidos`)).json();
  const linha = (d.telefones || [])[0];
  ok("e o /webhook/desconhecidos separa este motivo do 'não cadastrado'",
     linha && linha.motivo === "busca", JSON.stringify(d.telefones));
  ok("e diz o que fazer", !!(linha && /DUAS VEZES/.test(linha.o_que_fazer || "")),
     JSON.stringify(linha || null));

  await t.parar();
}

// ==================================================================
//  QUAL TELEFONE ESTÁ MUDO
// ==================================================================
//
//  A causa que sobrou depois de as outras duas serem descartadas com dado na
//  mão: a URL do webhook é configurada POR TELEFONE, dentro da Uazapi. Se a de
//  um deles estiver vazia ou errada, NADA chega à ponte — nenhum log, nenhum
//  descarte, nenhuma recusa. E o envio continua funcionando.
//
//  Nenhuma lista de erro responde isso, porque não há erro: há AUSÊNCIA. A
//  única forma de enxergar ausência é comparar com quem está presente.
{
  console.log("\nQual telefone está mudo");

  const DOIS = [
    { id: "adv-1", nome: "Comercial 1932", numero: "5567900001932", token: "t1",
      servidor: null, ativo: true, departamento_id: 1 },
    { id: "adv-2", nome: "Comercial 3857", numero: "5567900003857", token: "t2",
      servidor: null, ativo: true, departamento_id: 1 },
  ];
  const t = await subirTudo({}, { tabelas: { advogados: DOIS } });

  // Só o 1932 manda evento. O 3857 fica calado — é o cenário relatado.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...mensagemDaUazapi("oi", "mudo-1"), owner: "5567900001932" }),
  });
  await espera(700);

  const d = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/telefones`)).json();
  const por = Object.fromEntries((d.telefones || []).map((l) => [l.numero, l]));

  ok("lista TODOS os telefones cadastrados, não só os com problema",
     (d.telefones || []).length === 2, JSON.stringify(d.telefones));
  ok("quem mandou evento aparece como falante", por["5567900001932"]?.mudo === false,
     JSON.stringify(por["5567900001932"]));
  ok("e quem não mandou aparece como MUDO", por["5567900003857"]?.mudo === true,
     JSON.stringify(por["5567900003857"]));
  ok("o mudo vem primeiro na lista", d.telefones[0].numero === "5567900003857",
     JSON.stringify(d.telefones.map((l) => l.numero)));

  // A HONESTIDADE DA TABELA. A contagem vive na memória e zera a cada
  // publicação. Uma ponte que subiu agora mostra todo mundo mudo, e isso não
  // quer dizer nada — sem esta ressalva, a tabela seria lida como diagnóstico
  // quando ainda é um cronômetro começando, e alguém iria mexer no webhook de
  // um telefone que estava certo.
  ok("diz há quanto tempo a ponte está no ar", typeof d.ponte_no_ar_ha_minutos === "number");
  ok("e AVISA que é cedo demais para concluir", /cedo|Espere/i.test(d.recado || ""),
     d.recado);

  // O outro lado da mesma pergunta: quem manda evento e não está cadastrado.
  await fetch(`http://127.0.0.1:${t.porta}/webhook`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...mensagemDaUazapi("oi", "mudo-2"), owner: "5567911112222" }),
  });
  await espera(700);
  const d2 = await (await fetch(`http://127.0.0.1:${t.porta}/webhook/telefones`)).json();
  ok("e mostra quem mandou evento sem estar cadastrado",
     (d2.mandaram_evento_e_nao_estao_cadastrados || []).includes("5567911112222"),
     JSON.stringify(d2.mandaram_evento_e_nao_estao_cadastrados));

  // O EVENTO É ANOTADO MESMO QUANDO A MENSAGEM É DESCARTADA. É o que separa
  // "não chega" de "chega e cai" — as duas parecem iguais de fora e pedem
  // coisas completamente diferentes de quem for arrumar.
  ok("anota o evento mesmo do telefone não cadastrado (chegou, mas caiu)",
     (d2.mandaram_evento_e_nao_estao_cadastrados || []).length >= 1);

  await t.parar();
}

// ==================================================================
//  A NOTA INTERNA SOBE PARA O VANTORO
// ==================================================================
//
//  A equipe escreve a nota dentro da conversa, que é onde ela está quando
//  descobre o que precisa anotar. Mas quem for procurar aquilo meses depois vai
//  à ficha do cliente, ou ao histórico do processo.
//
//  O VÍNCULO É SEMPRE COM O CLIENTE; o processo é opcional, e serve para achar
//  a informação depois.
{
  console.log("\nA nota interna sobe para o Vantoro");

  const t = await subirTudo({}, { vantoro: {
    usuarios: [{ id: 1, login: "ana", nome: "Ana Aguiar" }] } });

  async function mandarNota(corpo) {
    return fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
      method: "POST",
      headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
      body: JSON.stringify(corpo),
    });
  }

  const r = await mandarNota({ id: "n-1", texto: "Cliente vai mandar o RG" });
  ok("a ponte aceita e responde", r.status === 200, `veio ${r.status}`);

  const recebida = t.van.recebidas.find((x) => x.caminho === "/clientes/7/nota");
  ok("e chama o endereço certo do Vantoro", !!recebida,
     JSON.stringify(t.van.recebidas.map((x) => x.caminho)));
  ok("levando o texto", recebida?.corpo?.texto === "Cliente vai mandar o RG");
  ok("e o id da nota, que é o elo entre os dois", recebida?.corpo?.id === "n-1",
     "sem ele, editar cria uma segunda em vez de reescrever");

  // O PROCESSO É OPCIONAL — a "nota geral" do cliente é o caso comum.
  ok("sem processo, manda null e não inventa um",
     recebida?.corpo?.processo_id === null, JSON.stringify(recebida?.corpo));

  await t.parar();
}

console.log("\nCom processo, ele vai junto");
{
  const t = await subirTudo({}, { vantoro: {} });
  await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
    method: "POST",
    headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
    body: JSON.stringify({ id: "n-2", texto: "sobre a ação", processo_id: 42 }),
  });
  const recebida = t.van.recebidas.find((x) => x.caminho === "/clientes/7/nota");
  ok("o processo escolhido chega ao Vantoro", recebida?.corpo?.processo_id === 42,
     JSON.stringify(recebida?.corpo));
  await t.parar();
}

console.log("\nO AUTOR É DECIDIDO NA PONTE, e não recebido do navegador");
{
  // É a mesma regra do histórico de alterações: a ponte confere o login antes
  // de deixar passar, então é aqui que se sabe QUEM é quem. Um histórico em que
  // o autor é o que o navegador disse ser não responde "quem escreveu isto?" —
  // e num escritório de advocacia essa é a pergunta que se faz.
  const t = await subirTudo({}, {
    vantoro: {},
    contas: [{ id: "u1", email: "rodrigo@x", jwt: "jwt-bom",
               user_metadata: { nome: "Rodrigo Alves" } }],
  });
  await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
    method: "POST",
    headers: { Authorization: "Bearer jwt-bom", "Content-Type": "application/json" },
    body: JSON.stringify({ id: "n-3", texto: "oi", autor: "Eu Sou Outro" }),
  });
  const recebida = t.van.recebidas.find((x) => x.caminho === "/clientes/7/nota");
  ok("o autor é quem está logado", recebida?.corpo?.autor === "Rodrigo Alves",
     `foi como "${recebida?.corpo?.autor}"`);
  ok("e NÃO o que o navegador mandou", recebida?.corpo?.autor !== "Eu Sou Outro",
     "qualquer um assinaria com o nome de qualquer um");
  await t.parar();
}

console.log("\nSem login, a nota não passa");
{
  const t = await subirTudo({}, { vantoro: {} });
  const r = await fetch(`http://127.0.0.1:${t.porta}/vantoro/cliente/7/nota`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id: "n-4", texto: "oi" }),
  });
  ok("recusa sem sessão", r.status === 401, `veio ${r.status}`);
  ok("e nada chega ao Vantoro",
     !t.van.recebidas.some((x) => x.caminho === "/clientes/7/nota"));
  await t.parar();
}

console.log(`\n${feitas - falhas}/${feitas} conferências passaram`);
process.exit(falhas ? 1 : 0);
