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

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_KEY
);

// ------------------------------------------------------------
//  Verificação de saúde (usada pelo cronjob para não "dormir").
// ------------------------------------------------------------
app.get('/', (req, res) => {
  res.status(200).send('Zorvin bridge online');
});

// ============================================================
//  PARTE 1 — RECEBER mensagens
// ============================================================
app.post('/webhook', async (req, res) => {
  res.status(200).send('OK'); // responde rápido para a Uazapi não reenviar

  try {
    const body = req.body;
    const evento = (body.EventType || body.event || '').toLowerCase();

    // Eventos de STATUS das mensagens que ENVIAMOS (entregue / lida) —
    // são o que faz o "tiquinho" virar azul, igual ao WhatsApp.
    if (evento && evento !== 'messages') {
      await tratarStatusMensagem(body, evento);
      return;
    }

    if (body.EventType !== 'messages' || !body.message) return;

    const m = body.message;

    // Se a mensagem foi enviada pelo próprio Zorvin (pela API), a ponte já
    // registrou ela no banco na hora do envio. Este aviso é só um "eco" —
    // ignoramos para não duplicar.
    if (m.wasSentByApi === true) {
      console.log('Eco de mensagem enviada pelo Zorvin; ignorado.');
      return;
    }

    // De qual ADVOGADO é esta conversa (owner = número do dono da instância).
    const advogadoNumero = body.owner || m.owner;
    const { data: adv, error: advErro } = await supabase
      .from('advogados')
      .select('id')
      .eq('numero', advogadoNumero)
      .maybeSingle();
    if (advErro) { console.error('Erro ao buscar advogado:', advErro.message); return; }
    if (!adv) { console.log('Número não cadastrado em advogados:', advogadoNumero); return; }

    // Quem é o CONTATO (usa o telefone real, não o @lid).
    const contatoNumero =
      (body.chat && body.chat.phone) || (m.sender_pn || '').split('@')[0];
    const contatoNome =
      (body.chat && body.chat.wa_name) || m.senderName || null;
    if (!contatoNumero) { console.log('Sem número de contato; ignorando.'); return; }

    const { data: contato, error: contErro } = await supabase
      .from('contatos')
      .upsert({ numero: contatoNumero, nome: contatoNome }, { onConflict: 'numero' })
      .select('id')
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

    // TIPO da mensagem.
    let tipo = 'texto';
    if (m.type === 'media') {
      if (m.mediaType === 'image') tipo = 'imagem';
      else if (m.mediaType === 'ptt' || m.mediaType === 'audio') tipo = 'audio';
      else if (m.mediaType === 'video') tipo = 'video';
      else tipo = 'documento';
    }

    const origem = m.fromMe ? 'advogado' : 'contato';
    const texto =
      m.text || (typeof m.content === 'string' ? m.content : '') || null;

    // Miniatura embutida da imagem (prévia imediata).
    let midiaUrl = null;
    if (tipo === 'imagem' && m.content && m.content.JPEGThumbnail) {
      midiaUrl = 'data:image/jpeg;base64,' + m.content.JPEGThumbnail;
    }
    const midiaMime = (m.content && m.content.mimetype) || null;

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
    // Se a mensagem recebida é uma RESPOSTA a outra, guarda a citação.
    const extras = extrairResposta(m);
    const msgErro = await salvarMensagem(base, extras);
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    console.log(`Recebida (${tipo}) de ${contatoNumero} p/ advogado ${advogadoNumero}.`);
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
    let novo = null;
    if (s === '3' || s === '4' || s.includes('read') || s.includes('play') || s.includes('lid')) {
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

// ============================================================
//  PARTE 2 — ENVIAR respostas (processa a fila_envio)
// ============================================================
//  A cada poucos segundos, a ponte olha a fila de mensagens que o
//  painel quer enviar, e manda cada uma pela Uazapi.
// ------------------------------------------------------------
async function processarFilaDeEnvio() {
  try {
    // Pega até 10 mensagens pendentes de cada vez.
    const { data: pendentes, error } = await supabase
      .from('fila_envio')
      .select('*')
      .eq('status', 'pendente')
      .order('criado_em', { ascending: true })
      .limit(10);

    if (error) { console.error('Erro ao ler fila:', error.message); return; }
    if (!pendentes || pendentes.length === 0) return;

    for (const item of pendentes) {
      // Marca como "enviando" para não processar duas vezes.
      await supabase.from('fila_envio')
        .update({ status: 'enviando', tentativas: 1 })
        .eq('id', item.id);

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
      const numeroDestino = conv.contato.numero;

      try {
        // Monta o corpo do envio. Se esta mensagem é uma RESPOSTA a outra,
        // passa o replyid para a Uazapi citar a mensagem original.
        const corpo = { number: numeroDestino, text: item.texto, readchat: true };
        if (item.responder_id_uazapi) corpo.replyid = item.responder_id_uazapi;

        // Chama a Uazapi para enviar o texto.
        const resposta = await fetch(`${servidor}/send/text`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'token': token
          },
          body: JSON.stringify(corpo)
        });

        if (!resposta.ok) {
          const detalhe = await resposta.text();
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
        await supabase.from('fila_envio')
          .update({ status: 'enviada', enviado_em: new Date().toISOString() })
          .eq('id', item.id);

        const base = {
          conversa_id: item.conversa_id,
          origem: 'advogado',
          tipo: 'texto',
          texto: item.texto,
          id_uazapi: idUazapi,
          status: 'enviada'
        };
        const extras = item.responder_id_uazapi
          ? {
              responder_id_uazapi: item.responder_id_uazapi,
              resposta_previa: item.resposta_previa || null,
              resposta_autor: item.resposta_autor || null
            }
          : null;
        await salvarMensagem(base, extras);

        console.log(`Enviada para ${numeroDestino}.`);
      } catch (envioErro) {
        await supabase.from('fila_envio')
          .update({ status: 'erro', erro_detalhe: envioErro.message })
          .eq('id', item.id);
        console.error(`Falha ao enviar (${item.id}):`, envioErro.message);
      }
    }
  } catch (e) {
    console.error('Erro ao processar fila:', e.message);
  }
}

// Roda a verificação da fila a cada 3 segundos.
setInterval(processarFilaDeEnvio, 3000);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log('Ponte do Zorvin rodando na porta', port);
});
