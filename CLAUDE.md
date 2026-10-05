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
index.js          — todo o código da ponte
package.json      — deps: express, @supabase/supabase-js, pg
sql/              — história: os 55 scripts já rodados à mão
sql/automaticos/  — daqui para a frente: a ponte aplica sozinha
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
- `VANTORO_LENTA_MS` — a partir de quantos milissegundos uma ida ao Vantoro merece
  uma linha no log. **Opcional**, padrão 3000. Ver "Quanto o Vantoro demora" abaixo.
- `DATABASE_URL` — o endereço do **Session Pooler** do Supabase, para a ponte
  aplicar sozinha os scripts de `sql/automaticos/`. **Opcional: sem ela, tudo
  como antes** e as mudanças de banco continuam sendo coladas à mão. Ver "Os
  scripts que se aplicam sozinhos" abaixo.
- `SCRIPTS_AUTOMATICOS` — `conferir` (padrão) ou `aplicar`. **Opcional.**

## Quanto o Vantoro demora — `/vantoro/tempos?token=…`

Relato de 14/09: "está demorando para aparecer o resultado do Vantoro". Demora
quanto? Não estava escrito em lugar nenhum, e havia três explicações plausíveis à
mão — o Vantoro hibernando, a consulta do cadastro, a própria ponte.

A ponte cronometra cada ida ao Vantoro e guarda **duas** medidas por rota:

- `ponte GET /vantoro/buscar` — o pedido inteiro, que é o que o navegador espera;
- `vantoro GET /clientes/buscar` — só a ida ao Vantoro, por dentro dele.

Se as duas são parecidas, o tempo é do Vantoro. Se a de cima é muito maior, é a
ponte. A janela abre no navegador, com o mesmo `IMPORT_TOKEN` das outras portas de
manutenção, e responde em texto (`&formato=json` para JSON).

Duas coisas que valem lembrar antes de mexer nisso:

- **o que foi perguntado não é guardado.** A busca vai na consulta do endereço
  (`?q=NOME`, `?cpf=…`), e a chave guarda só o caminho, com os números virando
  `:id`. Uma janela de diagnóstico que vaza cadastro é pior do que não existir;
- **a conta vive na memória e zera a cada reinício da Render.** Publicar reinicia.
  Números pequenos podem só querer dizer que a ponte subiu faz pouco — e a própria
  janela diz isso.

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

### A mensagem agendada (script 013, 02/10)

Pedido do Rodrigo: agendar mensagem, texto e anexo, que sai na hora marcada
mesmo que o cliente escreva antes. `sql/automaticos/013-a-mensagem-agendada.sql`
acrescenta `fila_envio.agendada_para` (mais `cancelada_em`/`cancelada_por`) e a
política que deixa quem entrou virar uma agendada pendente em `cancelada` — e
nenhuma outra passagem.

**É um item da fila como qualquer outro.** O painel grava a hora em
`agendada_para` E em `tentar_em`, então a leitura de sempre já o deixa de
fora, e o `fila_parada` de `zorvin_saude()` também. A ponte tem **a sua
guarda por cima**, e não é redundância: `esperaDesligada` liga sozinho e não
desliga até a ponte reiniciar, e sem a guarda própria a mensagem de amanhã
sairia agora. São duas: a leitura filtra `agendada_para` (senão dez agendadas
ocupariam os dez lugares da leitura e a fila do dia pararia) e o laço confere
item a item (`aindaNaoEhAHora`).

**Cancelar e a ponte pegar o item na mesma hora se resolve sozinho**: as duas
gravações exigem `status = 'pendente'`, e só a primeira acha a linha assim.

**Sem a coluna, tudo como antes**: a ponte avisa uma vez no log e lê sem a
regra; o painel não oferece agendar.

Conferido num Postgres 16 de verdade: banco limpo, banco com as tabelas,
reaplicação, e a política no papel `authenticated` (cancela a agendada, não
cancela a comum, não devolve a cancelada à fila). Prova: seção 55.

**E o banco do escritório recusava 'cancelada'.** A conferência do 013
perguntou e respondeu `false`: há em `fila_envio` uma regra (CHECK) com a
lista fechada de status, feita à mão no começo do projeto e que não está em
arquivo nenhum. `sql/automaticos/014-a-fila-aceita-cancelada.sql` refaz cada
regra dessas com a MESMA lista mais 'cancelada' — **só se ela for apenas uma
lista**; com qualquer outra coisa dentro, não mexe e mostra a regra na
conferência. O 013 não foi editado: script aplicado não se edita.

**Duas armadilhas da primeira escrita, pegas num Postgres de verdade antes de
ir ao Rodrigo:** o Postgres escreve a lista de dois jeitos (`ARRAY['a'::text,
…]` e `'{a,b}'::text[]`), e a regra refeita no segundo jeito não tinha
`'cancelada'` entre aspas — a conferência dizia `false` logo depois de
consertar, e a segunda rodada corrompia a lista. Hoje a leitura abre os dois
jeitos, a regra é refeita no primeiro, e "já tem cancelada" se pergunta pela
PALAVRA, não pelas aspas. **Script que se diz "rode de novo sem medo" se
testa rodando duas vezes.**

**Editar a agendada (script 016, 05/10).** Pedido do Rodrigo: mudar o texto
(ou a legenda) e a hora de uma agendada. `016-editar-a-mensagem-agendada.sql`
cria `editada_em`/`editada_por` e a política `fila_envio_editar_agendada`:
mexe só na agendada **pendente cuja hora ainda não chegou**, e ela tem de
continuar pendente e no futuro. **A primeira metade fecha a corrida com a
ponte sem mudar uma linha dela:** a fila só lê a agendada depois da hora, e a
partir da hora a edição é recusada — não há instante em que a ponte mande o
texto antigo enquanto alguém grava o novo. A segunda impede usar a edição para
mandar agora (hora no passado) ou tirar da fila por fora. **Recusada, a
edição dá ERRO (42501), e não zero linhas**: a regra do cancelar alcança a
mesma linha, e a checagem de saída de nenhuma das duas passa. Conferido num
Postgres 16.

## Transcrever um áudio — `POST /transcrever` (02/10)

Pedido da equipe: transcrição dos áudios. Decidido com o Rodrigo: pelo
**Groq** (Whisper `whisper-large-v3-turbo`, ~US$ 0,04 por hora de áudio) e
**ao clicar** — nada é transcrito sozinho. A chave é `GROQ_API_KEY`, na
Render; `GROQ_API_URL` e `GROQ_MODELO` são opcionais (a bancada aponta para um
Groq de mentira).

**A mensagem é lida COMO QUEM PEDIU** (`bancoComo(jwt)`: a chave de serviço no
`apikey`, o bilhete da pessoa no `Authorization`), então a regra de acesso do
banco decide — ninguém lê pela transcrição o áudio de um telefone que não
atende. "Não achei" e "não é sua" são a mesma resposta, de propósito.

**O texto fica guardado** em `mensagens.transcricao`
(`sql/automaticos/015-a-transcricao-do-audio.sql`): a segunda pessoa recebe o
guardado, sem nova ida ao Groq. Sem a coluna, transcreve e não guarda. **Dois
cliques juntos são uma ida só** (`transcricoesEmVoo`). A língua vai dita
(`pt`): sem ela um "alô" curto vira espanhol.

Prova: seção 56, 24 conferências, **6 sabotagens e 6 pegas** (ler com a chave
da ponte; sem a língua; sem devolver o guardado; sem juntar os cliques; sem a
chave no cabeçalho; sem guardar).

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

## Desativar um telefone — o que ele para de fazer, e o que continua

`advogados.ativo = false` só tirava a linha do **seletor do painel**. Nada mais
olhava para ela: nem a fila de envio, nem o caminho automático dos avisos de
audiência. Uma linha que o escritório considera desligada continuava mandando
mensagem para cliente — e no pior formato, porque ninguém escolheu aquilo e
ninguém vê: o telefone sumiu da tela, então não há para onde olhar.

Hoje, uma linha desativada:

- **não envia**, nem o que já estava na fila. Desativar é uma decisão de parar;
  honrá-la só daí para a frente deixaria sair justamente o que ninguém está
  olhando. A bolha diz que a linha está desativada e o que fazer.
- **não avisa cliente de audiência.** Este é o caminho automático — o Vantoro
  pede, a ponte escolhe a linha e manda, sem ninguém no meio —, e o motivo
  **volta para o Vantoro** em vez de o aviso sumir: calando aqui, o cliente
  faltaria à audiência sem ninguém saber por quê.
- **continua RECEBENDO, e isso é decisão, não esquecimento.** Perder mensagem de
  cliente é o pior desfecho deste sistema, e um número desativado continua sendo
  um número para onde clientes escrevem.

**Só o `false` explícito desativa.** Numa base antiga a coluna pode vir nula, e
tratar nulo como desativado calaria o escritório inteiro de uma vez — o oposto
do que isto existe para fazer.

**A consequência disto já foi fechada, do lado do painel:** as conversas de uma
linha desativada ficavam gravadas e **invisíveis**, porque o seletor a escondia.
Hoje elas voltam numa seção separada da barra, **só para quem administra**, e com
a caixa de escrever trocada por uma explicação — a linha continua fora de tudo o
que a tela oferece, que é o que esta recusa aqui na ponte exige. Ver "A linha
desativada não some", no CLAUDE.md do painel.

Variável **opcional** `AVISOS_INTERVALO_MS` (padrão 5 min), para a bancada
encurtar a rodada dos avisos. Junto entrou uma rodada 4s depois de subir: só
havia o intervalo, então toda publicação empurrava o primeiro aviso do dia
cinco minutos adiante.

## Os scripts que se aplicam sozinhos

Até 14/09, **toda** mudança de banco foi rodada à mão: 55 arquivos em `sql/`,
colados um a um no editor do Supabase, oito só em setembro. Funciona porque é um
escritório só e porque o Rodrigo está por perto na hora de publicar — e as duas
coisas param de valer no dia em que houver um segundo cliente.

Daqui para a frente, **script novo vai para `sql/automaticos/`** e a ponte o
aplica sozinha ao subir, uma vez cada, na ordem do nome. `sql/` vira história:
nada ali é reaplicado, e **não se move um arquivo de lá para cá** — no banco do
escritório ele já rodou, e a ponte não tem como saber disso.

A biblioteca do Supabase não serve para isto: ela fala PostgREST, que lê e
escreve LINHAS. `create table` não passa por ali — não é permissão, a porta não
existe. Por isso entrou o `pg`, falando direto com o Postgres, e por isso o
endereço é o do **Session Pooler** (armadilha nº 1: o direto é IPv6 e a Render
não alcança).

**As quatro regras, e nenhuma é enfeite:**

1. **Sem `DATABASE_URL`, tudo como antes.** Uma linha no log e nada mais.
2. **O padrão é `conferir`, não `aplicar`.** Com o endereço e nada mais, a ponte
   só DIZ o que rodaria. Rodar DDL sozinha, a cada publicação, num banco que
   atende oito pessoas, é coisa que se escolhe de propósito.
3. **Falha não derruba a ponte.** Script quebrado não pode calar o WhatsApp do
   escritório: a ponte anota a falha na tabela, grita no log e segue atendendo —
   mas **para nos seguintes**, porque o próximo quase sempre supõe o anterior.
4. **Cada script numa transação.** Meio script aplicado é o pior dos mundos: o
   banco num estado que nenhum arquivo descreve. Quem precisa do contrário
   (`create index concurrently`) escreve `-- sem-transacao` na primeira linha.

**A impressão digital recusa, em vez de avisar.** De cada script aplicado fica o
`sha256`. Mudando o arquivo depois, o banco e o código passam a discordar sobre o
que está lá dentro — e isso se descobriria como defeito estranho semanas depois.
Então a ponte **para** e diz qual arquivo mudou. Script aplicado não se edita: o
conserto é o próximo número.

**A trava existe por causa da própria Render.** Toda publicação sobe a ponte nova
enquanto a velha ainda está saindo (é o que o desligamento com calma faz, de
propósito). Por alguns segundos há duas pontes vivas, e as duas acordariam
querendo aplicar o mesmo script. `pg_try_advisory_lock` faz a segunda desistir.

**A tabela `zorvin_scripts_aplicados` nasce com RLS ligada e SEM política** — só
a ponte (`service_role`) a alcança. É a armadilha nº 5 aplicada na origem. Quando
o painel precisar mostrar isto, será por `zorvin_saude()`, que já sabe quem
administra — e não lendo a tabela direto.

**O que isto NÃO resolve ainda:** um cliente novo, com banco vazio, continua sem
um caminho — os 37 scripts estruturais de `sql/` descrevem a história, não o
estado final, e alguns criam o que os seguintes destroem. O ponto de partida de
um banco zerado é problema separado, e ainda em aberto.

**O primeiro script que passou por aqui** é
`sql/automaticos/001-quem-entra-vira-gente.sql`: um gatilho em `auth.users` que
cria a linha de `usuarios` junto com a conta, e faz a **primeira conta do banco
nascer administradora**. Ele existe por causa da entrada sem Vantoro (ver o
CLAUDE.md do painel): sem Vantoro, ninguém escreveria `usuarios.admin`, e as
telas de administração ficariam trancadas para todo mundo — inclusive para o
dono, sem jeito de destrancar por dentro.

**O corpo inteiro dele vive dentro de um `exception when others`, e isso não é
excesso de cuidado.** No caminho COM Vantoro é a ponte que cria a conta no Auth
(`createUser`) na primeira entrada da vida de alguém; um gatilho que estoure ali
faz a criação inteira falhar, e o sintoma é "fulano não entra de jeito nenhum",
no dia em que fulano foi contratado. Falhando, ele desiste em silêncio (com
`raise warning` no log do banco) e a conta nasce assim mesmo — a situação de
antes do script, e não uma pior.

A prova 51l-bis aponta para a **pasta de verdade** e confere que tudo o que está
lá aplica num banco limpo. Vale para todo script futuro: erro de digitação em
SQL passa por revisão de código sem ninguém notar e só aparece na hora de
instalar.

Variável **opcional** `SCRIPTS_PASTA`, para a bancada apontar scripts de mentira
sem escrever dentro do repositório — mesma linha de `CAIXA_INTERVALO_MS`. Prova:
seção 51, que sobe um **Postgres de verdade** (a integração contínua traz um), e
**reprova se ele faltar** em vez de se pular em silêncio.

## A equipe sem Vantoro — a mesma tela, outra fonte

`listarAtendentes` lê a lista de gente do Vantoro; `gravarAtendente` grava a
permissão lá. Para o escritório isso é o certo: é lá que o cadastro de pessoa
mora, e manter duas listas iguais é coisa que ninguém faz por muito tempo.

Quem compra o Zorvin sem ter Vantoro já **entra** (script 001) e nasce
administrador — e não tinha como cadastrar mais ninguém nem dizer o que cada
pessoa alcança. Um sistema de atendimento em **equipe** com uma pessoa só.

**O contrato com o painel não mudou, e essa é a decisão principal.** A tela
recebe a mesma forma de sempre (`zorvin`, `zorvin_telefones`,
`zorvin_so_telefones`, `zorvin_definido`) e manda os mesmos campos; só a FONTE
muda. Uma tela paralela teria de ser mantida junto com a velha e divergiria dela
na primeira mudança — e permissão é o lugar onde divergir significa alguém ver
conversa que não devia. Pelo mesmo motivo `aplicarPermissoes` não mudou uma
linha: ela recebe o mesmo objeto, montado a partir de `usuarios.acesso`.

**A chave é a própria configuração** (`VANTORO_API_URL` + `VANTORO_API_TOKEN`),
e não uma variável nova que poderia ser posta em desacordo com elas. A ponte
devolve `com_vantoro` na lista, e é assim que a TELA sabe em qual mundo está —
pela mesma razão.

`usuarios.acesso` (jsonb) é a **intenção** de quem administra; as linhas de
`permissoes` são o **efeito**. SQL: `sql/automaticos/002-a-equipe-mora-aqui.sql`.

**`definido` não volta atrás.** Ele separa "não pode ver nada" de "ninguém
decidiu ainda", e a segunda é a que faz a pessoa ver tudo. Desmarcar o último
departamento não pode devolver a pessoa para "ninguém decidiu" — seria abrir o
acesso em silêncio.

**A porta de saída sem volta.** Sem Vantoro não há um "lá fora" de onde
destrancar: quem perdesse o poder de administrar perderia junto a tela que o
devolve. Ninguém se tira de administradora nem se desativa. (A terceira regra —
"não tire a última" — é um **encosto inalcançável** hoje, e está escrito no
código por quê; não há prova apontando para ela, de propósito.)

**E `soAdmin` passou a exigir `admin` E `ativo`.** A porta do BANCO
(`zorvin_admin()`) sempre exigiu as duas; a da ponte exigia só `admin`. Duas
portas com réguas diferentes, latente enquanto nada desativava ninguém — e é
esta tela que passa a desativar. A frase separa "não administra" de "foi
desativada": pedem providências opostas de quem lê.

`POST /permissoes/pessoa` cria a conta (só sem Vantoro; com ele, recusa — seria
a segunda lista). Ela nasce com `email_confirm`, porque o escritório não tem
serviço de e-mail e esperar uma confirmação que nunca chega é a pessoa não
entrar no primeiro dia. A linha de `usuarios` é escrita **aqui também**, e não é
desconfiança do gatilho do 001: ele desiste em silêncio de propósito, e a pessoa
sem linha ficaria fora da lista da tela que acabou de cadastrá-la.

Prova: seção 52.

## As palavras da casa

O painel dizia "advogado" em nove frases. Para o escritório está certo; para
uma clínica ou uma imobiliária, o programa fala de uma profissão que não é a
deles. `sql/automaticos/003-as-palavras-da-casa.sql` cria
`zorvin_palavras` — **uma linha só**, garantida por `check (id)`: duas linhas de
configuração viram a pergunta "qual delas vale", sempre respondida tarde.

**Tabela, e não variável de ambiente.** Variável só muda com nova publicação, e
quem compra o programa não publica nada — ele abre a tela e escreve.

**O gênero é coluna.** "o advogado" / "a médica", "dono" / "dona". Deduzir da
terminação erraria em "gerente", "assistente", "representante".

**Lê quem entrou, escreve quem administra** (`zorvin_admin()`, que já exige
`admin E ativo`). A política vai junto com a tabela — armadilha nº 1. E são
DUAS políticas, não uma `for all`: `for all` daria DELETE junto, e apagar a
única linha é o jeito de esta tabela ficar num estado que nenhum código
descreve.

**"Processo" NÃO entrou**, e isso foi medido em 15/09: toda frase visível com
essa palavra está atrás de uma porta do Vantoro, que é o sistema do próprio
escritório — onde a palavra é sempre "processo". Um botão para trocá-la seria
um botão que ninguém pode usar.

Prova: `o-vocabulario`, no repo do painel.

## A citação — o formato que a Uazapi manda de verdade

Relato de 15/09, com foto dos dois lados: uma resposta citando outra mensagem
aparecia no WhatsApp com a citação, e no Zorvin como **bolha solta**.

`extrairResposta` dizia, por escrito, que estava chutando: *"o formato exato da
Uazapi ainda não foi confirmado, então tentamos vários campos comuns"*. Tentava
cinco nomes, e **nenhum acertava**. MEDIDO no evento cru do relato:

```jsonc
"quoted": "3AE7DBB44DDDD3B8A1E8",            // uma STRING, não um objeto
"content": { "contextInfo": {
    "stanzaID":      "3AE7DBB44DDDD3B8A1E8", // "ID" MAIÚSCULO
    "participant":   "271145613971676@lid",  // um LID, não um telefone
    "quotedMessage": { "conversation": "Eu" }
}}
```

**Eram três erros, e o primeiro envenenava tudo.**

1. `ctx = m.quoted || …` — e `m.quoted` é uma string **preenchida**, portanto
   verdadeira. `ctx` virava a string, e `ctx.stanzaId`, `ctx.text` e
   `ctx.quotedMessage` são todos indefinidos numa string. A função devolvia
   `null` e a citação sumia sem uma palavra em lugar nenhum.
2. O campo é `stanzaID`, com **D maiúsculo**; o código procurava `stanzaId`.
3. O autor da citada saía de `ctx.fromMe`, que **não existe** neste formato:
   toda citação virava `'contato'` por descarte. Acertava quase sempre, e
   erraria calado justamente quando alguém do escritório respondesse à própria
   mensagem — a tela diria o nome do cliente onde devia dizer "Você".

**As colunas já existiam** (`resposta_previa`, `resposta_autor`,
`responder_id_uazapi`) — conferido no banco em 15/09. O encanamento inteiro
estava pronto, esperando uma leitura que nunca acertava o formato.

**A regra que fica:** `ctx` tem de ser **objeto**. Um `||` encadeado entre
campos de tipos diferentes escolhe o primeiro **verdadeiro**, e não o primeiro
**útil** — foi assim que uma string entrou onde se esperava um objeto. Ao
acrescentar candidato, some à lista de objetos; se for um id solto, à lista de
ids.

**E o autor não se compara com `owner`:** `participant` vem como **LID**
(`271145613971676@lid`) e `owner` é telefone (`5511969401932`) — nunca casariam,
e a conta daria "é do cliente" sempre. A comparação que fecha é com o
**remetente desta mensagem**, cruzada com `fromMe`: quatro casos resolvidos sem
saber que número pertence a quem.

Prova: seção 54, seis conferências, **quatro delas sobre o evento de verdade**,
copiado de `eventos_recebidos`. Quatro sabotagens, quatro pegas.

**Uma delas só existe porque a sabotagem a exigiu:** "nós respondendo à NOSSA
própria mensagem" é o único caso em que a resposta é `'advogado'`. Sem ela,
todas as conferências de autor esperavam `'contato'` — e a sabotagem que fazia
tudo virar `'contato'` (o defeito antigo, exatamente) **passava**. Prova em que
todas as respostas certas são iguais não separa o certo do errado.

**Em aberto, e é empírico:** há **uma** amostra, de resposta a **texto**. Uma
citação de foto ou áudio deve trazer outra forma em `quotedMessage`, e a prévia
pode sair vazia — a bolha então não mostra a citação, que é o comportamento de
hoje (sem piora). Fechar isso depende de um evento real desse caso.

## A espera do cliente — a coluna que o gatilho mantém

Pedido de 25/09: as atendentes do SAC trabalham de baixo para cima numa lista
ordenada pela **última** mensagem, e é isso que erra. O cliente que escreveu
21/09 e de novo 24/09 aparece como "24/09", no meio dos que acabaram de chegar
— quando está esperando há quatro dias.

`conversas.esperando_desde` guarda a **primeira** mensagem do cliente depois da
nossa última resposta. Escrever de novo não reinicia a espera de ninguém — e é
por isso que existe uma coluna, em vez de a tela fazer a conta com
`ultima_atividade`. SQL: `sql/automaticos/004-a-espera-comeca-na-primeira.sql`.

**Dois casos foram conferidos no código antes de escrever o gatilho**: a nota
interna mora em `notas` e não em `mensagens`, então ele nunca a vê (e o cliente
também não); e a resposta que **falhou** não zera a espera, porque
`salvarMensagem` só grava depois que o WhatsApp aceita — a bolha vermelha vive
em `fila_envio`.

### O gatilho é incremental, e a importação de histórico é o passado chegando depois

**MEDIDO em 25/09, num Postgres de verdade:** sem a pergunta *"esta mensagem já
foi respondida?"*, uma conversa **já atendida** que recebesse histórico
importado de 2024 passava a esperar desde 2024 — **630 dias** — e ia para o
**topo** da fila do SAC. A fila existe para dizer quem está mais abandonado, e o
primeiro lugar dela seria um cliente já atendido.

Isso não é caso raro: a importação grava o horário de **quando a mensagem foi
enviada** (`horarioDeQuemEnviou`), e não o de agora. Mensagem de cliente com
data velha entrando hoje é o caso comum dela.

São **duas** perguntas, e a segunda é o espelho da primeira:

| o que entra | o gatilho |
|---|---|
| mensagem de cliente **anterior** a uma resposta nossa | não põe na fila |
| resposta nossa **anterior** à espera em curso | não tira da fila |

O erro do segundo seria o pior dos dois: a conversa **sumiria** da fila, em vez
de aparecer errada nela.

**E `/importar-historico` reconta a espera do lote inteiro no fim**
(`zorvin_recontar_espera(conversa_id)`, por RPC). O gatilho se defende dos dois
enganos piores, mas a conta certa depois de um lote é a que recalcula tudo do
zero. **Falhar ali não derruba a importação**: sem o script 004 a função não
existe, e a coluna também não — a régua de sempre.

**Só `'advogado'` limpa**, e está escrito assim de propósito: um `else` faria
qualquer origem futura (`'sistema'`, aviso automático) zerar a espera de um
cliente que continua sem resposta.

**O corpo inteiro do gatilho vive num `exception when others`**, como o do
script 001 e pelo mesmo motivo: um gatilho que estoura derruba o `INSERT` da
mensagem. Perder a ordem da fila é incômodo; perder a mensagem do cliente é o
pior desfecho deste sistema.

**O script inteiro vive dentro de um bloco guardado**, e foi a prova 51l-bis que
exigiu: ela aplica `sql/automaticos/` num banco **limpo**, onde `conversas` não
existe — as tabelas do Zorvin estão nos 37 scripts de `sql/`, que são história.
A saída fácil seria a prova criar aquelas tabelas, o que é escrever uma **segunda
definição** delas, para divergir da de produção no primeiro conserto. Então o
script desiste em silêncio quando as tabelas não existem — que também é o certo
num cliente novo, cujo banco ainda não tem esquema nenhum.

Prova do lado do painel: `a-espera-comeca-na-primeira`.

## "Já tratei" — a fila precisa de uma saída que não seja mandar mensagem

A fila do script 004 nasceu com **813 conversas**, e perguntar ao banco o que
elas são mudou o desenho:

| | quantas |
|---|---|
| nós respondemos e o cliente escreveu de volta | **601** |
| nunca respondemos nada | 214 |

E o que o cliente escreveu por último, nas 601: **`[anexo]` em 99** — o maior
grupo de todos —, "ok" em 42, "boa tarde" em 22, "bom dia" em 12, "obrigada"
em 9.

**A suposição de quem escreveu isto estava errada, e a medição corrigiu.** Eu
imaginava a fila entupida de agradecimentos. Somando as vinte frases mais
comuns, ~140 são espera **de verdade** (o anexo é documento de cliente sem
confirmação de recebimento; "bom dia" é uma conversa que começou e ninguém
atendeu) contra ~94 despedidas. A fila estava certa; o que faltava era **uma
saída para as 94**.

### `conversas.tratada_em` é "a nossa última ação", e não uma segunda fila

O script 004 define a espera como *"a primeira mensagem do cliente depois da
NOSSA ÚLTIMA RESPOSTA"*. "Já tratei" é isso mesmo — nós agimos, sem mandar
mensagem. Então ele **não ganha conta própria**: entra por um `greatest` ao
lado da última mensagem nossa. `greatest` ignora nulos no Postgres, e é disso
que a conta vive.

**A tela apagar `esperando_desde` e pronto NÃO funcionaria**, e é o motivo de
existir uma coluna: `zorvin_recontar_espera()` recalcula do zero, e depois de
uma importação de histórico devolveria à fila tudo o que a equipe tratou —
semanas de trabalho desfeitas sem nada na tela dizendo por quê.

### Desfazer não é luxo

Marcar por engano faz um cliente **sumir da fila em silêncio**, que é o pior
desfecho deste sistema com outra roupa. Então `tratada_em` volta a nulo, a
recontagem recoloca a conversa com a espera **original** (medido: 21/09 09h, e
não "agora"), e a linha do tratamento ganha `desfeito_em` **em vez de sumir** —
quem desfez e quando é justamente o que se pergunta depois.

### Duas decisões pequenas que evitam buraco no relatório

- **Assunto não se apaga, desativa-se.** Não existe política de DELETE em
  `zorvin_assuntos`, e não é esquecimento: apagar deixaria tratamentos antigos
  apontando para o nada. O índice único é sobre `lower(nome) where ativo`, e
  não sobre todos — reaproveitar um nome desativado é legítimo.
- **Desfazer é `grant update (desfeito_em, desfeito_por)`**, por COLUNA. A
  política libera a linha; só o grant por coluna impede reescrever o assunto ou
  a data de um tratamento antigo.

E **responder limpa o tratamento junto**: sem isso um `tratada_em` de agosto
continuaria valendo como "a nossa última ação" e seguraria fora da fila uma
mensagem de setembro.

SQL: `sql/automaticos/005-ja-tratei.sql`. Conferido num Postgres 16 de verdade
— sete cenas, mais banco vazio, reaplicação, e o assunto desativado que **não
ressuscita** ao rodar o script de novo.

### O "OUTROS" (script 009, 30/09)

`sql/automaticos/009-o-assunto-outros.sql`. "OUTROS" sozinho não diz nada no
relatório, então ele vem com texto obrigatório:

- `zorvin_assuntos.pede_descricao` — a marca que faz o painel pedir texto.
  **Uma coluna, e não o nome "OUTROS"**: quem compra pode chamá-lo de outra
  coisa, ou querer descrição em mais de um assunto. Troca-se na tela;
- `zorvin_tratamentos.observacao` — o texto, com **teto de 500** (`check`),
  para o relatório continuar sendo relatório.

**Rodar de novo não desfaz escolha de ninguém.** O OUTROS nasce com a marca
ligada só na rodada que CRIA a coluna; se alguém desligar pela tela, a
reaplicação não religa. E um "Outros" feito à mão é aproveitado, em vez de
nascer um segundo.

**Duas guardas, uma por metade:** num banco limpo `zorvin_assuntos` existe (o
005 a cria fora do bloco) e `zorvin_tratamentos` não — cada uma é conferida
por si, e a 51l-bis passa. Conferido num Postgres 16 de verdade: primeira
rodada, reaplicação com a marca desligada, "Outros" pré-existente e o teto
recusando 501 caracteres.

### O relatório do "Já tratei" (script 010, 30/09)

`sql/automaticos/010-o-relatorio-do-ja-tratei.sql` cria
`zorvin_relatorio_tratados(p_desde, p_ate, p_quem, p_fuso, p_telefone,
p_departamento, p_limite)`, que devolve num `jsonb` só as somas do período,
o "por assunto", o "por pessoa", o "por dia" e os registros. A tela é uma
seção do Painel de números (ver o CLAUDE.md do painel).

**Um "Já tratei" é um clique**: as linhas de um mesmo `insert` têm a mesma
conversa, a mesma pessoa e o mesmo `quando` (`now()` é o da transação), e é
por aí que a função agrupa. **O desfeito não soma** e é contado à parte.

**Quem não administra recebe só o próprio** (`auth.uid()`, a régua de
`painel_dashboard`) — menos o "por pessoa", que é para comparar. **E ela é
`security invoker`**: enxerga só as conversas de quem chama.

**Três cuidados que vieram das lições anteriores:**

- **apaga as versões antigas antes de criar**: `create or replace` com outra
  lista de argumentos cria uma segunda função, e a chamada do painel morreria
  com "could not choose the best candidate";
- **o texto do OUTROS vem por `to_jsonb(t) ->> 'observacao'`**, e não pelo
  nome da coluna: num banco sem o script 009 a função continua de pé;
- **a função nasce sempre**, mesmo num banco limpo — é `plpgsql`, e os nomes
  de dentro só são resolvidos ao rodar. A 51l-bis passa, e a conferência diz
  "rode o 005 antes".

Conferido num Postgres 16 de verdade: administradora vendo tudo (2 cliques, e
não 3 linhas; o desfeito à parte; a mediana da espera), atendente pedindo os
números de outra pessoa e recebendo só os dela, os filtros de telefone e
departamento, fuso inválido, o limite da lista, banco sem o 009, banco limpo e
reaplicação.

### A espera não começa no rabicho da conversa já atendida

Relato de 28/09, com foto: a conversa da ANDREIA dizia **"esperando há 6
dias"**. O que houve nela:

| quando | quem | o quê |
|---|---|---|
| 22/09 13:36 | **nós** | "Estamos trabalhando para que dê certo!" |
| 22/09 13:37 | ela | "Tomara a Deus" |
| 28/09 14:40 | ela | "Boa tarde" / "Temos alguma movimentação" |

Pela regra do 004 — *a primeira mensagem do cliente depois da nossa última
resposta* — a espera começa às 13:37, **um minuto** depois da resposta. Isso é
o **rabicho** de uma conversa atendida, e não uma espera. **Reproduzido num
Postgres de verdade antes de escrever o conserto:** o gatilho devolvia
exatamente 22/09 13:37. O defeito não era do gatilho, era da definição.

**A regra nova:** a espera começa na primeira mensagem do cliente que chega
**mais de 30 minutos** depois da nossa última ação (resposta ou "já tratei").
**E tem um encosto:** se NENHUMA mensagem dela chegar depois desses 30
minutos, vale a regra de antes. Sem ele, quem pergunta cinco minutos depois da
nossa resposta e some **sairia da fila para sempre**, calado — o pior desfecho
deste sistema. Com ele, o pior caso da mudança é uma conversa continuar como
está hoje.

**Os 30 minutos foram MEDIDOS, e contra a sugestão de 48 horas.** Sobre as 832
conversas da fila, testando quatro janelas:

| janela | mudariam | ficam como hoje | dias a menos, em média |
|---|---|---|---|
| **30 min** | **93** | 311 | **4,6** |
| 2 h | 96 | 405 | 5,9 |
| 12 h | 92 | 452 | 6,6 |
| 48 h | 74 | 497 | 9,8 |

**Quantas conversas mudam quase não depende da janela; quanto tempo é apagado,
sim.** Janela grande não conserta mais casos — apaga mais dias de cada um. E
na amostra de 48 h os textos pulados incluíam *"Porfavor avisa ao financeiro
que minha c…"* e *"E agr qual o próximo passo pois já fazem…"*, que são
pedidos de verdade. A régua da casa decide: janela curta demais deixa ruído
**visível**, com saída pronta ("Já tratei"); janela longa demais apaga espera
**em silêncio**.

**O número mora em `zorvin_carencia_da_espera()`**, uma função só. Trocá-lo é
um `create or replace` de uma linha mais `select zorvin_recontar_espera();` —
sem script novo. Escrito assim porque é palpite calibrado por medição, e não
lei da natureza.

**E o gatilho precisou de uma espera PROVISÓRIA**, que é a parte não óbvia.
Ele vê uma mensagem por vez e não sabe o futuro: quando o "Tomara a Deus"
chega, o "Boa tarde" de seis dias depois ainda não existe, e pelo encosto ele
TEM de entrar na fila. Então a espera nascida **dentro** da carência é
provisória, e a primeira mensagem que chega **fora** dela a substitui; a
nascida fora é definitiva e aí vale o `least` de sempre (escrever de novo não
reinicia). Como se sabe qual é qual sem coluna nova: a provisória é a que cabe
dentro de `nossa última ação + carência`.

SQL: `sql/automaticos/006-a-espera-nao-comeca-no-rabicho.sql`. **Ele reconta a
fila inteira ao instalar** — sem isso a regra nova valeria só para o que
chegasse depois, e a tela seguiria dizendo "6 dias" na conversa do relato.

**A conferência do fim virou tabela temporária, e foi uma medição que exigiu:**
um `select count(*) from public.conversas` solto no fim **estoura num banco
limpo**, porque o Postgres confere o nome da tabela ao PREPARAR a consulta —
um script que deveria desistir em silêncio derrubaria a prova 51l-bis. Com a
tabela temporária o arquivo continua sendo **um só**: o que vai para o Rodrigo
é byte por byte o que está no repositório.

Conferido num Postgres 16 de verdade: 10 cenas (inclusive a recontagem tendo
de concordar com o gatilho), banco vazio, reaplicação, e **5 sabotagens com 5
pegas**. Uma delas vazou primeiro e ensinou de novo a régua de sempre: a
sabotagem que tirava a recontagem da instalação passava, porque a bancada
aplicava o script num banco **vazio** e só depois inseria as mensagens — um
caminho que o cenário não exercitava. Entrou a cena da migração (fila já
cheia, com a data velha) e ela pegou.

## A linha que voltou não fica caída

Relato de 29/09, com foto: a faixa vermelha do painel dizia *"A linha de SAC
está desconectada do WhatsApp. Nada sai por ela até alguém reconectar o
aparelho."* — **e o aparelho já tinha sido reconectado e testado**. Pedido
dele: *"Remova a mensagem, pois ela nos atrapalha a usar o sistema."*

**A frase era falsa, e por isso ela saiu — não por incomodar.** O sinal
`linhas_caidas` de `zorvin_saude()` deduzia "está caída" olhando **só para o
passado**: mensagens que falharam com erro de desconexão nos últimos 30
minutos. Não havia pergunta nenhuma sobre o presente, então a única saída do
aviso era o **relógio** — meia hora de faixa vermelha depois de o problema ter
acabado.

**O script original já previa isto e escolheu conviver:** *"mais longo
manteria o aviso na tela depois de o aparelho voltar"*. A escolha estava
errada. Alarme que não pede ação de quem lê se aprende a ignorar, e aí o
próximo passa batido junto.

**Agora a linha só conta como caída se não deu SINAL DE VIDA depois do último
erro**, e são dois, os dois fatos do banco:

| prova de vida | por que vale |
|---|---|
| uma mensagem que **saiu** por ela (`fila_envio` = `enviada`) | a ponte só marca assim depois de a Uazapi aceitar — é o contrário exato do que a faixa afirma |
| uma mensagem que **chegou** por ela | o webhook só dispara com o aparelho conectado |

A segunda é mais fraca (receber não é enviar) **e entra assim mesmo**, por
duas razões: é a que aparece primeiro numa linha de SAC, e o erro dela se
conserta sozinho — se a linha recebe e não envia, o próximo envio falha, grava
um erro NOVO, e o aviso volta. O que não se conserta sozinho é o alarme de pé
sem ter o que pedir a quem lê.

**A janela de 30 minutos FICA**, como teto: a prova de vida é a saída rápida.
Tirá-la deixaria sem aviso a linha que caiu de madrugada e não teve movimento
nenhum até de manhã.

SQL: `sql/automaticos/007-a-linha-que-voltou-nao-fica-caida.sql`. Conferido num
**Postgres 16 de verdade**: 9 cenas, banco vazio, reaplicação, e **5 sabotagens
com 5 pegas**.

**E uma cena minha nasceu mentindo.** "Voltou e caiu de novo" tinha o erro novo
em `now() - 1 minute` e o envio bom em `now()` — ou seja, na linha do tempo o
envio era o evento MAIS RECENTE, e a faixa sumir estava certo. Eu ia consertar
a consulta por causa de um cenário que dizia uma coisa e media outra. **Cena
que não expressa o que o nome dela promete é pior do que cena nenhuma:** ela
manda consertar o que não está quebrado.

**E a conferência do fim nasce ANTES da guarda**, e isso é a lição do 006
repetida: criando a tabela temporária só depois, o `select` da última linha
estoura num banco limpo — um script que deveria desistir em silêncio derrubaria
a prova 51l-bis. Aconteceu na primeira escrita deste arquivo.

## O responsável pela conversa

Pedido de 30/09, como primeiro passo do Zorvin para CRM: toda conversa ganha
um dono. `sql/automaticos/008-o-responsavel-pela-conversa.sql` acrescenta
três colunas a `conversas` — `responsavel_id` (quem é o dono agora),
`responsavel_em` (desde quando) e `responsavel_por` (quem pôs ele ali: ele
mesmo ao assumir, ou o colega que passou a conversa).

**Uma coluna, e não uma tabela de histórico:** a tela precisa da resposta
de agora em toda linha da lista, e uma segunda tabela seria uma segunda
consulta por página. O histórico de passes fica para o dia em que alguém
pedir o relatório.

**O dono é `usuarios.id`**, com `on delete set null`: apagada a conta, a
conversa volta a "sem responsável" em vez de apontar para ninguém.

**A permissão não muda:** quem já edita a conversa muda o dono. Travar "só o
dono passa adiante" prenderia a conversa de quem saiu de férias.

**A ponte não faz nada com isso**, e é de propósito: quem assume ao
responder é o PAINEL, com `.is("responsavel_id", null)` na gravação — ver o
CLAUDE.md dele. A resposta pelo celular (sem painel) não assume ninguém,
porque o celular não sabe quem da equipe está segurando o aparelho.

Conferido num Postgres 16 de verdade: banco limpo (desiste em silêncio, e a
51l-bis passa), banco com as tabelas, reaplicação, e a conta apagada
devolvendo a conversa a "sem responsável".

### O relatório por responsável (script 011, 01/10)

`sql/automaticos/011-o-relatorio-por-responsavel.sql` cria
`zorvin_relatorio_responsaveis(p_telefone, p_departamento, p_fuso)`: a
carteira de cada responsável **agora** — conversas, quantas esperam, quantas
há 3 dias ou mais (dias de calendário no fuso do escritório, a régua do
vermelho da lista), a espera mais antiga e as não lidas —, mais a linha de
"sem responsável". A tela é uma seção do Painel de números.

**Sem datas, de propósito:** o banco guarda só o dono de hoje. **Arquivadas e
telefones desativados ficam fora** (`ativo` por `to_jsonb`: só o `false`
explícito desativa, e base sem a coluna não derruba a função).

**Quem não administra recebe a própria linha e a sem dono**, recorte feito
aqui. `security invoker`, como o 010.

**Sem a coluna do 008 ela responde `{"falta": "008"}`**, e não uma lista
vazia — que a tela leria como "ninguém tem conversa". As colunas de scripts
posteriores (espera, arquivada, não lidas) entram por `to_jsonb`.

Conferido num Postgres 16 de verdade: carteiras e a sem dono, arquivada e
telefone desativado fora, filtros de telefone e departamento, quem não
administra, fuso inválido, banco sem o 008, banco limpo e reaplicação — e
três sabotagens, três pegas.

**E chegou à tela quebrado** — *"permission denied for table advogados
(código 42501)"*, para todo mundo. A causa era `to_jsonb(a)`: ele lê a linha
INTEIRA do telefone, e em `advogados` quem entrou não alcança `token`,
`servidor` nem `instancia` (a chave da Uazapi, fechada em
`sql/2026-09-a-chave-da-uazapi-fica-guardada.sql`). Não é a coluna que fica de
fora: é a consulta inteira que morre, e a função é `security invoker`, então
herda a trava. `sql/automaticos/012-o-relatorio-por-responsavel-sem-ler-a-chave.sql`
troca por `a.ativo`, pelo nome.

**Passou nas provas por dois motivos, e os dois são a mesma lição:** o banco
de teste não tinha a trava de coluna, e a conferência do 011 rodava como
**dona** do banco, que alcança tudo. O 012 confere **chamando a função no
papel `authenticated`** — a sabotagem que devolve o `to_jsonb(a)` faz a
conferência dizer "NÃO — permission denied…", e a mesma sabotagem conferida
como dona dizia "sim". **A régua que fica:**

- **`to_jsonb(linha)` só em tabela sem coluna fechada.** Em `advogados`,
  sempre pelo nome — e só as colunas liberadas (`id, nome, numero, foto_url,
  departamento_id, ativo, setor`).
- **Função nova que quem atende chama: a conferência a CHAMA como
  `authenticated`**, e não só pergunta se ela existe.

## Mandar SQL para o Rodrigo — a conferência vai DENTRO do script

Em 26/09 a instalação do script 005 custou **dez idas e voltas** e nenhuma
delas era defeito de SQL. A causa, medida no fim: **o editor do Supabase
mostra só o resultado do ÚLTIMO comando**, e eu vinha mandando o script numa
mensagem e a conferência em outra. O Rodrigo rodava ora uma, ora outra — e a
parte que criava as tabelas nunca chegou a rodar inteira, enquanto a
conferência dizia, corretamente, que nada existia.

Pior: cada resposta parecia um defeito novo, e eu chutei duas causas erradas
(`zorvin_admin()` que não existia, a guarda do bloco `do`) antes de perceber
que o problema era **o formato do pedido**, não o conteúdo dele.

**A régua, daqui para a frente:**

1. **Um bloco só por mensagem.** Nunca o script e a conferência separados —
   ele não sabe, e não tem por que saber, que o editor só mostra o último
   resultado.
2. **A conferência é a ÚLTIMA LINHA do próprio script**, um `select` com uma
   coluna por coisa que deveria existir. Assim o que aparece na tela ao apertar
   Run já é a resposta de *"deu certo?"* — sem um segundo passo, sem depender
   de ele copiar o aviso verde, que some.
3. **O script vai no texto da mensagem**, em bloco de código. Saída de
   ferramenta não chega a ele.
4. **Diga que pode rodar de novo sem medo**, e garanta que é verdade
   (`if not exists`, `create or replace`, `drop policy if exists`).

**E uma coisa que o editor faz e assusta:** ele roda tudo numa transação só.
Um comando que falha no meio desfaz os anteriores — então "a tabela não existe"
depois de um erro **não** quer dizer que a criação falhou; quer dizer que algo
depois dela falhou e levou a criação junto. Ao diagnosticar, peça a mensagem de
erro **inteira** antes de formular hipótese: as duas que formulei sem ela
estavam erradas.

**Fato lateral medido no mesmo dia:** `zorvin_scripts_aplicados` **não existe**
no banco do escritório, ou seja, `DATABASE_URL` não está no Render e a ponte
**nunca aplicou script sozinha**. Tudo o que está lá foi colado à mão. A
automação de `sql/automaticos/` está escrita, provada e desligada em produção —
enquanto for assim, todo script novo é um pedido ao Rodrigo, e vale o que está
escrito acima.

## As provas rodavam duas vezes, e a franquia da conta acabou

**MEDIDO em 28/09**, com a página de cobrança do GitHub aberta: **2.000 de
2.000 minutos usados**, com reposição em 3 dias. E o efeito não foi um aviso —
foi as provas **pararem de rodar nos dois repositórios desde 25/09**, com os
trabalhos falhando em 5 segundos, **sem log e sem passo nenhum**.

**Aquilo tem cara de defeito de código, e eu cheguei a procurar defeito no
código.** O que resolveu foi comparar horários: às 21:00 uma rodada do painel
fechou verde em 30 minutos; às **21:44:49** a da ponte falhou em 5s e às
**21:44:57** a do painel falhou em 4s. Dois repositórios diferentes parando no
mesmo minuto é conta, não código — e trabalho sem passo nenhum é trabalho que
nunca foi despachado.

A conta que estourou:

| | tempo |
|---|---|
| painel, na PR | ~29 min |
| painel, **de novo** depois do merge | ~29 min |
| ponte, na PR | ~7 min |
| ponte, **de novo** depois do merge | ~7 min |
| **por entrega** | **~72 min** → 28 entregas/mês |

**A rodada do `push: main` saiu.** Ela existia por uma razão verdadeira — duas
PRs verdes separadas podem se somar numa `main` vermelha —, mas testava de
novo, minutos depois, o mesmo código que a PR tinha acabado de aprovar. E uma
proteção que se desliga sozinha por falta de minutos protege menos do que uma
que roda. Agora são ~36 min por entrega, ou ~55 entregas.

**O risco que ela cobria não ficou descoberto.** Entrou uma **rodada semanal**
(segunda de manhã) mais o disparo à mão. Neste repositório o caso que ela pega
não é hipótese: foi a estreia deste arquivo que descobriu que **a ponte não
sobe no Node 20**, e o `package-lock.json` está no `.gitignore` — `npm install`
traz o que houver no dia, então a `main` parada pode quebrar sozinha.

**A lição maior é a de sempre nesta casa, com outra roupa:** o alarme ficou
três dias desligado e ninguém soube. Ao mexer em qualquer coisa que AVISA,
pergunte quanto ela custa para continuar de pé — e o que se vê no dia em que
ela parar. Aqui o que se via era um X vermelho igual ao de um defeito de
verdade.

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
   **As funções foram fechadas depois**, uma a uma, em
   `sql/2026-09-as-quatro-funcoes-que-rodam-com-poder-de-dono.sql`. Toda função
   nasce executável por `public` — que inclui `anon` —, e quatro eram
   `security definer`. **A régua é tirar de `public` E DEVOLVER a
   `authenticated` na mesma passada**: `pode_ver_conversa` e `meus_telefones`
   não são chamadas por ninguém, vivem DENTRO das políticas, e sem elas a
   leitura de `conversas` morre com `permission denied` para o escritório
   inteiro. As dez restantes não eram `definer` e já estavam neutralizadas pelo
   `revoke` das tabelas: sem permissão em tabela nenhuma, `anon` não lê nada
   por elas.
   **E a conferência por SQL tem um limite escrito lá**: ela roda sem sessão,
   então uma política do feitio `auth.uid() is not null AND pode_ver_conversa()`
   nem chega a chamar a função — passa na consulta e quebra para quem entra. A
   conferência de verdade é abrir o painel.
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
7. **O balde `anexos` é PÚBLICO de propósito** (14/09/2026), e isto não é
   descuido: medido, são **4.187 arquivos e 1.996 MB**, com ~40 MB entrando por
   dia. Fechá-lo obriga a endereço assinado, e o bilhete do endereço assinado
   **muda a cada vez que é gerado** — para o navegador é outro endereço, então o
   cache de um ano (`CACHE_DA_MIDIA`, com `immutable`) deixa de valer e cada
   foto é rebaixada de novo, por pessoa, a cada expiração. É exatamente o que
   zerou a banda em 21/08 e suspendeu o workspace. O `immutable` **é** o
   conserto daquilo; o endereço assinado o desfaz por construção.
   O que se ganharia é menor do que parece: o endereço é
   `anexos/recebidos/{messageid}`, que não se adivinha — a exposição real é
   "quem tem o link", e não "qualquer um", como era na vista `equipe` (onde
   foram medidas 21 linhas abertas). **Se um dia precisar mudar, o caminho não é
   trocar por endereço assinado e torcer**: é medir a banda primeiro e
   provavelmente servir os arquivos pela ponte, com sessão conferida e cache
   longo preservado.
   O que mudou junto: a política era `ALL` — qualquer pessoa logada podia
   **APAGAR** procuração e contrato, e nada no código apaga arquivo. Hoje são
   três políticas (ler, mandar, regravar) e DELETE não é de ninguém. Ver
   `sql/2026-09-o-deposito-de-anexos.sql`.
   **O balde `avatares` também fica público, e por outro motivo.** O script
   tentou fechá-lo e se recusou, porque a conferência dentro do bloco achou
   fotos de perfil apontando para lá — **medido: 7 das 35**. Fechá-lo teria
   quebrado sete rostos na tela, em silêncio. Decidido em 14/09 deixar como
   está: são fotos de perfil DA EQUIPE, não de cliente, e mover tudo para o
   outro balde reapontando os endereços é risco real por uma porta pequena. O
   que esse episódio ensina vale mais do que a decisão: **a conferência dentro
   do bloco é o que impediu o estrago** — sem ela, o `update` teria passado e as
   fotos sumiriam sem nenhuma mensagem.
8. Chatwoot foi tentado antes e **abandonado** — estourava os 512 MB do plano free (precisa ~2 GB). Não sugerir voltar para ele sem discutir custo.

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
