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
- `IMPORT_TOKEN` — a senha da porta `/importar-historico`, que relê pela Uazapi o
  passado de uma conversa ou de um grupo. **Sem ela a porta recusa TUDO**, inclusive
  quem tem direito de usá-la. Ela faltava nesta lista, e foi por isso que nunca foi
  criada no Render: em 02/09 o resgate do histórico de um grupo esbarrou aqui, e a
  resposta da época mandava procurar erro de digitação num token que estava certo.

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

## A entrada de mensagens — a caixa de entrada do webhook

O "OK" que a ponte responde à Uazapi é uma **promessa**: dali em diante ela considera a
mensagem entregue e não manda de novo. Por isso o evento cru é gravado em
`eventos_recebidos` **antes** do "OK". Se o tratamento não terminar (uma publicação, o
banco fora por um minuto), uma rodada a cada 30s encontra o evento pendente e termina o
serviço — a mensagem entra com atraso, em vez de não entrar.

Três regras que sustentam isso, e que não podem ser desfeitas sem quebrar a garantia:

1. **Não guardou, não promete.** Falhando a gravação, o webhook responde `503` — a
   mensagem continua sendo da Uazapi para reentregar.
2. **Falha de banco no meio do tratamento SOBE** (`throw`), em vez de virar `return`.
   Um `return` faz a caixa marcar o evento como resolvido com a mensagem fora do banco —
   a perda, agora com um registro dizendo que deu tudo certo.
3. **Sem a tabela, tudo funciona como antes.** A ponte descobre sozinha, avisa uma vez no
   log e segue. Fazer o webhook depender de uma tabela que talvez não exista trocaria uma
   perda rara por uma parada total.

SQL: `sql/2026-09-a-caixa-de-entrada-do-webhook.sql`. Variável **opcional**
`CAIXA_INTERVALO_MS` (padrão 30s), que existe para a bancada encurtar a rodada.

## A fila de envio — quando a ponte insiste sozinha, e quando não

Uma falha, e a mensagem morria ali: virava bolha vermelha e só saía se alguém
estivesse com aquela conversa aberta para tocar em reenviar. Hoje a ponte tenta
de novo sozinha, com espera crescente (30s, 2min, 5min, 15min) e no máximo cinco
vezes.

**A régua não é "deu erro, tenta de novo"** — é *só tenta sozinha quando a falha
prova que nada chegou ao cliente*. Reenviar uma mensagem que talvez tenha saído é
o cliente recebendo duas vezes, e disso não há desfazer. Então:

- **insiste**: 429 (a Uazapi dizendo que não processou) e a conexão que nunca
  abriu (`ECONNREFUSED`, `ENOTFOUND`, `EAI_AGAIN`);
- **não insiste, vira erro na tela**: número que não existe, cliente que
  bloqueou, arquivo grande demais — insistir não mudaria nada;
- **não insiste, de propósito**: linha do escritório caída (pede uma pessoa para
  reconectar o aparelho, e insistir só adiaria o aviso) e **tempo limite,
  `ECONNRESET`, 5xx** — nesses o pedido pode ter chegado inteiro e só a resposta
  ter se perdido. Saber quais são seguros depende de medir o comportamento da
  Uazapi, e é uma pergunta ainda em aberto.

Esgotadas as cinco, a bolha diz que já tentamos várias vezes **e** guarda o
motivo técnico — sem ele, quem investiga perde a única pista do porquê.

O código da falha de rede (`cause.code`) vinha do Node e era descartado; sem ele
não há como separar "não falei com o servidor" de "falei e a resposta se perdeu",
que é exatamente a diferença entre poder insistir e não poder.

SQL: `sql/2026-09-a-mensagem-que-nao-saiu-tenta-de-novo.sql` (coluna
`fila_envio.tentar_em`). **Sem ela tudo funciona como antes** — a ponte descobre
sozinha, avisa uma vez no log, e a fila continua enviando.

## O anexo que não vem mais — "não consegui agora" e "não existe" são diferentes

MEDIDO em 11/09, resgatando os anexos vazios do escritório. A rota que serve
neste servidor é `POST /message/download`, e ela respondeu:

```
400 {"error":"Message does not contain downloadable media"}
```

Isso **não é a rota falhando** — é a rota funcionando e dizendo que aquela
mensagem não tem arquivo. A resposta não muda daqui a cinco minutos. E a ponte
insistia assim mesmo: mais três rodadas de seis pedidos, **24 chamadas para
ouvir a mesma frase**, num serviço com limite de uso de onde vem o 429 que faz a
fila segurar a mensagem que o atendente escreveu.

**A régua: insiste-se em quem não respondeu, não em quem disse não.** Só as
frases de `RECUSAS_DEFINITIVAS` param a insistência; qualquer outra continua
sendo tentada, porque parar por engano é desistir de um documento que viria.

O motivo vai para `mensagens.midia_erro`, e é dele que a tela se serve para dizer
"não veio — peça para reenviar" em vez de "indisponível" para sempre.

SQL: `sql/2026-09-o-anexo-que-nao-vem-mais.sql`. **Sem a coluna, tudo como
antes** — a ponte avisa uma vez no log e segue.

**E parte do que "se perdeu" nunca foi anexo.** Uma sessão anterior mediu isso
em 11/09 e consertou seis tipos (link com prévia, contato, localização, modelo,
interativa, indecifrável) que a regra `if (m.type === 'media') return 'documento'`
pegava por descarte. Em **12/09** apareceu o que faltava, e ele é de outra
natureza: `ButtonsResponseMessage` — o cliente **tocou num botão**, e o
escritório via "Documento — indisponível". Não é arquivo perdido: é **resposta
de cliente que nunca apareceu na tela**. A forma foi medida no evento cru
(`type: "media"`, `mediaType: "buttons_response"`, texto em `content.Response`).
Ao aparecer um tipo novo de mensagem, a pergunta certa é *"isto é anexo?"* antes
de *"por que o anexo não veio?"*.

**Números de 11/09**, sobre 1.237 anexos de 10 dias: 96,9% chegam com o arquivo,
**nenhum** fica só na miniatura, e 38 ficam vazios — 20 documentos e 5 imagens
entre eles. O tamanho do `id_uazapi` **não** é a causa (todos os tamanhos baixam
na maioria das vezes); a explicação é a que a própria Uazapi deu.

## A saída (publicação) — a ponte termina o que está no meio

Toda publicação derruba o processo. Ao receber `SIGTERM` (que é o que a Render manda),
a ponte **não morre na hora**: para de começar coisa nova (ciclo de fila, rodada de
permissões, avisos de audiência), fecha a porta para conexões novas, espera o que já
estava em voo — os webhooks sendo gravados e o ciclo da fila aberto — e só então sai.

Isso existe porque o webhook responde "OK" à Uazapi **antes** de gravar: morrer nesse
intervalo é a mensagem do cliente sumindo sem rastro. E um envio já aceito pela Uazapi
cuja marca de "enviada" não chegou ao banco ficaria preso em `enviando`, para ser
reenviado cinco minutos depois — o cliente recebendo duas vezes.

O teto de espera é de 25 segundos (a Render dá 30 antes de matar à força) e sai de
`DESLIGAR_PRAZO_MS`, **opcional**, que existe para a bancada poder encurtá-lo. Estourando
o prazo, a ponte sai assim mesmo e **diz no log** o que ficou pela metade.

Webhook que chega durante a saída recebe `503`, e não um "OK" que não será honrado.

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
4. **Vista sem `security_invoker` é um buraco na regra de acesso** (09/09/2026): a
   vista `equipe` (`select id, nome, foto_url from usuarios`) roda com os poderes
   da dona, então a RLS de `usuarios` **não vale por dentro dela** — e ela estava
   liberada para `anon`. Medido: 21 linhas devolvidas a quem não entrou, com a
   chave que vai no código da página. Pior, vista simples de uma tabela só é
   **gravável**: `anon` tinha `UPDATE`/`DELETE` nela, e escrever ali cai em
   `usuarios` sem passar por `usuarios_admin`. Conserto em
   `sql/2026-09-a-lista-da-equipe-nao-e-publica.sql`. **Ligar `security_invoker`
   seria o conserto errado** — `usuarios_leitura` é `id = auth.uid() or
   zorvin_admin()`, então cada atendente passaria a ver só a própria linha e os
   nomes das mensagens antigas sumiriam em silêncio. Ao criar vista nova, decida
   e ESCREVA qual das duas ela é.
5. **A regra de acesso estava sozinha** (09/09/2026): `anon` tinha DELETE,
   INSERT, UPDATE, SELECT e TRUNCATE em **todas** as tabelas — o padrão do
   Supabase. Nada vazava, porque nenhuma política o alcançava; mas bastava UMA
   política escrita para `{anon, ...}` para abrir tudo, e isso aconteceu duas
   vezes (a política da `fila_envio` e a vista `equipe`). Hoje `anon` não tem
   permissão em tabela nem sequência nenhuma, e
   `limpar_eventos_recebidos()` — `security definer`, que APAGA — é só da ponte.
   Conserto em `sql/2026-09-quem-nao-entrou-nao-alcanca-nada.sql`.
   **Ainda aberto**: as funções em `public` nascem executáveis por `public`, e
   várias são `security definer`. Fechá-las em bloco derruba o painel (o acesso
   de `authenticated` a várias vem do próprio `public`) — tem de ser uma a uma,
   e a parte 6 daquele arquivo lista todas.
   **E aquele `revoke` tinha prazo**: a varredura seguinte mostrou que toda
   tabela, sequência e função NOVA em `public` nascia liberada para `anon`
   (`anon=arwdDxtm`), então a próxima tabela criada reabriria tudo, calada. A
   herança foi fechada em `sql/2026-09-a-tabela-nova-nao-nasce-aberta.sql` —
   só para `anon`; `authenticated` continua herdando o que sempre herdou, e
   tabela nova segue servindo o painel sem passo extra. Ao criar tabela, o que
   continua sendo obrigatório é a POLÍTICA junto.
6. **Cache curto em mídia derruba o atendimento** (21/08/2026): a biblioteca do
   Supabase manda `max-age=3600` quando ninguém diz nada, então de hora em hora
   cada atendente rebaixava todas as fotos e áudios das conversas que abrisse.
   Com oito pessoas rolando conversas o dia inteiro e mais de 1 GB guardado, a
   franquia de banda zerou e o workspace foi suspenso. Hoje é um ano e
   `immutable` (`CACHE_DA_MIDIA`), o que é seguro porque o endereço é
   `recebidos/{messageid}` e o messageid não se repete — aquele endereço nunca
   aponta para outro conteúdo.
7. Chatwoot foi tentado antes e **abandonado** — estourava os 512 MB do plano free (precisa ~2 GB). Não sugerir voltar para ele sem discutir custo.

## Pendências / próximos passos

- ~~Mídias em alta resolução~~ e ~~enviar anexos pelo painel~~ — **as duas foram
  feitas**, e esta lista ficou meses dizendo o contrário. Isso tem custo: em
  11/09 uma sessão leu a lista em vez do código e recomendou refazer o que já
  estava pronto. **Ao terminar algo daqui, risque na mesma entrega.**
  - Enviar: `/send/media` cobre imagem, vídeo, áudio (`ptt`), documento e
    figurinha, com `replyid` e `docName`, e um segundo caminho em base64 para
    quando o endereço público do Storage é recusado.
  - Receber: `baixarMidiaRecebida` procura a rota de download (três endereços,
    por POST e por GET), **lembra o par que serviu** para não martelar o
    serviço, e guarda no Storage (`anexos`) com cache de um ano e `immutable`.
    A porta `/anexos/resgatar` preenche os vazios do passado — e **depende de
    `IMPORT_TOKEN`**, que sem existir recusa todo mundo.
  - **Em aberto, e é empírico, não de programação**: neste servidor as três
    rotas responderam 405 ao POST (medido em 11/09, nos 35 anexos vazios do
    escritório). As tentativas por GET entraram depois e ainda não foram
    confirmadas com anexo de verdade.
- **E-mails (Gmail)**: fase futura, fora do escopo atual.
- Recursos de UX: "Digitando…" (`delay`), marcar como lida (`readmessages`).

## Fluxo de trabalho — PRs (REGRA IMPORTANTE do Rodrigo)

- **Cada entrega/pedido deve ir numa PR NOVA.** Nunca reutilizar nem estender uma PR já mesclada.
- O Rodrigo faz o merge e, na rodada seguinte, quer **sempre uma PR nova** (não empilhar em cima da anterior).
- Fluxo por rodada: recomeçar a branch a partir da `main` mais recente
  (`git fetch origin main && git checkout -B <branch> origin/main`), aplicar a mudança,
  commit, push e **abrir uma PR nova**.
- Passo a passo (SQL, merge, etc.) vai **no chat**, não na descrição da PR.
