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

    const { error: msgErro } = await supabase
      .from('mensagens')
      .upsert(
        {
          conversa_id: conversa.id,
          origem,
          tipo,
          texto,
          midia_url: midiaUrl,
          midia_mime: midiaMime,
          id_uazapi: m.messageid,
          status: origem === 'contato' ? 'recebida' : 'enviada'
        },
        { onConflict: 'id_uazapi', ignoreDuplicates: true }
      );
    if (msgErro) { console.error('Erro ao salvar mensagem:', msgErro.message); return; }

    console.log(`Recebida (${tipo}) de ${contatoNumero} p/ advogado ${advogadoNumero}.`);
  } catch (e) {
    console.error('Erro inesperado no webhook:', e.message);
  }
});

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
      .select('id, conversa_id, texto')
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
        // Chama a Uazapi para enviar o texto.
        const resposta = await fetch(`${servidor}/send/text`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'token': token
          },
          body: JSON.stringify({
            number: numeroDestino,
            text: item.texto,
            readchat: true
          })
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

        await supabase.from('mensagens').upsert(
          {
            conversa_id: item.conversa_id,
            origem: 'advogado',
            tipo: 'texto',
            texto: item.texto,
            id_uazapi: idUazapi,
            status: 'enviada'
          },
          { onConflict: 'id_uazapi', ignoreDuplicates: true }
        );

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
