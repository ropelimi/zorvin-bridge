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
    //
    // O erro destas duas era jogado fora, e o `contUp.id` da linha seguinte
    // estourava em cima do nulo. Quem roda isto é uma pessoa, num navegador, e
    // o que ela recebia era "Cannot read properties of null (reading 'id')" —
    // o sintoma de um erro que ninguém conferiu, mostrado a quem não pode
    // fazer nada com ele.
    const { data: contUp, error: erroContato } = await supabase.from('contatos')
      .upsert({ numero: contatoNumero }, { onConflict: 'numero' }).select('id').single();
    if (erroContato || !contUp) {
      console.error('Histórico: não consegui garantir o contato —', erroContato && erroContato.message);
      return res.status(502).send(
        'Não consegui preparar o contato no banco, então parei antes de importar qualquer coisa. '
        + 'Nada foi alterado. Tente de novo em alguns minutos.');
    }
    const { data: conv, error: erroConversa } = await supabase.from('conversas')
      .upsert({ advogado_id: adv.id, contato_id: contUp.id }, { onConflict: 'advogado_id,contato_id' })
      .select('id').single();
    if (erroConversa || !conv) {
      console.error('Histórico: não consegui garantir a conversa —', erroConversa && erroConversa.message);
      return res.status(502).send(
        'Não consegui preparar a conversa no banco, então parei antes de importar qualquer coisa. '
        + 'Nada foi alterado. Tente de novo em alguns minutos.');
    }

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

    let importadas = 0, vistas = 0, offset = 0, comArquivo = 0, semArquivo = 0;
    let pagina = primeira || [];
    while (pagina && pagina.length && vistas < limiteTotal) {
      // O QUE JÁ ESTÁ AQUI.
      //
      // A gravação ignora repetida em silêncio (é o que torna seguro rodar de
      // novo), então "não deu erro" NÃO quer dizer "entrou". Contando assim, a
      // segunda execução anunciava "Importei 500 mensagens" tendo importado
      // zero — e esse número é a única resposta que a tela dá.
      //
      // Saber de antemão o que já existe serve para duas coisas: contar a
      // verdade, e não baixar de novo as fotos que já estão guardadas.
      const linhas = pagina.map((m) => ({ m, linha: mapearMensagemHistorico(m, conv.id) }))
                           .filter((x) => x.linha);
      const idsDaPagina = linhas.map((x) => x.linha.id_uazapi);
      const conhecidas = new Set();
      if (idsDaPagina.length) {
        const { data: jaTem } = await supabase.from('mensagens')
          .select('id_uazapi').in('id_uazapi', idsDaPagina);
        for (const x of jaTem || []) conhecidas.add(x.id_uazapi);
      }

      for (const { m, linha } of linhas) {
        if (conhecidas.has(linha.id_uazapi)) continue;

        // A FOTO DO HISTÓRICO PRECISA SER BAIXADA, IGUAL À QUE CHEGA AGORA.
        //
        // O endereço que a Uazapi devolve aponta para o servidor do WhatsApp:
        // é temporário e vem cifrado. Guardá-lo na mensagem importa uma bolha
        // que não abre — hoje ou daqui a alguns dias —, e nada na tela
        // explicaria por quê. O caminho do webhook já copia o arquivo para o
        // Storage; aqui faltava fazer o mesmo.
        if (linha.tipo !== 'texto') {
          const guardada = await baixarMidiaRecebida(
            servidor, adv.token, { messageid: linha.id_uazapi, content: m.content }, linha.midia_mime);
          if (guardada) { linha.midia_url = guardada; comArquivo++; }
          else semArquivo++;
        }

        const erro = await salvarMensagem(linha, null);
        if (!erro) importadas++;
      }
      vistas += pagina.length;
      offset += pagina.length;
      if (pagina.length < PAG) break; // última página
      pagina = await buscarPagina(chatid, offset);
    }

    // Conserta a prévia e a ordem da conversa: a mensagem mais recente pode ter
    // mudado se o histórico trouxe algo posterior ao que havia aqui.
    //
    // O `nao_lidas: 0` que existia aqui saiu. A intenção era "histórico
    // importado não é mensagem nova" — e não é mesmo: esta rotina grava direto
    // em `mensagens`, sem passar pela contagem que o webhook faz, então ela
    // nunca somou nada ao selo. Zerar não corrigia um efeito colateral: apagava
    // aviso de mensagem de verdade, ainda por ler, que nada tinha a ver com a
    // importação. Quem importasse o passado de um cliente marcava como lidas as
    // mensagens que ele mandou hoje de manhã.
    const { data: ult } = await supabase.from('mensagens')
      .select('texto, tipo, criado_em').eq('conversa_id', conv.id)
      .order('criado_em', { ascending: false }).limit(1);
    const u = ult && ult[0];
    if (u) {
      await supabase.from('conversas').update({
        ultima_mensagem: u.texto || previaMidiaHist(u.tipo) || '[mídia]',
        ultima_atividade: u.criado_em,
      }).eq('id', conv.id);
    }

    console.log(`Histórico: ${importadas} novas de ${vistas} vistas (contato ${contatoNumero}).`);
    const sobreArquivos = comArquivo || semArquivo
      ? ` Guardei ${comArquivo} arquivo(s)`
        + (semArquivo ? `; ${semArquivo} não deu(ram) para baixar da Uazapi.` : '.')
      : '';
    return res.status(200).send(
      importadas === 0
        ? `Pronto! Nenhuma mensagem nova: as ${vistas} que a Uazapi tinha do contato `
          + `${contatoNumero} já estavam aqui.${sobreArquivos}`
        : `Pronto! Importei ${importadas} mensagem(ns) do contato ${contatoNumero} `
          + `(vistas ${vistas}).${sobreArquivos} Abra o painel para conferir.`
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

// ------------------------------------------------------------
//  UM WEBHOOK RECUSADO PRECISA DIZER DE QUEM ERA
//
//  A linha era só "Webhook recusado: segredo ausente ou errado." — e com ela
//  não dá para separar dois casos que pedem coisas opostas:
//
//    • um telefone da Uazapi cadastrado com o endereço SEM o `?token=`. Aí
//      são MENSAGENS DE CLIENTE sendo jogadas fora, e ninguém percebe: a
//      conversa simplesmente não aparece no painel.
//    • alguém varrendo a internet e batendo na porta. Aí é ruído, e recusar é
//      exatamente o certo.
//
//  Em 19/08 apareceram vinte recusas em vinte minutos, sempre em volta dos
//  envios. Vinte mensagens perdidas e vinte batidas de porta se escrevem
//  igual no log — e é essa igualdade que precisa acabar.
//
//  O QUE VAI E O QUE NÃO VAI. Vai o telefone dono do evento, o tipo do
//  evento, de que endereço veio, e SE veio um segredo (ausente é
//  configuração; errado é outra coisa). Não vai o segredo, nem um pedaço
//  dele: um log de escritório de advocacia é lugar onde muita gente entra e
//  nada se apaga.
// ------------------------------------------------------------
const recusasContadas = new Map();   // quem → quantas, desde quando

function contarRecusa(req) {
  const b = (req && req.body) || {};
  const dono = String(b.owner || b.instance || b.instanceName
    || (b.event && (b.event.owner || b.event.Chat)) || '').slice(0, 40) || 'sem dono no corpo';
  const tipo = String(b.EventType || b.event_type || b.event || '').slice(0, 30) || 'sem tipo';
  const veioAlgo = !!String(req.query.token || req.headers['x-webhook-token']
    || req.headers['x-api-key'] || '').trim();
  const de = (req.headers['x-forwarded-for'] || req.ip || '').split(',')[0].trim();

  // AGRUPADO, senão a informação some no próprio volume. Vinte linhas iguais
  // por minuto empurram para fora do log tudo o que interessa — inclusive o
  // que a gente foi ali procurar.
  const chave = `${dono}|${tipo}|${veioAlgo}|${de}`;
  const antes = recusasContadas.get(chave);
  const agora = Date.now();
  if (antes && agora - antes.desde < 60000) { antes.quantas += 1; return; }
  const quantas = antes ? antes.quantas : 0;
  recusasContadas.set(chave, { quantas: 1, desde: agora });

  console.warn(`Webhook recusado (${veioAlgo ? 'segredo ERRADO' : 'sem segredo nenhum'}): `
    + `evento "${tipo}" do telefone "${dono}", vindo de ${de || 'origem desconhecida'}.`
    + (quantas > 1 ? ` [${quantas} iguais no último minuto]` : '')
    + (veioAlgo ? '' : ' Se este telefone é do escritório, o endereço do webhook '
      + 'dele na Uazapi está sem o "?token=…" — e as mensagens dele estão sendo PERDIDAS.'));
}

app.post('/webhook', async (req, res) => {
  if (!webhookAutorizado(req)) {
    contarRecusa(req);
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
    //
    // A ORDEM IMPORTA, e ela estava invertida. `imagePreview` é a MINIATURA: o
    // WhatsApp manda duas versões da foto de perfil — uma de umas dezenas de
    // pixels, para desenhar em lista, e a cheia, de algumas centenas. Pegando a
    // miniatura primeiro, era a miniatura que ficava guardada. Deu para viver
    // com isso enquanto a foto só aparecia num avatar de 40 pixels; quando o
    // painel passou a abri-la em tamanho grande, ela apareceu embaçada — não
    // está borrada, está sendo ampliada muito além do que tem.
    //
    // A cheia na frente, a miniatura por último: melhor miniatura do que
    // contato sem foto nenhuma.
    const fotoContato =
      (body.chat && (body.chat.imgUrl || body.chat.image || body.chat.profilePicUrl
                  || body.chat.profilePictureUrl || body.chat.imagePreview)) || null;

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
    // `m.caption` É A LEGENDA DA FOTO, e ela não estava sendo lida aqui.
    //
    // O cliente manda a certidão e escreve "essa é a de casamento" por baixo.
    // A legenda vem em `caption`, e este caminho lia só `text` e `content` —
    // a frase sumia, e a bolha chegava com a imagem e mais nada. A importação
    // de histórico já lia `caption` (é a mesma mensagem, lida por outra porta),
    // então o mesmo anexo trazia a legenda quando importado e a perdia quando
    // chegava ao vivo. Duas leituras diferentes do mesmo campo é sempre uma
    // delas errada.
    const texto =
      m.text || (typeof m.content === 'string' ? m.content : '') || m.caption || null;

    // Miniatura embutida (prévia imediata, baixa resolução). Vale para a
    // FIGURINHA também: se o download do arquivo grande falhar, é ela que
    // impede a bolha de nascer vazia.
    let midiaUrl = null;
    if ((tipo === 'imagem' || tipo === 'figurinha') && m.content && m.content.JPEGThumbnail) {
      midiaUrl = 'data:image/jpeg;base64,' + m.content.JPEGThumbnail;
    }
    const midiaMime = (m.content && m.content.mimetype) || null;

    // ------------------------------------------------------------
    //  O ARQUIVO GRANDE VEM DEPOIS. A BOLHA VEM AGORA.
    //
    //  Aqui se esperava o download inteiro antes de gravar a mensagem:
    //
    //      webhook → downloadmedia (até 20s, e até 3 rotas) → baixa o arquivo
    //              → sobe para o Storage → SÓ ENTÃO grava → só então a bolha
    //
    //  Enquanto isso a conversa fica VAZIA. Não é o arquivo que demora a
    //  aparecer — é a mensagem inteira que ainda não existe. Quem atende vê o
    //  cliente dizer "te mandei a foto" e não vê foto nenhuma. Foi o relato:
    //  "ao enviar ou receber algum arquivo, está demorando para aparecer".
    //
    //  E a miniatura logo acima, cujo comentário promete "prévia imediata",
    //  não era imediata coisa nenhuma: ela era calculada e ficava esperando o
    //  arquivo grande junto com todo o resto.
    //
    //  Agora a ordem se inverte. Grava-se a mensagem com a miniatura, a bolha
    //  nasce na hora pelo tempo real, e o arquivo de verdade entra no lugar
    //  quando chegar — na MESMA bolha, sem piscar e sem duplicar.
    //
    //  Medido na bancada: com o download demorando 1,2s, a bolha nascia em
    //  1287ms e passou a nascer em menos de 200ms.
    // ------------------------------------------------------------
    const buscarOArquivoDepois = tipo !== 'texto'
      ? () => {
          const servidorAdv = (adv.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
          // Sem `await` de propósito: quem chamou já respondeu ao webhook.
          baixarMidiaRecebida(servidorAdv, adv.token, m, midiaMime)
            .then((urlReal) => (urlReal
              ? trocarMiniaturaPeloArquivo(m.messageid, urlReal, midiaMime)
              // O ID VAI JUNTO E INTEIRO — é por ele que se cruza com o
              // `FileURL` que chega depois, num `messages_update`. Sem os dois
              // lados escritos do mesmo jeito, não há como saber se um conserto
              // é possível.
              : console.log(`Anexo (${tipo}) sem arquivo: o download falhou. `
                  + `Mensagem ${m.messageid} fica sem mídia. `
                  + 'Quem abrir a conversa vê um anexo vazio.')))
            .catch((e) => console.log(`Anexo (${tipo}) ${m.messageid}: ${(e && e.message) || e}`));
        }
      : null;

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
    // A duração vai junto dos campos de citação, e não dentro de `base`, de
    // propósito: `salvarMensagem` já sabe regravar sem os extras quando o banco
    // não tem a coluna. Numa base sem o script rodado, a mensagem entra do
    // mesmo jeito — só sem o tempo.
    const extras = { ...(extrairResposta(m) || {}) };
    const segundos = segundosDaMidia(m, tipo);
    if (segundos) extras.midia_segundos = segundos;

    const msgErro = await salvarMensagem(base, Object.keys(extras).length ? extras : null);
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    // A BOLHA JÁ EXISTE. Agora sim vai buscar o arquivo grande.
    //
    // Depois da gravação, e não antes: se a gravação falhar, não há linha para
    // atualizar, e sair baixando megabytes para não escrever em lugar nenhum
    // seria trabalho jogado fora — pior, contra a Uazapi, que tem limite.
    if (buscarOArquivoDepois) buscarOArquivoDepois();

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
    // O ENDEREÇO DO ARQUIVO VEM ANTES DE TUDO.
    //
    // Estava lá embaixo, no ramo de "não reconheci este evento" — e por isso
    // dependia de o evento NÃO trazer um status reconhecível. Alguns trazem
    // ("Delivered") e o endereço passava direto. Aqui em cima ele é aproveitado
    // sempre, e o resto do tratamento de status segue igual.
    const arquivo = body.FileURL || (body.event && body.event.FileURL);
    if (arquivo) {
      const ids = ((body.event && body.event.MessageIDs) || body.MessageIDs || [])
        .map(String).filter(Boolean);
      guardarEnderecoDeArquivo(ids, arquivo);
      console.log(`Endereço de arquivo recebido para ${JSON.stringify(ids)}: `
        + `${String(arquivo).split('?')[0]}`);
      // E, se alguma dessas mensagens já está gravada SEM arquivo, é agora que
      // ela ganha o dela. Sem `await` na sequência: um resgate lento não pode
      // segurar o tratamento do evento.
      for (const id of ids) resgatarAnexoVazio(id, arquivo).catch(() => {});
    }

    const alvo = body.message || body.update || body.data || body;
    const id =
      alvo.messageid || alvo.id || (alvo.key && alvo.key.id) || body.messageid || null;
    const bruto = alvo.status ?? alvo.ack ?? body.status ?? body.ack;

    // Se não achamos id ou status, registramos para referência e saímos. O
    // endereço de arquivo, quando vinha, já foi aproveitado lá em cima.
    if (!id || bruto === undefined || bruto === null) {
      if (arquivo) return;
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
// A ROTA DE DOWNLOAD QUE SERVE NESTE SERVIDOR.
//
// As três rotas abaixo são a mesma coisa em versões diferentes da Uazapi: cada
// servidor atende uma. A ponte tentava as três, sempre na mesma ordem, e nunca
// guardava qual tinha funcionado. Onde a que serve é a última, toda foto que
// chega custa duas tentativas jogadas fora — e uma delas pode ficar 20 segundos
// esperando resposta, com a mensagem do cliente parada até lá.
//
// Um servidor não troca de versão entre uma foto e a seguinte. Descobre-se uma
// vez e lembra-se. Se um dia a lembrada parar de servir, a busca recomeça
// sozinha pelas três.
const ROTAS_DE_DOWNLOAD = ['/message/downloadmedia', '/message/download', '/downloadmedia'];
const rotaQueServe = new Map();

async function baixarMidiaRecebida(servidor, token, m, mimeInformado) {
  try {
    if (!token || !m.messageid) return null;

    // A lembrada primeiro; as outras continuam na fila, para o dia em que ela
    // deixar de responder.
    const lembrada = rotaQueServe.get(servidor);
    const ordem = lembrada
      ? [lembrada, ...ROTAS_DE_DOWNLOAD.filter((r) => r !== lembrada)]
      : ROTAS_DE_DOWNLOAD;

    let dados = null;
    for (const rota of ordem) {
      try {
        const r = await fetchComTimeout(`${servidor}${rota}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'token': token },
          body: JSON.stringify({ id: m.messageid })
        }, 20000);
        if (r.ok) {
          dados = await r.json().catch(() => null);
          if (dados) {
            if (lembrada !== rota) {
              console.log(`downloadmedia: este servidor atende por ${rota}.`);
              rotaQueServe.set(servidor, rota);
            }
            break;
          }
        } else if (rota === lembrada) {
          // A que servia parou de servir: esquece e deixa as outras tentarem.
          rotaQueServe.delete(servidor);
        }
      } catch (e) {
        if (rota === lembrada) rotaQueServe.delete(servidor);
        console.log(`downloadmedia ${rota} erro: ${e.message}`);
      }
    }
    if (!dados) {
      // A SEGUNDA CHANCE, antes de desistir: o endereço que a Uazapi mandou
      // por um `messages_update`, guardado pelo id EXATO desta mensagem.
      //
      // Foi o caso de 19/08 ao contrário: lá o endereço chegou DEPOIS do
      // download falhar (e o resgate cuida disso); aqui é quando ele chegou
      // ANTES, o que acontece sempre que o evento de arquivo vem na frente.
      const guardado = enderecoGuardado(m.messageid);
      if (guardado) {
        try {
          const salvo = await guardarArquivoDoEndereco(m.messageid, guardado);
          if (salvo.url) {
            console.log(`Anexo salvo pelo endereço que a Uazapi mandou à parte (${m.messageid}).`);
            return salvo.url;
          }
        } catch (e) {
          console.log(`O endereço guardado também não serviu (${m.messageid}): ${(e && e.message) || e}`);
        }
      }
      // O conteúdo da mensagem só vai para o log QUANDO DÁ ERRADO, que é
      // quando ele serve para alguma coisa. Antes ia sempre — legenda, nome de
      // arquivo, miniatura, de toda mídia recebida. Num escritório de
      // advocacia, log é lugar onde muita gente entra e nada se apaga.
      try {
        console.log('Mídia que não deu para baixar (content):', JSON.stringify(m.content).slice(0, 600));
      } catch (_) { /* ignora */ }
      return null;
    }

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

/** Uma coluna vazia e uma miniatura `data:` são a mesma coisa para quem
 *  procura o arquivo de verdade: nos dois casos ele ainda não chegou. Os dois
 *  caminhos que põem arquivo em mensagem já gravada perguntam por aqui, para
 *  não divergirem no dia em que um deles for mexido. */
const ehSoMiniatura = (v) => !v || String(v).startsWith('data:');

/**
 * Põe o arquivo de verdade na mensagem que nasceu com a miniatura.
 *
 * A TRAVA É O VALOR QUE ACABEI DE LER, e não "está vazio". Entre esta leitura
 * e a gravação cabe o resgate pelo `FileURL` (que corre por fora e pode ter
 * chegado primeiro): sem trava, o segundo a terminar sobrescreveria o primeiro,
 * e nada garante que o segundo seja o melhor arquivo. Gravando só quando a
 * coluna ainda está exatamente como eu a li, quem chegou depois desiste em
 * silêncio — que é o certo, porque o arquivo já está lá.
 *
 * Vale também para a repetição do mesmo webhook: na segunda vez a coluna já
 * aponta para o Storage, não casa com a miniatura, e nada é reescrito.
 */
async function trocarMiniaturaPeloArquivo(idUazapi, url, mime) {
  if (!idUazapi || !url) return;
  const { data: alvo, error } = await supabase
    .from('mensagens').select('id, midia_url').eq('id_uazapi', idUazapi).maybeSingle();
  if (error) { console.log(`Não consegui achar a mensagem ${idUazapi}: ${error.message}`); return; }
  if (!alvo) return;
  // Já tem arquivo de verdade: nada a fazer. `data:` é miniatura, e miniatura
  // é justamente o que veio para ser substituído.
  if (!ehSoMiniatura(alvo.midia_url)) return;

  const remendo = { midia_url: url };
  if (mime) remendo.midia_mime = mime;
  let escrita = supabase.from('mensagens').update(remendo).eq('id', alvo.id);
  escrita = alvo.midia_url === null || alvo.midia_url === undefined
    ? escrita.is('midia_url', null)
    : escrita.eq('midia_url', alvo.midia_url);
  const { error: erroEscrita } = await escrita;
  if (erroEscrita) console.log(`Não consegui pôr o arquivo em ${idUazapi}: ${erroEscrita.message}`);
}

// ============================================================
//  O ANEXO QUE FICOU VAZIO — E O ENDEREÇO QUE CHEGA LOGO DEPOIS
//
//  Do log de 19/08, com um segundo de diferença:
//
//    Anexo (documento) sem arquivo: o download falhou.
//    Mensagem A5F59D4D… fica sem mídia.
//    Evento não tratado: messages_update {…"FileURL":"https://…jpg"…
//
//  Alguém abriu essa conversa e viu um anexo em branco — um documento que o
//  cliente mandou e o escritório não tem. E o endereço do arquivo chegou um
//  segundo depois, de bandeja, indo direto para o balde dos eventos ignorados.
//
//  O QUE TORNA ISTO SEGURO, e é a única coisa que importa aqui: o casamento é
//  pelo id EXATO da mensagem. Nunca por "a última mídia", nunca por "a mesma
//  conversa". Num escritório de advocacia, gravar o arquivo de um cliente na
//  mensagem de outro é pior do que não gravar nenhum — e um resgate esperto
//  demais erraria exatamente assim.
//
//  E a gravação só acontece onde NÃO HÁ arquivo (`midia_url is null`). Um
//  anexo que já chegou nunca é sobrescrito por este caminho.
//
//  Dez minutos de validade: se o download falhou e o endereço não veio nesse
//  tempo, ele não vem mais. Um mapa que só cresce é um vazamento de memória
//  disfarçado de cache, e a ponte é um processo só que fica meses de pé.
// ============================================================
const enderecosDeArquivo = new Map();   // id da mensagem -> { url, ate }
const VALIDADE_DO_ENDERECO_MS = 10 * 60 * 1000;
const TETO_DE_ENDERECOS = 500;

function guardarEnderecoDeArquivo(ids, url) {
  const agora = Date.now();
  for (const [k, v] of enderecosDeArquivo) if (v.ate < agora) enderecosDeArquivo.delete(k);
  // Teto duro, para o caso de uma enxurrada dentro da mesma janela de dez
  // minutos: sai o mais velho.
  while (enderecosDeArquivo.size >= TETO_DE_ENDERECOS) {
    enderecosDeArquivo.delete(enderecosDeArquivo.keys().next().value);
  }
  for (const id of ids) {
    if (id) enderecosDeArquivo.set(String(id), { url, ate: agora + VALIDADE_DO_ENDERECO_MS });
  }
}

function enderecoGuardado(id) {
  const g = enderecosDeArquivo.get(String(id || ''));
  if (!g) return null;
  if (g.ate < Date.now()) { enderecosDeArquivo.delete(String(id)); return null; }
  return g.url;
}

/** O tipo do arquivo pela ponta do endereço. A Uazapi não manda o mime junto
 *  do `FileURL`, e um arquivo salvo como "application/octet-stream" o
 *  navegador oferece para baixar em vez de mostrar. */
function mimePelaPonta(url) {
  const ponta = String(url || '').split('?')[0].split('.').pop().toLowerCase();
  const tabela = {
    jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp',
    gif: 'image/gif', mp4: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm',
    mp3: 'audio/mpeg', ogg: 'audio/ogg', oga: 'audio/ogg', opus: 'audio/ogg',
    m4a: 'audio/mp4', wav: 'audio/wav', pdf: 'application/pdf',
    doc: 'application/msword', xls: 'application/vnd.ms-excel', txt: 'text/plain',
    zip: 'application/zip',
  };
  return tabela[ponta] || 'application/octet-stream';
}

/** Baixa de um endereço e guarda no Storage. Devolve o endereço público, ou
 *  `null` — e o `null` nunca é silencioso, porque quem chama registra. */
async function guardarArquivoDoEndereco(messageid, url) {
  const mime = mimePelaPonta(url);
  const arq = await fetchComTimeout(url, {}, 20000);
  if (!arq.ok) throw new Error(`o endereço respondeu ${arq.status}`);
  const bytes = Buffer.from(await arq.arrayBuffer());
  if (!bytes.length) throw new Error('o endereço respondeu vazio');
  const ext = (String(mime).split('/')[1] || 'bin').split(';')[0];
  const caminho = `recebidos/${messageid}.${ext}`;
  const { error } = await supabase.storage.from('anexos')
    .upload(caminho, bytes, { contentType: mime, upsert: true });
  if (error) throw new Error(`Storage recusou: ${error.message}`);
  const { data: pub } = supabase.storage.from('anexos').getPublicUrl(caminho);
  return { url: pub && pub.publicUrl, mime };
}

/** O resgate: uma mensagem JÁ GRAVADA e sem arquivo recebe o que chegou.
 *
 *  A trava é o valor lido, e não `is null`: desde que a bolha passou a nascer
 *  com a MINIATURA, "sem arquivo" deixou de querer dizer "coluna vazia". Uma
 *  mensagem com `data:image/...` continua sendo uma mensagem sem o arquivo de
 *  verdade, e era exatamente essa que o resgate existe para salvar — com a
 *  trava velha, ele passaria direto por ela e o anexo ficaria sendo uma
 *  miniatura borrada para sempre.
 *
 *  E se a mensagem ainda não existe no banco (o evento chegou primeiro), não
 *  há o que atualizar — o endereço fica guardado para quando o download dela
 *  falhar, que é o outro caminho. */
async function resgatarAnexoVazio(id, url) {
  try {
    const { data: alvo } = await supabase.from('mensagens')
      .select('id, midia_url').eq('id_uazapi', id).maybeSingle();
    if (!alvo || !ehSoMiniatura(alvo.midia_url)) return;  // não existe, ou já tem arquivo

    const guardado = await guardarArquivoDoEndereco(id, url);
    if (!guardado.url) return;
    let escrita = supabase.from('mensagens')
      .update({ midia_url: guardado.url, midia_mime: guardado.mime })
      .eq('id', alvo.id);
    escrita = alvo.midia_url === null || alvo.midia_url === undefined
      ? escrita.is('midia_url', null)
      : escrita.eq('midia_url', alvo.midia_url);
    const { error } = await escrita;
    if (error) { console.error(`resgate do anexo ${id}: o banco recusou —`, error.message); return; }
    console.log(`Anexo resgatado: a mensagem ${id} estava sem arquivo e recebeu o que a Uazapi mandou depois.`);
  } catch (e) {
    console.log(`Não consegui resgatar o anexo de ${id}: ${(e && e.message) || e}`);
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
//  QUANTO TEMPO TEM O ÁUDIO
//
//  No WhatsApp a lista de conversas mostra "Mensagem de voz (1:19)", e o tempo
//  não é enfeite: é o que separa um "ok" de dez segundos de um relato de três
//  minutos, na hora de decidir o que ouvir primeiro. Sem ele, a prévia do
//  Zorvin dizia só que havia um áudio.
//
//  O NOME DO CAMPO NÃO ESTÁ CONFIRMADO. A Uazapi entrega o nó cru da mensagem
//  em `content`, e o WhatsApp guarda a duração ali em `seconds` — mas isso é o
//  que a documentação sugere, não o que eu vi. Então procuramos em vários
//  cantos e por vários nomes, e quando um áudio chega sem nenhum deles o log
//  diz QUAIS campos vieram. É assim que o nome certo se descobre, com um áudio
//  de verdade, em vez de por adivinhação.
// ------------------------------------------------------------
const NOMES_DE_DURACAO = ['seconds', 'duration', 'duracao', 'audioDuration',
                          'mediaDuration', 'durationInSeconds'];
let avisouSemDuracao = false;

function segundosDaMidia(m, tipo) {
  const c = m.content && typeof m.content === 'object' ? m.content : {};
  const cantos = [m, c, c.audioMessage, c.videoMessage, c.message,
                  c.message && c.message.audioMessage];
  for (const canto of cantos) {
    if (!canto || typeof canto !== 'object') continue;
    for (const nome of NOMES_DE_DURACAO) {
      const v = Number(canto[nome]);
      // Um dia inteiro é o teto do absurdo: campos chamados "duration" às
      // vezes vêm em milissegundos, e 79000 viraria "1316:40" na tela.
      if (Number.isFinite(v) && v > 0 && v < 24 * 3600) return Math.round(v);
    }
  }
  if ((tipo === 'audio' || tipo === 'video') && !avisouSemDuracao) {
    avisouSemDuracao = true;
    const chaves = Object.keys(c).slice(0, 25);
    console.log(`Áudio/vídeo sem duração reconhecida. Os campos que vieram em `
      + `content foram: ${JSON.stringify(chaves)}. Se um deles for a duração, `
      + 'é só acrescentar o nome em NOMES_DE_DURACAO.');
  }
  return null;
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
// ============================================================
//  POR QUE A MENSAGEM NÃO SAIU — dito em português
//
//  A bolha vermelha na tela dizia só "não enviado". Quem atende ficava sem
//  saber se o número está errado, se o cliente não tem WhatsApp, se a linha do
//  escritório caiu ou se foi coisa de um minuto que basta tentar de novo — e
//  cada um desses casos pede uma ação diferente. Sem o motivo, a única ação
//  possível era clicar em "reenviar" e torcer.
//
//  O motivo já era gravado em `erro_detalhe`, mas em linguagem de máquina
//  ("Uazapi respondeu 400: {"error":"number not exists"}"). Isso não se mostra
//  a ninguém. Aqui ele é traduzido para uma frase, e o texto técnico continua
//  guardado à parte, para quem precisar investigar.
//
//  O QUE EU SEI E O QUE EU NÃO SEI. As regras por código HTTP e as que vêm dos
//  erros do próprio Zorvin são seguras. As que dependem do vocabulário exato da
//  Uazapi são as prováveis, montadas a partir do que ela costuma responder —
//  não tenho como conferir todas daqui.
//
//  Por isso a regra de ouro: erro que NÃO for reconhecido não vira frase
//  genérica. Ele vai para a tela como está, e para o log com um aviso, para o
//  vocabulário ser aprendido dos casos de verdade em vez de adivinhado.
// ============================================================
/** A linha do escritório caiu do WhatsApp?
 *
 *  Sai daqui e não de dentro de `motivoDoErro` porque duas pessoas diferentes
 *  precisam da resposta: a atendente, que lê a frase na bolha vermelha, e
 *  quem administra, que precisa saber POR QUAL TELEFONE nada mais sai. */
function ehLinhaDesconectada(bruto) {
  const t = String(bruto || '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  return /(disconnected|not connected|desconect|instance.{0,20}(closed|down)|qrcode|qr code|需要)/.test(t);
}

function motivoDoErro(bruto) {
  const cru = String(bruto || '');
  const t = cru.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
  const status = Number((cru.match(/respondeu (\d{3})/) || [])[1]) || 0;

  // ---- 1. erros do próprio Zorvin: destes eu tenho certeza ----
  if (/enviada ao whatsapp, mas nao gravada/.test(t)) {
    return 'A mensagem CHEGOU ao cliente, mas não foi gravada no histórico daqui. '
         + 'Não reenvie — ele receberia duas vezes. Avise quem administra.';
  }
  if (/conversa\/advogado\/contato nao encontrado/.test(t)) {
    return 'O Zorvin não encontrou o telefone ou o contato desta conversa. '
         + 'Avise quem administra: é cadastro, não é a mensagem.';
  }
  if (/falhou apos \d+ tentativas/.test(t)) {
    return 'Tentamos várias vezes seguidas e não deu. Se o número estiver certo, '
         + 'espere alguns minutos e toque em reenviar.';
  }

  // ---- 2. conexão: também vem do nosso lado, e é certo ----
  if (/demorou demais|aborterror|timeout|etimedout|econnaborted/.test(t)) {
    return 'O servidor do WhatsApp não respondeu a tempo. Toque em reenviar daqui a pouco.';
  }
  if (/fetch failed|enotfound|econnrefused|econnreset|network|socket hang up/.test(t)) {
    return 'Não conseguimos falar com o servidor do WhatsApp (Uazapi). '
         + 'Costuma ser passageiro — toque em reenviar daqui a pouco.';
  }

  // ---- 3. o que a Uazapi costuma dizer ----
  // Estas são as prováveis. Se alguma nunca casar, o erro cai no fim e aparece
  // como está — nada fica escondido por causa de um palpite errado.
  if (/(numero|number|phone).{0,25}(nao existe|not exist|not found|nao encontrado|invalid|inval)/.test(t)
      || /(not|nao).{0,15}(on|no|tem).{0,10}whatsapp/.test(t)
      || /exists.{0,10}false/.test(t)) {
    return 'Este número não tem conta no WhatsApp, ou está escrito errado. '
         + 'Confira o número na ficha do cliente.';
  }
  if (ehLinhaDesconectada(cru)) {
    return 'A linha do escritório está desconectada do WhatsApp. '
         + 'Avise quem administra: é preciso reconectar o aparelho.';
  }
  if (/blocked|bloquead|forbidden by (the )?(user|contact)/.test(t)) {
    return 'O cliente bloqueou este número do escritório. Tente por outro telefone nosso.';
  }
  if (/(too large|file size|payload too large|arquivo.{0,15}grande)/.test(t) || status === 413) {
    return 'O arquivo é grande demais para o WhatsApp. Reduza o tamanho e mande de novo.';
  }

  // ---- 4. pelo código HTTP: seguro, e é a última rede antes do desconhecido ----
  if (status === 401 || status === 403) {
    return 'A Uazapi recusou o acesso desta linha. Avise quem administra: '
         + 'costuma ser a chave da instância vencida ou trocada.';
  }
  if (status === 429) {
    return 'Muitas mensagens de uma vez. Espere um minuto e toque em reenviar.';
  }
  if (status >= 500) {
    return 'O servidor do WhatsApp (Uazapi) está com problema neste momento. '
         + 'Toque em reenviar daqui a pouco.';
  }

  // ---- 5. não reconhecido ----
  //
  // O log grita de propósito: é assim que a lista acima cresce a partir de
  // casos reais, em vez de adivinhação. E a tela mostra o texto cru: ver algo
  // que não se entende é ruim, mas é melhor do que uma frase bonita e falsa.
  console.log(`MOTIVO DE ERRO NÃO RECONHECIDO (vale acrescentar em motivoDoErro): ${cru.slice(0, 300)}`);
  return null;
}

/** Marca o item como erro, com o motivo em português e o texto técnico à parte. */
async function marcarErroNaFila(itemId, bruto, avisoVantoroId) {
  const motivo = motivoDoErro(bruto);
  const campos = { status: 'erro', erro_detalhe: String(bruto || '').slice(0, 1000) };
  campos.erro_motivo = motivo;
  let { error } = await supabase.from('fila_envio').update(campos).eq('id', itemId);
  // Instalação sem a coluna nova: grava sem ela. O item PRECISA virar erro —
  // se esta gravação falhar por inteiro, a bolha nem fica vermelha e a
  // mensagem some da tela como se nada tivesse acontecido.
  if (error && /erro_motivo/i.test(error.message || '')) {
    delete campos.erro_motivo;
    ({ error } = await supabase.from('fila_envio').update(campos).eq('id', itemId));
  }
  if (error) console.error(`Não consegui marcar o item ${itemId} como erro:`, error.message);
  if (avisoVantoroId) await avisoDeuErro(avisoVantoroId, String(bruto || ''));
}

// LINHA CAÍDA É AVISO, E NÃO MAIS UMA FALHA NA PILHA.
//
// "Uazapi respondeu 503: WhatsApp disconnected: session is not reconnectable"
// não é uma mensagem que deu errado: é um TELEFONE DO ESCRITÓRIO fora do ar,
// e nada mais sai por ele até alguém reconectar. A atendente vê a bolha
// vermelha com a frase certa; quem administra não via nada, e só ficava
// sabendo quando alguém reclamasse.
//
// Uma linha por telefone a cada dez minutos: repetir a cada mensagem
// afogaria o log justamente quando ele mais importa, e calar de vez faria a
// linha ficar caída o fim de semana inteiro sem ninguém notar.
const linhasAvisadas = new Map();
function avisarQueALinhaCaiu(bruto, numero, nome) {
  if (!ehLinhaDesconectada(bruto)) return;
  const ultimo = linhasAvisadas.get(numero) || 0;
  if (Date.now() - ultimo < 10 * 60 * 1000) return;
  linhasAvisadas.set(numero, Date.now());
  console.error(`LINHA DESCONECTADA: o telefone ${numero}${nome ? ` (${nome})` : ''} `
    + 'perdeu a conexão com o WhatsApp e NADA MAIS SAI por ele. '
    + 'É preciso reconectar o aparelho na Uazapi — ler o QR de novo. '
    + 'As mensagens ficam na fila marcadas como erro, e podem ser reenviadas depois.');
}

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
        await marcarErroNaFila(item.id, `Falhou após ${MAX_TENTATIVAS} tentativas`, item.aviso_vantoro_id);
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
        .select('id, contato:contato_id (numero), advogado:advogado_id (token, servidor, numero, nome)')
        .eq('id', item.conversa_id)
        .single();

      if (!conv || !conv.advogado || !conv.contato) {
        await marcarErroNaFila(item.id, 'Conversa/advogado/contato não encontrado', item.aviso_vantoro_id);
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
        // O aviso de audiência volta a aparecer como "Falhou" no Vantoro, com o
        // motivo — em vez de sumir e só dar as caras quando o cliente faltar.
        await marcarErroNaFila(item.id, envioErro.message, item.aviso_vantoro_id);
        // POR QUAL LINHA E PARA QUEM. O identificador do item é um código que
        // não diz nada a ninguém; em 19/08 o log trazia só ele, e para
        // descobrir qual telefone tinha caído era preciso ir ao banco.
        const linha = conv.advogado.numero || 'telefone desconhecido';
        const deQuem = conv.advogado.nome ? ` (${conv.advogado.nome})` : '';
        console.error(`Falha ao enviar pela linha ${linha}${deQuem} para ${numeroDestino} `
                    + `[item ${item.id}]:`, envioErro.message);
        avisarQueALinhaCaiu(envioErro.message, linha, conv.advogado.nome);
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
// A ORIGEM PERMITIDA, LIMPA — e o motivo de ela existir separada.
//
// `PAINEL_ORIGEM` é preenchida à mão num campo de site. Colar ali arrasta
// espaço, barra no fim e, sobretudo, QUEBRA DE LINHA. O Node recusa pôr um
// "\n" dentro de um cabeçalho e lança `ERR_INVALID_CHAR` — e como isso
// acontece DENTRO da rota, ela morre antes de responder. O navegador vê a
// conexão falhar e escreve "Load failed"; do lado de cá, o log só mostra uma
// pilha de erro que não menciona a variável.
//
// Foi assim que uma quebra de linha invisível derrubou a entrada de todo o
// escritório numa manhã de expediente. Uma variável mal colada pode fazer o
// sistema funcionar pior; não pode fazer ele parar.
//
// Então: o que dá para consertar sozinho é consertado (espaço, barra no fim),
// e o que não dá vira aviso e cai no `*`, que é o padrão de sempre. Degradar
// para permissivo com aviso é melhor do que derrubar tudo em silêncio.
let origemLembrada = null;
function origemPermitida() {
  if (origemLembrada) return origemLembrada;
  const cru = String(process.env.PAINEL_ORIGEM || '');
  const limpa = cru.replace(/[\r\n\t]/g, '').trim().replace(/\/+$/, '');

  if (!limpa) {
    origemLembrada = '*';
  } else if (!/^https?:\/\/[A-Za-z0-9.:-]+$/.test(limpa)) {
    console.log(`PAINEL_ORIGEM não parece um endereço (${JSON.stringify(cru)}). `
              + 'Aceitando qualquer origem, que é o padrão. Ela deve ser só o '
              + 'endereço do painel, assim: https://zorvin.exemplo.com.br');
    origemLembrada = '*';
  } else {
    if (limpa !== cru) {
      console.log(`PAINEL_ORIGEM tinha espaço, barra ou quebra de linha sobrando `
                + `(${JSON.stringify(cru)}). Usando "${limpa}".`);
    }
    origemLembrada = limpa;
  }
  return origemLembrada;
}

function liberarCors(res, req) {
  const permitida = origemPermitida();
  res.set('Access-Control-Allow-Origin', permitida);
  res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.set('Access-Control-Allow-Methods', 'GET, POST, PATCH, OPTIONS');

  // O ERRO MAIS INVISÍVEL QUE ESTA PONTE PODE DAR.
  //
  // `Access-Control-Allow-Origin` tem de casar com a origem do pedido LETRA
  // POR LETRA — uma barra a mais no fim, `www.` a mais, `http` no lugar de
  // `https`, e o navegador descarta a resposta. Do lado de cá parece que deu
  // tudo certo: a rota respondeu 200 e nada foi para o log. Do lado de lá, o
  // Safari escreve "Load failed" e o Chrome, "Failed to fetch".
  //
  // Este aviso existe para esse caso não ser mais invisível. Ele não muda o
  // comportamento — só conta o que está acontecendo, com os dois valores lado
  // a lado, que é o que falta para consertar em trinta segundos.
  const origem = req && req.headers && req.headers.origin;
  if (permitida !== '*' && origem && origem !== permitida) {
    console.log(`CORS: o painel pediu de "${origem}" mas PAINEL_ORIGEM está "${permitida}". `
              + 'O navegador vai descartar a resposta e dizer "Load failed". '
              + 'Ajuste a variável PAINEL_ORIGEM (sem barra no fim) ou deixe-a vazia.');
  }
}

// ============================================================
//  O BILHETE DE ENTRADA ASSINADO AQUI
//
//  Na manhã de 19/08 o escritório inteiro ficou de fora. O banco respondia em
//  168ms; quem não respondia era o `/auth/v1/*` do Supabase — o serviço que
//  cuida de conta e senha, que fica atrás do MESMO endereço do banco e cai
//  sozinho. O que voltava era uma página do Cloudflare com "Error 521".
//
//  A entrada dependia dele em dois pontos, e bastava um para ninguém entrar:
//  a ponte pedia um `generateLink` para abrir a sessão, e o painel trocava
//  esse bilhete por uma sessão com `verifyOtp`.
//
//  O QUE ESTE PEDAÇO FAZ. A sessão do Supabase é um bilhete assinado com um
//  segredo do projeto — o "JWT Secret". Quem tem o segredo pode assinar um. A
//  ponte já guarda a chave de serviço, que é mais poderosa do que isso (ela
//  própria é um bilhete assinado com o mesmo segredo, com poder de
//  administrador do banco). Então guardar o segredo aqui não abre porta
//  nenhuma que já não estivesse aberta — e fecha a que derrubou a manhã.
//
//  QUEM CONFERE O BILHETE DEPOIS. O banco, sozinho, com o mesmo segredo. É
//  por isso que isto funciona com o Auth no chão: quem estava logado naquela
//  manhã continuou conversando normalmente, porque mensagem, etiqueta e busca
//  vão direto ao banco. O que quebrava era só a PORTA DE ENTRADA.
//
//  O SEGREDO É OPCIONAL, DE PROPÓSITO. Sem `SUPABASE_JWT_SECRET`, tudo aqui
//  fica desligado e a entrada é exatamente a de antes. Assim esta mudança não
//  pode quebrar nada por si só: ela só entra em cena onde foi configurada.
// ============================================================
const crypto = require('crypto');

const JWT_SEGREDO = String(process.env.SUPABASE_JWT_SECRET || '').replace(/[\r\n\t]/g, '').trim();

// DOZE HORAS, e não os 60 minutos do Supabase.
//
// O bilhete do Supabase dura uma hora porque ele tem como se renovar sozinho:
// o navegador pede um novo com o "refresh token", e isso passa pelo Auth. O
// nosso não tem — é justamente o Auth que pode estar fora. Então ele precisa
// durar mais do que um expediente, senão quem entrou às 8h seria posto para
// fora às 9h no meio de um atendimento, sem ter como voltar.
//
// Doze horas cobrem o dia inteiro com folga e ainda são curtas o bastante para
// que uma conta desligada no Vantoro perca o acesso no mesmo dia.
const VALIDADE_S = 12 * 60 * 60;

function base64url(dado) {
  return Buffer.from(dado).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function assinar(conteudo) {
  return crypto.createHmac('sha256', JWT_SEGREDO).update(conteudo).digest('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Existe segredo configurado? É o interruptor de tudo neste arquivo. */
function souCapazDeAssinar() {
  return JWT_SEGREDO.length >= 20;
}

/** O bilhete de sessão, no mesmo formato que o Supabase emite.
 *
 *  As informações são as que o banco lê: `sub` é quem a pessoa é (é dele que
 *  sai `auth.uid()`, e é `auth.uid()` que decide quais conversas ela abre),
 *  `role` é o papel no banco, `exp` é até quando vale. O resto está aqui
 *  porque o Supabase põe — um bilhete que não se pareça com os outros é um
 *  bilhete que vai surpreender alguém um dia. */
function assinarSessao({ id, email, nome, login, foto }) {
  const agora = Math.floor(Date.now() / 1000);
  const exp = agora + VALIDADE_S;
  const cabecalho = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const corpo = base64url(JSON.stringify({
    iss: `${String(process.env.SUPABASE_URL || '').replace(/\/+$/, '')}/auth/v1`,
    sub: id,
    aud: 'authenticated',
    role: 'authenticated',
    email: email || '',
    phone: '',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: { nome: nome || '', login: login || '', email: email || '',
                     foto_url: foto || null,
                     email_verified: true, phone_verified: false },
    // A "sessão" a que este bilhete pertence. O Supabase põe um id aqui e
    // algumas regras de banco olham para ele; um valor sorteado agora é o que
    // mais se parece com o que ele faria.
    session_id: crypto.randomUUID(),
    aal: 'aal1',
    amr: [{ method: 'password', timestamp: agora }],
    is_anonymous: false,
    iat: agora,
    exp,
  }));
  const assinatura = assinar(`${cabecalho}.${corpo}`);
  return { token: `${cabecalho}.${corpo}.${assinatura}`, expira_em: exp };
}

/** Confere um bilhete SEM sair da máquina, e devolve quem é a pessoa.
 *
 *  Devolve `null` quando não dá para dizer que o bilhete é bom — assinatura
 *  que não bate, prazo vencido, ou um bilhete assinado de outro jeito (um
 *  projeto que use chave assimétrica não é conferível assim). `null` aqui não
 *  quer dizer "recuse": quer dizer "não sei", e quem chamou volta a perguntar
 *  ao Supabase, que é o que se fazia antes. */
function conferirSessao(bilhete) {
  if (!souCapazDeAssinar()) return null;
  const partes = String(bilhete || '').split('.');
  if (partes.length !== 3) return null;
  const [cabecalho, corpo, assinatura] = partes;

  let cab = null;
  try { cab = JSON.parse(Buffer.from(cabecalho, 'base64url').toString('utf8')); } catch (_e) { return null; }
  // SÓ O QUE ESTE SEGREDO ASSINA. Um projeto migrado para chave assimétrica
  // emite `RS256`/`ES256`, e tentar conferir com o segredo simétrico daria
  // "assinatura ruim" para um bilhete perfeitamente bom.
  if (!cab || cab.alg !== 'HS256') return null;

  const esperada = assinar(`${cabecalho}.${corpo}`);
  // COMPARAÇÃO DE TEMPO CONSTANTE. Comparar com `===` vaza, pelo tempo que a
  // comparação leva, quantas letras do começo bateram — e com isso dá para
  // descobrir a assinatura certa uma letra por vez.
  const a = Buffer.from(assinatura), b = Buffer.from(esperada);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;

  let dados = null;
  try { dados = JSON.parse(Buffer.from(corpo, 'base64url').toString('utf8')); } catch (_e) { return null; }
  if (!dados || !dados.sub) return null;
  if (dados.aud !== 'authenticated' || dados.role !== 'authenticated') return null;
  if (!dados.exp || dados.exp * 1000 <= Date.now()) return null;

  // No formato que o resto da ponte já espera de `auth.getUser`.
  return { id: dados.sub, email: dados.email || '',
           user_metadata: dados.user_metadata || {},
           app_metadata: dados.app_metadata || {} };
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

  // PRIMEIRO AQUI DENTRO, SEM SAIR DA MÁQUINA.
  //
  // Este era o segundo lugar em que a entrada dependia do Auth do Supabase, e
  // o menos óbvio: `auth.getUser` é uma ida à rede, e é ela que dizia se a
  // sessão vale. Com o Auth fora do ar, quem já estava logado ia perdendo o
  // acesso à Ficha e ao Histórico à medida que a lembrança de 60 segundos
  // vencia — sem entender por quê, porque as mensagens continuavam chegando.
  //
  // O bilhete é assinado com o segredo do projeto, e conferir uma assinatura
  // não precisa de ninguém: é uma conta. Vale para os bilhetes que a ponte
  // assina E para os que o Supabase emite, porque o segredo é o mesmo.
  //
  // Quando não dá para conferir aqui — sem segredo configurado, ou um projeto
  // que assine com chave assimétrica — a pergunta volta a ser feita ao
  // Supabase, exatamente como antes.
  const local = conferirSessao(jwt);
  if (local) {
    limparLembradas();
    sessoesLembradas.set(jwt, { usuario: local, ate: Date.now() + LEMBRAR_MS });
    return local;
  }

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
  // ------------------------------------------------------------
  //  PRIMEIRO O BANCO, QUE JÁ SABE A RESPOSTA
  //
  //  Isto aqui começava chamando `createUser` A CADA ENTRADA, contando com o
  //  erro "já registrado" para descobrir que a conta existe. Funcionava, e era
  //  uma ESCRITA na API de administração do Auth por login de cada pessoa —
  //  o caminho mais caro e mais frágil que havia para responder uma pergunta
  //  que o banco responde num piscar.
  //
  //  No dia em que essa API ficou lenta, o efeito foi este: entrada de 6
  //  minutos e meio, e depois nem isso. O escritório inteiro na porta, e o
  //  passo que travava era a criação de contas que já existiam há meses.
  //
  //  `usuarios` guarda o id e o e-mail de todo mundo que já entrou — a própria
  //  ponte grava isso ao fim de cada entrada. Para quem já entrou uma vez (que
  //  é todo mundo, todo dia), a resposta sai daí: uma leitura indexada, sem
  //  tocar no Auth.
  //
  //  O caminho antigo continua embaixo, para quem entra pela primeira vez —
  //  ou para quem foi apagado de `usuarios` e continua existindo no Auth.
  // ------------------------------------------------------------
  const { data: jaConhecido } = await supabase
    .from('usuarios').select('id').eq('email', email).maybeSingle();
  if (jaConhecido && jaConhecido.id) return jaConhecido.id;

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

// ------------------------------------------------------------
//  LER A TABELA INTEIRA — E NÃO AS MIL PRIMEIRAS LINHAS
//
//  O PostgREST devolve no máximo 1000 linhas por consulta, e não avisa: a
//  resposta chega com mil linhas e cara de resposta inteira. Quem escreveu
//  `select(...)` sem paginar acredita que leu tudo, e o que passar de mil some
//  em silêncio — o pior tipo de falta, porque não há erro nenhum para procurar.
//
//  Nas rotinas de permissão isso tem uma consequência exata: a pessoa espelhada
//  depois da milésima linha de `usuarios` nunca é encontrada, e a permissão dela
//  nunca é reaplicada. A tela do Vantoro mostra tudo marcado, certinho, e ela
//  continua sem ver as conversas. Ninguém procuraria a causa num teto de leitura.
//
//  A ordem por `id` não é enfeite: sem `order`, o Postgres não promete a mesma
//  ordem entre uma página e a seguinte, e daria para pular e para repetir linha.
// ------------------------------------------------------------
const PAGINA_POSTGREST = 1000;

async function lerTudo(tabela, colunas, ajustar, ordem = 'id') {
  const tudo = [];
  for (let pagina = 0; pagina < 500; pagina++) {
    let consulta = supabase.from(tabela).select(colunas).order(ordem)
      .range(pagina * PAGINA_POSTGREST, (pagina + 1) * PAGINA_POSTGREST - 1);
    if (ajustar) consulta = ajustar(consulta);
    const { data, error } = await consulta;
    if (error) return { data: null, error };
    tudo.push(...(data || []));
    if (!data || data.length < PAGINA_POSTGREST) break;
  }
  return { data: tudo, error: null };
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
  const { data: fones, error } = await lerTudo(
    'advogados', '*', (q) => q.eq('ativo', true));
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

// `emMaos` é a lista de telefones e a de departamentos já lidas por quem
// chamou. A rodada percorre o escritório inteiro, e essas duas listas são as
// MESMAS para todo mundo: relê-las por pessoa fazia dezenas de consultas
// idênticas a cada três minutos, para sempre. Quem chama por uma pessoa só
// (a entrada no sistema, a tela de permissões) não passa nada e a rotina lê
// como sempre leu.
//
// DEVOLVE `{ tirei, pus }` quando escreveu alguma coisa, e nada quando não
// escreveu — que é o caso de quase toda rodada. Quem chama por uma pessoa só
// ignora a resposta; quem percorre o escritório usa para não anunciar trabalho
// que não houve.
async function aplicarPermissoes(usuarioId, u, emMaos = null) {
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
    let fones = emMaos && emMaos.fones;
    if (!fones) {
      const lido = await lerTudo('advogados', '*');
      if (lido.error) {
        console.log(`Permissões: não consegui ler os telefones (${lido.error.message}).`);
        return;
      }
      fones = lido.data;
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
    let data = null;
    if (emMaos && emMaos.deps) {
      data = emMaos.deps.filter((d) => chaves.includes(d.slug));
    } else {
      const lido = await supabase
        .from('departamentos').select('id, slug').in('slug', chaves);
      if (lido.error) {
        console.log(`Permissões: não consegui ler os departamentos (${lido.error.message}).`);
        return;
      }
      data = lido.data;
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
  // ------------------------------------------------------------
  //  MAS SUBSTITUIR NÃO É APAGAR TUDO E GRAVAR TUDO DE VOLTA
  //
  //  Era o que esta rotina fazia, e ela roda de três em três minutos para cada
  //  pessoa do escritório. Entre o `delete` e o `insert` — dois pedidos de
  //  rede, algumas dezenas de milissegundos — a pessoa não tem permissão
  //  nenhuma. Quem estivesse carregando a lista de conversas naquele instante
  //  não via nada, e ao recarregar via tudo de novo. Um sumiço curto, sem erro,
  //  que volta sozinho: exatamente o feitio de "às vezes aparece, às vezes não".
  //
  //  E quando a gravação falhava — a rede caiu, o banco recusou —, o apagar já
  //  tinha acontecido: a pessoa ficava cega até uma rodada seguinte dar certo.
  //  Se a causa fosse permanente, ficava cega para sempre, com a tela do
  //  Vantoro mostrando a permissão marcada, certinha.
  //
  //  A correção é comparar antes de escrever. Quase sempre nada mudou desde a
  //  rodada anterior, e então não se escreve NADA — a janela nem chega a abrir.
  //  Quando mudou, mexe-se só na diferença: tira o que não vale mais, depois
  //  acrescenta o que passou a valer. Nessa ordem de propósito. Se a segunda
  //  metade falhar, a pessoa fica vendo de menos por alguns minutos; na ordem
  //  inversa, ela ficaria vendo o que a tela já diz que ela não pode ver. Num
  //  escritório de advocacia, errar para menos é o único lado aceitável.
  //
  //  A consulta não cita `grupo_id` de propósito: a coluna ainda existe, mas os
  //  grupos saíram e ela está esperando o painel parar de mencioná-la para ser
  //  apagada. Amarrar esta rotina a ela faria a permissão parar de ser aplicada
  //  no dia em que a coluna sumir — e sem nada dizendo por quê. Linha herdada
  //  de grupo (sem departamento e sem telefone) entra como sobra e sai, que é o
  //  mesmo destino que tinha antes.
  // ------------------------------------------------------------
  const chaveDaLinha = (l) => (l.telefone_id ? `t:${l.telefone_id}`
                             : l.departamento_id ? `d:${l.departamento_id}` : null);

  const { data: atuais, error: erroLe } = await supabase
    .from('permissoes').select('id, departamento_id, telefone_id').eq('usuario_id', usuarioId);
  if (erroLe) {
    console.log(`Permissões: não consegui ler as atuais (${erroLe.message}).`);
    return;
  }

  const querido = new Map();
  for (const l of linhas) querido.set(chaveDaLinha(l), l);

  const jaTem = new Set();
  const sobrando = [];
  for (const p of atuais || []) {
    const chave = chaveDaLinha(p);
    // `jaTem.has` cobre a linha repetida: duas rodadas que se atropelaram no
    // passado podem ter deixado a mesma permissão duas vezes. A primeira fica,
    // a segunda sai.
    if (chave && querido.has(chave) && !jaTem.has(chave)) jaTem.add(chave);
    else sobrando.push(p.id);
  }
  const faltando = [];
  for (const [chave, linha] of querido) if (!jaTem.has(chave)) faltando.push(linha);

  // Nada mudou: não se escreve nada. É o caso de quase toda rodada — e é por
  // isso que a resposta é vazia aqui, para o log lá em cima não anunciar uma
  // reaplicação que não aconteceu.
  if (!sobrando.length && !faltando.length) return null;

  if (sobrando.length) {
    const { error } = await supabase.from('permissoes').delete().in('id', sobrando);
    if (error) {
      console.log(`Permissões: não consegui tirar as que não valem mais (${error.message}).`);
      return null;
    }
  }
  // `pus` conta o que ENTROU, e não o que se pretendia pôr: com a gravação
  // falhando, dizer que pôs seria o log inventando um trabalho que não houve —
  // que é justamente o defeito que esta mudança veio corrigir.
  let pus = 0;
  if (faltando.length) {
    const { error } = await supabase.from('permissoes').insert(faltando);
    if (error) console.log(`Permissões: não consegui gravar (${error.message}).`);
    else pus = faltando.length;
  }
  return { tirei: sobrando.length, pus };
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

  const { data: espelhados, error } = await lerTudo('usuarios', 'id, login, email');
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

  // Os telefones e os departamentos são os mesmos para todo mundo: lidos uma
  // vez aqui e emprestados a cada pessoa. Se a leitura falhar, `emMaos` fica
  // sem a lista e cada chamada lê por conta própria — a rodada fica mais cara,
  // mas não deixa de acontecer.
  const emMaos = {};
  const lidosFones = await lerTudo('advogados', '*');
  if (!lidosFones.error) emMaos.fones = lidosFones.data;
  const lidosDeps = await supabase.from('departamentos').select('id, slug');
  if (!lidosDeps.error) emMaos.deps = lidosDeps.data;

  // ------------------------------------------------------------
  //  ESTA RODADA ACONTECE DE TRÊS EM TRÊS MINUTOS, E QUASE SEMPRE NÃO FAZ NADA
  //
  //  O log dizia `Permissões: reaplicadas para 14 usuário(s).` a cada rodada.
  //  Duas coisas erradas na mesma linha:
  //
  //  A frase era falsa. `aplicadas` contava quem a rotina VISITOU, não quem
  //  teve permissão mexida — e a rotina foi consertada justamente para não
  //  escrever quando nada mudou. Ela anunciava uma reaplicação que não
  //  acontecia.
  //
  //  E, sendo a cada três minutos, ela enchia o log de linhas iguais: quase
  //  quinhentas por dia, todas sem notícia. Quem for procurar o que houve às
  //  quinze para as três — uma linha caída, um webhook recusado — precisa
  //  passar por elas. Um log que repete o que não mudou esconde o que mudou.
  //
  //  Agora só sai linha quando alguma permissão de fato mexeu, e ela diz DE
  //  QUEM. É a pergunta que quem administra faz depois: "a fulana parou de ver
  //  o departamento, quando isso mudou?".
  // ------------------------------------------------------------
  const mexidos = [];
  let conferidos = 0;
  for (const u of corpo.usuarios) {
    const id = porLogin.get(String(u.login || '').toLowerCase())
            || porEmail.get(String(u.email || '').toLowerCase());
    if (!id) continue;   // ainda não entrou no Zorvin nenhuma vez
    try {
      const mexeu = await aplicarPermissoes(id, u, emMaos);
      conferidos += 1;
      if (mexeu && (mexeu.tirei || mexeu.pus)) {
        const conta = [mexeu.pus ? `+${mexeu.pus}` : null,
                       mexeu.tirei ? `-${mexeu.tirei}` : null].filter(Boolean).join(' ');
        mexidos.push(`${u.login} (${conta})`);
      }
    } catch (e) {
      console.log(`Permissões de ${u.login}: ${(e && e.message) || e}`);
    }
  }
  if (mexidos.length) {
    // O TETO DE NOMES. Na primeira rodada depois de uma implantação — ou
    // depois de alguém mexer no perfil de meio escritório — todo mundo muda de
    // uma vez, e a linha inteira viraria um parágrafo. Oito nomes contam a
    // história; o resto vira número, que é o que interessa nesse caso.
    const TETO = 8;
    const lista = mexidos.length > TETO
      ? `${mexidos.slice(0, TETO).join(', ')} e mais ${mexidos.length - TETO}`
      : mexidos.join(', ');
    console.log(`Permissões: mudei ${lista} — de ${conferidos} conferido(s).`);
  }
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
  const { data: fones, error } = await lerTudo(
    'advogados', '*', (q) => q.is('departamento_id', null));
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
// UMA RODADA DE CADA VEZ.
//
// A rodada percorre todo mundo, e cada pessoa custa algumas idas ao banco. Com
// o escritório crescendo, ou com o Vantoro lento (a chamada espera até 20
// segundos), uma rodada pode passar dos três minutos do intervalo — e então a
// seguinte começa em cima dela. Duas rodadas mexendo na permissão da mesma
// pessoa ao mesmo tempo se atropelam: uma tira o que a outra acabou de pôr.
//
// É a mesma trava que a fila de envio já tem, pelo mesmo motivo.
let rodadaRodando = false;

async function rodada() {
  if (rodadaRodando) {
    console.log('Rodada: a anterior ainda está correndo — esta fica para o próximo intervalo.');
    return;
  }
  rodadaRodando = true;
  try {
    await umaRodada();
  } finally {
    rodadaRodando = false;
  }
}

async function umaRodada() {
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
  const { data: contas } = await lerTudo('usuarios', 'id, login, email');
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
    const { data: contas } = await lerTudo('usuarios', 'id, login, email');
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
//  A FOTO DO CONTATO EM TAMANHO CHEIO
//
//  A foto de perfil chegava pelo webhook e ficava guardada. Só que o campo que
//  vinha na frente era `imagePreview` — a MINIATURA. Corrigida a ordem, as
//  novas passam a vir cheias; as que já estão guardadas, não: o webhook só
//  traz foto quando o contato manda mensagem, e um cliente que não escreve há
//  um mês fica com a miniatura de um mês atrás para sempre.
//
//  Esta rota vai buscar a foto DE NOVO, sob demanda. O painel só a oferece
//  quando a foto aberta é pequena de verdade — não adianta pedir de novo o que
//  já está bom.
//
//  A ROTA DA UAZAPI VARIA COM A VERSÃO, como já variava a de download de mídia.
//  Mesma solução, e pelo mesmo motivo: tenta as conhecidas, LEMBRA a que
//  serviu, e quando nenhuma serve diz isso em português em vez de falhar
//  calada. Se um dia o servidor mudar de rota, uma linha nesta lista resolve.
// ------------------------------------------------------------
//
//  `preview: false` NÃO É DETALHE — é o parâmetro inteiro. A documentação da
//  Uazapi diz, sobre `/chat/details`:
//
//    preview | true: imagem em tamanho preview (menor, otimizada para
//                    listagens)
//            | false (padrão): tamanho full (resolução original, maior
//                    qualidade)
//
//  Ou seja: é este endereço que resolve o "abre grande, porém embaçada".
//  Vai escrito mesmo sendo o padrão — um padrão que muda de versão em versão
//  vira defeito silencioso, e este em particular já custou uma rodada.
const ROTAS_DE_FOTO = [
  { rota: '/chat/details',            corpo: (n) => ({ number: n, preview: false }) },
  { rota: '/chat/GetNameAndImageURL', corpo: (n) => ({ number: n, preview: false }) },
  { rota: '/contact/picture',         corpo: (n) => ({ number: n, preview: false }) },
];
const rotaDeFotoQueServe = new Map();

/** Acha a maior foto dentro da resposta, seja qual for o formato.
 *
 *  Procurar por NOME de campo (`imgUrl`, `profilePicUrl`, …) obrigaria a
 *  conhecer de antemão o formato de cada versão, que é justamente o que não se
 *  sabe. Aqui a regra é a que vale para todas: um endereço http que pareça
 *  imagem, preferindo o que NÃO é miniatura. */
function acharFotoNaResposta(dados) {
  const achados = [];
  const andar = (v, caminho) => {
    if (!v) return;
    if (typeof v === 'string') {
      if (/^https?:\/\//.test(v) && /(img|image|pic|photo|foto|avatar)/i.test(caminho)) {
        achados.push({ url: v, miniatura: /(preview|thumb|small)/i.test(caminho) });
      }
      return;
    }
    if (typeof v !== 'object') return;
    for (const k of Object.keys(v)) andar(v[k], caminho + '.' + k);
  };
  andar(dados, '');
  const cheia = achados.find((a) => !a.miniatura);
  return (cheia || achados[0] || {}).url || null;
}

async function buscarFotoNaUazapi(servidor, token, numero) {
  const lembrada = rotaDeFotoQueServe.get(servidor);
  const ordem = lembrada
    ? [lembrada, ...ROTAS_DE_FOTO.filter((r) => r.rota !== lembrada.rota)]
    : ROTAS_DE_FOTO;

  const tentadas = [];
  for (const candidata of ordem) {
    try {
      const r = await fetchComTimeout(`${servidor}${candidata.rota}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', token },
        body: JSON.stringify(candidata.corpo(numero)),
      }, 15000);
      tentadas.push(`${candidata.rota} → ${r.status}`);
      if (!r.ok) {
        if (lembrada && candidata.rota === lembrada.rota) rotaDeFotoQueServe.delete(servidor);
        continue;
      }
      const dados = await r.json().catch(() => null);
      const url = acharFotoNaResposta(dados);
      if (!url) continue;
      if (!lembrada || lembrada.rota !== candidata.rota) {
        console.log(`foto do contato: este servidor atende por ${candidata.rota}.`);
        rotaDeFotoQueServe.set(servidor, candidata);
      }
      return { url };
    } catch (e) {
      tentadas.push(`${candidata.rota} → ${e.message}`);
      if (lembrada && candidata.rota === lembrada.rota) rotaDeFotoQueServe.delete(servidor);
    }
  }
  console.log('foto do contato: nenhuma rota serviu — ' + tentadas.join(' · '));
  return { url: null, tentadas };
}

app.options('/contato/foto', (req, res) => { liberarCors(res); res.sendStatus(204); });
// `rotaVantoro` é o embrulho de CORS + login + erro. O nome vem de onde ele
// nasceu; o que ele faz serve para qualquer rota que exija estar logado.
app.post('/contato/foto', rotaVantoro(async (req) => {
  const conversaId = String((req.body && req.body.conversa_id) || '').trim();
  if (!conversaId) return { status: 400, corpo: { ok: false, erro: 'Informe a conversa.' } };

  const { data: conv } = await supabase
    .from('conversas')
    .select('id, contato:contato_id (id, numero, foto_url), advogado:advogado_id (servidor, token)')
    .eq('id', conversaId).maybeSingle();
  if (!conv || !conv.contato || !conv.advogado) {
    return { status: 404, corpo: { ok: false, erro: 'Não achei essa conversa.' } };
  }
  if (!conv.advogado.token) {
    return { status: 503, corpo: { ok: false, erro: 'Este telefone não está conectado à Uazapi.' } };
  }
  // Grupo não tem foto de perfil de pessoa; pedir seria pedir o que não existe.
  const numero = String(conv.contato.numero || '');
  if (!numero || numero.startsWith('grupo:')) {
    return { status: 400, corpo: { ok: false, erro: 'Esta conversa não tem foto de perfil para buscar.' } };
  }

  const servidor = (conv.advogado.servidor || 'https://novaera.uazapi.com').replace(/\/$/, '');
  const { url } = await buscarFotoNaUazapi(servidor, conv.advogado.token, numero);
  if (!url) {
    return { status: 502, corpo: { ok: false,
      erro: 'Não consegui buscar a foto agora. Ela aparece maior sozinha na próxima mensagem deste contato.' } };
  }
  if (url === conv.contato.foto_url) {
    return { status: 200, corpo: { ok: true, foto_url: url, trocou: false } };
  }
  const { error } = await supabase.from('contatos').update({ foto_url: url }).eq('id', conv.contato.id);
  if (error) {
    return { status: 502, corpo: { ok: false, erro: 'Achei a foto, mas não consegui guardá-la.' } };
  }
  return { status: 200, corpo: { ok: true, foto_url: url, trocou: true } };
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

// ------------------------------------------------------------
//  CADA PASSO DA ENTRADA TEM PRAZO, E CADA PASSO APARECE NO LOG
//
//  A entrada é uma fila de cinco idas à rede: Vantoro, criar/achar a conta,
//  alinhar o nome, espelhar o usuário, gerar o bilhete. Só a primeira tinha
//  prazo. Qualquer uma das outras, travando, travava a entrada inteira — e o
//  log não dizia nada, porque nenhuma delas escreve ao começar.
//
//  Foi o que aconteceu numa manhã de expediente: "tentativa de rodrigo.sousa"
//  no log e depois silêncio; a tela esperou 75 segundos e desistiu, sem que
//  ninguém pudesse dizer QUAL passo estava pendurado.
//
//  Agora cada um tem prazo próprio e deixa no log quanto demorou. Uma entrada
//  que falha em cinco segundos dizendo onde falhou vale mais do que uma que
//  fica pendurada dando esperança.
// ------------------------------------------------------------
function comPrazo(promessa, ms, oQue) {
  return new Promise((resolve, reject) => {
    const relogio = setTimeout(
      () => reject(new Error(`o passo "${oQue}" não respondeu em ${Math.round(ms / 1000)}s`)), ms);
    Promise.resolve(promessa).then(
      (v) => { clearTimeout(relogio); resolve(v); },
      (e) => { clearTimeout(relogio); reject(e); });
  });
}

async function passoDaEntrada(oQue, ms, fazer) {
  const comecou = Date.now();
  try {
    const r = await comPrazo(fazer(), ms, oQue);
    console.log(`entrada · ${oQue}: ${Date.now() - comecou}ms`);
    return r;
  } catch (e) {
    console.error(`entrada · ${oQue}: FALHOU depois de ${Date.now() - comecou}ms — ${(e && e.message) || e}`);
    // O NOME DO PASSO VIAJA COM O ERRO, e não dentro do texto dele. O passo
    // falha de vários jeitos — prazo estourado aqui, prazo estourado lá dentro,
    // conexão recusada — e procurar o nome no meio da frase só acertaria o
    // primeiro. Numa propriedade, ele sobrevive a qualquer mensagem.
    const erro = (e instanceof Error) ? e : new Error(String(e));
    if (!erro.passo) erro.passo = oQue;
    throw erro;
  }
}

app.options('/auth/login', (req, res) => {
  liberarCors(res, req);
  // O PEDIDO DE PERMISSÃO, que vem ANTES do de verdade. Uma entrada com corpo
  // em JSON sempre manda este primeiro; se ele não passa, o pedido de verdade
  // nunca sai do navegador — e no log da ponte não aparece nada, porque nada
  // chegou. Registrado, ele separa "não chegou aqui" de "chegou e falhou".
  console.log(`entrada: pedido de permissão (OPTIONS) de "${req.headers.origin || 'sem origem'}"`);
  res.sendStatus(204);
});

app.post('/auth/login', async (req, res) => {
  liberarCors(res, req);
  const login = String((req.body && (req.body.login || req.body.email)) || '').trim();
  console.log(`entrada: tentativa de "${login || '(sem usuário)'}" de "${req.headers.origin || 'sem origem'}"`);
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
    const { status, corpo } = await passoDaEntrada('perguntar ao Vantoro', 25000, () =>
      chamarVantoro('/auth/login', { method: 'POST', body: JSON.stringify({ login, senha }) }));
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
    const id = await passoDaEntrada('conta no Supabase', 20000, () => contaDoSupabase(email, u.nome));

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
    // ALINHAR O NOME SAI DO CAMINHO — sem `await` nenhum.
    //
    // Primeiro ele não tinha prazo e travava a entrada para sempre. Depois
    // ganhou prazo de 10 segundos, e aí passou a custar 10 segundos de espera
    // a CADA pessoa, todo dia, num serviço que estava lento — para escrever um
    // nome que ninguém está esperando.
    //
    // Ele fala com a mesma API de administração do Auth que hoje está doente.
    // E é a única coisa nesta rota que não precisa acontecer agora: a pessoa
    // entra com o nome de antes e a próxima entrada realinha.
    //
    // Mesmo tratamento que as permissões já recebiam duas linhas abaixo, e
    // pelo mesmo motivo: quem está digitando a senha não pode esperar por
    // sincronização.
    passoDaEntrada('alinhar o nome', 10000, () => alinharNomeDaConta(id, u.nome))
      .catch(() => {});

    // Espelha quem é a pessoa, para a tela de permissões mostrar nome em vez
    // de um código, e para as regras de visibilidade terem onde se apoiar.
    // `admin` do Vantoro manda: quem é superusuário lá administra aqui.
    const { error: erroUsuario } = await passoDaEntrada('espelhar o usuário', 15000, () =>
      supabase.from('usuarios').upsert({
        id, login: u.login, nome: u.nome || '', email,
        admin: Boolean(u.admin), ativo: true, visto_em: new Date().toISOString(),
      }, { onConflict: 'id' }));
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

    // ------------------------------------------------------------
    //  ABRIR A SESSÃO — POR DOIS CAMINHOS, E O SEGUNDO NÃO DEPENDE DE NINGUÉM
    //
    //  O caminho de sempre é pedir um bilhete de uso único ao Auth do
    //  Supabase (`generateLink`); o painel troca por uma sessão na hora. É o
    //  caminho normal e continua sendo o primeiro, porque a sessão que sai
    //  dele se renova sozinha e dura o quanto a pessoa quiser ficar.
    //
    //  Só que era ele o ponto único de falha: em 19/08 o Auth ficou fora e
    //  ninguém entrou a manhã inteira. Então agora existe o segundo caminho —
    //  a própria ponte assina o bilhete, com o segredo do projeto — e a
    //  resposta leva os DOIS quando ambos estão disponíveis. O painel usa o
    //  primeiro que funcionar; se o Auth responder ao `generateLink` mas
    //  falhar no `verifyOtp`, ele ainda tem o outro no bolso.
    //
    //  O prazo caiu de 20 segundos (com uma segunda tentativa, 60 no total)
    //  para 8, e a segunda tentativa saiu. Ela existia porque desistir era
    //  não entrar; hoje desistir é entrar pelo outro caminho, e oito segundos
    //  esperando por um serviço doente já é tempo demais na cara de quem
    //  digitou a senha.
    // ------------------------------------------------------------
    const posso = souCapazDeAssinar();
    let hashDoBilhete = null;
    const bilhete = await passoDaEntrada('gerar o bilhete', posso ? 8000 : 20000, () =>
      supabase.auth.admin.generateLink({ type: 'magiclink', email })).catch(() => null);
    if (bilhete && bilhete.data && bilhete.data.properties && bilhete.data.properties.hashed_token) {
      hashDoBilhete = bilhete.data.properties.hashed_token;
    } else if (!posso) {
      // Sem segredo configurado não há segundo caminho: é aqui que a entrada
      // acaba, como acabava antes.
      console.error('login: generateLink falhou e não há SUPABASE_JWT_SECRET para assinar por conta própria.');
      return res.status(502).json({ ok: false, erro: 'Não consegui abrir a sessão. Tente de novo.' });
    } else {
      console.log('entrada: o Auth não deu o bilhete; assinando a sessão aqui mesmo.');
    }

    // A FOTO VAI JUNTO. O painel desenha o rostinho da pessoa no canto a
    // partir do que está na sessão; sem isto, quem entrasse pelo caminho
    // assinado veria as iniciais no lugar da foto e concluiria que o sistema
    // "perdeu" alguma coisa. É uma leitura de banco, que é a metade que fica
    // de pé — e se falhar, segue sem foto em vez de segurar a entrada.
    let fotoDaPessoa = null;
    if (posso) {
      try {
        const { data: eu } = await supabase.from('usuarios')
          .select('foto_url').eq('id', id).maybeSingle();
        fotoDaPessoa = (eu && eu.foto_url) || null;
      } catch (_e) { /* sem foto, e a entrada segue */ }
    }

    const sessao = posso
      ? assinarSessao({ id, email, nome: u.nome, login: u.login, foto: fotoDaPessoa })
      : null;

    freioLimpa(chaveFreio);
    // O FIM FELIZ TAMBÉM VAI PARA O LOG. Sem ele, "nenhuma linha de entrada no
    // log" tanto pode ser "ninguém tentou" quanto "todo mundo entrou" — e a
    // primeira vez que isso importou foi justamente numa manhã em que ninguém
    // conseguia entrar.
    console.log(`entrada: "${u.login}" entrou${hashDoBilhete ? '' : ' (pela sessão assinada aqui)'}.`);
    return res.json({
      ok: true,
      token_hash: hashDoBilhete,
      // A SESSÃO PRONTA. Vem SEM nada que sirva para renovar: o bilhete vale
      // doze horas e acabou. É de propósito — uma credencial de renovação
      // seria mais uma chave de longa vida circulando no navegador, e o que
      // ela compraria (não ter de entrar de novo no dia seguinte) não paga.
      sessao: sessao && {
        access_token: sessao.token,
        expira_em: sessao.expira_em,
        usuario_id: id,
      },
      email,
      usuario: { login: u.login, nome: u.nome, admin: Boolean(u.admin) },
    });
  } catch (e) {
    const motivo = (e && e.message) || String(e);
    console.error('entrada: FALHOU —', motivo);

    // O SUPABASE TEM DUAS METADES, E ELAS CAEM SEPARADAS.
    //
    // Banco e autenticação são serviços diferentes atrás do mesmo endereço. Em
    // 19/08 o banco respondeu em 168ms enquanto o `/auth/v1/*` devolvia erro
    // 521 do Cloudflare — "o servidor de origem não está respondendo". Metade
    // do projeto de pé, metade no chão.
    //
    // Sem isto, a tela mandava "tente de novo" para uma coisa que não vai dar
    // certo tentando de novo: o escritório inteiro repetindo a senha, achando
    // que errou. "Não é a sua senha" é a informação que falta.
    // SÓ SOBROU UM PASSO QUE O AUTH PODE DERRUBAR, e ele só acontece com
    // quem NUNCA entrou: é a criação da conta. "Alinhar o nome" e "gerar o
    // bilhete" também falam com o Auth, mas hoje os dois são contornados —
    // o primeiro sai do caminho sem `await`, o segundo tem a sessão assinada
    // aqui como saída. Nenhum dos dois chega até este ponto.
    const PASSOS_DO_AUTH = ['conta no Supabase'];
    if (e && e.passo && PASSOS_DO_AUTH.includes(e.passo)) {
      console.error('entrada: a AUTENTICAÇÃO do Supabase não está respondendo (o banco está). '
                  + 'Reinicie o projeto em Settings → General → Restart project, '
                  + 'e confira status.supabase.com.');
      return res.status(503).json({
        ok: false,
        erro: 'O serviço de autenticação está fora do ar — não é a sua senha. '
            + 'Isto só atrapalha quem está entrando no Zorvin pela primeira vez; '
            + 'quem já entrou alguma vez consegue. Avise quem administra.',
      });
    }
    // O PASSO VAI NA RESPOSTA. Quem está na porta não precisa do detalhe
    // técnico, mas precisa saber que não foi a senha dele — e quem administra
    // precisa saber ONDE. Sem isso o relato volta como "não entrou", que é
    // onde esta manhã começou.
    return res.status(502).json({
      ok: false,
      erro: e && e.passo
        ? `Não foi possível entrar agora: ${e.passo} não respondeu. Tente de novo.`
        : 'Não foi possível entrar agora. Tente de novo.',
    });
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
// ------------------------------------------------------------
//  AO SUBIR, A PONTE DIZ SE SABE ASSINAR A SESSÃO
//
//  A saída para o Auth fora do ar só aparece no dia em que o Auth cair. Até
//  lá, ligada ou desligada, a ponte se comporta igual — e quem configurou a
//  variável não tem como saber se acertou. Descobrir no dia seria descobrir
//  do pior jeito.
//
//  E MAIS UMA CONFERÊNCIA, que vale a ida à rede: se o projeto tiver migrado
//  para chave assimétrica (o Supabase oferece isso num botão chamado
//  "Migrate JWT secret"), o banco passa a recusar os bilhetes assinados aqui —
//  eles são HS256. A saída continuaria existindo no código e não funcionaria
//  mais, em silêncio, até o dia em que fosse precisa. Uma linha no log no dia
//  da migração é o aviso mais barato que existe.
//
//  A lista de chaves é pública de propósito (é assim que qualquer um confere
//  uma assinatura), então não há nada de sigiloso nesta chamada. Ela é
//  best-effort: falhando, não diz nada e não atrapalha nada.
// ------------------------------------------------------------
async function contarComoEstaAEntrada() {
  if (!souCapazDeAssinar()) {
    console.log('entrada: SUPABASE_JWT_SECRET não está configurada. A entrada '
              + 'funciona normalmente, mas se o Auth do Supabase cair de novo '
              + 'ninguém entra — foi o que houve em 19/08. O valor está em '
              + 'Settings → JWT Keys → Legacy JWT Secret.');
    return;
  }
  console.log('entrada: sei assinar a sessão por conta própria — se o Auth do '
            + 'Supabase cair, o escritório continua entrando.');

  const base = String(process.env.SUPABASE_URL || '').replace(/\/+$/, '');
  if (!base) return;
  try {
    const r = await fetchComTimeout(`${base}/auth/v1/.well-known/jwks.json`, {}, 8000);
    const corpo = await r.json();
    const chaves = (corpo && corpo.keys) || [];
    const assimetricas = chaves.filter((k) => k && k.kty && k.kty !== 'oct');
    if (assimetricas.length) {
      console.error('entrada: ATENÇÃO — este projeto do Supabase passou a assinar com chave '
                  + `assimétrica (${assimetricas.map((k) => k.alg || k.kty).join(', ')}). `
                  + 'Os bilhetes que a ponte assina são HS256 e o banco vai recusá-los, '
                  + 'então a saída para o Auth fora do ar deixou de funcionar. '
                  + 'Isso precisa ser refeito antes da próxima queda.');
    }
  } catch (_e) {
    // Sem resposta agora não quer dizer nada: pode ser justamente o Auth fora
    // do ar, que é o dia para o qual tudo isto existe.
  }
}

app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
  contarComoEstaAEntrada().catch(() => {});
});
