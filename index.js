// ============================================================
//  ZORVIN by Ropelimi — Ponte (middleware)
//  Liga o WhatsApp (via Uazapi) ao banco do Zorvin (Supabase).
//
//  Faz duas coisas:
//   1) RECEBE mensagens do WhatsApp e guarda no banco.
//   2) ENVIA respostas: lê a "fila de envio" que o painel preenche
//      e manda cada mensagem pela Uazapi.
// ============================================================

const express = require('express');
const { createClient } = require('@supabase/supabase-js');

const app = express();
app.use(express.json({ limit: '15mb' }));

// Rede de segurança: um erro assíncrono não tratado NÃO pode derrubar a ponte
// (é um único processo no plano free do Render). Registra e segue vivo.
process.on('unhandledRejection', (err) => {
  console.error('unhandledRejection:', (err && err.message) || err);
});
process.on('uncaughtException', (err) => {
  console.error('uncaughtException:', (err && err.message) || err);
});

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// fetch com timeout: evita que uma chamada à Uazapi fique pendurada e
// segure a fila. Aborta após `ms` milissegundos.
async function fetchComTimeout(url, opts = {}, ms = 15000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { ...opts, signal: ctrl.signal });
  } finally {
    clearTimeout(t);
  }
}

// ============================================================
//  GRUPO É UMA CONVERSA SÓ — e não uma por participante.
//
//  O erro que isto conserta: mensagem de GRUPO virava conversa nova.
//
//  A ponte tratava todo chat como pessoa. Num grupo, isso dá dois estragos
//  diferentes, e os dois foram vistos:
//
//    - mensagem que NÓS mandamos ao grupo (fromMe) tinha como "contato" o
//      identificador do grupo, que não é telefone de ninguém. Nascia uma
//      conversa com nome de número esquisito ("+70929710"), separada do grupo;
//    - mensagem RECEBIDA no grupo tinha como "contato" o PARTICIPANTE. Um grupo
//      de cinco pessoas ia virando cinco conversas de um-para-um, cada uma com
//      um pedaço da mesma discussão.
//
//  A identidade certa de um grupo é o JID dele (`...@g.us`): ele não muda
//  quando o grupo é renomeado, e é o mesmo para todo mundo lá dentro. Guardamos
//  como `grupo:<jid>` em `contatos.numero` — o mesmo prefixo que a importação de
//  histórico já usava, então o painel continua reconhecendo grupo do mesmo jeito.
// ============================================================
function chatDaMensagem(body, m) {
  const chat = body.chat || {};
  const candidatos = [chat.id, chat.jid, chat.chatid, m && m.chatid, m && m.chatId]
    .filter(Boolean).map(String);
  const jid = candidatos.find((c) => c.toLowerCase().includes('@g.us'));
  const marcado = chat.isGroup === true || body.isGroup === true || (m && m.isGroup === true);

  if (jid || marcado) {
    // Sem o JID não dá para inventar uma chave estável — e chave instável é
    // exatamente o defeito que estamos consertando. Melhor deixar seguir pelo
    // caminho de sempre do que criar um grupo por mensagem.
    if (!jid) return { ehGrupo: false, chave: numeroRealDoContato(body, m), nome: null };
    return {
      ehGrupo: true,
      chave: 'grupo:' + jid.split('@')[0].toLowerCase(),
      // O nome do GRUPO vem do chat, e vale inclusive em mensagem nossa: aqui
      // `chat.name` é o nome do grupo, e não o do advogado (que é o motivo de o
      // nome ser ignorado em fromMe nas conversas de uma pessoa só).
      nome: chat.name || chat.wa_name || chat.subject || chat.pushName || null,
    };
  }
  return { ehGrupo: false, chave: numeroRealDoContato(body, m), nome: null };
}

// Quem escreveu ESTA mensagem dentro do grupo. Sem isto, a conversa do grupo
// vira um monólogo de balões sem autor — que é como se lê uma discussão de
// cinco pessoas quando ninguém está identificado.
function autorNoGrupo(body, m) {
  if (m && m.fromMe) return 'WhatsApp';
  const nome = (m && m.senderName) || (body.chat && body.chat.wa_name) || '';
  if (nome && !/^\+?\d[\d\s()-]*$/.test(nome)) return String(nome).slice(0, 80);
  const fone = String((m && (m.sender_pn || m.sender)) || '').split('@')[0].replace(/\D/g, '');
  return fone ? '+' + fone : 'Participante';
}

// ------------------------------------------------------------
//  O QUE JÁ FOI GRAVADO ERRADO SE JUNTA SOZINHO
//
//  Consertar daqui para a frente não resolve o que a equipe está vendo hoje: o
//  mesmo grupo espalhado em duas ou três conversas, cada uma com um pedaço da
//  discussão. Pedir um SQL para isso seria empurrar para quem não escreve SQL o
//  conserto de um erro nosso.
//
//  Então a primeira mensagem que chegar do grupo depois deste deploy junta tudo:
//  acha as conversas antigas daquele grupo, muda as mensagens delas para a
//  conversa boa e apaga o que ficou vazio. Roda uma vez por grupo — depois disso
//  não há mais o que achar.
//
//  Os dois rastros que o erro deixou, e como cada um é reconhecido:
//    1. os DÍGITOS CRUS do JID, virados "telefone" (a conversa "+70929710");
//    2. o grupo IMPORTADO do histórico, que tem chave `grupo:<hash do nome>` —
//       reconhecido pelo NOME, que é o único dado que os dois têm em comum.
//
//  O caso 2 só junta quando há UM candidato com aquele nome exato. Dois grupos
//  de mesmo nome é o momento de não adivinhar: fica como está, e o log diz.
// ------------------------------------------------------------
async function juntarConversasDoGrupo(advId, chave, jidDigitos, nome) {
  // O rastro 1 nem sempre são os dígitos INTEIROS do JID: no caso que motivou
  // este conserto, a conversa nasceu como "+70929710" — um PEDAÇO do fim do
  // identificador do grupo. Então procuramos por todas as terminações dele.
  //
  // E só entram as SEM NOME. É a diferença entre juntar o estrago e destruir
  // dado bom: a mensagem que NÓS mandamos criou contato sem nome nenhum (é o
  // sintoma), enquanto a recebida criou contato com o nome do PARTICIPANTE — e
  // esse é uma pessoa de verdade, que provavelmente tem conversa de um-para-um
  // com o escritório. Juntar essa apagaria a conversa dela.
  const terminacoes = [];
  for (let n = 6; n <= jidDigitos.length; n++) terminacoes.push(jidDigitos.slice(-n));

  const { data: achados, error } = await supabase
    .from('contatos').select('id, numero, nome')
    .in('numero', [chave, ...terminacoes]);
  if (error) { console.log(`Grupo: não consegui procurar as conversas antigas (${error.message}).`); return; }

  const candidatos = (achados || []).filter((c) => c.numero === chave || !c.nome);
  if (nome) {
    const { data: porNome } = await supabase
      .from('contatos').select('id, numero, nome')
      .like('numero', 'grupo:%').eq('nome', nome);
    const outros = (porNome || []).filter((c) => c.numero !== chave);
    if (outros.length === 1) candidatos.push(outros[0]);
    else if (outros.length > 1) {
      console.log(`Grupo "${nome}": ${outros.length} conversas com esse nome — não juntei, `
                + 'para não misturar grupos diferentes de mesmo nome.');
    }
  }
  const antigos = candidatos.filter((c) => c.numero !== chave);
  if (!antigos.length) return;

  // O contato DEFINITIVO: o que já tem a chave certa; se não existe nenhum,
  // promove o primeiro antigo (renomear preserva as mensagens dele).
  let bom = candidatos.find((c) => c.numero === chave) || null;
  if (!bom) {
    bom = antigos.shift();
    const { error: erroRen } = await supabase
      .from('contatos').update({ numero: chave, nome: nome || bom.nome }).eq('id', bom.id);
    if (erroRen) { console.log(`Grupo: não consegui promover a conversa antiga (${erroRen.message}).`); return; }
    console.log(`Grupo "${nome || chave}": a conversa "${bom.numero}" era o mesmo grupo — passou a ser a conversa dele.`);
    bom = { ...bom, numero: chave };
    if (!antigos.length) return;
  }

  const { data: convBoa } = await supabase
    .from('conversas').select('id').eq('advogado_id', advId).eq('contato_id', bom.id).maybeSingle();
  if (!convBoa) return;   // ainda não existe; a mensagem de agora vai criá-la

  for (const velho of antigos) {
    const { data: convs } = await supabase
      .from('conversas').select('id').eq('advogado_id', advId).eq('contato_id', velho.id);
    for (const cv of convs || []) {
      if (cv.id === convBoa.id) continue;
      const { erro: erroMove } = await mudarDeConversa(cv.id, convBoa.id);
      if (erroMove) { console.log(`Grupo: não consegui mover as mensagens (${erroMove}).`); continue; }
      await supabase.from('conversas').delete().eq('id', cv.id);
      console.log(`Grupo "${nome || chave}": juntei as mensagens de "${velho.numero}" na conversa do grupo.`);
    }
    // O contato antigo só sai se não sobrou conversa nenhuma nele (ele pode ser
    // de outro telefone do escritório, e aí não é nosso para apagar).
    const { data: sobrou } = await supabase
      .from('conversas').select('id').eq('contato_id', velho.id).limit(1);
    if (!sobrou || !sobrou.length) await supabase.from('contatos').delete().eq('id', velho.id);
  }
}

// ------------------------------------------------------------
//  MUDAR TUDO DE UMA CONVERSA PARA OUTRA
//
//  Juntar duas conversas é mover o que está pendurado nelas — e o que está
//  pendurado não é só a mensagem. A NOTA INTERNA (o combinado da equipe, que
//  nunca foi para o WhatsApp), a ETIQUETA e o ENVIO QUE AINDA ESTÁ NA FILA
//  moram em tabelas separadas, todas apontando para `conversa_id`. Mover só as
//  mensagens e apagar a conversa levava as outras três junto, em silêncio: o
//  banco apaga em cascata, e ninguém fica sabendo que a nota sumiu.
//
//  A etiqueta é o único caso com regra própria: se a conversa de destino JÁ tem
//  aquela etiqueta, a da origem é descartada em vez de movida — senão a mesma
//  etiqueta apareceria duas vezes na mesma conversa.
//
//  O "não lidas" das duas se soma. A conversa que sai pode ter mensagem que
//  ninguém leu, e essas mensagens continuam existindo depois da junção; zerar
//  a conta faria a equipe passar por elas sem ver.
//
//  `notas` e `fila_envio` podem não existir numa instalação mais antiga. O erro
//  delas é registrado e a junção segue — perder a nota é ruim, mas parar no
//  meio, com as mensagens já movidas, seria pior.
// ------------------------------------------------------------
async function mudarDeConversa(origemId, destinoId) {
  const { count, error } = await supabase
    .from('mensagens').update({ conversa_id: destinoId }, { count: 'exact' })
    .eq('conversa_id', origemId);
  if (error) return { erro: error.message };

  for (const tabela of ['notas', 'fila_envio']) {
    const { error: e } = await supabase
      .from(tabela).update({ conversa_id: destinoId }).eq('conversa_id', origemId);
    if (e) console.log(`Junção: não movi "${tabela}" (${e.message}).`);
  }

  const { data: doDestino } = await supabase
    .from('conversa_tags').select('tag_id').eq('conversa_id', destinoId);
  const jaTem = new Set((doDestino || []).map((t) => t.tag_id));
  const { data: daOrigem } = await supabase
    .from('conversa_tags').select('tag_id').eq('conversa_id', origemId);
  for (const t of daOrigem || []) {
    const { error: e } = jaTem.has(t.tag_id)
      ? await supabase.from('conversa_tags').delete()
          .eq('conversa_id', origemId).eq('tag_id', t.tag_id)
      : await supabase.from('conversa_tags').update({ conversa_id: destinoId })
          .eq('conversa_id', origemId).eq('tag_id', t.tag_id);
    if (e) console.log(`Junção: não movi a etiqueta (${e.message}).`);
  }

  const { data: duas } = await supabase
    .from('conversas').select('id, nao_lidas').in('id', [origemId, destinoId]);
  const soma = (duas || []).reduce((t, c) => t + (c.nao_lidas || 0), 0);
  if (soma) await supabase.from('conversas').update({ nao_lidas: soma }).eq('id', destinoId);

  return { movidas: count || 0 };
}

// ------------------------------------------------------------
//  Descobre o telefone REAL do contato, ignorando o "@lid"
//  (identificador de privacidade da WhatsApp que criava contatos e
//  conversas duplicados). Para mensagens que NÓS enviamos (fromMe),
//  o contato é o "chat"; para recebidas, é o remetente (sender_pn).
// ------------------------------------------------------------
function numeroRealDoContato(body, m) {
  const chatPhone = body.chat && body.chat.phone;
  const chatId = body.chat && body.chat.id;
  // Em mensagens que NÓS enviamos (fromMe), o remetente (sender_pn/sender) é o
  // ADVOGADO — nunca pode ser usado como número do contato. O contato é sempre
  // o "chat". Em mensagens recebidas, o contato é o remetente.
  const fontes = (m && m.fromMe)
    ? [chatPhone, chatId]
    : [m && m.sender_pn, chatPhone, chatId, m && m.sender];
  const limpos = fontes.filter(Boolean).map(String);
  // 1ª passada: só telefone real (ignora @lid).
  for (const f of limpos) {
    if (f.includes('@lid')) continue;
    const num = f.split('@')[0].replace(/\D/g, '');
    if (num.length >= 8) return num;
  }
  // 2ª passada: qualquer coisa com dígitos suficientes (última tentativa).
  for (const f of limpos) {
    const num = f.split('@')[0].replace(/\D/g, '');
    if (num.length >= 8) return num;
  }
  return null;
}

// ------------------------------------------------------------
//  Verificação de saúde (usada pelo cronjob para não "dormir").
// ------------------------------------------------------------
app.get('/', (req, res) => {
  res.status(200).send('Zorvin bridge online');
  // Aproveita CADA acesso (o cronjob que mantém a ponte acordada E o "toque"
  // que o painel dá ao enviar) para despachar a fila na hora. Assim, se a
  // ponte tinha acabado de acordar, as mensagens não ficam "carregando"
  // esperando o próximo ciclo do setInterval.
  processarFilaDeEnvio().catch(() => {});
});

// Endereço enxuto para o cronjob de keep-alive: responde 200 com corpo VAZIO
// (evita o "output too large" que desativava o job no cron-job.org) e ainda
// aproveita para despachar a fila. Aponte o cronjob para .../ping.
app.get('/ping', (req, res) => {
  res.status(200).end();
  processarFilaDeEnvio().catch(() => {});
});

// ------------------------------------------------------------
//  IMPORTAR HISTÓRICO de um contato (backfill via Uazapi /message/find).
//  Uso administrativo e MANUAL — protegido por senha (env IMPORT_TOKEN).
//  Ex.: /importar-historico?token=SENHA&advogado=5511...&contato=5511...&limite=500
//  Seguro rodar de novo: id_uazapi é único, então não duplica.
// ------------------------------------------------------------
// QUE TIPO DE MENSAGEM É ESTA — um lugar só, para o webhook e para a
// importação de histórico.
//
// Eram dois lugares. O do webhook só olhava `mediaType`, e só quando `type`
// era exatamente 'media'; qualquer outro formato caía em 'texto', e uma
// figurinha — que não tem texto — era descartada logo depois como "evento sem
// conteúdo". Sumia dos dois lados: nada na conversa e nada no log dizendo que
// uma figurinha havia chegado.
//
// Agora olha os três campos, como a importação já fazia. E um anexo que a
// Uazapi anuncie de um jeito novo vira documento: um botão de baixar é melhor
// que uma bolha vazia, e muito melhor que a mensagem desaparecer.
function tipoDaMensagem(m) {
  const mt = String(m.mediaType || m.messageType || m.type || '').toLowerCase();
  if (mt.includes('sticker') || mt.includes('figurinha')) return 'figurinha';
  if (mt.includes('image')) return 'imagem';
  if (mt === 'ptt' || mt.includes('audio') || mt.includes('voice')) return 'audio';
  if (mt.includes('video')) return 'video';
  if (mt.includes('document') || mt.includes('file')) return 'documento';
  if (m.type === 'media') return 'documento';
  return 'texto';
}
const tipoDaMidiaHist = tipoDaMensagem;
function previaMidiaHist(tipo) {
  if (tipo === 'figurinha') return '🩹 Figurinha';
  if (tipo === 'imagem') return '📷 Foto';
  if (tipo === 'audio') return '🎤 Mensagem de voz';
  if (tipo === 'video') return '🎬 Vídeo';
  if (tipo === 'documento') return '📄 Documento';
  return '';
}
// Converte uma mensagem do /message/find no formato da nossa tabela "mensagens".
function mapearMensagemHistorico(m, conversaId) {
  const idUazapi = m.messageid || m.id || (m.key && m.key.id) || null;
  if (!idUazapi) return null;
  const fromMe = m.fromMe === true || (m.key && m.key.fromMe === true);
  const tipo = tipoDaMidiaHist(m);
  const texto = m.text || (typeof m.content === 'string' ? m.content : '') || m.caption || null;
  const midiaUrl = m.fileURL || m.mediaUrl || m.url || null;
  const midiaMime = m.mimetype || (m.content && m.content.mimetype) || null;
  // Horário original: pode vir em segundos ou milissegundos.
  let ts = m.messageTimestamp || m.timestamp || m.momment || m.t || null;
  const linha = {
    conversa_id: conversaId,
    origem: fromMe ? 'advogado' : 'contato',
    tipo,
    texto,
    midia_url: midiaUrl,
    midia_mime: midiaMime,
    id_uazapi: idUazapi,
    status: fromMe ? 'enviada' : 'recebida',
  };
  if (ts) {
    ts = Number(ts);
    if (ts > 0) {
      if (ts < 1e12) ts = ts * 1000; // segundos -> ms
      linha.criado_em = new Date(ts).toISOString();
    }
  }
  return linha;
}

app.get('/importar-historico', async (req, res) => {
  try {
    const senha = process.env.IMPORT_TOKEN;
    if (!senha || req.query.token !== senha) {
      return res.status(403).send('Acesso negado. Configure IMPORT_TOKEN e informe ?token= correto.');
    }
    const advogadoNumero = String(req.query.advogado || '').replace(/\D/g, '');
    const contatoNumero = String(req.query.contato || '').replace(/\D/g, '');
    const limiteTotal = Math.min(parseInt(req.query.limite || '500', 10) || 500, 5000);
    if (!advogadoNumero || !contatoNumero) {
      return res.status(400).send('Informe advogado e contato (só números).');
    }

    const { data: adv } = await supabase.from('advogados')
      .select('id, token, servidor').eq('numero', advogadoNumero).maybeSingle();
    if (!adv || !adv.token) return res.status(404).send('Advogado não encontrado (ou sem token) no banco.');

    // Garante contato e conversa.
    const { data: contUp } = await supabase.from('contatos')
      .upsert({ numero: contatoNumero }, { onConflict: 'numero' }).select('id').single();
    const { data: conv } = await supabase.from('conversas')
      .upsert({ advogado_id: adv.id, contato_id: contUp.id }, { onConflict: 'advogado_id,contato_id' })
      .select('id').single();

    const servidor = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
    const PAG = 100;

    // Busca uma página do histórico; tenta os dois formatos de "chatid".
    async function buscarPagina(chatid, offset) {
      const r = await fetchComTimeout(`${servidor}/message/find`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'token': adv.token },
        body: JSON.stringify({ chatid, limit: PAG, offset }),
      }, 25000);
      if (!r.ok) { console.error('message/find HTTP', r.status); return null; }
      const dados = await r.json().catch(() => ({}));
      if (Array.isArray(dados)) return dados;
      return dados.messages || dados.data || dados.results || [];
    }

    // Descobre qual sufixo de chatid a Uazapi aceita (varia por versão).
    let chatid = `${contatoNumero}@s.whatsapp.net`;
    let primeira = await buscarPagina(chatid, 0);
    if (!primeira || primeira.length === 0) {
      const alt = `${contatoNumero}@c.us`;
      const tent = await buscarPagina(alt, 0);
      if (tent && tent.length) { chatid = alt; primeira = tent; }
    }

    let importadas = 0, vistas = 0, offset = 0;
    let pagina = primeira || [];
    while (pagina && pagina.length && vistas < limiteTotal) {
      for (const m of pagina) {
        const linha = mapearMensagemHistorico(m, conv.id);
        if (!linha) continue;
        const erro = await salvarMensagem(linha, null);
        if (!erro) importadas++;
      }
      vistas += pagina.length;
      offset += pagina.length;
      if (pagina.length < PAG) break; // última página
      pagina = await buscarPagina(chatid, offset);
    }

    // Conserta a conversa: ordena pela mensagem mais recente e zera "não lidas"
    // (histórico importado não é mensagem nova).
    const { data: ult } = await supabase.from('mensagens')
      .select('texto, tipo, criado_em').eq('conversa_id', conv.id)
      .order('criado_em', { ascending: false }).limit(1);
    const u = ult && ult[0];
    if (u) {
      await supabase.from('conversas').update({
        ultima_mensagem: u.texto || previaMidiaHist(u.tipo) || '[mídia]',
        ultima_atividade: u.criado_em,
        nao_lidas: 0,
      }).eq('id', conv.id);
    }

    console.log(`Histórico: ${importadas} importadas de ${vistas} vistas (contato ${contatoNumero}).`);
    return res.status(200).send(
      `Pronto! Importei ${importadas} mensagem(ns) do contato ${contatoNumero} ` +
      `(vistas ${vistas}). Abra o painel para conferir.`
    );
  } catch (e) {
    console.error('Erro ao importar histórico:', e.message);
    return res.status(500).send('Erro ao importar: ' + e.message);
  }
});

// ============================================================
//  PARTE 1 — RECEBER mensagens
// ============================================================
//
// QUEM PODE ESCREVER AQUI.
//
// Este endereço não pedia nada. Qualquer pessoa que descobrisse a URL da ponte
// podia mandar um POST e a mensagem entrava no banco como se tivesse chegado do
// cliente: aparecia na conversa, contava no Painel, e ficava no histórico do
// escritório. Num escritório de advocacia isso não é um incômodo — é um
// registro forjado.
//
// A trava é um segredo combinado, aceito de duas formas (na URL ou no
// cabeçalho), porque nem todo provedor deixa mandar cabeçalho no webhook.
//
// ENQUANTO `WEBHOOK_TOKEN` NÃO ESTIVER CONFIGURADO, tudo passa — e a ponte
// avisa no log. É de propósito: ligar a exigência antes de o endereço na Uazapi
// ter o segredo faria as mensagens dos clientes pararem de chegar, em silêncio.
// A ordem certa é: primeiro põe o `?token=` no endereço da Uazapi, depois cria
// a variável aqui.
let avisouSemSegredo = false;
function webhookAutorizado(req) {
  const esperado = String(process.env.WEBHOOK_TOKEN || '').trim();
  if (!esperado) {
    if (!avisouSemSegredo) {
      avisouSemSegredo = true;
      console.warn(
        'ATENÇÃO: /webhook está SEM segredo. Qualquer um que saiba o endereço ' +
        'pode inserir mensagens. Configure WEBHOOK_TOKEN (e ponha ?token=… no ' +
        'endereço do webhook na Uazapi).');
    }
    return true;
  }
  const veio = String(
    req.query.token || req.headers['x-webhook-token'] || req.headers['x-api-key'] || '').trim();
  // Comparação de tamanho fixo não faz diferença prática aqui (o segredo vai na
  // URL, e o atacante não tem como medir microssegundos pela internet), mas o
  // custo de fazer certo é zero.
  if (veio.length !== esperado.length) return false;
  let diferenca = 0;
  for (let i = 0; i < esperado.length; i += 1) diferenca |= veio.charCodeAt(i) ^ esperado.charCodeAt(i);
  return diferenca === 0;
}

app.post('/webhook', async (req, res) => {
  if (!webhookAutorizado(req)) {
    console.warn('Webhook recusado: segredo ausente ou errado.');
    return res.status(403).send('nao autorizado');
  }
  res.status(200).send('OK'); // responde rápido para a Uazapi não reenviar

  try {
    const body = req.body;
    const evento = (body.EventType || body.event || '').toLowerCase();

    // Eventos que NÃO são mensagens: status (entregue/lida) e presença
    // ("digitando…"). Tentamos tratar os dois; nada quebra se não reconhecer.
    if (evento && evento !== 'messages') {
      await tratarPresenca(body, evento);
      await tratarStatusMensagem(body, evento);
      return;
    }

    if (evento !== 'messages' || !body.message) return;

    const m = body.message;

    // Se a mensagem foi enviada pelo próprio Zorvin (pela API), a ponte já
    // registrou ela no banco na hora do envio. Este aviso é só um "eco" —
    // ignoramos para não duplicar.
    if (m.wasSentByApi === true) {
      console.log('Eco de mensagem enviada pelo Zorvin; ignorado.');
      return;
    }

    // De qual ADVOGADO é esta conversa (owner = número do dono da instância).
    // Normaliza para só dígitos (igual ao contato), senão um owner formatado
    // não bate com o cadastro e a mensagem seria descartada.
    const advogadoNumero = String(body.owner || m.owner || '').replace(/\D/g, '');
    // select('*') em vez da lista de colunas: assim a frente_fixa (números de
    // uso interno, como RH e cadastro) vem junto sem quebrar quem ainda não
    // rodou o SQL das frentes — pedir uma coluna inexistente daria erro e a
    // mensagem seria descartada.
    const { data: adv, error: advErro } = await supabase
      .from('advogados')
      .select('*')
      .eq('numero', advogadoNumero)
      .maybeSingle();
    if (advErro) { console.error('Erro ao buscar advogado:', advErro.message); return; }
    if (!adv) { console.log('Número não cadastrado em advogados:', advogadoNumero); return; }

    // Quem é o CONTATO — SEMPRE o telefone real, ignorando o identificador de
    // privacidade "@lid" que a WhatsApp passou a enviar (ele criava um segundo
    // contato/conversa para a MESMA pessoa).
    // GRUPO ou pessoa: a identidade do grupo é o JID dele, e não o telefone de
    // quem escreveu (recebida) nem o do próprio grupo virado número (enviada).
    const chat = chatDaMensagem(body, m);
    const contatoNumero = chat.chave;
    if (!contatoNumero) {
      console.log('Sem número de contato; ignorando.', JSON.stringify(body).slice(0, 250));
      return;
    }
    // `chat.id` no log porque e ELE que decide se a mensagem e de grupo. Quando
    // uma conversa de grupo nascer errada de novo, esta linha diz por que — sem
    // ela, o diagnostico depende de adivinhar o formato que a Uazapi mandou.
    console.log(`Contato ${contatoNumero}${chat.ehGrupo ? ' (grupo)' : ''} | `
              + `chat.id=${(body.chat && body.chat.id) || '—'} | `
              + `chat.phone=${body.chat && body.chat.phone} | sender_pn=${m.sender_pn} | fromMe=${m.fromMe}`);

    // Antes de gravar, junta o que este mesmo grupo deixou espalhado enquanto o
    // erro existia. Não bloqueia a mensagem: se falhar, ela entra igual e a
    // próxima tenta de novo.
    if (chat.ehGrupo) {
      const jidDigitos = contatoNumero.replace('grupo:', '').replace(/\D/g, '');
      await juntarConversasDoGrupo(adv.id, contatoNumero, jidDigitos, chat.nome).catch(() => {});
    }

    // Foto de perfil do contato (vem no próprio webhook, no chat).
    const fotoContato =
      (body.chat && (body.chat.imagePreview || body.chat.imgUrl || body.chat.image || body.chat.profilePicUrl || body.chat.profilePictureUrl)) || null;

    // NOME do contato: só confiamos em mensagens RECEBIDAS. Numa mensagem fromMe
    // (o advogado escrevendo pelo próprio WhatsApp), os campos de nome trazem o
    // nome do ADVOGADO (ex.: "Acordos Yunes Kaled"), então NÃO tocamos no nome
    // do contato para não sobrescrever com o dado errado.
    // No GRUPO o nome vem do chat sempre — inclusive em mensagem nossa, porque
    // ali `chat.name` é o nome do grupo. Era isso que fazia a conversa nascer
    // sem nome nenhum e aparecer como "+70929710": a regra de não confiar no
    // nome em `fromMe` existe para conversa de uma pessoa só, onde o campo traz
    // o nome do ADVOGADO.
    const contatoNome = chat.ehGrupo
      ? chat.nome
      : (m.fromMe ? null : ((body.chat && body.chat.wa_name) || m.senderName || null));

    // O MESMO TELEFONE ESCRITO SEM O CÓDIGO DO PAÍS.
    //
    // O painel deixava cadastrar o contato como "11956706171" — o número do
    // jeito que se digita no Brasil, sem o 55. Nós mandávamos a primeira
    // mensagem e ela ia normalmente; quando a pessoa respondia, o WhatsApp
    // devolvia "5511956706171", e aqui, não achando ninguém com esse texto,
    // nascia um SEGUNDO contato e uma SEGUNDA conversa. A resposta aparecia
    // separada da conversa que nós mesmos tínhamos começado.
    //
    // O painel novo já grava com o 55, mas os contatos antigos continuam curtos
    // no banco. Antes de criar qualquer coisa, procuramos a versão curta e,
    // achando, ARRUMAMOS ela — a conversa que já existe segue viva, com o
    // histórico inteiro, e passa a casar com o que o WhatsApp manda.
    //
    // É uma comparação exata (os mesmos dígitos, menos o "55" da frente), e não
    // um "parecido": palpite aqui juntaria conversa de cliente errado.
    if (!chat.ehGrupo && contatoNumero.length > 11 && contatoNumero.startsWith('55')) {
      const semDdi = contatoNumero.slice(2);
      const { data: curto } = await supabase
        .from('contatos').select('id, numero').eq('numero', semDdi).maybeSingle();
      if (curto) {
        const { data: jaTem } = await supabase
          .from('contatos').select('id').eq('numero', contatoNumero).maybeSingle();
        if (jaTem) {
          // Os dois já existem: quem manda é o longo, e o curto some da frente
          // para não voltar a receber nada. Juntar as conversas é decisão de
          // gente — o painel tem "Juntar duas conversas" para isso.
          console.log(`Contato ${semDdi} e ${contatoNumero} coexistem; use "Juntar duas conversas".`);
        } else {
          const { error: arrumou } = await supabase
            .from('contatos').update({ numero: contatoNumero }).eq('id', curto.id);
          console.log(arrumou
            ? `Não consegui pôr o 55 em ${semDdi}: ${arrumou.message}`
            : `Contato ${semDdi} virou ${contatoNumero} (mesma pessoa, agora com o código do país).`);
        }
      }
    }

    // Só inclui foto_url/nome quando temos valor, para não apagar o que já existe.
    const contatoUpsert = { numero: contatoNumero };
    if (contatoNome) contatoUpsert.nome = contatoNome;
    if (fotoContato) contatoUpsert.foto_url = fotoContato;

    // ANTES DE CRIAR, PROCURA O MESMO CELULAR NA OUTRA FORMA DO NONO DÍGITO.
    //
    // O bloco acima resolve o 55; este resolve o 9. O cadastro tem
    // "+55 31 99945-6790" e o WhatsApp devolve "+55 31 9945-6790" — a mesma
    // linha, com um dígito a menos. Sem esta procura nasce um segundo contato,
    // e a resposta do cliente vai parar numa conversa separada daquela em que
    // a equipe escreveu. Foi o caso da MARIA DE JESUS DA SILVA.
    //
    // Achando, o contato existente é PROMOVIDO para o número que o WhatsApp
    // usa: a conversa e o histórico continuam os mesmos, e as próximas
    // mensagens passam a casar. Se os dois já existirem, não se junta nada
    // por conta própria — juntar histórico é decisão de gente, e o painel tem
    // "Juntar duas conversas" para isso.
    let contatoExistente = null;
    if (!chat.ehGrupo) {
      const { data: achados } = await supabase
        .from('contatos').select('id, numero').in('numero', variantesDoNumero(contatoNumero));
      const lista = achados || [];
      contatoExistente = lista.find((c) => c.numero === contatoNumero) || null;
      const outro = lista.find((c) => c.numero !== contatoNumero) || null;
      if (!contatoExistente && outro) {
        const { error: erroPromo } = await supabase
          .from('contatos').update({ numero: contatoNumero }).eq('id', outro.id);
        if (erroPromo) {
          console.log(`Nono dígito: não consegui promover ${outro.numero} (${erroPromo.message}).`);
        } else {
          console.log(`Contato ${outro.numero} virou ${contatoNumero} (mesmo celular, nono dígito).`);
          contatoExistente = { id: outro.id, numero: contatoNumero };
        }
      } else if (contatoExistente && outro) {
        console.log(`Contato ${outro.numero} e ${contatoNumero} são o mesmo celular e coexistem; `
                  + 'use "Juntar duas conversas".');
      }
    }

    // select('*') pelo mesmo motivo do advogado: traz frente/frente_em quando
    // essas colunas já existirem, sem exigir que existam.
    const { data: contato, error: contErro } = await supabase
      .from('contatos')
      .upsert(contatoUpsert, { onConflict: 'numero' })
      .select('*')
      .single();
    if (contErro) { console.error('Erro no contato:', contErro.message); return; }

    // A CONVERSA entre este advogado e este contato.
    const { data: conversa, error: convErro } = await supabase
      .from('conversas')
      .upsert(
        { advogado_id: adv.id, contato_id: contato.id },
        { onConflict: 'advogado_id,contato_id' }
      )
      .select('id')
      .single();
    if (convErro) { console.error('Erro na conversa:', convErro.message); return; }

    // De quem é esta conversa: cliente, advogado da parte contrária, lead…
    // Não bloqueia nada — se falhar, a mensagem entra igual e a etiqueta sai
    // na próxima que chegar.
    // A FRENTE continua sendo gravada na conversa (`conversas.frente`): é o dado
    // que diz de que natureza é aquele atendimento, e o Vantoro o usa. O que
    // saiu foi o GRUPO — a etiqueta colorida que o painel carimbava a partir
    // dela. Ver o bloco "o grupo saiu" mais abaixo.
    await definirFrente(contato, adv, conversa.id, body);

    // REAÇÃO, e não mensagem. Vem antes de tudo o que monta a linha porque uma
    // reação não é uma linha: ela pertence à mensagem que já está na conversa.
    // Se `aplicarReacao` não conseguir prendê-la (mensagem alvo fora do Zorvin,
    // coluna ainda não criada), o código segue e ela vira mensagem, como antes.
    // "ISTO É UMA REAÇÃO?" é uma pergunta diferente de "CONSIGO APLICÁ-LA?",
    // e as duas têm consequências diferentes. Antes eram a mesma: quando a
    // reação não podia ser aplicada, o código seguia adiante e gravava uma
    // mensagem. Na RETIRADA da reação — que chega com todos os campos de texto
    // vazios — isso criava uma BOLHA EM BRANCO na conversa, só com o horário.
    //
    // Agora, se o evento é de reação, ele nunca vira mensagem. Aplicada ou
    // não, o webhook para aqui; o que não deu para ler fica no log.
    const ehEventoDeReacao = /reaction/i.test(String(m.messageType || m.type || ''))
      || (typeof m.reaction === 'string' && m.reaction !== '');
    if (ehEventoDeReacao) {
      const reacao = extrairReacao(m);
      if (reacao) await aplicarReacao(reacao, m.fromMe ? 'advogado' : 'contato');
      else console.log('Reação sem alvo identificável; ignorada (nada foi gravado).');
      return;
    }

    // TIPO da mensagem. Mesma leitura da importação de histórico, agora que
    // as duas usam a mesma função.
    const tipo = tipoDaMensagem(m);

    const origem = m.fromMe ? 'advogado' : 'contato';
    const texto =
      m.text || (typeof m.content === 'string' ? m.content : '') || null;

    // Miniatura embutida (prévia imediata, baixa resolução). Vale para a
    // FIGURINHA também: se o download do arquivo grande falhar, é ela que
    // impede a bolha de nascer vazia.
    let midiaUrl = null;
    if ((tipo === 'imagem' || tipo === 'figurinha') && m.content && m.content.JPEGThumbnail) {
      midiaUrl = 'data:image/jpeg;base64,' + m.content.JPEGThumbnail;
    }
    const midiaMime = (m.content && m.content.mimetype) || null;

    // Mídia em ALTA RESOLUÇÃO: tenta baixar o arquivo real pela Uazapi e
    // salvar no Storage. Se conseguir, usa essa URL; se não, fica a miniatura
    // (ou nada, no caso de áudio) — comportamento de antes, sem quebrar.
    //
    // A condição era `m.type === 'media'`, a mesma que decidia o tipo. Onde a
    // Uazapi anuncia o anexo por outro campo, nem o tipo saía certo nem o
    // arquivo era buscado. Agora quem manda é o tipo já apurado.
    if (tipo !== 'texto') {
      const servidorAdv = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
      const urlReal = await baixarMidiaRecebida(servidorAdv, adv.token, m, midiaMime);
      if (urlReal) midiaUrl = urlReal;
      else console.log(`Anexo (${tipo}) sem arquivo: o download falhou. Mensagem ${m.messageid} fica sem mídia.`);
    }

    // BOLHA EM BRANCO, NUNCA.
    //
    // Texto sem texto e sem mídia não é mensagem: é um evento que não soubemos
    // ler. Gravar cria uma bolha só com o horário — que ninguém consegue
    // interpretar, e que a equipe não tem como apagar pela tela.
    //
    // Vale como rede para além da reação: qualquer evento novo que a Uazapi
    // passe a mandar e que este código ainda não entenda cai aqui, e vira uma
    // linha de log em vez de sujeira na conversa do cliente.
    if (tipo === 'texto' && !texto && !midiaUrl) {
      console.log('Ignorado: evento sem texto e sem mídia. Corpo:', JSON.stringify(m).slice(0, 500));
      return;
    }

    const base = {
      conversa_id: conversa.id,
      origem,
      tipo,
      texto,
      midia_url: midiaUrl,
      midia_mime: midiaMime,
      id_uazapi: m.messageid,
      status: origem === 'contato' ? 'recebida' : 'enviada'
    };
    // Mensagem "fromMe" que chega pelo webhook (e não é eco de envio pela API,
    // que já foi ignorado acima) = foi enviada DIRETO pelo WhatsApp (app do
    // celular ou desktop), fora do Zorvin. Não sabemos qual atendente foi, então
    // marca com um rótulo de sistema para a equipe distinguir na bolha.
    if (origem === 'advogado') base.enviado_por = 'WhatsApp';
    // No grupo, quem escreveu importa em toda mensagem — inclusive nas recebidas,
    // que num grupo vêm de gente diferente a cada linha. É o mesmo campo que a
    // importação de histórico já preenchia, então a bolha mostra igual.
    if (chat.ehGrupo) base.enviado_por = autorNoGrupo(body, m);
    // Se a mensagem recebida é uma RESPOSTA a outra, guarda a citação.
    const extras = extrairResposta(m);
    const msgErro = await salvarMensagem(base, extras);
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    // A CONVERSA ARQUIVADA VOLTA quando o contato escreve.
    //
    // Arquivar quer dizer "por ora, resolvido". Se a pessoa voltou a falar, não
    // está mais resolvido — e uma mensagem que chega numa conversa arquivada
    // fica invisível: não aparece na lista, e ninguém vai procurá-la dentro de
    // Arquivadas. É assim que o WhatsApp se comporta, e é o comportamento que
    // não deixa cliente sem resposta.
    //
    // Só o CONTATO desarquiva. Mensagem nossa, saindo do próprio Zorvin, não
    // deve tirar da pasta o que a equipe acabou de guardar lá.
    //
    // O `.eq('arquivada', true)` evita uma escrita inútil em toda mensagem: só
    // as que estão arquivadas são tocadas.
    if (origem === 'contato') {
      const { data: voltou, error: erroArq } = await supabase.from('conversas')
        .update({ arquivada: false }).eq('id', conversa.id).eq('arquivada', true).select('id');
      if (erroArq) console.log('Não consegui desarquivar (coluna "arquivada"?):', erroArq.message);
      else if (voltou && voltou.length) console.log(`Conversa ${conversa.id} saiu das arquivadas: o contato escreveu.`);
    }

    console.log(`Recebida (${tipo}) de ${contatoNumero} p/ advogado ${advogadoNumero}.`);
    // A ponte está acordada agora: aproveita para despachar qualquer mensagem
    // que estava esperando na fila (não espera o próximo ciclo do setInterval).
    processarFilaDeEnvio().catch(() => {});
  } catch (e) {
    console.error('Erro inesperado no webhook:', e.message);
  }
});

// ------------------------------------------------------------
//  Atualiza o STATUS de uma mensagem que enviamos (entregue/lida).
//  Isso é o que deixa o "tiquinho" azul quando o contato lê.
//
//  ATENÇÃO: o formato exato desses eventos varia entre versões da
//  Uazapi e ainda não foi confirmado em teste. Por isso a função é
//  tolerante (tenta vários formatos) e, quando não reconhece, apenas
//  registra no log — nada quebra. Ao ver no log do Render qual é o
//  formato real, dá para ajustar com precisão.
// ------------------------------------------------------------
async function tratarStatusMensagem(body, evento) {
  try {
    const alvo = body.message || body.update || body.data || body;
    const id =
      alvo.messageid || alvo.id || (alvo.key && alvo.key.id) || body.messageid || null;
    const bruto = alvo.status ?? alvo.ack ?? body.status ?? body.ack;

    // Se não achamos id ou status, registramos para referência e saímos.
    if (!id || bruto === undefined || bruto === null) {
      console.log('Evento não tratado (p/ referência):', evento, JSON.stringify(body).slice(0, 300));
      return;
    }

    const s = String(bruto).toLowerCase();

    // O CONTATO APAGOU UMA MENSAGEM PARA TODOS.
    //
    // No WhatsApp ela sumiria. AQUI ELA FICA. Este é um escritório de
    // advocacia: o que o cliente escreveu é registro do atendimento, e um
    // registro que a outra parte pode apagar depois não serve para nada — nem
    // para conferir um combinado, nem para se defender de uma reclamação.
    //
    // O que muda é só o aviso na bolha: a equipe passa a saber que houve a
    // tentativa. O texto e o anexo continuam intactos.
    //
    // Isto já acontecia por acidente (o status "Deleted" caía em "não mapeado"
    // e nada era alterado). Agora é decisão escrita, para ninguém "consertar"
    // achando que faltava tratar o evento.
    if (s.includes('delet') || s.includes('revok') || s.includes('apagad')) {
      const { error: erroAviso } = await supabase.from('mensagens')
        .update({ apagada_pelo_contato: true })
        .eq('id_uazapi', id).eq('origem', 'contato');
      if (erroAviso && /apagada_pelo_contato/i.test(erroAviso.message || '')) {
        console.log('Falta a coluna "apagada_pelo_contato"? Rode sql/2026-08-apagar-mensagem.sql.');
      } else if (erroAviso) {
        console.log('Não consegui marcar a exclusão do contato:', erroAviso.message);
      } else {
        console.log(`O contato apagou a mensagem ${id} no WhatsApp; ela CONTINUA no Zorvin.`);
      }
      return;
    }

    let novo = null;
    if (s === '3' || s === '4' || s.includes('read') || s.includes('play')) {
      novo = 'lida';
    } else if (s === '2' || s.includes('deliver') || s.includes('entreg')) {
      novo = 'entregue';
    }
    if (!novo) {
      console.log('Status não mapeado (p/ referência):', evento, bruto);
      return;
    }

    const { error } = await supabase
      .from('mensagens')
      .update({ status: novo })
      .eq('id_uazapi', id)
      .eq('origem', 'advogado'); // só marcamos "lida" nas mensagens que enviamos
    if (error) { console.error('Erro ao atualizar status:', error.message); return; }
    console.log(`Status "${novo}" aplicado à mensagem ${id}.`);
  } catch (e) {
    console.error('Erro ao tratar status de mensagem:', e.message);
  }
}

// ------------------------------------------------------------
//  "Digitando…": detecta eventos de presença (composing) da Uazapi e
//  marca conversas.digitando_ate com uma janela curta. O painel mostra
//  "digitando…" enquanto essa data estiver no futuro.
//
//  ATENÇÃO: o formato do evento de presença da Uazapi ainda NÃO foi
//  confirmado. Detectamos "composing"/"paused" de forma tolerante e
//  registramos no log; nada quebra se não reconhecer ou se a coluna
//  digitando_ate ainda não existir.
// ------------------------------------------------------------
async function tratarPresenca(body, evento) {
  try {
    const bruto = JSON.stringify(body).toLowerCase();
    // "digitando" = composing/recording; "parou" = paused/available/unavailable.
    const digitando = bruto.includes('composing') || bruto.includes('recording');
    const parou = bruto.includes('paused') || bruto.includes('available');
    if (!digitando && !parou) return;

    // O número do contato (e do advogado) pode vir em vários campos, dependendo
    // da versão da Uazapi. Tentamos todos os lugares comuns.
    const d = body.data || body.presence || body.chat || {};
    const advogadoNumero = body.owner || d.owner || (body.message && body.message.owner) || null;
    const contatoBruto =
      (body.chat && body.chat.phone) || body.number || body.phone || body.chatId || body.chat_id ||
      body.sender || body.sender_pn || d.phone || d.number || d.chatId || d.chat_id || d.id || body.id || '';
    const contatoNumero = String(contatoBruto).split('@')[0].replace(/\D/g, '');
    if (!advogadoNumero || !contatoNumero) {
      // Não achamos os números: loga o corpo INTEIRO para eu ver os campos reais.
      console.log('Presença: não localizei os números. Corpo:', JSON.stringify(body).slice(0, 500));
      return;
    }

    const { data: adv } = await supabase.from('advogados').select('id').eq('numero', advogadoNumero).maybeSingle();
    if (!adv) return;
    const { data: cont } = await supabase.from('contatos').select('id').eq('numero', contatoNumero).maybeSingle();
    if (!cont) return;

    const ate = digitando
      ? new Date(Date.now() + 8000).toISOString()   // digitando: some em 8s
      : new Date(Date.now() - 1000).toISOString();  // parou: expira já
    const { error } = await supabase.from('conversas')
      .update({ digitando_ate: ate })
      .eq('advogado_id', adv.id).eq('contato_id', cont.id);
    if (error) console.log('digitando_ate (coluna?):', error.message);
    else console.log(`Presença: ${digitando ? 'digitando' : 'parou'} (${contatoNumero}).`);
  } catch (e) {
    console.error('Erro em tratarPresenca:', e.message);
  }
}

// ------------------------------------------------------------
//  Baixa a mídia RECEBIDA (imagem/áudio/vídeo/doc) em alta resolução
//  pela Uazapi e salva no Storage do Supabase. Retorna a URL pública,
//  ou null se não conseguir (aí mantém a miniatura de antes).
//
//  ATENÇÃO: o endpoint/retorno de download da Uazapi ainda não foi
//  confirmado. Tentamos algumas rotas e formatos comuns e registramos
//  no log a estrutura real, para ajustar com precisão depois. Nada
//  quebra se falhar.
// ------------------------------------------------------------
async function baixarMidiaRecebida(servidor, token, m, mimeInformado) {
  try {
    try { console.log('Mídia recebida (content):', JSON.stringify(m.content).slice(0, 600)); } catch (_) { /* ignora */ }
    if (!token || !m.messageid) return null;

    let dados = null;
    for (const rota of ['/message/downloadmedia', '/message/download', '/downloadmedia']) {
      try {
        const r = await fetchComTimeout(`${servidor}${rota}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'token': token },
          body: JSON.stringify({ id: m.messageid })
        }, 20000);
        if (r.ok) {
          dados = await r.json().catch(() => null);
          if (dados) { console.log(`downloadmedia OK via ${rota}`); break; }
        } else {
          console.log(`downloadmedia ${rota} -> ${r.status}`);
        }
      } catch (e) { console.log(`downloadmedia ${rota} erro: ${e.message}`); }
    }
    if (!dados) return null;

    const mime = dados.mimetype || dados.mime || mimeInformado || 'application/octet-stream';
    let bytes = null;
    const b64 = dados.file || dados.data || dados.base64 || dados.media || dados.buffer;
    const urlBaixavel = dados.url || dados.fileURL || dados.fileUrl || dados.link || dados.mediaUrl;
    if (typeof b64 === 'string' && b64.length > 100) {
      bytes = Buffer.from(b64.replace(/^data:[^;]+;base64,/, ''), 'base64');
    } else if (urlBaixavel) {
      const arq = await fetchComTimeout(urlBaixavel, {}, 20000);
      if (arq.ok) bytes = Buffer.from(await arq.arrayBuffer());
    }
    if (!bytes || !bytes.length) {
      console.log('downloadmedia sem arquivo reconhecível:', JSON.stringify(dados).slice(0, 300));
      return null;
    }

    const ext = (String(mime).split('/')[1] || 'bin').split(';')[0];
    const caminho = `recebidos/${m.messageid}.${ext}`;
    const { error: upErr } = await supabase.storage.from('anexos').upload(caminho, bytes, { contentType: mime, upsert: true });
    if (upErr) { console.error('Erro ao salvar mídia recebida no Storage:', upErr.message); return null; }
    const { data: pub } = supabase.storage.from('anexos').getPublicUrl(caminho);
    return pub?.publicUrl || null;
  } catch (e) {
    console.error('Erro em baixarMidiaRecebida:', e.message);
    return null;
  }
}

// ------------------------------------------------------------
//  Extrai o caminho interno do Storage a partir da URL pública.
//  Ex.: https://xxx.supabase.co/storage/v1/object/public/anexos/CAMINHO
//       -> "CAMINHO"
// ------------------------------------------------------------
function caminhoDoStorage(url) {
  if (!url) return null;
  const marca = '/anexos/';
  const i = url.indexOf(marca);
  if (i < 0) return null;
  try { return decodeURIComponent(url.slice(i + marca.length)); }
  catch (_) { return url.slice(i + marca.length); }
}

// ------------------------------------------------------------
//  Grava uma mensagem, tolerando colunas novas que talvez ainda
//  não existam no banco (ex.: as de citação). Se o upsert falhar
//  com os campos extras, tenta de novo só com o básico.
// ------------------------------------------------------------
async function salvarMensagem(base, extras) {
  const temExtras = extras && Object.keys(extras).length > 0;
  const payload = temExtras ? { ...base, ...extras } : base;
  let { error } = await supabase
    .from('mensagens')
    .upsert(payload, { onConflict: 'id_uazapi', ignoreDuplicates: true });
  if (error && temExtras) {
    // Provável coluna inexistente: grava sem os campos de citação.
    console.log('Regravando mensagem sem campos de citação:', error.message);
    ({ error } = await supabase
      .from('mensagens')
      .upsert(base, { onConflict: 'id_uazapi', ignoreDuplicates: true }));
  }
  return error;
}

// ------------------------------------------------------------
//  Detecta se uma mensagem recebida é RESPOSTA (citação) a outra.
//  O formato exato da Uazapi ainda não foi confirmado, então
//  tentamos vários campos comuns; se não achar, retorna null.
// ------------------------------------------------------------
function extrairResposta(m) {
  const ctx =
    m.quoted || m.quotedMsg || m.contextInfo ||
    (m.content && (m.content.contextInfo || m.content.quotedMessage)) || null;
  if (!ctx) return null;
  const idCitada =
    ctx.stanzaId || ctx.quotedId || ctx.id || (ctx.key && ctx.key.id) ||
    m.quotedMessageId || null;
  const texto =
    ctx.text || ctx.body || ctx.caption ||
    (ctx.quotedMessage && (ctx.quotedMessage.conversation || ctx.quotedMessage.text)) ||
    (typeof ctx.quotedMessage === 'string' ? ctx.quotedMessage : null);
  if (!idCitada && !texto) return null;
  return {
    responder_id_uazapi: idCitada || null,
    resposta_previa: texto ? String(texto).slice(0, 120) : null,
    resposta_autor: ctx.fromMe === true ? 'advogado' : 'contato',
  };
}

// ------------------------------------------------------------
//  REAÇÃO: o emoji que alguém prende NUMA MENSAGEM QUE JÁ EXISTE.
//
//  Sem isto, o emoji chegava como se fosse mensagem nova. Na tela aparecia uma
//  bolha solta com "😮" e um horário, sem ligação nenhuma com o que estava
//  sendo respondido — e ainda contava como não lida, então a conversa pedia
//  atenção por causa de um emoji. No celular, a mesma reação aparece presa à
//  bolha, que é o que ela é.
//
//  O FORMATO REAL DA UAZAPI, confirmado por um exemplo de produção:
//
//    { "messageType": "ReactionMessage",
//      "type": "reaction",
//      "reaction": "3EB088E41ADA6D9DDA3B71",     <- ID DA MENSAGEM ALVO
//      "text": "\u{1F622}",
//      "content": { "key": { "ID": "3EB088E41ADA6D9DDA3B71", "fromMe": false },
//                   "text": "\u{1F622}" },
//      "messageid": "3ABE8968E64050E659D5" }     <- id da PRÓPRIA reação
//
//  A armadilha está no nome: o campo `reaction` NÃO é a reação, é o id da
//  mensagem reagida. Foi exatamente por confiar nesse nome que a bolha passou a
//  exibir "3EB080DB9CFFC33549C426" no lugar do emoji. O emoji mora em
//  `content.text` (e também no `text` do topo), e o alvo em `content.key.ID` —
//  com ID em maiúsculas, diferente do resto da API.
//
//  Mesmo com o formato conhecido, a busca continua olhando vários campos e
//  filtrando pelo que TEM CARA DE EMOJI: uma versão nova da Uazapi que mude um
//  nome de campo passa a falhar em silêncio, e não a exibir lixo na conversa.
//  Quando NÃO dá para identificar a mensagem alvo, a reação segue o caminho
//  antigo e vira mensagem: continua feio, mas some sem deixar rastro seria
//  pior.
// ------------------------------------------------------------
// Diz se um texto TEM CARA DE EMOJI. É a trava que faltava.
//
// A primeira versão desta detecção pegou o campo errado do webhook e gravou o
// ID DA MENSAGEM no lugar do emoji: a bolha passou a exibir
// "3EB080DB9CFFC33549C426" numa pastilha, e como um id nunca é vazio, a
// retirada da reação também não apagava nada.
//
// A lição não é "acertar o campo" — é que adivinhar o campo de um formato não
// documentado É a situação normal aqui, e o código tem de recusar o que não
// serve em vez de exibir. Um emoji é curto e não é feito de letras e números
// ASCII; um id de mensagem do WhatsApp tem 20 e poucos caracteres e é só isso.
// O TELEFONE NA FORMA QUE A UAZAPI ESPERA: só dígitos, com o código do país.
//
// Um número de 10 ou 11 dígitos é brasileiro sem o 55 — é assim que a pessoa
// digita e é assim que o cadastro guarda. Qualquer outro tamanho já vem com
// DDI (ou é um id de grupo), e nesse caso só a pontuação sai.
function numeroLimpo(bruto) {
  const d = String(bruto || '').replace(/\D/g, '');
  if (d.length === 10 || d.length === 11) return '55' + d;
  return d;
}

// O NONO DÍGITO: as duas formas do mesmo celular.
//
// No Brasil o celular ganhou um 9 na frente do número local. O cadastro guarda
// a forma nova ("+55 31 99945-6790") e o WhatsApp devolve a antiga
// ("+55 31 9945-6790") — ou o contrário, dependendo de quando a conta foi
// criada. São a MESMA linha, e nenhuma limpeza de máscara ou de DDI faz uma
// virar a outra: uma tem um dígito a mais que a outra.
//
// Só vale para CELULAR. Fixo tem 8 dígitos começando em 2..5, e pôr um 9 nele
// criaria um número que não existe — pior que não achar o par.
function variantesDoNumero(bruto) {
  const d = String(bruto || '').replace(/\D/g, '');
  if (!d) return [];
  const com55 = d.startsWith('55') && (d.length === 12 || d.length === 13);
  const nacional = com55 ? d.slice(2) : d;
  const formas = new Set([nacional]);

  if (nacional.length === 11 && nacional[2] === '9') {
    formas.add(nacional.slice(0, 2) + nacional.slice(3));      // tira o nono
  } else if (nacional.length === 10 && '6789'.includes(nacional[2])) {
    formas.add(nacional.slice(0, 2) + '9' + nacional.slice(2)); // põe o nono
  }
  const todas = [];
  for (const f of formas) { todas.push(f, '55' + f); }
  return todas;
}

function pareceEmoji(txt) {
  const t = String(txt == null ? '' : txt).trim();
  if (!t) return false;
  if (Array.from(t).length > 8) return false;      // conta por caractere, não por byte
  return !/^[\w\s.,:;@/+-]+$/.test(t);            // só ASCII "de identificador" não é emoji
}

function extrairReacao(m) {
  const cru = m.reaction || (m.content && m.content.reactionMessage) || null;
  const tipo = String(m.messageType || m.mediaType || m.type || '').toLowerCase();
  if (!cru && !tipo.includes('reaction')) return null;

  // O corpo cru vai para o log SEMPRE que é reação. É o que permite ajustar os
  // campos com um exemplo real em mãos, em vez de com mais um palpite.
  console.log('Reação recebida. Corpo:', JSON.stringify(m).slice(0, 800));

  // O EMOJI: em vez de escolher um campo e torcer, olhamos todos os candidatos
  // e ficamos com o primeiro que TEM CARA DE EMOJI. Assim o campo certo é
  // encontrado mesmo que eu tenha errado a ordem, e o campo errado é recusado
  // mesmo que venha primeiro.
  const candidatos = [
    cru && cru.text, cru && cru.emoji, cru && cru.body,
    typeof cru === 'string' ? cru : null,
    m.content && m.content.text, m.content && m.content.emoji,
    typeof m.content === 'string' ? m.content : null,
    m.text, m.body, m.caption,
  ];
  const emoji = candidatos.find((c) => pareceEmoji(c));
  // Nenhum candidato tem conteúdo = RETIRADA da reação (o WhatsApp manda o
  // mesmo evento com o emoji vazio). Mas se havia conteúdo e nada parecia
  // emoji, é o campo errado de novo — e aí não se grava nada. Melhor a reação
  // não aparecer do que a bolha exibir um código.
  const tinhaAlgo = candidatos.some((c) => String(c == null ? '' : c).trim());
  if (!emoji && tinhaAlgo) {
    console.log('Reação: não achei o emoji em nenhum campo conhecido. Nada foi gravado.');
    return null;
  }

  // O id do ALVO, e nunca o id da própria reação: só vale campo que fale da
  // mensagem reagida. Por isso não há um `m.id` de recurso aqui.
  // O id do ALVO, e nunca o id da própria reação (esse é `m.messageid`, e não
  // aparece em lugar nenhum desta lista de propósito).
  const chave = (cru && cru.key) || (m.content && m.content.key) || null;
  const alvo = (chave && (chave.ID || chave.id))
    || (typeof m.reaction === 'string' ? m.reaction : null)   // o campo mal batizado
    || m.quotedMessageId || m.reactedMessageId
    || (cru && (cru.messageid || cru.stanzaId || cru.id))
    || null;
  if (!alvo) return null;

  return { alvo: String(alvo), emoji: emoji ? String(emoji).trim() : '' };
}

// Prende a reação na mensagem. Devolve `true` quando conseguiu — e é esse
// `true` que faz o webhook parar ali e não gravar uma mensagem nova.
async function aplicarReacao(reacao, de) {
  const { data: alvo, error: erroBusca } = await supabase
    .from('mensagens').select('id, reacoes').eq('id_uazapi', reacao.alvo).maybeSingle();
  if (erroBusca) {
    console.log('Reação: não consegui procurar a mensagem alvo:', erroBusca.message);
    return false;
  }
  if (!alvo) {
    console.log(`Reação a uma mensagem que não está no Zorvin (${reacao.alvo}).`);
    return false;
  }

  // UMA REAÇÃO POR PESSOA: a nova substitui a anterior e o emoji vazio a
  // retira. É como o WhatsApp se comporta, e é o que evita a mesma pessoa
  // acumular cinco emojis na mesma bolha por ter mudado de ideia.
  // Trava dupla: nada que não pareça emoji entra na bolha, venha de onde vier.
  // Isto também limpa o que a versão anterior gravou errado — na primeira
  // reação da conversa, o id que estava lá é descartado junto.
  const atuais = (Array.isArray(alvo.reacoes) ? alvo.reacoes : [])
    .filter((r) => r && r.de !== de && pareceEmoji(r.emoji));
  if (reacao.emoji && pareceEmoji(reacao.emoji)) {
    atuais.push({ emoji: reacao.emoji, de, em: new Date().toISOString() });
  }

  const { error } = await supabase.from('mensagens').update({ reacoes: atuais }).eq('id', alvo.id);
  if (error) {
    console.log('Reação: não consegui gravar. Falta a coluna "reacoes"? '
              + 'Rode sql/2026-08-reacoes.sql no Supabase. Erro:', error.message);
    return false;
  }
  console.log(`Reação ${reacao.emoji || '(retirada)'} de ${de} na mensagem ${reacao.alvo}.`);
  return true;
}

// ============================================================
//  PARTE 2 — ENVIAR respostas (processa a fila_envio)
// ============================================================
//  A cada poucos segundos, a ponte olha a fila de mensagens que o
//  painel quer enviar, e manda cada uma pela Uazapi.
// ------------------------------------------------------------
let filaRodando = false; // impede que dois ciclos processem a fila ao mesmo tempo
async function processarFilaDeEnvio() {
  if (filaRodando) return; // o ciclo anterior ainda não terminou
  filaRodando = true;
  try {
    // Recuperação: se um item ficou preso em 'enviando' por mais de 5 min
    // (ex.: o Render reiniciou/dormiu no meio de um envio), volta para
    // 'pendente' para ser reprocessado — senão a mensagem some sem aviso.
    //
    // PELO MOMENTO EM QUE O ENVIO COMEÇOU, e não pelo momento em que o item foi
    // criado. Era `criado_em`, e a diferença manda uma mensagem duas vezes para
    // o cliente: um item que esperou 6 minutos na fila e ACABOU de ser
    // reivindicado já se encaixava na regra de "preso há mais de 5 minutos" —
    // então outro ciclo o devolvia para 'pendente' enquanto o primeiro ainda
    // estava falando com a Uazapi, e a mensagem saía de novo.
    //
    // Dentro de um processo só, `filaRodando` evitava o cruzamento. Basta uma
    // segunda instância no ar — o que acontece em toda publicação, com a nova
    // subindo antes de a antiga sair — para o caso acontecer.
    const limiteTravado = new Date(Date.now() - 5 * 60 * 1000).toISOString();
    const { data: destravadas } = await supabase
      .from('fila_envio')
      .update({ status: 'pendente' })
      .eq('status', 'enviando')
      .lt('enviando_em', limiteTravado)
      .select('id');
    // Os itens de antes desta mudança não têm `enviando_em`. Para eles, e só
    // para eles, vale a regra antiga — senão ficariam presos para sempre.
    const { data: antigas } = await supabase
      .from('fila_envio')
      .update({ status: 'pendente' })
      .eq('status', 'enviando')
      .is('enviando_em', null)
      .lt('criado_em', limiteTravado)
      .select('id');
    const quantas = (destravadas || []).length + (antigas || []).length;
    if (quantas) console.log(`Fila: ${quantas} item(ns) preso(s) em 'enviando' devolvido(s) para 'pendente'.`);

    // Pega até 10 mensagens pendentes de cada vez.
    const { data: pendentes, error } = await supabase
      .from('fila_envio')
      .select('*')
      .eq('status', 'pendente')
      .order('criado_em', { ascending: true })
      .limit(10);

    if (error) { console.error('Erro ao ler fila:', error.message); return; }
    if (!pendentes || pendentes.length === 0) return;

    const MAX_TENTATIVAS = 5;
    for (const item of pendentes) {
      // Trava de segurança: se o item já tentou demais (ex.: ficou preso e foi
      // devolvido para 'pendente' várias vezes), para de reenviar e marca erro.
      // Evita um laço infinito que reentregaria a mesma mensagem sem parar.
      if ((item.tentativas || 0) >= MAX_TENTATIVAS) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: `Falhou após ${MAX_TENTATIVAS} tentativas` })
          .eq('id', item.id);
        console.error(`Fila: item ${item.id} excedeu ${MAX_TENTATIVAS} tentativas; marcado como erro.`);
        continue;
      }
      // Reivindica o item de forma ATÔMICA: só processa se ainda estava
      // 'pendente'. Evita envio duplicado se dois ciclos se cruzarem.
      const { data: claim, error: claimErr } = await supabase.from('fila_envio')
        .update({ status: 'enviando', tentativas: (item.tentativas || 0) + 1,
                  enviando_em: new Date().toISOString() })
        .eq('id', item.id)
        .eq('status', 'pendente')
        .select('id');
      if (claimErr) { console.error('Erro ao reivindicar item da fila:', claimErr.message); continue; }
      if (!claim || claim.length === 0) continue; // outro ciclo já pegou este item

      // Descobre para qual número enviar e por qual advogado (token/servidor).
      const { data: conv } = await supabase
        .from('conversas')
        .select('id, contato:contato_id (numero), advogado:advogado_id (token, servidor)')
        .eq('id', item.conversa_id)
        .single();

      if (!conv || !conv.advogado || !conv.contato) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: 'Conversa/advogado/contato não encontrado' })
          .eq('id', item.id);
        continue;
      }

      const servidor = (conv.advogado.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
      const token = conv.advogado.token;
      // O DESTINO VAI LIMPO, seja como for que o contato tenha entrado.
      //
      // Aqui ia o número exatamente como está no banco. Enquanto todo caminho
      // do painel gravava a forma canônica isso não incomodava — mas o caminho
      // do cadastro do Vantoro gravava como o Vantoro devolve, com máscara
      // ("(11) 93404-2997"), e era isso que saía para a Uazapi. O painel já
      // foi corrigido; esta limpeza é a rede para os contatos que entraram
      // torto antes disso, que continuam funcionando sem depender de arrumar
      // o banco primeiro.
      const numeroDestino = numeroLimpo(conv.contato.numero);

      try {
        // Esta mensagem é um ANEXO (imagem/documento/áudio/vídeo) ou texto?
        const ehMidia = item.tipo && item.tipo !== 'texto' && item.midia_url;
        // REAÇÃO não é mensagem: não vira bolha nova nem entra no histórico.
        // Reaproveita `responder_id_uazapi` porque é exatamente o que a coluna
        // já significa — "a mensagem à qual isto se refere".
        const ehReacao = item.tipo === 'reacao';
        // EDIÇÃO: também não é mensagem nova. Reaproveita `responder_id_uazapi`
        // para apontar a mensagem que será reescrita, como a reação faz.
        const ehEdicao = item.tipo === 'edicao';
        // APAGAR PARA TODOS. A documentação da Uazapi não oferece "apagar só
        // para mim": esta rota tira a mensagem da conversa dos dois lados, e
        // funciona tanto no que nós mandamos quanto no que recebemos.
        const ehExclusao = item.tipo === 'exclusao';

        let resposta;
        if (ehExclusao) {
          resposta = await fetchComTimeout(`${servidor}/message/delete`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify({ id: item.responder_id_uazapi })
          }, 30000);
        } else if (ehEdicao) {
          resposta = await fetchComTimeout(`${servidor}/message/edit`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify({ id: item.responder_id_uazapi, text: item.texto || '' })
          }, 30000);
        } else if (ehReacao) {
          // O número vai no formato de JID que a Uazapi documenta para esta
          // rota. Ela aceita o número cru nas outras, mas aqui seguimos o
          // exemplo da documentação em vez de supor.
          resposta = await fetchComTimeout(`${servidor}/message/react`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify({
              number: `${numeroDestino}@s.whatsapp.net`,
              text: item.texto || '',          // vazio = retirar a reação
              id: item.responder_id_uazapi,
            })
          }, 30000);
        } else if (ehMidia) {
          const tipoUaz =
            item.tipo === 'imagem' ? 'image' :
            item.tipo === 'video' ? 'video' :
            item.tipo === 'figurinha' ? 'sticker' :
            item.tipo === 'audio' ? 'ptt' : 'document';

          // Chama /send/media com um "file" (URL pública ou base64).
          const enviarMidia = async (fileParam, via) => {
            const corpoM = { number: numeroDestino, type: tipoUaz, file: fileParam, text: item.texto || '' };
            if (item.midia_nome) corpoM.docName = item.midia_nome;
            if (item.responder_id_uazapi) corpoM.replyid = item.responder_id_uazapi;
            console.log(`Enviando mídia (${tipoUaz}) via ${via} para ${numeroDestino}.`);
            return fetchComTimeout(`${servidor}/send/media`, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'token': token },
              body: JSON.stringify(corpoM)
            }, 45000); // mídia é mais lenta: dá mais tempo antes de abortar
          };

          // 1ª tentativa: URL pública do Storage (bucket público).
          resposta = await enviarMidia(item.midia_url, 'url');

          // Se falhar, 2ª tentativa: baixa o arquivo e envia como base64.
          if (!resposta.ok) {
            const det = await resposta.text().catch(() => '');
            console.log(`Envio por URL falhou (${resposta.status}): ${det.slice(0, 200)}`);
            try {
              const caminho = caminhoDoStorage(item.midia_url);
              if (caminho) {
                const { data: blob, error: dlErr } = await supabase.storage.from('anexos').download(caminho);
                if (dlErr) {
                  console.error('Erro ao baixar anexo do Storage:', dlErr.message);
                } else {
                  const buff = Buffer.from(await blob.arrayBuffer());
                  const mime = item.midia_mime || 'application/octet-stream';
                  resposta = await enviarMidia(`data:${mime};base64,${buff.toString('base64')}`, 'base64');
                }
              }
            } catch (prepErro) {
              console.error('Falha na 2ª tentativa (base64):', prepErro.message);
            }
          }
        } else {
          // Envia texto. Se é uma RESPOSTA, passa o replyid para citar.
          const corpo = { number: numeroDestino, text: item.texto, readchat: true };
          if (item.responder_id_uazapi) corpo.replyid = item.responder_id_uazapi;
          resposta = await fetchComTimeout(`${servidor}/send/text`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'token': token },
            body: JSON.stringify(corpo)
          }, 45000);
        }

        if (!resposta.ok) {
          // .catch: no caminho de mídia a 1ª resposta já pode ter sido lida
          // (linha da tentativa por URL) — evita o erro "body already read".
          const detalhe = await resposta.text().catch(() => '');
          throw new Error(`Uazapi respondeu ${resposta.status}: ${detalhe}`);
        }

        // Tenta capturar o id que a Uazapi deu à mensagem enviada.
        // Serve como trava extra: se um eco chegar com o mesmo id, o banco
        // recusa a duplicata automaticamente.
        let idUazapi = null;
        try {
          const dados = await resposta.json();
          idUazapi = dados?.messageid || dados?.id || dados?.message?.messageid || null;
        } catch (_) { /* resposta sem JSON: seguimos sem o id */ }

        // Deu certo: marca como enviada e registra a mensagem no histórico.
        const { error: okErr } = await supabase.from('fila_envio')
          .update({ status: 'enviada', enviado_em: new Date().toISOString() })
          .eq('id', item.id);
        if (okErr) console.error(`Enviada ao WhatsApp mas falhou ao marcar 'enviada' (item ${item.id}):`, okErr.message);

        // Era um aviso de audiência? Só AGORA o Vantoro pode marcar como
        // enviado — é aqui que a mensagem realmente saiu. Confirmar lá atrás,
        // na hora de enfileirar, faria o Vantoro achar que o cliente foi
        // avisado mesmo quando a Uazapi recusou.
        if (item.aviso_vantoro_id) {
          try {
            await chamarAudiencias(`/avisos/${item.aviso_vantoro_id}/enviado`, { method: 'POST' });
            console.log(`Aviso ${item.aviso_vantoro_id} confirmado no Vantoro.`);
          } catch (e) {
            console.error('Não consegui confirmar o aviso no Vantoro:', (e && e.message) || e);
          }
        }

        // A EXCLUSÃO PARA AQUI. A bolha não sai do histórico do Zorvin: ela
        // vira "Esta mensagem foi apagada", como no WhatsApp. Apagar a linha
        // deixaria um buraco silencioso na conversa — a equipe veria a resposta
        // sem a pergunta, e não teria como saber que algo foi removido nem por
        // quem.
        if (ehExclusao) {
          const dados = await resposta.json().catch(() => null);
          if (dados && (dados.success === false || dados.error)) {
            throw new Error(`Uazapi recusou apagar: ${dados.error || dados.message || 'sem detalhe'}`);
          }
          let { error: erroDel } = await supabase.from('mensagens')
            .update({ apagada: true, texto: null, midia_url: null })
            .eq('id_uazapi', item.responder_id_uazapi);
          if (erroDel && /apagada/i.test(erroDel.message || '')) {
            console.log('Falta a coluna "apagada"? Rode sql/2026-08-apagar-mensagem.sql. Erro:', erroDel.message);
          } else if (erroDel) {
            console.log('Exclusão: não consegui marcar a mensagem:', erroDel.message);
          }
          await supabase.from('fila_envio')
            .update({ status: 'enviada', enviado_em: new Date().toISOString() }).eq('id', item.id);
          console.log(`Mensagem ${item.responder_id_uazapi} apagada para todos.`);
          continue;
        }

        // A EDIÇÃO PARA AQUI: ela reescreve uma bolha que já existe, em vez de
        // criar outra. Sem este desvio, editar criaria uma segunda mensagem com
        // o texto novo e a antiga continuaria na conversa — o oposto de editar.
        //
        // O WhatsApp gera um ID NOVO para a mensagem editada, e por isso o
        // `id_uazapi` é trocado junto: sem isso, uma edição seguinte apontaria
        // para um id que já não existe, e a segunda correção falharia.
        if (ehEdicao) {
          const novoTexto = item.texto || '';
          let idNovo = null;
          // 200 NÃO É SUCESSO AQUI. A Uazapi aceita o pedido e responde OK
          // mesmo quando o WhatsApp recusa a edição depois — foi o que
          // aconteceu ao editar uma mensagem de mais de uma hora: o contato
          // recebeu a notificação e o texto ficou como estava.
          //
          // Por isso o corpo é lido: se ele disser que não deu, o item vai
          // para 'erro' e o banco NÃO é reescrito, senão o Zorvin mostraria
          // uma correção que só existe aqui dentro.
          const dados = await resposta.json().catch(() => null);
          if (dados && (dados.success === false || dados.error)) {
            throw new Error(`Uazapi recusou a edição: ${dados.error || dados.message || 'sem detalhe'}`);
          }
          idNovo = dados?.messageid || dados?.id || dados?.message?.messageid || null;
          const campos = { texto: novoTexto, editada: true };
          if (idNovo) campos.id_uazapi = String(idNovo).split(':').pop();
          let { error: erroEd } = await supabase.from('mensagens')
            .update(campos).eq('id_uazapi', item.responder_id_uazapi);
          // Instalação sem a coluna `editada`: grava só o texto. Perder o selo
          // "editada" é aceitável; não gravar a correção, não.
          if (erroEd && /editada/i.test(erroEd.message || '')) {
            delete campos.editada;
            ({ error: erroEd } = await supabase.from('mensagens')
              .update(campos).eq('id_uazapi', item.responder_id_uazapi));
          }
          if (erroEd) console.log('Edição: não consegui gravar o texto novo:', erroEd.message);
          await supabase.from('fila_envio')
            .update({ status: 'enviada', enviado_em: new Date().toISOString() }).eq('id', item.id);
          console.log(`Mensagem ${item.responder_id_uazapi} editada.`);
          continue;
        }

        // A REAÇÃO PARA AQUI. Ela não vira linha no histórico: prende-se à
        // mensagem que já está lá, do mesmo jeito que a reação recebida. Sem
        // este desvio, reagir pelo Zorvin criaria a bolha solta que este
        // trabalho todo foi feito para eliminar.
        if (ehReacao) {
          await aplicarReacao({ alvo: item.responder_id_uazapi, emoji: item.texto || '' }, 'advogado');
          console.log(`Reação ${item.texto || '(retirada)'} enviada para ${numeroDestino}.`);
          continue;
        }

        const base = {
          conversa_id: item.conversa_id,
          origem: 'advogado',
          tipo: item.tipo || 'texto',
          texto: item.texto || null,
          midia_url: ehMidia ? item.midia_url : null,
          midia_mime: ehMidia ? (item.midia_mime || null) : null,
          id_uazapi: idUazapi,
          status: 'enviada'
        };
        // Campos "extras" (colunas que podem não existir ainda no banco): quem
        // enviou (atendente) e os dados de citação. Se alguma coluna faltar, o
        // salvarMensagem regrava só com o básico, sem quebrar.
        const extras = {};
        if (item.enviado_por) extras.enviado_por = item.enviado_por;
        if (item.enviado_por_foto) extras.enviado_por_foto = item.enviado_por_foto;
        // O ID de quem enviou viaja junto com o nome. O nome é o que a bolha
        // mostra (o nome de então); o id é o que o painel conta, porque ele não
        // muda quando alguém edita o próprio perfil. Entra como "extra" pelo
        // mesmo motivo dos outros: numa base sem o SQL rodado a coluna não
        // existe, e a mensagem não pode deixar de ser gravada por causa disso.
        if (item.enviado_por_id) extras.enviado_por_id = item.enviado_por_id;
        if (item.responder_id_uazapi) {
          extras.responder_id_uazapi = item.responder_id_uazapi;
          extras.resposta_previa = item.resposta_previa || null;
          extras.resposta_autor = item.resposta_autor || null;
        }
        // O RESULTADO DESTA GRAVAÇÃO NÃO PODE SER JOGADO FORA.
        //
        // Ele era. A mensagem saía para o WhatsApp, o contato recebia, e se o
        // banco recusasse a linha — coluna faltando, restrição no `tipo`,
        // política de RLS — ninguém ficava sabendo: nem a tela, que não
        // mostrava a bolha, nem o log, que não dizia nada. Era assim que uma
        // figurinha podia chegar ao cliente e não existir no Zorvin.
        //
        // O item continua 'enviada', porque enviada ele foi. O motivo fica
        // gravado em `erro_detalhe`, que é onde se procura quando algo não
        // aparece.
        const erroHist = await salvarMensagem(base, Object.keys(extras).length ? extras : null);
        if (erroHist) {
          console.error(`ENVIADA MAS NÃO GRAVADA (item ${item.id}, tipo ${item.tipo || 'texto'}):`, erroHist.message);
          await supabase.from('fila_envio')
            .update({ erro_detalhe: `enviada ao WhatsApp, mas não gravada no histórico: ${erroHist.message}` })
            .eq('id', item.id);
        }

        console.log(`Enviada (${item.tipo || 'texto'}) para ${numeroDestino}.`);
      } catch (envioErro) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: envioErro.message })
          .eq('id', item.id);
        // O aviso de audiência volta a aparecer como "Falhou" no Vantoro, com o
        // motivo — em vez de sumir e só dar as caras quando o cliente faltar.
        if (item.aviso_vantoro_id) await avisoDeuErro(item.aviso_vantoro_id, envioErro.message);
        console.error(`Falha ao enviar (${item.id}):`, envioErro.message);
      }
    }
  } catch (e) {
    console.error('Erro ao processar fila:', e.message);
  } finally {
    filaRodando = false;
  }
}

// ============================================================
//  VANTORO — ficha do cliente dentro do atendimento
//
//  O painel roda no NAVEGADOR, então ele não pode conhecer o token do
//  Vantoro (seria dar a base inteira de clientes para quem abrir o
//  inspecionar). Por isso a ponte funciona como intermediária:
//
//     painel  ->  (sessão do Supabase)  ->  ponte  ->  (token)  ->  Vantoro
//
//  A ponte confere se quem chamou está logado no Zorvin e só então
//  repassa a chamada, acrescentando o token no servidor.
//
//  Variáveis necessárias (Render do zorvin-bridge):
//     VANTORO_API_URL    ex.: https://SEU-VANTORO.onrender.com/cadastro/api/v1
//     VANTORO_API_TOKEN  o mesmo valor gerado no Render do Vantoro
// ============================================================

const VANTORO_URL = (process.env.VANTORO_API_URL || '').replace(/\/+$/, '');
const VANTORO_TOKEN = process.env.VANTORO_API_TOKEN || '';

// O painel fica em outro endereço, então o navegador exige estes cabeçalhos.
function liberarCors(res) {
  res.set('Access-Control-Allow-Origin', process.env.PAINEL_ORIGEM || '*');
  res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods', 'GET, POST, PATCH, OPTIONS');
}

// QUEM JÁ FOI CONFERIDO HÁ POUCO NÃO É CONFERIDO DE NOVO.
//
// `auth.getUser` é uma ida à API do Supabase — rede, ida e volta — e ela
// acontecia em TODA chamada do painel: abrir a ficha do cliente são duas (a
// ficha e o histórico), digitar na busca é mais uma a cada pausa. O tempo
// somava na cara da pessoa sem servir para nada: a mesma sessão, conferida
// cinco vezes em dez segundos, dá cinco vezes a mesma resposta.
//
// A lembrança dura 60 segundos. É o preço de sair: quem for desligado continua
// entrando por até um minuto. Para uma ferramenta interna, onde desligar
// alguém é um ato deliberado e acompanhado, um minuto é aceitável — e a conta
// no Vantoro, que é o que manda, já foi cortada.
const sessoesLembradas = new Map();   // jwt -> { usuario, ate }
const LEMBRAR_MS = 60 * 1000;

function limparLembradas() {
  const agora = Date.now();
  for (const [k, v] of sessoesLembradas) if (v.ate < agora) sessoesLembradas.delete(k);
}

// Só passa quem está logado no Zorvin (sessão válida do Supabase).
async function exigirLogin(req, res) {
  const cabecalho = String(req.headers.authorization || '');
  const jwt = cabecalho.toLowerCase().startsWith('bearer ')
    ? cabecalho.slice(7).trim() : '';
  if (!jwt) {
    res.status(401).json({ ok: false, erro: 'Faça login no Zorvin.' });
    return null;
  }
  const lembrada = sessoesLembradas.get(jwt);
  if (lembrada && lembrada.ate > Date.now()) return lembrada.usuario;

  const { data, error } = await supabase.auth.getUser(jwt);
  if (error || !data || !data.user) {
    // Sessão ruim NÃO é lembrada: senão um token expirado ficaria recusado por
    // um minuto depois de a pessoa entrar de novo.
    sessoesLembradas.delete(jwt);
    res.status(401).json({ ok: false, erro: 'Sessão expirada. Entre de novo.' });
    return null;
  }
  limparLembradas();
  sessoesLembradas.set(jwt, { usuario: data.user, ate: Date.now() + LEMBRAR_MS });
  return data.user;
}

// Repassa a chamada ao Vantoro colocando o token (que só existe aqui).
async function chamarVantoro(caminho, opcoes = {}) {
  if (!VANTORO_URL || !VANTORO_TOKEN) {
    return { status: 503, corpo: { ok: false, erro: 'Integração com o Vantoro não configurada (VANTORO_API_URL/VANTORO_API_TOKEN).' } };
  }
  const r = await fetchComTimeout(`${VANTORO_URL}${caminho}`, {
    ...opcoes,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${VANTORO_TOKEN}`,
      ...(opcoes.headers || {}),
    },
  }, 20000);
  let corpo = null;
  try { corpo = await r.json(); } catch (_e) { corpo = { ok: false, erro: 'Resposta inválida do Vantoro.' }; }
  return { status: r.status, corpo };
}

// Envolve cada rota: CORS + login + tratamento de erro, sem repetir código.
function rotaVantoro(handler) {
  return async (req, res) => {
    liberarCors(res);
    try {
      const usuario = await exigirLogin(req, res);
      if (!usuario) return;
      const { status, corpo } = await handler(req, usuario);
      res.status(status).json(corpo);
    } catch (e) {
      console.error('vantoro:', (e && e.message) || e);
      res.status(502).json({ ok: false, erro: 'Não foi possível falar com o Vantoro agora.' });
    }
  };
}

app.options('/vantoro/*', (req, res) => { liberarCors(res); res.sendStatus(204); });

// Acha o cliente pelo número do WhatsApp da conversa aberta.
app.get('/vantoro/cliente', rotaVantoro(async (req) => {
  const telefone = String(req.query.telefone || '').replace(/\D/g, '');
  const cpf = String(req.query.cpf || '').replace(/\D/g, '');
  if (!telefone && !cpf) {
    return { status: 400, corpo: { ok: false, erro: 'Informe telefone ou cpf.' } };
  }
  const busca = telefone ? `telefone=${telefone}` : `cpf=${cpf}`;
  return chamarVantoro(`/clientes/buscar?${busca}`);
}));

// Busca livre no cadastro: nome, CPF ou número do processo. É o que permite ao
// atendente procurar no Zorvin do mesmo jeito que procuraria no Vantoro, em vez
// de depender de já ter o telefone da pessoa.
app.get('/vantoro/buscar', rotaVantoro(async (req) => {
  const termo = String(req.query.q || '').trim();
  if (termo.length < 3) {
    return { status: 400, corpo: { ok: false, erro: 'Digite ao menos 3 letras ou números.' } };
  }
  return chamarVantoro(`/clientes/buscar?q=${encodeURIComponent(termo)}`);
}));

// Ficha completa (dados, pendências da ordem de serviço e processos).
app.get('/vantoro/cliente/:id', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}`)));

// Cria o pré-cadastro a partir do atendimento.
app.post('/vantoro/cliente', rotaVantoro(async (req) =>
  chamarVantoro('/clientes', { method: 'POST', body: JSON.stringify(req.body || {}) })));

/**
 * Guarda no histórico do Zorvin o que mudou no cadastro do cliente.
 *
 * AQUI, e não no navegador, porque é aqui que se sabe QUEM é quem: a ponte
 * confere o login antes de deixar passar. O painel poderia mandar um nome
 * qualquer no corpo do pedido, e um histórico em que o autor é o que o
 * navegador disse ser não serve para responder "quem mexeu nisto?".
 *
 * O valor ANTERIOR também é lido daqui, do próprio Vantoro, e não recebido
 * pronto: a tela pode estar aberta há meia hora e mostrar um "antes" que já
 * não era o de antes.
 *
 * Nada disto pode impedir a edição de acontecer. Se o histórico falhar, a
 * alteração vale do mesmo jeito e fica um aviso no log — o contrário seria
 * trocar um registro perdido por um atendente travado.
 */
async function registrarEdicaoDeCadastro(clienteId, mudou, anterior, usuario) {
  try {
    const campos = Object.keys(mudou || {});
    if (!campos.length) return;

    // De qual contato do Zorvin é este cliente. Sem ele a linha continua
    // valendo (o histórico geral a mostra), só não aparece na ficha daquela
    // conversa.
    let contatoId = null;
    const { data: cont } = await supabase
      .from('contatos').select('id').eq('vantoro_cliente_id', clienteId).limit(1);
    if (cont && cont[0]) contatoId = cont[0].id;

    const nome = (usuario && usuario.user_metadata && usuario.user_metadata.nome) || '';
    const linhas = campos
      // Campo que não mudou de verdade não vira linha: o painel manda o que
      // ele acha que mudou, e "  " para "" encheria o histórico de nada.
      .filter((c) => String((anterior || {})[c] ?? '').trim() !== String(mudou[c] ?? '').trim())
      .map((c) => ({
        contato_id: contatoId,
        tipo: 'cadastro',
        alvo: c,
        antes: String((anterior || {})[c] ?? ''),
        depois: String(mudou[c] ?? ''),
        autor: nome,
        autor_id: (usuario && usuario.id) || null,
      }));
    if (!linhas.length) return;

    const { error } = await supabase.from('alteracoes').insert(linhas);
    if (error) console.log(`histórico: não gravei a edição do cadastro (${error.message}).`);
  } catch (e) {
    console.log('histórico: não gravei a edição do cadastro —', (e && e.message) || e);
  }
}

// Atendente corrige/completa os dados sem sair da conversa.
app.patch('/vantoro/cliente/:id', rotaVantoro(async (req, usuario) => {
  const id = encodeURIComponent(req.params.id);
  const mudou = req.body || {};
  // O "antes", lido agora. Best-effort: se o Vantoro não responder a esta,
  // a edição segue e o histórico fica sem o valor anterior.
  let anterior = {};
  try {
    const atual = await chamarVantoro(`/clientes/${id}`);
    if (atual.status === 200 && atual.corpo && atual.corpo.cliente) anterior = atual.corpo.cliente;
  } catch (_) { /* segue sem o "antes" */ }

  const r = await chamarVantoro(`/clientes/${id}/editar`,
    { method: 'PATCH', body: JSON.stringify(mudou) });
  if (r.status === 200 && r.corpo && r.corpo.ok) {
    await registrarEdicaoDeCadastro(req.params.id, mudou, anterior, usuario);
  }
  return r;
}));

// Manda para o cadastro um arquivo recebido no WhatsApp.
app.post('/vantoro/cliente/:id/documento', rotaVantoro(async (req) =>
  chamarVantoro(`/clientes/${encodeURIComponent(req.params.id)}/documentos`,
    { method: 'POST', body: JSON.stringify(req.body || {}) })));

// Diagnóstico rápido: a integração está configurada?
app.get('/vantoro/status', (req, res) => {
  liberarCors(res);
  res.json({
    ok: true,
    configurado: Boolean(VANTORO_URL && VANTORO_TOKEN),
    url: VANTORO_URL ? VANTORO_URL.replace(/\/\/[^/]+/, '//…') : null,
  });
});

// ============================================================
//  LOGIN ÚNICO — a senha mora no Vantoro
//
//  Antes: cada pessoa tinha uma conta criada à mão no Supabase, com uma senha
//  que não era a do Vantoro. Duas listas de gente para manter iguais à mão, e
//  ninguém lembra das duas.
//
//  Agora o painel manda login e senha para cá; a ponte pergunta ao Vantoro se
//  confere (é ela quem tem o token) e, se conferir, abre a sessão do Supabase
//  com a chave de serviço. A conta do Supabase passa a ser uma carcaça: ela
//  existe só para o `auth.uid()` das regras de visibilidade ter um valor. A
//  senha de verdade existe num lugar só.
//
//  A senha NUNCA é gravada nem repassada para o Supabase — ela só atravessa
//  esta função a caminho do Vantoro.
// ============================================================

// Freio contra tentativa de adivinhar senha. Em memória de propósito: a ponte
// é um processo só, e um freio simples que funciona vale mais do que um
// elaborado que depende de outra peça no ar.
const tentativas = new Map();
const TENTATIVAS_MAX = 8;
const TENTATIVAS_JANELA_MS = 5 * 60 * 1000;

function freioBateu(chave) {
  const agora = Date.now();
  const reg = tentativas.get(chave);
  if (!reg || agora - reg.desde > TENTATIVAS_JANELA_MS) {
    tentativas.set(chave, { n: 1, desde: agora });
    return false;
  }
  reg.n += 1;
  return reg.n > TENTATIVAS_MAX;
}

function freioLimpa(chave) { tentativas.delete(chave); }

// O mapa do freio só crescia: cada par (ip, login) que já tentou entrar ficava
// lá para sempre. Numa ponte que fica meses no ar, é memória que nunca volta.
// Uma varredura a cada 10 minutos custa nada e fecha o vazamento.
setInterval(() => {
  const agora = Date.now();
  for (const [k, v] of tentativas) if (agora - v.desde > TENTATIVAS_JANELA_MS) tentativas.delete(k);
}, 10 * 60 * 1000).unref();

// Acha (ou cria) a conta do Supabase daquele e-mail e devolve o id.
async function contaDoSupabase(email, nome) {
  // `listUsers` não filtra por e-mail na API atual, então a criação vem
  // primeiro: se já existir, o erro diz isso e aí sim procuramos. Evita
  // varrer a lista inteira de usuários a cada login.
  const criada = await supabase.auth.admin.createUser({
    email,
    email_confirm: true,          // sem isto a conta nasce impedida de entrar
    user_metadata: { nome: nome || '' },
  });
  if (criada && criada.data && criada.data.user) return criada.data.user.id;

  const msg = String((criada && criada.error && criada.error.message) || '').toLowerCase();
  const jaExiste = msg.includes('already') || msg.includes('registered') || msg.includes('exists');
  if (!jaExiste) throw new Error((criada && criada.error && criada.error.message) || 'Falha ao criar a conta.');

  // Procura pelo e-mail, paginando. A base é de dezenas de pessoas, não de
  // milhares — mas o laço tem teto para não virar varredura infinita se a API
  // mudar de comportamento.
  for (let pagina = 1; pagina <= 20; pagina += 1) {
    const { data, error } = await supabase.auth.admin.listUsers({ page: pagina, perPage: 200 });
    if (error) throw new Error(error.message);
    const achada = (data.users || []).find(
      (u) => String(u.email || '').toLowerCase() === email.toLowerCase());
    if (achada) return achada.id;
    if (!data.users || data.users.length < 200) break;
  }
  throw new Error('A conta existe mas não foi encontrada.');
}

/**
 * Deixa o nome guardado no Supabase Auth igual ao do cadastro do Vantoro.
 *
 * O painel lê o nome de `user_metadata`, e ele só era escrito na criação da
 * conta. Trocar o nome no Vantoro não chegava aqui nunca.
 *
 * Não é uma escrita a cada login: só grava quando MUDOU. Login é caminho
 * quente e uma ida à API de admin por entrada, para reescrever a mesma coisa,
 * é desperdício puro.
 *
 * Falhar aqui não impede ninguém de entrar — a pessoa entra com o nome antigo
 * e a próxima entrada tenta de novo. Barrar o login porque o nome não alinhou
 * seria trocar um incômodo por um impedimento.
 */
async function alinharNomeDaConta(id, nomeDoVantoro) {
  const nome = String(nomeDoVantoro || '').trim();
  if (!id || !nome) return;
  try {
    const { data, error } = await supabase.auth.admin.getUserById(id);
    if (error || !data || !data.user) return;
    const meta = data.user.user_metadata || {};
    if (String(meta.nome || '').trim() === nome) return;
    const { error: erroGravar } = await supabase.auth.admin.updateUserById(id, {
      user_metadata: { ...meta, nome },
    });
    if (erroGravar) {
      console.log(`login: não alinhei o nome da conta (${erroGravar.message}).`);
      return;
    }
    console.log(`login: nome da conta atualizado para "${nome}" (era "${meta.nome || ''}").`);
  } catch (e) {
    console.log(`login: não alinhei o nome da conta (${e.message}).`);
  }
}

// ============================================================
//  PERMISSÕES — o Vantoro decide, a Ponte aplica
//
//  Quem pode ver quais conversas é decisão de CADASTRO DE PESSOA, e cadastro de
//  pessoa mora no Vantoro. Duas telas de permissão para a mesma pessoa é como o
//  escritório acaba com alguém que saiu da empresa ainda lendo conversa de
//  cliente: só metade dos acessos foi cortada.
//
//  Faltavam as duas pontas do caminho, e sem elas a tela do Vantoro guardava a
//  escolha sem que ela chegasse a lugar nenhum:
//
//    1. a lista de departamentos daqui nunca era enviada ao Vantoro, então a
//       tela de lá não tinha o que oferecer para marcar;
//    2. o que fosse marcado lá nunca era gravado em `permissoes` aqui.
//
//  O momento é o LOGIN: é quando a Ponte já está falando com o Vantoro sobre
//  esta pessoa, e é quando a permissão precisa valer — ela entra na tela em
//  seguida. Uma rotina de fundo chegaria depois de a pessoa já estar dentro.
// ============================================================

// A lista de departamentos muda quando alguém mexe na tela de departamentos —
// quase nunca. Sem o teto, todo login viria com duas idas ao banco e uma
// chamada ao Vantoro para reenviar exatamente a mesma coisa.
let departamentosEnviadosEm = 0;
const DEPARTAMENTOS_VALIDADE_MS = 10 * 60 * 1000;

async function mandarDepartamentosAoVantoro() {
  if (!VANTORO_URL || !VANTORO_TOKEN) return;
  if (Date.now() - departamentosEnviadosEm < DEPARTAMENTOS_VALIDADE_MS) return;

  const { data, error } = await supabase
    .from('departamentos').select('slug, nome').eq('ativo', true);
  if (error) {
    console.log(`Departamentos: não consegui ler (${error.message}). Falta rodar o SQL?`);
    return;
  }
  // Lista vazia não se envia: do lado do Vantoro, uma lista vazia não desativa
  // nada (ele trata isso), mas mandar "nenhum departamento existe" quando na
  // verdade não consegui ler seria afirmar uma coisa que não sei.
  if (!data || !data.length) return;

  const { status } = await chamarVantoro('/zorvin/departamentos', {
    method: 'POST',
    body: JSON.stringify({ departamentos: data }),
  });
  if (status === 200) {
    departamentosEnviadosEm = Date.now();
  } else {
    console.log(`Departamentos: o Vantoro respondeu ${status}.`);
  }
}

// O NÚMERO COMO O VANTORO GUARDA: só dígitos, sem o 55 na frente, últimos 11.
//
// É a mesma redução que o cadastro do Vantoro usa para casar telefone
// (`core.models.normalizar_telefone`), e ela precisa ser a mesma dos dois lados:
// a permissão por telefone é encontrada comparando esta chave. Aqui o número
// vem cru da instância ("5511934042997"); lá ele foi normalizado ao entrar.
function chaveDoNumero(bruto) {
  let d = String(bruto || '').replace(/\D/g, '');
  if (d.length > 11 && d.startsWith('55')) d = d.slice(2);
  return d.length > 11 ? d.slice(-11) : d;
}

// A lista de telefones muda quando alguém liga uma instância nova — quase nunca.
// O mesmo teto dos departamentos, pela mesma razão.
let telefonesEnviadosEm = 0;

async function mandarTelefonesAoVantoro() {
  if (!VANTORO_URL || !VANTORO_TOKEN) return;
  if (Date.now() - telefonesEnviadosEm < DEPARTAMENTOS_VALIDADE_MS) return;

  // `select('*')` e não a lista de colunas: o formato de `advogados` varia com o
  // que já foi rodado no banco, e pedir uma coluna que ainda não existe devolve
  // erro e mata a rotina inteira. Mesmo cuidado que a rotina do departamento.
  const { data: fones, error } = await supabase
    .from('advogados').select('*').eq('ativo', true);
  if (error) {
    console.log(`Telefones: não consegui ler (${error.message}).`);
    return;
  }
  if (!fones || !fones.length) return;

  const { data: deps } = await supabase.from('departamentos').select('id, slug');
  const slugPorId = new Map((deps || []).map((d) => [d.id, d.slug]));

  const lista = fones
    .map((f) => ({
      numero: chaveDoNumero(f.numero),
      nome: String(f.nome || f.numero || '').slice(0, 120),
      // O departamento vai junto para a tela de permissões poder dizer "este
      // número já está incluído no departamento X" — sem isso, marcar os dois
      // parece dobrar o acesso quando só repete.
      departamento: slugPorId.get(f.departamento_id) || String(f.setor || '').trim(),
    }))
    .filter((f) => f.numero);
  if (!lista.length) return;

  const { status } = await chamarVantoro('/zorvin/telefones', {
    method: 'POST',
    body: JSON.stringify({ telefones: lista }),
  });
  if (status === 200) {
    telefonesEnviadosEm = Date.now();
  } else {
    console.log(`Telefones: o Vantoro respondeu ${status}.`);
  }
}

async function aplicarPermissoes(usuarioId, u) {
  // `zorvin_definido` distingue "não pode ver nada" de "ninguém definiu ainda".
  // Sem essa distinção, o primeiro login depois desta mudança apagaria a
  // permissão de todo mundo que ainda não tem perfil no Vantoro — o sistema
  // inteiro ficaria cego de uma vez, e por causa de uma melhoria.
  if (!u || u.zorvin_definido !== true) return;
  // Admin vê tudo pelas regras de visibilidade; linha de permissão para ele
  // seria enfeite que confunde quem for conferir depois.
  if (u.admin) return;

  // DOIS CORTES, E O FINO GANHA DO GROSSO.
  //
  // O departamento é o corte certo na maioria dos casos. O que ele não resolve
  // aparece toda semana: a pessoa que atende UM número e só ele — uma estagiária
  // no número do cadastro, um parceiro no de vendas. Pelo departamento, liberar
  // esse número libera todos os números do departamento junto.
  //
  // Quando o Vantoro diz `zorvin_so_telefones`, ele já conferiu que há telefone
  // marcado (chave ligada com lista vazia não vira restrição lá, justamente para
  // não deixar ninguém sem ver nada no meio de uma edição). Aqui a lista de
  // telefones SUBSTITUI os departamentos: é o que a tela promete a quem marcou.
  const soTelefones = u.zorvin_so_telefones === true;
  const chaves = Array.isArray(u.zorvin) ? u.zorvin.filter(Boolean) : [];
  const numeros = Array.isArray(u.zorvin_telefones) ? u.zorvin_telefones.filter(Boolean) : [];

  const linhas = [];

  if (soTelefones) {
    // `select('*')` e não a lista de colunas, pelo mesmo motivo das outras
    // rotinas: o formato de `advogados` varia com o que já foi rodado no banco.
    const { data: fones, error } = await supabase.from('advogados').select('*');
    if (error) {
      console.log(`Permissões: não consegui ler os telefones (${error.message}).`);
      return;
    }
    const porChave = new Map((fones || []).map((f) => [chaveDoNumero(f.numero), f.id]));
    const perdidos = [];
    for (const n of numeros) {
      const id = porChave.get(chaveDoNumero(n));
      if (id) linhas.push({ usuario_id: usuarioId, telefone_id: id });
      else perdidos.push(n);
    }
    if (perdidos.length) {
      console.log(`Permissões de ${u.login}: o Zorvin não tem os telefones ${perdidos.join(', ')}.`);
    }
    // Nenhum telefone reconhecido: sair sem apagar nada. Substituir a permissão
    // por uma lista vazia deixaria a pessoa cega por causa de um número escrito
    // diferente dos dois lados — e o sintoma não apontaria para a causa.
    if (!linhas.length) return;
  } else if (chaves.length) {
    const { data, error } = await supabase
      .from('departamentos').select('id, slug').in('slug', chaves);
    if (error) {
      console.log(`Permissões: não consegui ler os departamentos (${error.message}).`);
      return;
    }
    for (const d of data || []) linhas.push({ usuario_id: usuarioId, departamento_id: d.id });
    // Chave marcada no Vantoro que não existe aqui é erro de digitação lá. Fica
    // registrado: é o que explica "marquei e a pessoa continua sem ver".
    const achados = new Set((data || []).map((d) => d.slug));
    const perdidas = chaves.filter((s) => !achados.has(s));
    if (perdidas.length) {
      console.log(`Permissões de ${u.login}: o Zorvin não conhece ${perdidas.join(', ')}.`);
    }
  }

  // AGORA AS DUAS ESPÉCIES DE LINHA SÃO SUBSTITUÍDAS — antes, só as de
  // departamento eram. A regra mudou porque o lugar de decidir mudou: enquanto
  // o telefone só se liberava aqui, apagar essas linhas seria o sistema mais
  // grosseiro passando por cima do mais fino. Agora o Vantoro tem a tela dos
  // dois cortes, e quem tem perfil lá tem a resposta inteira lá. Deixar
  // sobrar linha de telefone dada em outro tempo faria a pessoa continuar vendo
  // o que a tela diz que ela não vê — e ninguém procuraria o resto da resposta
  // num segundo lugar.
  //
  // A consulta não cita `grupo_id` de propósito: a coluna ainda existe, mas os
  // grupos saíram e ela está esperando o painel parar de mencioná-la para ser
  // apagada. Amarrar esta rotina a ela faria a permissão parar de ser aplicada
  // no dia em que a coluna sumir — e sem nada dizendo por quê.
  const { error: erroApaga } = await supabase
    .from('permissoes').delete().eq('usuario_id', usuarioId);
  if (erroApaga) {
    console.log(`Permissões: não consegui limpar as antigas (${erroApaga.message}).`);
    return;
  }
  if (!linhas.length) return;

  const { error: erroInsere } = await supabase.from('permissoes').insert(linhas);
  if (erroInsere) console.log(`Permissões: não consegui gravar (${erroInsere.message}).`);
}

// ------------------------------------------------------------
//  A PERMISSÃO NÃO PODE ESPERAR O PRÓXIMO LOGIN
//
//  Aplicar só na entrada tem um defeito que só aparece no uso: quem já está com
//  o painel aberto — que é o caso de todo mundo no meio do expediente —
//  continua com a permissão velha até sair e entrar de novo. Do lado de quem
//  administra, o sintoma é exatamente "liberei o departamento e a pessoa
//  continua sem ver as conversas", sem nada na tela explicando que falta um
//  logout.
//
//  Esta rotina reaplica a permissão de todo mundo de tempos em tempos, lendo a
//  mesma lista que o Vantoro já expõe em /usuarios. Quem estiver com a tela
//  aberta passa a enxergar sozinho, sem instrução nenhuma.
//
//  Só mexe em quem JÁ ENTROU alguma vez (está em `usuarios`): criar conta no
//  Supabase para quem nunca entrou encheria a base de contas que ninguém pediu,
//  e a permissão dessa pessoa é aplicada no primeiro login dela de todo jeito.
// ------------------------------------------------------------
const PERMISSOES_INTERVALO_MS = 3 * 60 * 1000;

async function sincronizarPermissoes() {
  if (!VANTORO_URL || !VANTORO_TOKEN) return;

  const { status, corpo } = await chamarVantoro('/usuarios');
  if (status !== 200 || !corpo || !Array.isArray(corpo.usuarios)) {
    console.log(`Permissões: o Vantoro respondeu ${status} ao listar usuários.`);
    return;
  }

  const { data: espelhados, error } = await supabase
    .from('usuarios').select('id, login, email');
  if (error) {
    console.log(`Permissões: não consegui ler os usuários (${error.message}).`);
    return;
  }

  // Casa pelo login E pelo e-mail. O login é a identidade no Vantoro; o e-mail
  // entra porque foi ele que abriu a conta aqui, e quem trocou de login lá
  // continuaria casando por ele.
  const porLogin = new Map();
  const porEmail = new Map();
  for (const u of espelhados || []) {
    if (u.login) porLogin.set(String(u.login).toLowerCase(), u.id);
    if (u.email) porEmail.set(String(u.email).toLowerCase(), u.id);
  }

  let aplicadas = 0;
  for (const u of corpo.usuarios) {
    const id = porLogin.get(String(u.login || '').toLowerCase())
            || porEmail.get(String(u.email || '').toLowerCase());
    if (!id) continue;   // ainda não entrou no Zorvin nenhuma vez
    try {
      await aplicarPermissoes(id, u);
      aplicadas += 1;
    } catch (e) {
      console.log(`Permissões de ${u.login}: ${(e && e.message) || e}`);
    }
  }
  if (aplicadas) console.log(`Permissões: reaplicadas para ${aplicadas} usuário(s).`);
}

// ------------------------------------------------------------
//  TELEFONE SEM DEPARTAMENTO É TELEFONE INVISÍVEL
//
//  A regra de visibilidade compara o departamento da permissão com o do
//  TELEFONE. Telefone sem departamento não bate com nada, então as conversas
//  dele somem para todo mundo que não é administrador — e somem em silêncio,
//  inclusive para quem tem a permissão certa. É a causa que mais engana, porque
//  a permissão está lá, marcada, correta.
//
//  O SQL que criou os departamentos já resolveu isso para os telefones daquele
//  dia (cada um foi para o departamento do seu `setor`, e quem não tinha setor
//  foi para `acordos`, que era o padrão de antes). Telefone cadastrado DEPOIS
//  nasce sem departamento e recria o problema. Esta rotina aplica a mesma regra
//  daquele SQL, continuamente — não é regra nova, é a mesma deixando de valer
//  só uma vez.
// ------------------------------------------------------------
async function garantirDepartamentoDosTelefones() {
  // `select('*')` e não a lista de colunas: o formato de `advogados` varia com
  // o que já foi rodado no banco, e pedir uma coluna que ainda não existe
  // devolve erro e mata a rotina inteira. É o mesmo cuidado que a busca do
  // advogado no webhook já toma, e pelo mesmo motivo.
  const { data: fones, error } = await supabase
    .from('advogados').select('*').is('departamento_id', null);
  if (error || !fones || !fones.length) return;

  const { data: deps } = await supabase.from('departamentos').select('id, slug');
  if (!deps || !deps.length) return;
  const porSlug = new Map(deps.map((d) => [d.slug, d.id]));
  const padrao = porSlug.get('acordos') || deps[0].id;

  for (const f of fones) {
    const destino = porSlug.get(String(f.setor || '').trim()) || padrao;
    const { error: erroGrava } = await supabase
      .from('advogados').update({ departamento_id: destino }).eq('id', f.id);
    if (erroGrava) {
      console.log(`Telefone ${f.nome || f.numero || f.id}: não consegui definir o departamento (${erroGrava.message}).`);
    } else {
      console.log(`Telefone ${f.nome || f.numero || f.id} estava sem departamento — suas conversas `
                + 'não apareciam para ninguém que não fosse administrador. Corrigido.');
    }
  }
}

// A primeira rodada sai logo depois de subir (dando tempo de o processo ficar
// de pé), e daí em diante no intervalo. `unref` para o temporizador não segurar
// o processo se ele for encerrado.
async function rodada() {
  // A ordem importa: o telefone precisa ter departamento ANTES de a permissão
  // ser conferida, senão a primeira rodada aplica permissão que ainda não
  // alcança conversa nenhuma.
  await garantirDepartamentoDosTelefones().catch(() => {});
  await mandarDepartamentosAoVantoro().catch(() => {});
  // Os telefones vão DEPOIS dos departamentos: a tela de permissões mostra a que
  // departamento cada número pertence, e para isso o departamento já tem de
  // existir lá. Na ordem inversa, a primeira sincronização mostraria os números
  // soltos, e quem marcasse ali não veria que já estavam cobertos.
  await mandarTelefonesAoVantoro().catch(() => {});
  await sincronizarPermissoes().catch(() => {});
}
setTimeout(() => { rodada().catch(() => {}); }, 20 * 1000).unref();
setInterval(() => { rodada().catch(() => {}); }, PERMISSOES_INTERVALO_MS).unref();

// ============================================================
//  A TELA DE ATENDENTES DO ZORVIN
//
//  Quem administra o escritório passa a dar e tirar acesso DENTRO do Zorvin, em
//  vez de abrir o admin do Django. É a mesma permissão — não uma segunda.
//
//  E é por isso que estas rotas escrevem no VANTORO, e não direto em
//  `permissoes` aqui. A Ponte reescreve as linhas de lá a partir do Vantoro a
//  cada poucos minutos: o que a tela gravasse direto no Supabase sumiria
//  sozinho na rodada seguinte, sem nada dizendo por quê. Uma resposta, um lugar.
//
//  Depois de gravar, a permissão é aplicada NA HORA (`aplicarPermissoes`), sem
//  esperar a rodada: quem acabou de marcar quer conferir na tela ao lado, e
//  "espere três minutos" é o tipo de coisa que faz a pessoa marcar de novo
//  achando que não salvou.
// ============================================================

// Só admin abre: as duas rotas contam e mudam quem enxerga o quê.
function soAdmin(handler) {
  return rotaVantoro(async (req, usuario) => {
    const { data: eu } = await supabase
      .from('usuarios').select('admin').eq('id', usuario.id).maybeSingle();
    if (!eu || !eu.admin) {
      return { status: 403, corpo: { ok: false, erro: 'Só quem administra pode mexer nas permissões.' } };
    }
    return handler(req, usuario);
  });
}

// Nomeadas, e não escritas dentro do `app.get`: assim dá para exercitá-las com
// um dublê do Supabase e do Vantoro, que é o único jeito de conferir quem pode
// mexer em quê sem depender de um banco de verdade.
async function listarAtendentes() {
  // A lista sai do Vantoro porque é lá que a permissão mora. Vem com o estado de
  // cada pessoa (departamentos, telefones e a chave), que é o que a tela desenha.
  const { status, corpo } = await chamarVantoro('/usuarios');
  if (status !== 200 || !corpo || !corpo.ok) {
    return { status: 502, corpo: { ok: false, erro: 'Não consegui ler os usuários do Vantoro.' } };
  }
  // Quem nunca entrou no Zorvin ainda não tem conta aqui — e a permissão dele só
  // vira linha no dia em que entrar. A tela precisa dizer isso, senão o
  // administrador marca, confere e não vê efeito nenhum.
  const { data: contas } = await supabase.from('usuarios').select('id, login, email');
  const conhecidos = new Set();
  for (const c of contas || []) {
    if (c.login) conhecidos.add(String(c.login).toLowerCase());
    if (c.email) conhecidos.add(String(c.email).toLowerCase());
  }
  const usuarios = (corpo.usuarios || []).map((u) => ({
    ...u,
    ja_entrou: conhecidos.has(String(u.login || '').toLowerCase())
            || conhecidos.has(String(u.email || '').toLowerCase()),
  }));
  return { status: 200, corpo: { ok: true, usuarios } };
}

async function gravarAtendente(req) {
  const corpoEnviado = req.body || {};
  if (!corpoEnviado.usuario) {
    return { status: 400, corpo: { ok: false, erro: 'Informe de quem é a permissão.' } };
  }
  const { status, corpo } = await chamarVantoro('/zorvin/permissoes', {
    method: 'POST',
    body: JSON.stringify(corpoEnviado),
  });
  if (status !== 200 || !corpo || !corpo.ok) {
    return { status, corpo: corpo || { ok: false, erro: 'O Vantoro não aceitou a mudança.' } };
  }

  // Aplicar agora, e não na próxima rodada. Se falhar, a gravação no Vantoro
  // continua valendo — a rodada seguinte aplica. Por isso o erro daqui não
  // desfaz nada: ele só avisa que o efeito vai demorar alguns minutos.
  let aplicada = false;
  try {
    const login = String(corpo.usuario.login || '').toLowerCase();
    const { data: contas } = await supabase.from('usuarios').select('id, login, email');
    const conta = (contas || []).find(
      (c) => String(c.login || '').toLowerCase() === login
          || String(c.email || '').toLowerCase() === login);
    if (conta) {
      await aplicarPermissoes(conta.id, { ...corpo.usuario, admin: false });
      aplicada = true;
    }
  } catch (e) {
    console.log('Permissões: gravei no Vantoro mas não apliquei agora —', (e && e.message) || e);
  }
  return { status: 200, corpo: { ok: true, usuario: corpo.usuario, aplicada } };
}

app.options('/permissoes/atendentes', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/permissoes/atendentes', soAdmin(listarAtendentes));
app.options('/permissoes/atendente', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.post('/permissoes/atendente', soAdmin(gravarAtendente));


// ============================================================
//  JUNTAR DUAS CONVERSAS À MÃO
//
//  A junção automática dos grupos depende de reconhecer o rastro que o erro
//  deixou, e ela só roda quando chega uma mensagem nova daquele grupo. Duas
//  coisas que ela não alcança:
//
//    - grupo parado: ninguém escreve nele há dias, então nada dispara;
//    - rastro que não bate com nenhum dos padrões conhecidos — e aí o certo é
//      deixar quem OLHA a tela dizer "estas duas são a mesma", em vez de o
//      código adivinhar com mais uma regra.
//
//  Esta rota é isso: a pessoa aponta as duas, e nós movemos.
//
//  Ela mora AQUI e não no painel por causa do RLS: mover mensagem é UPDATE em
//  `mensagens`, e apagar conversa é DELETE em `conversas` — duas coisas que o
//  painel não pode fazer (e não deve). A ponte fala com o banco pelo papel de
//  serviço, e por isso é ela quem faz, com o admin conferido antes.
// ============================================================
async function juntarConversas(req) {
  const de = String((req.body && req.body.de) || '').trim();
  const para = String((req.body && req.body.para) || '').trim();
  if (!de || !para) return { status: 400, corpo: { ok: false, erro: 'Informe as duas conversas.' } };
  if (de === para) return { status: 400, corpo: { ok: false, erro: 'São a mesma conversa.' } };

  const { data: ambas, error } = await supabase
    .from('conversas').select('id, advogado_id, contato_id').in('id', [de, para]);
  if (error) return { status: 500, corpo: { ok: false, erro: error.message } };
  const origem = (ambas || []).find((c) => String(c.id) === de);
  const destino = (ambas || []).find((c) => String(c.id) === para);
  if (!origem || !destino) return { status: 404, corpo: { ok: false, erro: 'Não achei uma das conversas.' } };
  // Telefones diferentes não se juntam: a conversa pertence ao número por onde
  // ela aconteceu, e misturar dois números apagaria essa informação — além de
  // levar mensagem para um telefone que talvez outra equipe enxergue.
  if (String(origem.advogado_id) !== String(destino.advogado_id)) {
    return { status: 400, corpo: { ok: false,
      erro: 'As duas conversas são de telefones diferentes. Junte só conversas do mesmo número.' } };
  }

  const { movidas, erro: erroMove } = await mudarDeConversa(origem.id, destino.id);
  if (erroMove) return { status: 500, corpo: { ok: false, erro: erroMove } };

  await supabase.from('conversas').delete().eq('id', origem.id);

  // O contato da conversa que saiu só é apagado se não sobrou conversa nenhuma
  // nele — ele pode ter conversa em outro telefone do escritório, e aí não é
  // nosso para apagar.
  const { data: sobrou } = await supabase
    .from('conversas').select('id').eq('contato_id', origem.contato_id).limit(1);
  if (!sobrou || !sobrou.length) {
    await supabase.from('contatos').delete().eq('id', origem.contato_id);
  }
  console.log(`Conversas: juntei ${movidas} mensagem(ns) da conversa ${origem.id} na ${destino.id}.`);
  return { status: 200, corpo: { ok: true, movidas } };
}

app.options('/conversas/juntar', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.post('/conversas/juntar', soAdmin(juntarConversas));


// ------------------------------------------------------------
//  HISTÓRICO DE ATENDIMENTO DE UM CLIENTE
//
//  Quem já falou com esta pessoa, quando, e por qual dos telefones do
//  escritório. O painel montava isso sozinho, direto do Supabase — e por isso
//  via só os telefones que a PESSOA LOGADA alcança: a regra de linha
//  (`pode_ver_conversa`) recorta a consulta dela. Uma lista recortada respondia
//  "ninguém falou com esse cliente" quando a resposta certa era "falaram, por
//  um telefone que você não abre".
//
//  Aqui a chave é a de serviço, que enxerga o escritório inteiro. É por isso
//  que esta rota existe em vez de uma política mais frouxa no banco: afrouxar
//  a leitura de `conversas` abriria TODAS as conversas para todo mundo dentro
//  do painel, e não é isso que se quer. O que sai daqui é só o RESUMO — nome
//  de quem escreveu, data e telefone. Nenhum texto de mensagem atravessa.
//
//  Basta estar logado no Zorvin: a informação é de organização do trabalho, e
//  guardá-la por permissão é justamente o que criava a resposta errada.
// ------------------------------------------------------------
app.options('/historico/contato/:id', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/historico/contato/:id', rotaVantoro(async (req) => {
  const contatoId = String(req.params.id || '').trim();
  if (!contatoId) return { status: 400, corpo: { ok: false, erro: 'Informe o contato.' } };

  const { data: convs, error } = await supabase
    .from('conversas').select('id, advogado_id').eq('contato_id', contatoId);
  if (error) return { status: 502, corpo: { ok: false, erro: 'Não consegui ler o histórico.' } };

  const { data: advs } = await supabase.from('advogados').select('id, nome, numero');

  // PRIMEIRA e ÚLTIMA por conversa, com `limit(1)` em cada sentido — e não uma
  // leitura de tudo para depois escolher. Cliente antigo tem milhares de
  // mensagens, e seriam todas na memória da ponte para mostrar duas.
  const ponta = (convId, crescente) => supabase
    .from('mensagens')
    .select('enviado_por, enviado_por_foto, criado_em')
    .eq('conversa_id', convId).eq('origem', 'advogado')
    .order('criado_em', { ascending: crescente }).limit(1);

  const linhas = await Promise.all((convs || []).map(async (v) => {
    const [pri, ult] = await Promise.all([ponta(v.id, true), ponta(v.id, false)]);
    const adv = (advs || []).find((a) => String(a.id) === String(v.advogado_id)) || null;
    return {
      conversa_id: v.id,
      advogado_id: v.advogado_id,
      advogado_nome: adv ? adv.nome : null,
      advogado_numero: adv ? adv.numero : null,
      primeira: (pri.data || [])[0] || null,
      ultima: (ult.data || [])[0] || null,
    };
  }));

  return { status: 200, corpo: { ok: true, linhas } };
}));


// ------------------------------------------------------------
//  POR QUE FULANO NÃO VÊ AS CONVERSAS
//
//  A regra de visibilidade tem alguns elos, e quando um falha o sintoma é
//  sempre o mesmo: tela vazia. Sem esta rota, descobrir QUAL deles falhou exige
//  abrir o Supabase e escrever consulta — e quem administra o escritório não
//  faz isso. Aqui a resposta vem em português, com o passo que resolve.
//
//  Só admin abre: a resposta conta quem enxerga o quê.
// ------------------------------------------------------------
app.options('/permissoes/diagnostico', (req, res) => { liberarCors(res); res.sendStatus(204); });
app.get('/permissoes/diagnostico', rotaVantoro(async (req, usuario) => {
  const { data: eu } = await supabase
    .from('usuarios').select('admin').eq('id', usuario.id).maybeSingle();
  if (!eu || !eu.admin) {
    return { status: 403, corpo: { ok: false, erro: 'Só quem administra pode abrir este diagnóstico.' } };
  }

  const alvo = String(req.query.login || req.query.email || '').trim().toLowerCase();
  if (!alvo) return { status: 400, corpo: { ok: false, erro: 'Informe ?login=' } };

  const { data: pessoas } = await supabase
    .from('usuarios').select('id, login, nome, email, admin, ativo');
  const pessoa = (pessoas || []).find(
    (p) => String(p.login || '').toLowerCase() === alvo
        || String(p.email || '').toLowerCase() === alvo);

  if (!pessoa) {
    return { status: 200, corpo: { ok: true, problema:
      'Esta pessoa nunca entrou no Zorvin. A permissão é gravada aqui na primeira '
      + 'entrada dela — peça para ela fazer login uma vez.' } };
  }
  if (pessoa.admin) {
    return { status: 200, corpo: { ok: true, problema: null,
      resumo: 'É administradora: enxerga todas as conversas, independentemente de permissão.' } };
  }

  const { data: perms } = await supabase
    .from('permissoes').select('departamento_id, telefone_id').eq('usuario_id', pessoa.id);
  const { data: deps } = await supabase.from('departamentos').select('id, nome');
  const nomeDep = new Map((deps || []).map((d) => [d.id, d.nome]));

  // Telefone sem departamento é invisível para quem não é admin: a regra compara
  // o departamento da permissão com o do telefone, e comparar com vazio nunca dá
  // verdadeiro. É a causa que mais engana, porque a permissão ESTÁ lá.
  const { data: fones } = await supabase.from('advogados').select('*');
  const orfaos = (fones || []).filter((f) => !f.departamento_id);
  const nomeDoFone = (f) => f.nome || f.numero || f.id;

  const liberados = (perms || []).filter((p) => p.departamento_id)
    .map((p) => nomeDep.get(p.departamento_id) || `#${p.departamento_id}`);

  // Permissão por TELEFONE deixou de ser exceção: é o corte fino da tela do
  // Vantoro ("limitar a telefones específicos"), e quem está nele vê os números
  // marcados e mais nada. Antes esta rota tratava isso como defeito — dizia
  // "ela tem permissão só por telefone" como se faltasse alguma coisa, e quem
  // lia ia mexer numa configuração que estava certa.
  const nomeDoFone2 = new Map((fones || []).map((f) => [f.id, f.nome || f.numero || f.id]));
  const fonesLiberados = (perms || []).filter((p) => p.telefone_id)
    .map((p) => nomeDoFone2.get(p.telefone_id) || `#${p.telefone_id}`);

  let problema = null;
  if (!pessoa.ativo) {
    problema = 'O acesso dela está desativado aqui.';
  } else if (!perms || !perms.length) {
    problema = 'Não há permissão nenhuma gravada para esta pessoa. Confira se o '
             + 'departamento está marcado no cadastro dela no Vantoro — a Ponte '
             + 'reaplica a cada poucos minutos.';
  } else if (!liberados.length && !fonesLiberados.length) {
    problema = 'Há linhas de permissão, mas nenhuma aponta para departamento nem '
             + 'para telefone. É resto de uma versão antiga: salve o cadastro dela '
             + 'no Vantoro para a Ponte regravar.';
  } else if (orfaos.length && liberados.length) {
    problema = `Há ${orfaos.length} telefone(s) sem departamento definido `
             + `(${orfaos.slice(0, 5).map(nomeDoFone).join(', ')}). `
             + 'As conversas deles não aparecem para quem não é administrador — '
             + 'defina o departamento de cada telefone.';
  }

  return { status: 200, corpo: { ok: true, pessoa: pessoa.login, ativa: pessoa.ativo,
    departamentos_liberados: liberados,
    // Quando esta lista vem preenchida, a pessoa está no corte fino: ela vê
    // ESTES telefones e nada mais, e é por isso que os departamentos podem
    // aparecer vazios sem que haja nada errado.
    telefones_liberados: fonesLiberados,
    telefones_sem_departamento: orfaos.length, problema } };
}));

app.options('/auth/login', (req, res) => { liberarCors(res); res.sendStatus(204); });

app.post('/auth/login', async (req, res) => {
  liberarCors(res);
  const login = String((req.body && (req.body.login || req.body.email)) || '').trim();
  const senha = String((req.body && req.body.senha) || '');
  if (!login || !senha) {
    return res.status(400).json({ ok: false, erro: 'Informe usuário e senha.' });
  }

  const chaveFreio = `${req.ip || 'sem-ip'}|${login.toLowerCase()}`;
  if (freioBateu(chaveFreio)) {
    return res.status(429).json({
      ok: false,
      erro: 'Muitas tentativas seguidas. Espere alguns minutos e tente de novo.',
    });
  }

  try {
    const { status, corpo } = await chamarVantoro('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ login, senha }),
    });
    if (status !== 200 || !corpo || !corpo.ok) {
      // Repassa 401/403 como vieram; qualquer outra coisa é problema nosso, e
      // dizer "usuário ou senha incorretos" quando o Vantoro está fora do ar
      // mandaria a equipe caçar um erro que não existe.
      if (status === 401 || status === 403) {
        return res.status(status).json({ ok: false, erro: (corpo && corpo.erro) || 'Login ou senha incorretos.' });
      }
      console.error('login: Vantoro respondeu', status, corpo && corpo.erro);
      return res.status(503).json({
        ok: false,
        erro: 'O Vantoro não respondeu agora — é ele quem confere a senha. Tente de novo em instantes.',
      });
    }

    const u = corpo.usuario;
    const email = String(u.email || '').toLowerCase();
    const id = await contaDoSupabase(email, u.nome);

    // O NOME VEM DO CADASTRO DO VANTORO, SEMPRE.
    //
    // `contaDoSupabase` grava o nome só no dia em que a conta nasce. Quem
    // entrou antes de o Vantoro ter o nome completo ficou com o que havia na
    // hora — em geral o começo do e-mail ("rodrigo", "max") — e nada nunca
    // trocava aquilo. Era esse nome que assinava a bolha e que ia para o
    // Painel, e por isso a mesma pessoa aparecia duas vezes no relatório.
    //
    // Agora cada entrada realinha. É de propósito que a fonte seja o Vantoro:
    // é lá que o cadastro de pessoa mora e é lá que quem administra mexe. O
    // Zorvin não é dono do nome de ninguém.
    await alinharNomeDaConta(id, u.nome);

    // Espelha quem é a pessoa, para a tela de permissões mostrar nome em vez
    // de um código, e para as regras de visibilidade terem onde se apoiar.
    // `admin` do Vantoro manda: quem é superusuário lá administra aqui.
    const { error: erroUsuario } = await supabase.from('usuarios').upsert({
      id, login: u.login, nome: u.nome || '', email,
      admin: Boolean(u.admin), ativo: true, visto_em: new Date().toISOString(),
    }, { onConflict: 'id' });
    if (erroUsuario) {
      console.log(`login: não espelhei o usuário (${erroUsuario.message}). Falta rodar o SQL de departamentos?`);
    }

    // As duas metades que faltavam para a permissão do Vantoro valer aqui.
    // Rodam DEPOIS de espelhar o usuário (as permissões dependem da linha dele)
    // e sem `await` bloqueando a entrada: quem está digitando a senha não pode
    // esperar por sincronização. Se falharem, a pessoa entra com o que já
    // tinha, e a próxima entrada tenta de novo.
    mandarDepartamentosAoVantoro().catch(() => {});
    aplicarPermissoes(id, u).catch(() => {});

    // O bilhete de entrada. É de uso único e curta duração — o painel troca
    // por uma sessão na hora. A senha não vai junto, e não existe do lado de cá.
    const { data: link, error: erroLink } = await supabase.auth.admin.generateLink({
      type: 'magiclink', email,
    });
    if (erroLink || !link || !link.properties || !link.properties.hashed_token) {
      console.error('login: generateLink falhou —', erroLink && erroLink.message);
      return res.status(502).json({ ok: false, erro: 'Não consegui abrir a sessão. Tente de novo.' });
    }

    freioLimpa(chaveFreio);
    return res.json({
      ok: true,
      token_hash: link.properties.hashed_token,
      email,
      usuario: { login: u.login, nome: u.nome, admin: Boolean(u.admin) },
    });
  } catch (e) {
    console.error('login:', (e && e.message) || e);
    return res.status(502).json({ ok: false, erro: 'Não foi possível entrar agora. Tente de novo.' });
  }
});

// ============================================================
//  FRENTES — de quem é esta conversa?
//
//  O mesmo número de advogado atende duas coisas opostas: negociar acordo com
//  o escritório do réu e avisar/atender o próprio cliente. Separar pelo número
//  não funciona; quem define é quem está do outro lado, e isso o Vantoro sabe.
//
//    CLIENTE       — é um cliente nosso (SAC, audiências)
//    ACORDO        — é o advogado da parte contrária, ou a própria parte
//    LEAD          — não é conhecido e escreveu vindo de um anúncio
//    INTERNO       — chegou num número nosso de uso interno (RH, cadastro)
//    DESCONHECIDA  — ainda não deu para saber
//
//  A frente fica gravada no CONTATO (quem a pessoa é não muda de advogado para
//  advogado) e é copiada para a CONVERSA, que é onde o painel filtra.
// ============================================================

// Reclassifica um contato no máximo uma vez por semana. A resposta quase nunca
// muda, e perguntar ao Vantoro a cada mensagem só atrasaria o webhook.
const FRENTE_VALIDADE_MS = 7 * 24 * 60 * 60 * 1000;

// Marcas que a Uazapi manda quando a conversa começou por um anúncio de
// clique-para-WhatsApp. Não é lista fechada: por isso procuramos no JSON todo.
const MARCAS_DE_ANUNCIO = ['externaladreply', 'sourceurl', 'sourceid', 'ctwa', 'referral'];

function veioDeAnuncio(body) {
  try {
    const blob = JSON.stringify(body || {}).toLowerCase();
    return MARCAS_DE_ANUNCIO.some((marca) => blob.includes(marca));
  } catch (_e) {
    return false;
  }
}

// Grava colunas que talvez ainda não existam (o SQL das frentes pode não ter
// sido rodado). Isso nunca pode derrubar a entrada de mensagens: conversa sem
// etiqueta é um contratempo; mensagem perdida, não.
// Coluna que não existe é problema PERMANENTE — só passa quando alguém roda o
// SQL. Continuar tentando a cada mensagem não conserta nada e enche o log do
// Postgres de erro, que é onde um erro de verdade precisaria ser visto. Então a
// primeira recusa por coluna inexistente desliga aquela gravação até o próximo
// restart da ponte (que é quando o SQL novo teria sido rodado, de todo modo).
//
// Erro de rede NÃO entra nesta conta: esse passa sozinho, e desligar por causa
// dele deixaria a etiqueta parada por horas sem motivo.
const SEM_ESSA_COLUNA = ['42703', '42P01', 'PGRST204', 'PGRST200'];
const faltaColuna = (erro) => Boolean(erro) && (
  SEM_ESSA_COLUNA.includes(String(erro.code)) ||
  /does not exist|could not find|schema cache/i.test(String(erro.message || '')));

const GRAVACOES_DESLIGADAS = new Set();

async function gravarTolerante(tabela, campos, filtro, rotulo) {
  const chave = tabela + ':' + Object.keys(campos).sort().join(',');
  if (GRAVACOES_DESLIGADAS.has(chave)) return false;

  const { error } = await supabase.from(tabela).update(campos).match(filtro);
  if (!error) return true;

  if (faltaColuna(error)) {
    GRAVACOES_DESLIGADAS.add(chave);
    console.log(`${rotulo}: a coluna não existe (${error.message}). `
      + 'Parei de tentar até a ponte reiniciar — rode o SQL das frentes no Supabase.');
  } else {
    console.log(`${rotulo}: não gravei agora (${error.message}). Tento na próxima.`);
  }
  return false;
}

async function perguntarFrenteAoVantoro(numero) {
  const { status, corpo } = await chamarVantoro(
    `/contatos/classificar?telefone=${encodeURIComponent(numero)}`);
  if (status !== 200 || !corpo || !corpo.ok) return null;
  return corpo;
}

/**
 * Descobre e grava a frente desta conversa.
 *
 * Ordem de decisão, da mais forte para a mais fraca:
 *   1. o número NOSSO que recebeu é de uso interno  → a frente dele manda;
 *   2. o Vantoro reconhece a pessoa                 → CLIENTE ou ACORDO;
 *   3. veio de anúncio e ninguém conhece            → LEAD;
 *   4. nada disso                                   → DESCONHECIDA.
 */
async function definirFrente(contato, advogado, conversaId, body) {
  try {
    if (advogado.frente_fixa) {
      await gravarTolerante('conversas', { frente: advogado.frente_fixa },
        { id: conversaId }, 'frente da conversa');
      return advogado.frente_fixa;
    }

    const recente = contato.frente_em &&
      (Date.now() - new Date(contato.frente_em).getTime()) < FRENTE_VALIDADE_MS;
    let frente = contato.frente || null;

    if (!recente) {
      const resposta = await perguntarFrenteAoVantoro(contato.numero);
      if (resposta) {
        frente = resposta.frente;
        if (frente === 'DESCONHECIDA' && veioDeAnuncio(body)) frente = 'LEAD';
        await gravarTolerante('contatos', {
          frente,
          frente_em: new Date().toISOString(),
          vantoro_cliente_id: resposta.cliente ? resposta.cliente.id : null,
          vantoro_nome: resposta.cliente ? resposta.cliente.nome : null,
        }, { id: contato.id }, 'frente do contato');
      }
    }

    if (frente) {
      await gravarTolerante('conversas', { frente }, { id: conversaId }, 'frente da conversa');
    }
    return frente;
  } catch (e) {
    // Classificar é um extra. Se o Vantoro estiver fora do ar, a mensagem
    // continua entrando normalmente e a etiqueta sai na próxima.
    console.log('Frente: não consegui classificar agora —', (e && e.message) || e);
    return null;
  }
}

// ============================================================
//  GRUPOS DENTRO DO DEPARTAMENTO
//
//  O departamento diz de QUEM é o telefone (Advogados, SAC, Vendas). O grupo
//  diz que TIPO de conversa é aquela — e essa é a distinção que o telefone
//  sozinho nunca dá: no departamento Advogados, o mesmo número negocia acordo
//  com o réu e avisa o cliente da audiência.
//
//  Quem separa é quem está do outro lado, e isso a frente já respondeu. Aqui
//  só se traduz frente → grupo daquele departamento, com um balaio para o que
//  não se encaixar.
// ============================================================

// O GRUPO SAIU — e com ele a etiqueta que ninguém tinha criado.
//
// O grupo existia para um problema só: no departamento Advogados, os MESMOS
// telefones negociavam acordo com o réu e avisavam o cliente da audiência —
// duas conversas de natureza oposta no mesmo número. O aviso de audiência passou
// a sair de um telefone próprio, e aí o telefone voltou a responder a pergunta
// sozinho. O `sql/2026-07-sem-grupos.sql` já tinha tirado o grupo da permissão
// por isso; ficava só o carimbo na tela.
//
// E o carimbo era o pior pedaço: na lista, ele ficava idêntico às tags que a
// equipe cria à mão. "Sem identificar" — o balaio de quem ainda não tem ficha —
// caía em quase toda conversa, uma etiqueta dizendo "não sei" em cada linha.
//
// Gravar `conversas.grupo_id` a cada mensagem virou escrita que ninguém lê. Sai
// junto: é um UPDATE por mensagem recebida.

// O painel pergunta a frente de um número (para mostrar o selo na hora).
app.get('/vantoro/classificar', rotaVantoro(async (req) => {
  const telefone = String(req.query.telefone || '').replace(/\D/g, '');
  if (!telefone) return { status: 400, corpo: { ok: false, erro: 'Informe o telefone.' } };
  return chamarVantoro(`/contatos/classificar?telefone=${telefone}`);
}));

// ============================================================
//  AVISOS DE AUDIÊNCIA
//
//  O Vantoro monta a fila (quem avisar, o que dizer, de qual advogado sai) e a
//  ponte só executa: enfileira em fila_envio e, quando a Uazapi confirmar,
//  avisa o Vantoro de volta. Marcar como enviado na hora de enfileirar seria
//  mentira — a mensagem ainda não saiu.
// ============================================================

// A API de clientes fica em /cadastro/api/v1 e a de audiências em
// /audiencias/api/v1. Deriva uma da outra para não exigir mais uma variável;
// VANTORO_AUDIENCIAS_URL existe como escape se o endereço fugir do padrão.
const VANTORO_AUDIENCIAS = (process.env.VANTORO_AUDIENCIAS_URL ||
  VANTORO_URL.replace(/\/cadastro\/api\/v1$/, '/audiencias/api/v1')).replace(/\/+$/, '');

async function chamarAudiencias(caminho, opcoes = {}) {
  if (!VANTORO_AUDIENCIAS || !VANTORO_TOKEN) return { status: 503, corpo: null };
  const r = await fetchComTimeout(`${VANTORO_AUDIENCIAS}${caminho}`, {
    ...opcoes,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${VANTORO_TOKEN}`,
      ...(opcoes.headers || {}),
    },
  }, 20000);
  let corpo = null;
  try { corpo = await r.json(); } catch (_e) { corpo = null; }
  return { status: r.status, corpo };
}

async function avisoDeuErro(id, motivo) {
  try {
    await chamarAudiencias(`/avisos/${id}/erro`,
      { method: 'POST', body: JSON.stringify({ motivo }) });
  } catch (_e) { /* segue pendente no Vantoro; tentamos de novo no próximo ciclo */ }
}

// O Vantoro manda o número sem o código do país; a Uazapi quer com ele.
function numeroComPais(digitos) {
  const d = String(digitos || '').replace(/\D/g, '');
  if (!d) return '';
  return d.startsWith('55') ? d : `55${d}`;
}

let avisosRodando = false;
async function buscarAvisosDeAudiencia() {
  if (avisosRodando) return;
  avisosRodando = true;
  try {
    const { status, corpo } = await chamarAudiencias('/avisos/pendentes');
    if (status !== 200 || !corpo || !corpo.ok) return;
    const avisos = corpo.avisos || [];
    if (!avisos.length) return;
    console.log(`Audiências: ${avisos.length} aviso(s) para enviar.`);

    for (const aviso of avisos) {
      const destino = numeroComPais(aviso.telefone);
      if (!destino) {
        await avisoDeuErro(aviso.id, 'Cliente sem número de WhatsApp no cadastro.');
        continue;
      }

      // DE QUAL WHATSAPP ESTA MENSAGEM SAI.
      //
      // O Vantoro manda o NÚMERO da linha de audiências — todos os avisos saem
      // por ela, para o histórico do cliente não ficar espalhado por um número
      // diferente a cada advogado. Casamos pela chave do número, que tolera as
      // formas com e sem o 55 e com e sem o nono dígito.
      //
      // O nome continua aceito, e por isso a busca antiga ficou como segunda
      // tentativa: avisos já enfileirados antes desta mudança trazem o nome do
      // advogado da ação, e recusá-los faria o cliente não ser avisado por
      // causa de uma troca que é nossa, não dele.
      const pedido = String(aviso.remetente || '').trim();
      let adv = null;
      if (/^[\d\s()+-]+$/.test(pedido) && pedido.replace(/\D/g, '').length >= 10) {
        const { data: todos } = await supabase.from('advogados').select('id, nome, numero');
        adv = (todos || []).find((a) => chaveDoNumero(a.numero) === chaveDoNumero(pedido)) || null;
      } else if (pedido) {
        const { data } = await supabase.from('advogados')
          .select('id, nome').ilike('nome', `%${pedido}%`).limit(1).maybeSingle();
        adv = data || null;
      }
      if (!adv) {
        await avisoDeuErro(aviso.id,
          `Telefone "${pedido || '(em branco)'}" não encontrado no Zorvin.`);
        continue;
      }

      const { data: contato } = await supabase.from('contatos')
        .upsert({ numero: destino }, { onConflict: 'numero' }).select('id').single();
      if (!contato) { await avisoDeuErro(aviso.id, 'Não consegui criar o contato.'); continue; }

      const { data: conversa } = await supabase.from('conversas')
        .upsert({ advogado_id: adv.id, contato_id: contato.id },
          { onConflict: 'advogado_id,contato_id' }).select('id').single();
      if (!conversa) { await avisoDeuErro(aviso.id, 'Não consegui abrir a conversa.'); continue; }

      // Já nasce etiquetada: é conversa com CLIENTE, não negociação de acordo.
      await gravarTolerante('conversas', { frente: aviso.finalidade || 'CLIENTE' },
        { id: conversa.id }, 'frente do aviso');

      // aviso_vantoro_id tem índice único: se este ciclo repetir antes de a fila
      // ser processada, o banco recusa a segunda cópia e o cliente não recebe a
      // mesma mensagem duas vezes.
      const { error: filaErro } = await supabase.from('fila_envio').insert({
        conversa_id: conversa.id, texto: aviso.texto,
        status: 'pendente', tipo: 'texto', aviso_vantoro_id: aviso.id,
      });
      if (filaErro) {
        console.log(`Aviso ${aviso.id}: não entrou na fila (${filaErro.message}).`);
        continue;
      }
      console.log(`Aviso ${aviso.id} enfileirado para ${destino} por ${adv.nome}.`);
    }
  } catch (e) {
    console.error('Avisos de audiência:', (e && e.message) || e);
  } finally {
    avisosRodando = false;
  }
}

// Roda a verificação da fila a cada 3 segundos.
setInterval(processarFilaDeEnvio, 3000);

// Os avisos de audiência mudam de hora em hora, não de segundo em segundo:
// 5 minutos é de sobra e não pesa no plano free.
setInterval(buscarAvisosDeAudiencia, 5 * 60 * 1000);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
});
