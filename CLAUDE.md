# CLAUDE.md — Zorvin Bridge (a ponte)

> Contexto do projeto para o Claude Code. Leia antes de qualquer alteração.

## Quem é o usuário

Rodrigo (@ropelimi), gerente comercial de um escritório de advocacia. **Não é desenvolvedor** — se descreve como leigo. Explique em linguagem simples, evite jargão, e prefira dar o passo a passo em vez de assumir conhecimento de terminal, Git ou infraestrutura. Fala português (pt-BR).

## O que é o Zorvin

Central de atendimento de WhatsApp da equipe de **Acordos e Execução** do escritório, sob a marca **Ropelimi**. Permite que qualquer atendente da equipe veja e responda as conversas de WhatsApp de **vários advogados** (hoje ~8, pode crescer até 20) num único painel, estilo WhatsApp Web.

Sistema **separado** do Vantoro (o dashboard comercial do mesmo usuário). Não compartilham banco, login nem código.

## Arquitetura (3 peças)

```
WhatsApp ⇄ Uazapi ⇄ [zorvin-bridge] ⇄ Supabase ⇄ [zorvin-painel]
                     (este repo)                   (repo separado)
```

- **zorvin-bridge** (ESTE REPO) — Node.js + Express. Recebe webhooks da Uazapi e grava no Supabase; processa a `fila_envio` e envia mensagens via Uazapi. Hospedado no **Render** como Web Service (plano free + cronjob a cada 10 min para não dormir).
- **zorvin-painel** — Vite + React. Interface estilo WhatsApp Web. Hospedado no Render como **Static Site**.
- **Supabase** — banco Postgres + Auth + Realtime + Storage. Projeto **separado** do Vantoro.

## Este repositório

```
index.js        — todo o código da ponte
package.json    — deps: express, @supabase/supabase-js
```

Variáveis de ambiente (no Render):
- `SUPABASE_URL`
- `SUPABASE_SERVICE_KEY` — chave **service_role** (ignora RLS, é o que permite a ponte escrever)
- `SUPABASE_JWT_SECRET` — o **JWT Secret** do projeto (Supabase → Settings → API → JWT Secret).
  **Opcional.** Sem ela a entrada funciona como sempre funcionou; com ela, a ponte
  consegue assinar a sessão sozinha quando o Auth do Supabase está fora do ar, e
  confere as sessões sem sair da máquina. Ver "A entrada" abaixo.

## A entrada (login) — e por que ela tem dois caminhos

Em **19/08/2026** o serviço de autenticação do Supabase (`/auth/v1/*`) ficou fora do
ar por horas, enquanto o banco do mesmo projeto respondia em 168ms. O escritório
inteiro ficou sem entrar numa manhã de expediente.

A entrada é: o Vantoro confere a senha → a ponte acha/cria a conta → a ponte abre a
sessão. Só o último passo dependia do Auth, e bastava ele para ninguém entrar.

Hoje há dois caminhos, e a resposta traz os dois quando ambos estão disponíveis:

1. **`token_hash`** — o bilhete de uso único do Auth (`generateLink`); o painel troca
   por uma sessão com `verifyOtp`. É o preferido: a sessão que sai dele se renova
   sozinha e a pessoa fica entrada o quanto quiser.
2. **`sessao`** — a ponte assina o bilhete com `SUPABASE_JWT_SECRET`. Vale **12 horas**
   e **não se renova** (não há credencial de renovação, de propósito). O painel guarda
   direto no armazenamento do `supabase-js` e recarrega — `setSession` não serve, ela
   também chama o Auth por baixo.

`exigirLogin` também confere o bilhete **localmente** com o mesmo segredo, em vez de
chamar `auth.getUser` a cada pedido. Vale para os bilhetes que a ponte assina e para
os que o Auth emite, porque o segredo é o mesmo.

**Sem a variável, tudo isso fica desligado** e a entrada é exatamente a de antes.

Fica de fora: quem **nunca entrou** precisa que a conta nasça no Auth (`createUser`),
e isso não tem como ser contornado. Numa queda, só a primeira entrada da vida de
alguém falha.

Rotas:
- `GET /` → health check ("Zorvin bridge online"), usada pelo cronjob
- `POST /webhook` → recebe mensagens da Uazapi

Envio: `setInterval` a cada 3s lê `fila_envio` (status `pendente`), envia e marca como `enviada`/`erro`.

## Uazapi — formato real (confirmado em teste)

Servidor do usuário: `https://novaera.uazapi.com`. Uma instância por advogado.

**Webhook de entrada** (`POST /webhook`), campos relevantes:
```jsonc
{
  "EventType": "messages",
  "owner": "5511945672809",        // número do ADVOGADO (dono da instância)
  "chat":    { "phone": "...", "wa_name": "..." },   // dados do CONTATO
  "message": {
    "messageid": "...",            // id único (usado como id_uazapi, evita duplicata)
    "fromMe": false,
    "wasSentByApi": false,         // true = eco de mensagem enviada pelo Zorvin → IGNORAR
    "type": "text" | "media",
    "mediaType": "image" | "ptt" | "audio" | "video" | "document",
    "text": "...",
    "sender_pn": "5511970598987@s.whatsapp.net",
    "content": { /* string p/ texto; objeto p/ mídia */ }
  }
}
```

**Envio de texto:**
```
POST {servidor}/send/text
Header: token: <token da instância>
Body:   { "number": "5511...", "text": "...", "readchat": true }
```
Campos opcionais úteis ainda não usados: `delay` (mostra "Digitando…"), `readmessages`, `replyid`, `mentions`.

Documentação: https://docs.uazapi.com/ (carrega via JS; não dá para ler com fetch simples).

## Banco de dados (Supabase)

- `advogados` — id, nome, numero, instancia, token, servidor, foto_url, ativo
- `contatos` — id, numero (unique), nome, foto_url
- `conversas` — id, advogado_id, contato_id (unique juntos), ultima_mensagem, ultima_atividade, nao_lidas
- `mensagens` — id, conversa_id, origem ('contato'|'advogado'), tipo, texto, midia_url, midia_mime, id_uazapi (unique), status
- `fila_envio` — id, conversa_id, texto, status ('pendente'|'enviando'|'enviada'|'erro'), erro_detalhe

Trigger em `mensagens` atualiza `conversas` (prévia, ordem, não lidas). Realtime ligado em `mensagens`, `conversas`, `fila_envio`. RLS ligado com políticas para `authenticated` (a ponte não é afetada — usa service_role).

## Armadilhas já encontradas (não repetir)

1. **IPv6**: a connection string direta do Supabase resolve para IPv6 e o Render **não alcança**. Usar sempre a do **Session Pooler** (IPv4).
2. **Duplicação de mensagens enviadas**: a ponte gravava a mensagem E o eco do webhook gravava de novo. Resolvido ignorando `wasSentByApi === true` e gravando o `id_uazapi` retornado no envio.
3. **Plano free do Render** não tem Shell, nem Pre-Deploy Command, nem Background Worker. Qualquer solução que dependa disso não serve.
4. Chatwoot foi tentado antes e **abandonado** — estourava os 512 MB do plano free (precisa ~2 GB). Não sugerir voltar para ele sem discutir custo.

## Pendências / próximos passos

- **Mídias em alta resolução**: hoje imagens só têm a miniatura (`JPEGThumbnail`) e áudios não são baixados. As URLs da Uazapi vêm criptografadas (`.enc` + `mediaKey`) — falta usar o endpoint de download/convert da Uazapi e salvar no Storage do Supabase.
- **Enviar anexos pelo painel** (imagem, áudio, documento) — endpoints `/send/media` da Uazapi.
- **E-mails (Gmail)**: fase futura, fora do escopo atual.
- Recursos de UX: "Digitando…" (`delay`), marcar como lida (`readmessages`).

## Fluxo de trabalho — PRs (REGRA IMPORTANTE do Rodrigo)

- **Cada entrega/pedido deve ir numa PR NOVA.** Nunca reutilizar nem estender uma PR já mesclada.
- O Rodrigo faz o merge e, na rodada seguinte, quer **sempre uma PR nova** (não empilhar em cima da anterior).
- Fluxo por rodada: recomeçar a branch a partir da `main` mais recente
  (`git fetch origin main && git checkout -B <branch> origin/main`), aplicar a mudança,
  commit, push e **abrir uma PR nova**.
- Passo a passo (SQL, merge, etc.) vai **no chat**, não na descrição da PR.
