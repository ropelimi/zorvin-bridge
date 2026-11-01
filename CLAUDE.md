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

- **zorvin-bridge** (ESTE REPO) — Node.js + Express. Recebe webhooks da Uazapi e grava no Supabase; processa a `fila_envio` e envia mensagens via Uazapi. Hospedado no **Render** como Web Service, no plano free: dorme 15 minutos depois da última chamada, e o cronjob que a mantinha acordada parou em 05/08 — ver "A ponte dorme à noite" abaixo.
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
- `VANTORO_ACORDADO_DE`, `VANTORO_ACORDADO_ATE`, `VANTORO_ACORDADO_SABADO` e
  `VANTORO_ACORDADO_DOMINGO` — a janela em que a ponte mantém o Vantoro
  acordado (padrão: das 7h às 20h, sábado sim, domingo não). **Opcionais.** Ver
  "A prova da janela do Vantoro reprovava todo domingo (01/11)".
- `DATABASE_URL` — o endereço do **Session Pooler** do Supabase, para a ponte
  aplicar sozinha os scripts de `sql/automaticos/`. **Opcional: sem ela, tudo
  como antes** e as mudanças de banco continuam sendo coladas à mão. Ver "Os
  scripts que se aplicam sozinhos" abaixo. Pode ir **como a Supabase mostra**,
  com `[YOUR-PASSWORD]` dentro. **No escritório ela está ligada desde 08/10**,
  com `SCRIPTS_AUTOMATICOS=aplicar` — ver "Ligado em produção".
- `DATABASE_PASSWORD` — a senha do banco, à parte do endereço. **Opcional**, e é
  o jeito recomendado: senha com `@`, `#`, `/` ou `?` escrita crua dentro do
  endereço o parte no lugar errado.
- `SCRIPTS_AUTOMATICOS` — `conferir` (padrão) ou `aplicar`. **Opcional.**
- `SCRIPTS_RODADOS_A_MAO` — o número do último script de `sql/automaticos/` que
  já foi colado à mão (ex.: `020`). **Só vale na primeira vez**, com a tabela de
  controle vazia. Ver "O marco" abaixo.
- `ANTHROPIC_API_KEY` — a chave da Anthropic, para o copiloto ("Sugerir
  resposta"). **Opcional: sem ela o botão não aparece** e a rota diz qual
  variável falta. Ver "O copiloto", abaixo.
- `COPILOTO_MODELO` — o modelo do copiloto. **Opcional**, padrão
  `claude-haiku-5-5`. Trocar aqui não pede publicação.
- `ANEXO_TETO_MB` — acima de quantos MB um anexo recebido não é baixado.
  **Opcional**, padrão 50, que é o que a memória da ponte aguenta com folga.
  Ver "A memória da ponte", abaixo.
- `PERMISSOES_INTERVALO_MS` e `PERMISSOES_PRIMEIRA_MS` — de quanto em quanto
  a rodada das permissões roda (padrão 3 min) e quando é a primeira (20 s
  depois de subir). **Opcionais**, para a bancada. Ver "A auditoria de 27/10".
- `GROQ_API_KEY` — a chave do Groq, para transcrever os áudios (no clique e
  sozinho). **Sem ela, nada é transcrito** e o botão diz qual variável falta.
  `GROQ_API_URL` e `GROQ_MODELO` são opcionais. Ver "Transcrever um áudio".
- `TRANSCRICAO_AUTOMATICA` — `desligada` volta a transcrição a ser só no
  clique, sem mexer no código. **Opcional: sem ela, os áudios são
  transcritos sozinhos.** `TRANSCRICAO_INTERVALO_MS` e
  `TRANSCRICAO_PRIMEIRA_MS` (os dois com padrão de 20 s) são para a bancada.

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
- **a prova da chamada que não volta (49e) segura a porta.** Ela abria um
  servidor e o fechava logo ("agora ninguém atende ali"), e em 08/10, na
  integração contínua, outro servidor da bancada pegou a porta solta: a ponte
  chamou a si mesma no lugar do Vantoro e a prova leu o 404 dela, com a conta
  dizendo zero falhas. Reproduzido fazendo a porta "morta" responder 404 — as
  mesmas duas reprovações, com os mesmos números. Hoje o servidor fica de pé
  até o fim da cena, derrubando cada conexão. **Porta "livre" que a prova solta
  não é de ninguém — é de quem pegar primeiro.**

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
- `GET /` → health check ("Zorvin bridge online"), que o cronjob chamava até 05/08
- `POST /webhook` → recebe mensagens da Uazapi

Envio: `setInterval` a cada 3s lê `fila_envio` (status `pendente`), envia e marca como `enviada`/`erro`.

## O controle de atendimento do Vantoro — `POST /vantoro/atendimento` (21/10)

A tela **Controle de atendimento** do Vantoro mostra as conversas abertas pela
ordem de quem espera há mais tempo, com quando foi e quem mandou a última
mensagem. O Vantoro **não lê o banco do Zorvin**: ele pede o resumo a esta
porta, e a ponte responde com a função `zorvin_controle_atendimento` (script
`sql/automaticos/030`).

- **Assinada** como `nota-mudou` e `cliente-mudou`: HMAC-SHA256 do corpo com
  `VANTORO_WEBHOOK_SECRET` no cabeçalho `X-Vantoro-Assinatura`. Sem o segredo,
  recusa tudo.
- **O pedido vence em 5 minutos** (`pedido_em` no corpo assinado). As outras
  duas portas escrevem; esta LÊ a lista de conversas, e um pedido assinado
  guardado não pode abri-la para sempre. Relógio da Render e do Vantoro
  desencontrados em mais de 5 minutos fazem a porta recusar — o log diz.
- **Devolve todos os telefones.** Quem vê o quê é decidido no Vantoro, com a
  mesma permissão que ele manda para cá em `/usuarios`. Por isso a função do
  banco só é executável pela `service_role` — liberada para quem entrou no
  painel, ela seria um atalho por cima das permissões.
- A espera é `conversas.esperando_desde` (a mesma do painel, com a carência e o
  "Já tratei"); quem mandou por último vem da última linha de `mensagens`.
- Provas: seções 69 (a porta) e 70 (a função, num Postgres de verdade).
- **Desde o 031 (22/10)** o resumo traz também o **departamento** de cada
  conversa (nome, `slug`, `ordem`) e as **finalizadas** dos últimos `p_dias`,
  com quando e por quem foram finalizadas (o protocolo de agora) — a tela do
  Vantoro passou a ter as abas Novos / Em atendimento / Finalizados e a
  fileira de departamentos, como o painel. As finalizadas têm o seu próprio
  limite (`p_finalizados`, padrão 500), para nunca empurrarem uma aberta para
  fora. A porta não mudou: o argumento novo tem padrão. Prova: seção 71.
- **Desde o 033 (23/10)** cada conversa traz também as **etiquetas** dela
  (`etiquetas`: `[{id, nome, cor}]`, de `conversa_tags` + `tags`, em ordem
  alfabética) — a tela do Vantoro mostra as etiquetas em cada linha e filtra
  por elas. Sem etiqueta, a lista vem **vazia (`[]`), e não nula**: o Vantoro
  sabe que a ponte ainda não manda as etiquetas pela AUSÊNCIA da chave, e
  avisa na tela. A porta não mudou: ela já repassa cada conversa como vem.
  Prova: seção 74.

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

**A limpeza da caixa nunca rodava, e quando rodou, levou o que faltava resgatar
(26/10).** `limpar_eventos_recebidos` (que guardava sete dias; desde o 035,
trinta) morava depois de um "não há
pendente? então volta", e só rodava na volta em que algum evento tinha ficado
pela metade. Ver "O que não entrava no histórico (26/10)", logo abaixo da
seção das rápidas com anexo.

**Fechar vem DEPOIS de tratar, e a prova espera por isso (13/10).** A ponte
grava a mensagem, ainda pergunta ao banco pela distribuição e pela resposta
fora do horário, e só então marca `processado_em`. A conferência "a linha é
fechada" olhava no instante em que a mensagem aparecia — o meio do caminho —
e, com a máquina ocupada por sabotagens em paralelo, caiu ali. Hoje ela espera
até 5 segundos pelo fechamento: se a ponte nunca fechar, continua reprovando.

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

**O tempo limite foi medido em 26/10, e ele quase sempre SAIU.** Das seis
mensagens que acabaram em "This operation was aborted" desde setembro, as seis
chegaram ao cliente: o eco do WhatsApp veio de 56 a 104 segundos depois de o
item entrar na fila. Três foram reenviadas pela equipe, e o cliente recebeu duas
vezes. A régua de não insistir no tempo limite estava certa; a frase que
mandava reenviar, não. Ver "O que não entrava no histórico (26/10)".

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

## Transcrever um áudio — `POST /transcrever` (02/10) e sozinho (31/10)

Pedido da equipe: transcrição dos áudios. Decidido com o Rodrigo: pelo
**Groq** (Whisper `whisper-large-v3-turbo`, ~US$ 0,04 por hora de áudio) e
**ao clicar**. ~~Nada é transcrito sozinho.~~ **Desde 31/10, também
sozinho** — ver "Sozinho, assim que chega", logo abaixo. A chave é `GROQ_API_KEY`, na
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

### Sozinho, assim que chega (31/10)

Pedido do Rodrigo, da lista de recomendações: *"Vamos trabalhar nas suas
recomendações! Pode mandar bala na primeira"* — transcrever todo áudio sozinho,
assim que chega. **A decisão de 02/10 caiu pela medição:** nos 14 dias até
31/10 chegaram 388 áudios de clientes (2 h 12 min de fala, uns US$ 0,10 no
Groq), e 161 deles (41%) já tinham sido transcritos no clique. O "não pagar
pelo que ninguém precisou ler" custava centavos, e a equipe clicava em quase
metade.

**A rodada** (`transcreverOsQueChegaram`, no `index.js`): de 20 em 20 segundos,
os áudios dos **últimos sete dias** ainda sem texto, **os mais novos
primeiro**, no máximo **cinco por volta**, um de cada vez. Do cliente e da
equipe, de conversa e de grupo — a busca e o copiloto precisam também do que a
equipe disse. **O apagado não é transcrito.** Na primeira subida eram uns 170
pendentes (medido em 31/10), e a fila anda em uns doze minutos.

**Vinte segundos, e não quinze, para sobrar vez ao clique.** O limite de
pedidos por minuto do Groq vale para a rodada e para o botão juntos, e cinco
por volta de 15 em 15 segundos seriam 20 por minuto — o que o plano gratuito
dele aceitava pela documentação que eu conhecia. **Não foi conferido:** a
página de limites não abriu daqui em 31/10 (o proxy da sessão não alcança
`console.groq.com`), e o plano da conta do escritório não se vê. De 20 em 20
são 15 por minuto, e passando do limite a rodada para pelo tempo que o Groq
pedir.

**Uma escrita só para o clique e a rodada** (`transcreverEGuardar`). A
promessa fica em `transcricoesEmVoo` até o texto estar GUARDADO: o clique que
chega no meio da rodada espera a resposta dela, sem segunda ida ao Groq, e
recebe `guardada` certo.

**O que fica no banco e o que fica na memória** — e essa é a decisão que
segura o resto:

| desfecho | o que acontece |
|---|---|
| texto | guardado em `transcricao` |
| sem fala (o Groq leu e não há fala) | só `transcrita_em`: a marca de "já tentei", que impede pagar de novo pelo mesmo silêncio |
| grande demais (mais de 25 MB) | só `transcrita_em`; o tamanho é conferido pelo `Content-Length` ANTES de ler (a memória de 22/10) |
| chave recusada (401/403) | a rodada para por 30 minutos, com uma linha no log |
| limite do Groq (429) | a rodada para pelo tempo que ele pedir (`retry-after`, de 30 s a 10 min): o clique usa a mesma cota |
| qualquer outra falha | tenta de novo depois de 1, 5 e 30 minutos, e depois fica para o clique — **só na memória** |

**Nenhuma recusa do Groq nem do depósito vira "desisti" no banco.** Um 400
tanto pode ser o arquivo quanto um modelo trocado na Render, e um 404 do
depósito, um balde fechado: guardar a desistência marcaria de uma vez todos os
áudios da semana, que ninguém transcreveria depois do conserto. A memória da
ponte esquece ao reiniciar, e aí ela tenta de novo. **O painel só olha
`transcricao`**: o áudio marcado como "sem fala" continua com o botão.

**O prazo vale até o fim do corpo** (`pedirComPrazo`). `fetchComTimeout` solta
o relógio quando chegam os cabeçalhos, e um arquivo que parasse no meio
prenderia a rodada inteira até a ponte reiniciar.

**O que para a rodada:** sem `GROQ_API_KEY`; `TRANSCRICAO_AUTOMATICA=desligada`;
e **sem a coluna do 015** — sem guardar, ela pagaria pelo mesmo áudio a cada
volta. O clique continua nos três casos em que pode.

**A primeira volta espera 20 segundos:** numa publicação, a ponte velha ainda
termina o que começou, e as duas não podem pegar o mesmo áudio. **Nada do que
foi dito vai para o log**: só quantos áudios e quantos segundos.

**O risco que fica dito:** o Whisper às vezes "ouve" uma frase pronta num áudio
de silêncio ou só de barulho (em português, "Legendas pela comunidade
Amara.org" é a conhecida). Já acontecia no clique; sozinho, acontece sem
ninguém ter pedido. Se aparecer na tela, o caminho é filtrar essas frases
conhecidas, depois de medir quantas existem.

**E a busca acha o que foi dito** — `sql/automaticos/040-o-que-foi-dito-nos-audios-entra-na-busca.sql`:

- **`buscar_conversas` procura também em `transcricao`**, numa pergunta à
  parte (`casadas_no_audio`), e não num `or`, que não usaria nenhum dos dois
  índices. A conversa achada por um áudio volta com o motivo **`'audio'`** e o
  trecho falado; vale a mais recente da conversa, escrita ou falada; o nome
  continua vencendo. **A assinatura e as colunas são as mesmas**: `create or
  replace`, sem o instante em que a função não existe;
- **só troca a busca que existe** — ela nasceu num script colado à mão;
- **dois índices**: o trigrama só nas linhas com transcrição
  (`mensagens_transcricao_busca_idx`), e o da rodada
  (`mensagens_audio_por_transcrever`), com o predicado escrito igual à
  pergunta da ponte — é só assim que o banco aceita usar um índice parcial. O
  `m.transcricao is not null` da função é o que deixa o primeiro servir;
- **a conferência chama a busca no papel de quem atende** (regra 4).

Provas: seção 84 (a rodada, 39 conferências, com um Groq de mentira que
também serve os arquivos — o "grande" anuncia 30 MB, o "parado" para no meio)
e seção 85 (o 040 num Postgres de verdade, 28, montado pelos dois scripts de
agosto a partir dos próprios arquivos). **29 sabotagens e 29 pegas**, todas
limpas, rodadas em cópias e lidas uma a uma:

- **a rodada:** que nunca começa; sem a janela de 7 dias; transcrevendo o
  apagado; sem a escrita única (na rodada, e no clique); os mais velhos
  primeiro; sem o teto de cinco; o "sem fala" fora do banco; sem conferir o
  tamanho anunciado; a falha passageira virando desistência; o limite que não
  pausa, e sem o `retry-after`; a chave recusada que não pausa; o prazo só até
  os cabeçalhos; desligada que não desliga; sem a chave rodando assim mesmo;
  sem a coluna pagando de novo a cada volta; o log levando o que foi dito; a
  promessa saindo de `transcricoesEmVoo` antes de guardar;
- **o 040:** sem o áudio na busca; o áudio com acento; a escrita sempre
  vencendo o áudio; o áudio com o motivo 'mensagem'; o áudio de outro
  telefone; o áudio vencendo o nome; o índice da rodada com outra pergunta; a
  busca sem o `is not null` (pega pelo `auto_explain`, que mostra o plano de
  DENTRO da função — o `explain` de fora só vê "Function Scan"); criando a
  busca que não existia; sem a guarda das colunas do 015.

**As provas que não são desta rotina empurram a rodada para daqui a uma hora**
(em `subirTudo`), como o resgate dos anexos: na seção 56, que liga a chave do
Groq para o clique, a rodada pegaria sozinha os áudios da cena e a conta de
idas ao Groq mudaria de assunto.

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

## A memória da ponte — o anexo grande que a derrubou (22/10)

E-mail da Render, 22/10 às 11:13: *"Web Service zorvin-bridge exceeded its
memory limit"*. O plano gratuito tem **512 MB**, e a Render derruba e religa o
serviço que passa disso.

**Medido no Supabase, só lendo** — os registros do portão da API com a chave da
ponte, `storage.objects` e `eventos_recebidos`, só números e nomes de campos:

- às 11:13:19 um **PDF de 19,9 MB** foi mandado num **grupo com cinco telefones
  do escritório**. Chegaram cinco avisos da mesma mensagem em 365 ms, com
  `fileLength` = 20.889.483 nos cinco;
- a ponte subiu o arquivo ao depósito às 11:13:33 e morreu antes de ligá-lo às
  mensagens. A nova subiu às 11:13:44. **É a cadência da caixa de entrada que dá
  a hora exata:** ela lê `eventos_recebidos` de 30 em 30 segundos desde que o
  processo sobe, e o compasso muda de fase quando sobe outro;
- as cinco cópias ficaram **sem arquivo**, com o arquivo no depósito.

**Reproduzido na bancada**, com o `index.js` de verdade:

| a cena | antes | depois (três medidas) |
|---|---|---|
| 1 telefone, PDF de 20 MB | 202 MB | 173 a 188 MB |
| 5 telefones, o mesmo PDF de 20 MB (arquivo dentro do JSON) | **586 MB**, o arquivo pedido 5 vezes | **175 a 182 MB**, pedido 1 vez |
| 5 telefones, o mesmo PDF (por endereço) | **500 MB** | 151 a 174 MB |
| 4 PDFs diferentes de 20 MB juntos | **569 MB** | 217 a 234 MB |
| 1 arquivo de 48 MB | 462 MB | 307 a 372 MB |

Cada MB de arquivo custava seis a oito MB de memória, todos ao mesmo tempo: os
bytes da resposta da Uazapi, o texto deles, a cópia do `JSON.parse` e o arquivo
decodificado. **Não se sabe em qual dos dois formatos a Uazapi do escritório
responde** (a resposta não fica guardada em lugar nenhum), e por isso a
bancada mede os dois.

**As regras** (`index.js`, "UM DOWNLOAD POR MENSAGEM, E UM ARQUIVO GRANDE POR VEZ"):

1. **Um download por mensagem** (`umaVezPorMensagem`). O mesmo id da Uazapi
   pedido por cinco telefones é um arquivo só: os outros esperam o primeiro, e
   `trocarMiniaturaPeloArquivo` já põe o arquivo nas cinco cópias. Vale também
   para o resgate pelo `FileURL`, que espera o download em curso em vez de
   baixar uma segunda cópia por fora.
2. **O arquivo grande baixa sozinho** (`naVez`, com três vagas). O pequeno ocupa
   uma vaga, e o grande ocupa as três. Grande é **10 MB ou mais pelo
   `fileLength` do aviso**, ou o que chega **sem tamanho**: não saber é o caso
   em que o arquivo pode ter qualquer tamanho. É uma fila de verdade: o grande
   na frente segura os pequenos de trás, senão uma sequência de fotos o deixaria
   esperando para sempre. **O envio em base64 da fila de envio** (a segunda
   tentativa de mandar um anexo) entra na mesma fila, porque também põe o
   arquivo inteiro na memória.
3. **Acima de 50 MB, não baixa** (`ANEXO_TETO_MB`, opcional, padrão 50). É o
   que a memória da ponte aguenta com folga: um arquivo de 48 MB já a leva a
   uns 370 MB dos 512 da Render (ver a tabela logo abaixo). **Uma correção do
   que ficou escrito em 22/10:** este parágrafo dizia que 50 MB era o teto do
   depósito no plano gratuito do Supabase — e o Zorvin está no plano **Pro**,
   onde o teto do depósito é uma configuração do projeto, que não se lê pelo
   SQL (o balde `anexos` não tem teto próprio: `file_size_limit` nulo). A
   razão do número é a memória da ponte, e não o depósito, e a frase que vai
   para `midia_erro` passou a dizer isso: *"acima dos 50 MB que o Zorvin
   baixa"*, e não mais *"que o depósito do Zorvin aceita"*. O tamanho é
   conferido de dois jeitos:
   - pelo tamanho do aviso, antes de pedir;
   - sem tamanho no aviso, **lendo com teto** (`lerComTeto`): a leitura para
     quando passa dele, em vez de descobrir depois de ter tudo na memória.

   A mensagem ganha `midia_erro` com a frase do tamanho, e a recusa é
   **definitiva**: está em `RECUSAS_DEFINITIVAS`, e a ponte não tenta de novo.
4. **O arquivo que vem dentro do JSON é decodificado direto dos bytes da
   resposta** (`arquivoDentroDoJson`), aos pedaços de 256 KB, quando a
   resposta passa de 1 MB. Duas coisas voltam ao `JSON.parse` inteiro de
   sempre: uma barra invertida dentro do campo e um JSON que não fecha. Com o
   tamanho no cabeçalho, a leitura enche **um buffer só**, sem a segunda cópia
   do `concat`.

   **O campo é conferido depois do corte**: tem de ser o que o `JSON.parse`
   de sempre escolheria, o primeiro dos nomes com valor e no **primeiro
   nível** do JSON. A busca pelos bytes acha o nome em qualquer lugar, e uma
   miniatura num campo de dentro com o mesmo nome seria guardada no lugar do
   arquivo, com cara de certo. Não sendo o mesmo campo, o `dados` já lido
   segue para o caminho de sempre, sem um segundo `JSON.parse`. **A leitura
   direta muda a memória, e nunca quais bytes são guardados.**

   **O ganho aqui é menor do que eu supus, e foi medido assim.** O Node guarda
   fora do heap o texto grande feito só de letras simples, e o `JSON.parse`
   não copia o campo. Por isso, com um arquivo de 48 MB, o jeito de sempre deu
   picos de 403 a 413 MB, contra 368 a 372 da leitura direta. **O que pesa é a
   letra fora do latim**: com um travessão no nome do arquivo, o texto inteiro
   vai para o heap a dois bytes por letra, o que dá 128 MB para um arquivo de
   48. Com o heap limitado a 96 MB, o jeito de sempre derrubou a ponte
   (*"Reached heap limit"*), e a leitura direta passou.

   **Os pedaços são de 256 KB, e não de 1 MB**: a partir de ~1 MB o Node guarda
   cada pedaço fora do heap, e o lixo do tamanho do arquivo inteiro fica
   esperando o coletor. Com 1 MB, os picos foram de 369 a 431 MB.

**O que cabe na memória, por isto, medido:**

| a cena | o pico |
|---|---|
| os cinco telefones com o PDF de 20 MB | 175 a 210 MB |
| quatro PDFs diferentes de 20 MB | 215 a 235 MB |
| um arquivo de 48 MB sozinho | até uns 370 MB |
| a ponte parada | uns 75 MB |

As faixas juntam as duas medições: a da tabela de cima (a mesma régua do
"antes", feita à parte com a bancada) e a que a seção 72 imprime, com bytes
aleatórios e o download mais lento. O pico depende do coletor de lixo, e por
isso a prova não confere um número exato: ela exige menos de 400 MB, e confere
o que não depende de sorte — quantas vezes o arquivo foi pedido, quantos
downloads estiveram no ar juntos, e a impressão digital do que chegou.

**E a régua sai do uso.** Desde 08/09 chegaram 5.599 anexos com tamanho no
aviso. 32 passavam de 10 MB e nenhum de 50; o maior tinha 25,7 MB. E **nos
últimos 30 dias, 36 anexos chegaram a cinco telefones de uma vez**: o grupo de
22/10 não é caso único. Em 21/10 um PDF de 10,3 MB passou pelo mesmo grupo sem
derrubar nada.

### O resgate depois de subir

As tentativas de novo de um anexo (20 s, 1 min, 5 min) moram em relógios do
processo, e a queda os leva junto. Foi o que deixou as cinco cópias de 22/10
dizendo "indisponível", com o arquivo guardado.

**Um minuto depois de subir** (`RESGATE_AO_SUBIR_MS`, opcional), a ponte procura
o que o processo anterior deixou:

- anexos dos **últimos dois dias**, sem arquivo;
- chegados **antes desta subida**: os de depois têm a perseguição deste processo
  cuidando deles;
- **sem recusa definitiva** em `midia_erro`;
- até trinta.

**Ela pergunta primeiro ao depósito** (`arquivoJaNoDeposito`, um HEAD no endereço
que o download teria dado, com a mesma `extensaoDoArquivo`). Foi o caso de
22/10: o arquivo estava lá. Conferido no banco antes de escrever: o objeto é
`recebidos/{id}.pdf`, com os 20.889.483 bytes, e as cinco linhas têm
`application/pdf` e um nome terminado em `.pdf` — o HEAD acerta o endereço.

**A Uazapi, só para o que a queda cortou.** Ao depósito pergunta-se pelos dois
dias, porque um HEAD não custa nada. À Uazapi, só pelo que chegou dentro da
**janela da perseguição** antes da subida: as esperas somadas (20 s, 1 min e
5 min) mais dez minutos de folga, uns **16 minutos**. Um processo que caiu antes
disso ainda estava perseguindo o anexo; depois disso, ele já tinha tentado até
o fim.

E é a ponte que dorme que obriga a isso. Ela sobe a cada mensagem que a acorda
de madrugada, e sem a janela pediria à Uazapi, a cada acordada, os mesmos
anexos que já não vieram, para ouvir a mesma resposta. **Medido em 22/10:** nos
14 dias anteriores, cinco anexos ficaram sem arquivo e sem recusa definitiva
(13 linhas, porque dois deles vieram por grupos de cinco telefones); só o de
22/10 estava no depósito. O que fica de fora da janela é contado à parte no log
(`deixados`), e não como falha: ninguém pediu e ouviu "não". E continua ao
alcance da porta `/anexos/resgatar`, que pergunta por tudo.

**É o mesmo caminho da porta `/anexos/resgatar`** (`resgatarAnexosVazios`). Ela
também passou a pedir **uma vez por mensagem**, e não uma por cópia: num grupo
de cinco telefones, eram cinco downloads do mesmo arquivo. A conta continua
sendo de linhas, que é o que a tela mostra. A porta pergunta inclusive pelo que
já teve recusa definitiva, porque alguém a abriu de propósito.

**A bancada empurra o resgate para daqui a uma hora** (em `subirTudo`). Uma prova
longa veria, no meio dela, a ponte indo atrás de um anexo vazio que a própria
prova plantou. A seção 72, que é a dele, encurta.

### O que não mudou, e é decisão

- **Um arquivo perto de 50 MB ainda chega a uns 370 MB.** A ponte em produção
  começa um pouco acima dos 75 MB da bancada. Abaixar o teto recusaria arquivos
  que hoje chegam: já houve um de 38 MB. E, se um dia estourar, a ponte se
  refaz sozinha: a caixa de entrada termina o aviso, e o resgate depois de
  subir completa o arquivo.
- **`NODE_OPTIONS=--max-old-space-size` não entrou.** O que pesava eram arquivos
  inteiros na memória ao mesmo tempo, e um teto do Node só trocaria a queda da
  Render por um *"heap out of memory"*.
- **A bolha do painel para o arquivo grande demais ainda diz "não veio — peça
  para reenviar"**, com a frase certa só no `title`. Nunca aconteceu (nenhum
  acima de 50 MB em seis semanas). Quando acontecer, o certo é o painel dizer
  "abra no celular", e isso é mudança no painel.

### Três armadilhas da bancada que este conserto achou

**O depósito de mentira estragava todo arquivo binário.** Ele montava o corpo
com `corpo += pedaço`, que passa cada pedaço por UTF-8, e guardava só o tamanho.
Ninguém via. Hoje ele guarda os bytes e a impressão digital (`digitais`), e a
prova confere que o arquivo chegou igual. Sem isso, um base64 decodificado com o
corte no lugar errado passaria: o tamanho é o mesmo.

**E uma cena minha media a ordem errada.** O "OK" do aviso sai antes de a ponte
tratá-lo. Por isso o envio que a cena pôs na fila entrou antes de o download
grande começar, e saiu primeiro, como a fila manda. Hoje a cena espera o
download estar no ar antes de pôr o envio na fila.

**E a ponte que estoura o heap passava por viva.** Na primeira rodada, a
sabotagem que desliga a leitura direta vazou: com o arquivo em letras simples,
o caminho de sempre também cabia. A cena ganhou um nome de arquivo com
travessão (o texto vai para o heap) e o heap limitado a 96 MB, e a ponte de
antes morreu ali — mas a conferência *"a ponte continua de pé"* passava com
ela morta. **O Node que estoura o heap morre por SINAL** (`signalCode`), e a
cena olhava só o código de saída (`exitCode`), que fica nulo. Hoje ela olha os
dois.

### Duas coisas que só apareceram relendo o código antes do commit

Com a seção 72 inteira passando e as 17 sabotagens da época pegas:

- **a leitura direta podia guardar uma miniatura no lugar do arquivo.** Ela acha
  o nome do campo pelos bytes, em qualquer lugar do JSON, e o caminho de sempre
  só olha o primeiro nível. Nenhuma prova via isso, porque a Uazapi de mentira
  nunca mandou um campo de dentro com o mesmo nome. Hoje há a conferência do
  campo (regra 4) e três cenas com iscas;
- **o resgate da subida martelaria a Uazapi a cada acordada da ponte**. Ver "A
  Uazapi, só para o que a queda cortou", acima.

**A régua de sempre, com outra roupa: prova que passa mostra o que foi
perguntado, e não o que faltou perguntar.**

### Uma observação do mesmo dia, que não é deste conserto

**A ponte dorme.** Na madrugada de 22/10 ela ficou de pé em janelas de **15
minutos exatos**, e às 09:55 dormiu **5 minutos** em pleno expediente. É o plano
gratuito da Render: 15 minutos sem ninguém chamar, e o serviço para. O
`cronjob` de 10 minutos que impedia isso **parou em 05/08**, e religá-lo como
era estouraria a franquia da Render — ver "A ponte dorme à noite", logo
abaixo. Nenhuma mensagem da equipe ficou esperando
naquela manhã: ninguém mandou nada naqueles 5 minutos. Mas, enquanto ela
dorme, a fila de envio para, e uma agendada da madrugada sai só quando alguém
acorda a ponte.

Prova: seção 72, 51 conferências, **23 sabotagens e 23 pegas**, todas limpas,
rodadas em cópias e lidas uma a uma:

- **um download por mensagem**: sem `umaVezPorMensagem`; o resgate pelo
  `FileURL` baixando por fora;
- **a fila**: sem a fila; tudo exclusivo (as fotos uma por uma); o envio em
  base64 fora da fila;
- **o teto**: sem conferir o tamanho do aviso; sem o teto ao ler; a recusa
  do grande demais deixando de ser definitiva;
- **a leitura direta**: desligada (a ponte morre com o heap em 96 MB); o
  corte fora do múltiplo de 4; sem voltar ao `JSON.parse` com barra
  invertida; sem conferir o campo; conferindo só os nomes de antes; conferindo
  só o primeiro nível;
- **o resgate da subida**: sem ele; sem perguntar ao depósito; a janela antes
  do depósito; sem a janela (na função e na chamada); perguntando pelo
  recusado; sem a hora da subida; trinta dias no lugar de dois; um pedido por
  cópia.

**O tempo da seção, medido antes de mandar:** 41 s numa máquina parada, que é
mais lenta que a do GitHub (a suíte inteira, 11min27s aqui; a rodada da `main`
de 22/10, sem a seção 72, 6min50s lá). O teto da integração contínua era de 10
minutos (`provas.yml`), e a conta dava uns 7min30s. Em 27/10 ele foi para 20:
ver "O teto da rodada foi de 10 para 20 minutos (27/10)".

## A ponte dorme à noite — e por que o cronjob não volta como era (22/10)

Um dos três pedidos do Rodrigo em 22/10: *investigar por que o cron-job.org não
está mantendo a ponte acordada, e consertar.*

**Medido nos registros do Supabase, só lendo.** Acordada, a ponte pergunta à
caixa de entrada a cada 30 segundos e à fila a cada 3, então cada minuto em
que ela está de pé deixa pedidos com a chave dela (`service_role`) nos
registros do portão da API. Minuto sem pedido dela é minuto dormindo.

| período | minutos acordada |
|---|---|
| até 05/08 | **1.440 de 1.440 por dia** — de pé o dia inteiro |
| a partir das 20h de 05/08 | dorme 15 minutos depois de cada acordada |
| semana de 15 a 21/10 | de 490 a 897 por dia útil, 176 no domingo — **~83 h na semana** |

**O cronjob parou de bater às 20h de 05/08** (23:00 UTC; a ponte dormiu às
20:15). Não houve commit da ponte nesse dia: a mudança foi fora do código — o
job foi desligado no cron-job.org, ou passou a chamar um endereço que não é o
dela. O painel do cron-job.org não se alcança daqui.

**De madrugada, quem acorda a ponte é a mensagem do cliente, e ela entra.**
Em 22/10, cada acordada da madrugada coincide com um evento novo na caixa de
entrada, gravado no minuto em que a ponte subiu (a Render segura o pedido
enquanto ela acorda). O que fica parado enquanto ela dorme:

- a fila de envio — uma agendada da madrugada sai quando algo acordar a ponte.
  Nos 30 dias até 22/10 não houve nenhuma agendada fora do expediente;
- os avisos de audiência do Vantoro.

### Religar o cronjob como era estouraria a franquia

A Render dá **750 horas de máquina por mês para o workspace inteiro**, somadas
entre os serviços gratuitos, e suspende TODOS eles quando elas acabam, até o
mês seguinte. O workspace tem dois serviços gratuitos — a ponte e o Vantoro
(`plan: free` no `render.yaml` dele; e a ponte o mantém acordado de dia, em
"MANTER O VANTORO ACORDADO", no `index.js`):

| | horas por mês |
|---|---|
| a ponte, como está hoje (medido) | ~356 |
| o Vantoro, acordado das 7h às 20h de segunda a sábado (estimado) | ~338 |
| **total hoje** | **~694 de 750** |
| a ponte de pé 24 horas, com o cronjob de antes | ~744 |
| **total com o cronjob de antes** | **~1.080 — a franquia acabaria por volta do dia 21** |

**Religar o cronjob de 10 minutos trocaria a ponte que dorme de madrugada pela
ponte E o Vantoro suspensos nos últimos dez dias de cada mês.** É o que não se
faz. Fica escrito porque o conserto "óbvio" é religar o job, e ele parece
grátis.

**O conserto que não divide a franquia é pago:** o plano Starter da Render
para a ponte, US$ 7 por mês. Ela deixa de dormir, as horas dela deixam de sair
das 750, e o cronjob deixa de ser preciso. **A decisão é do Rodrigo**; enquanto
ela não vem, a ponte dorme de madrugada, e é seguro — o que chega a acorda.

**Uma suposição, dita como tal:** a conta supõe o Vantoro no mesmo workspace e
no plano gratuito, como diz o comentário do `index.js`. Quem confirma é a
página de cobrança da Render ("Free usage", com as horas do mês).

### A prova da janela do Vantoro reprovava todo domingo (01/11)

A batida que mantém o Vantoro acordado (`dentroDoHorarioDeTrabalho`) fecha o
domingo **por escrito**, e as cenas da "janela escancarada" (das 0h às 24h)
esperavam a batida em qualquer dia. Todo domingo, duas conferências
reprovavam sem defeito nenhum: *"dentro da janela, a ponte bate"* e *"o ping
não leva o token"*. Achado no domingo de 01/11, rodando a suíte inteira antes
da entrega do "Resumir". Ninguém tinha visto porque a rodada semanal é na
segunda e quase nenhuma PR é feita no domingo.

Entrou `VANTORO_ACORDADO_DOMINGO`, **opcional e desligada** (o domingo continua
fechado no escritório; ligá-la custa as horas da franquia acima). As duas cenas
a ligam, e uma cena nova confere a regra do domingo **no domingo**: sem a
variável, a janela das 0h às 24h não bate. Nos outros dias, a mesma cena
confere que bate. Uma meia-noite no meio dela vale qualquer um dos dois.

Prova: na seção 20. **3 sabotagens e 3 pegas**, rodadas num domingo, em
cópias, e lidas uma a uma: a variável ignorada (é o código de antes, e
reproduz as duas reprovações), o domingo ligado por padrão, e a regra do
domingo tirada. **Ao escrever uma cena que depende do dia, pense no dia em que
ela vai rodar sem você olhando.**

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

## A resposta do cliente ao aviso de audiência (26/10)

Pedido do escritório, pelo Vantoro: *"Se o cliente responder a mensagem
concordando, marcar como 'cliente confirmou'."* Todo aviso termina pedindo
para "confirmar ciência e comparecimento", e a resposta chega aqui. **Quem lê
e decide é o Vantoro** (`audiencias/respostas.py`, rota
`POST /audiencias/api/v1/avisos/<id>/resposta`); a ponte diz **o que o cliente
respondeu, e a qual aviso** — `repassarRespostasDosAvisos`, no `index.js`.

**Qual mensagem é resposta ao aviso.** A conversa com a linha das audiências
continua depois do aviso, e um "ok" pode ser para outra coisa. Conta:

- a mensagem de texto do cliente que **cita** a do aviso — e a que cita outra
  mensagem não conta, por mais perto do aviso que esteja;
- a que não cita nada e chegou quando **a última coisa dita pelo escritório**
  naquela conversa era o aviso. Se alguém da equipe escreveu no meio, o "ok" é
  para essa pessoa. O aviso que saiu e não entrou no histórico conta pela hora
  do envio (`fila_envio.enviado_em`);
- a **reação do cliente** na mensagem do aviso. A chave dela é a mensagem e o
  emoji: trocar 👍 por ❤️ é outra resposta.

Não conta o que não é texto (nem a legenda de foto), o que veio antes do
aviso, o aviso que falhou e o aviso de mais de 15 dias. **A resposta
automática fora do horário não atrapalha**: ela não vira linha em `mensagens`.

**Fora do webhook, de propósito.** A mensagem do cliente entra como sempre; a
rodada corre na toada dos avisos (`AVISOS_INTERVALO_MS`, 5 min), olha as
conversas dos avisos dos últimos 15 dias e o que o cliente mandou nas últimas
48 horas, e repassa o que ainda não repassou. Esperar o Vantoro dentro do
webhook seria segurar a mensagem do cliente pelo meio minuto em que ele acorda.

**O que acontece quando dá errado:**

| o Vantoro responde | a ponte |
|---|---|
| 200 | anota que repassou e não manda de novo |
| 400 ou 404 **em JSON** (aviso que não existe, resposta que não serve) | anota e não insiste |
| 404 **sem JSON** — a rota que ainda não existe | tenta na próxima rodada |
| 5xx, página de erro, sem resposta (dormindo) | para a rodada e tenta na próxima |

O 404 sem JSON é o caso da **ponte publicada antes do Vantoro**: sem esta
diferença, cada resposta daquele intervalo seria dada por perdida.

**Repassar duas vezes não faz mal.** A memória do que já foi é da ponte
(`respostasRepassadas`) e some quando ela reinicia; aí as respostas das
últimas 48 horas vão de novo, e o Vantoro não registra a mesma mensagem duas
vezes — a chave é o id dela no WhatsApp.

**O log diz o número do aviso e o que o Vantoro entendeu, nunca o que o
cliente escreveu.**

**Nenhum SQL e nenhuma variável nova.** Usa `fila_envio.aviso_vantoro_id`,
`status` e `enviado_em`, `mensagens.responder_id_uazapi` e `reacoes` (sem a
coluna das reações, lê sem ela e a resposta escrita continua valendo), e o
`VANTORO_API_URL`/`VANTORO_API_TOKEN` dos avisos — a chave já grava, porque os
avisos já mandam `/enviado` e `/erro`.

**As provas são a seção 76** de `testes/prova.mjs`: onze conversas, uma por
caso; o Vantoro acordando; a rota que ainda não existe e o aviso que o
Vantoro não conhece; e o caminho inteiro, do aviso saindo pela fila à resposta
chegando pelo webhook.

### A IA lê as douradas (26/10)

*"Pode usar a IA para as douradas."* A resposta que a regra do Vantoro não
entende volta de lá como `OUTRA` — na tela dele, dourada, "leia e marque".
Quando o Vantoro diz também `lida_pela_ia: false`, a ponte manda essa resposta
ao **Claude do copiloto** (`lerRespostaComIA`), com o texto do aviso ao lado, e
repassa a mesma mensagem de novo com a leitura em `leitura_ia`: `CONFIRMOU`,
`NAO_VAI` ou `OUTRA`. O que fazer com ela, quem decide é o Vantoro — a leitura
só vale para a dourada, e com as mesmas condições de marcar.

- **A mesma chave e o mesmo modelo do copiloto** (`ANTHROPIC_API_KEY`,
  `COPILOTO_MODELO`, pelo `pedirAoClaude`). Sem a chave, nada muda.
- **Esforço baixo e a resposta presa às três leituras** (`output_config` com o
  esquema): é uma escolha entre três. Na dúvida, a regra manda dizer `OUTRA`.
- **O aviso e a resposta vão entre etiquetas**, e a etiqueta que o cliente
  escreve sai do texto dele antes — a régua de `semAEtiqueta`, do copiloto.
- **Nem a que a regra entendeu, nem reação.** Um Vantoro que não diz
  `lida_pela_ia` (mais velho que a leitura) também não faz a ponte perguntar.
- **A IA que não responde ganha três tentativas**, uma por rodada; depois, a
  resposta fica para a equipe. A que se recusa a ler devolve `OUTRA`.
- **No log, a leitura e o número do aviso** — nunca o texto do cliente nem o
  que a IA devolveu.

As provas são a **seção 78**: o Claude de mentira lê a resposta no pedido e
devolve a leitura de uma tabela; o Vantoro de mentira diz quais não entende.

## O aviso de audiência vai para o contato que já existe (27/10)

Relato do Rodrigo: "as mensagens enviadas para os clientes, sobre audiência,
estão criando conversa duplicada" — a GIRLEIS RIBEIRO MATOS aparecia em
(77) 8154-5221 e em (77) 98154-5221, e a EDNALVA NUNES SILVA em
(75) 9905-2309 e em (75) 99905-2309.

**A causa:** o cadastro do Vantoro guarda o celular com o nono dígito, e o
WhatsApp de muitos clientes antigos é a forma sem ele. O laço dos avisos
(`buscarAvisosDeAudiencia`) fazia `upsert` do contato pelo número EXATO, e
nascia um segundo contato, com uma conversa só de avisos. O cliente continuava
respondendo na antiga — e a resposta ao aviso, longe da conversa do aviso,
também não chegava ao Vantoro para marcar o "Cliente confirmou?".

Era a lacuna anotada na auditoria de 07/10 ("os avisos de audiência sem as
variantes do nono dígito"): a entrada de mensagens já procurava as duas formas
desde o caso da MARIA DE JESUS DA SILVA; o aviso não.

**A correção (`contatoDoAviso`):**

- procura o contato nas formas de `variantesDoNumero` — com e sem o 55, com e
  sem o nono dígito — e usa o que existe, **sem mudar o número dele**: quem
  acerta o número pelo WhatsApp é a entrada de mensagens;
- só cria contato quando nenhuma forma existe, com o número do cadastro;
- se as duas formas já existem (o duplicado de antes), vai a que teve conversa
  mais recente — a régua de `sql/2026-08-juntar-duplicados-nono-digito.sql` —
  e o log manda usar "Juntar duas conversas";
- fixo não ganha nono dígito (a régua de `variantesDoNumero`).

**Os duplicados que já existiam** foram juntados depois, a pedido do Rodrigo,
pelo script automático 036 (a seção seguinte). O de agosto
(`sql/2026-08-juntar-duplicados-nono-digito.sql`) não serve mais para isso.

As provas são a **seção 79**; com o laço antigo, 6 das 11 conferências reprovam.

## Os duplicados do nono dígito, juntos (script 036, 27/10)

Pedido do Rodrigo, depois da correção dos avisos: *"Junta as conversas
duplicadas que já existem."*

`sql/automaticos/036-os-contatos-do-nono-digito-juntos.sql` faz no banco, uma
vez, para todo celular com mais de um contato (as formas com e sem o nono
dígito, com e sem o 55), o que o "Juntar duas conversas" do painel faz uma a uma.

**Quem fica:** o contato por onde o cliente **escreve** — o da mensagem mais
recente dele. É a forma que o WhatsApp usa. Sem mensagem do cliente em nenhum,
fica o mais antigo. **O número de quem fica não muda.**

**O que vai junto:**

- as conversas do mesmo telefone do escritório viram uma: mensagem, nota,
  envio da fila, tarefa, "Já tratei", etiqueta e resposta automática. O que
  bateria de frente (a mesma etiqueta, o mesmo aviso gravado nas duas) sai em
  vez de duplicar. As não lidas se somam, a última mensagem é a mais recente
  das duas, e a espera (005) e a situação (028) são recontadas;
- a conversa de um telefone que quem fica não tinha só muda de dono;
- o cartão do funil, com o histórico (o painel apagava o cartão junto com o
  contato);
- o nome, a foto e o cliente do Vantoro que só o contato que sai tinha;
- o histórico de alterações (cadastro e notas).

**O que não vai:** o "Já tratei" da conversa que sai não vira o da que fica.
O clique tratou aquela conversa, e levá-lo poderia tirar da fila uma pergunta
do cliente que ninguém respondeu. A distribuição e os atendimentos contados na
conversa que sai vão com ela, como no painel.

**Por que não o script de agosto:** ele apagava o cartão do funil (a cascata
do 017), perdia o nome e o cliente do Vantoro do contato que saía, trocava o
número de quem ficava pela forma com o nono dígito, e movia toda tabela com
`conversa_id` — inclusive a da distribuição, que aceita uma linha por conversa
(023).

**Tudo ou nada:** a ponte roda cada script numa transação. Um índice único de
expressão que bata faz o banco recusar a junção inteira, em vez de o script
apagar o que não sabe comparar. Rodável de novo; num banco sem o Zorvin, sai
cedo. O registro fica em `juntada_contatos_log`, e a conferência na janela de
scripts do painel: quantos saíram, e se sobrou algum celular com dois contatos.

As provas são a **seção 81**, num Postgres de verdade, com os gatilhos de
produção que a junção dispara. Os 16 defeitos plantados um a um (quem fica,
o que bate de frente, o funil, o número, o fixo, a espera, o histórico, a
resposta automática, o índice de expressão, o "Já tratei", as não lidas, a
última mensagem) são todos reprovados.

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
a ponte (`service_role`) a alcança. É a armadilha nº 5 aplicada na origem. O
painel não a lê: ele pergunta à ponte (`GET /scripts/estado`, ver "Ligar no
escritório", logo abaixo).

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

**E ela conferia o começo da pasta, e não a pasta (27/10).** `pontComScripts`
volta 400 ms depois da primeira linha da rodada, e falando direto com o banco
essa linha (*"falei com o banco"*) sai antes do primeiro script. Com um ou dois
scripts, como quando a cena nasceu, isso bastava. Com 34, não:

- medido com a máquina parada: a conferência *"todos os scripts da pasta
  aplicaram sem falha"* aprovou com **2 dos 34** anotados, e a ponte foi
  derrubada no fim da cena depois do 11º. Os outros 23 nunca rodaram ali;
- com a máquina quente, a mesma cena via os 34. A cobertura dependia da sorte;
- em 26/10, na suíte inteira, o `drop table` da cena trombou com o 032
  (*"tuple concurrently updated"*) e derrubou a prova toda.

Hoje a cena espera o banco anotar todos os `.sql` da pasta, ou um falhar, e
confere pelos **nomes**. Reproduzido numa cópia, com a ponte atrasando 80 ms
por script, que é o que faz uma máquina ocupada:

| a cópia | a cena de antes | a de hoje |
|---|---|---|
| um script quebrado no fim da pasta | passava, conferindo com 5 de 35 | reprova, com o nome e o erro dele |
| a ponte parando calada depois do 10º | passava, com 10 anotados e todos certos | reprova: "10 de 34 anotados" |
| só a ponte lenta | — | passa |

E as duas partes do conserto fazem falta, medido tirando uma de cada vez: sem
a espera, a ponte lenta reprova com 4 de 34 anotados; contando linhas no lugar
dos nomes, a ponte que para calada passa. **Esperar o primeiro sinal de um
trabalho não é esperar o trabalho.**

Variável **opcional** `SCRIPTS_PASTA`, para a bancada apontar scripts de mentira
sem escrever dentro do repositório — mesma linha de `CAIXA_INTERVALO_MS`. Prova:
seção 51, que sobe um **Postgres de verdade** (a integração contínua traz um), e
**reprova se ele faltar** em vez de se pular em silêncio.

### Ligar no escritório (08/10) — o marco, a guarda, a senha e a janela

Pedido do Rodrigo: *"pode seguir com os scripts automáticos"* — parar de colar
SQL. A automação estava escrita e provada desde 14/09, e **ligá-la como estava
seria um estrago**: `zorvin_scripts_aplicados` não existe no banco do
escritório, então a primeira subida rodaria de 001 a 020 de novo. A pasta
inteira, na ordem, aguenta isso — mas não de graça (regra 5 do LEIA-ME: o 009
recria o "OUTROS" renomeado ou desativado). Entraram cinco coisas antes do
interruptor.

**O marco — `SCRIPTS_RODADOS_A_MAO=020`.** Na primeira vez, com a tabela sem
registro nenhum, a ponte anota de 001 a 020 com `origem = 'a_mao'` **sem rodar
nenhum** — numa transação, porque metade do marco anotada faria a subida
seguinte achar que há histórico e rodar a outra metade. Três cuidados:

- o número vai **como no nome do arquivo**. "02" lido como número seria o 002, e
  a ponte rodaria de novo de 003 a 020 achando que obedecia: valor que não é o
  número de um arquivo da pasta é recusado, e **nada** roda;
- **só vale na primeira vez**. Com histórico ele é ignorado, e o log diz que a
  variável pode sair da Render: trocar o número depois não pode pular calado um
  script que nunca rodou;
- **"0" quer dizer nenhum** — para quem montou o Zorvin pelos scripts de `sql/`.

**A guarda.** Sem registro e sem o marco, num banco que já tem `conversas`, a
ponte **não aplica nada** e diz o que falta. Esquecer a variável não pode ser o
jeito de rodar os vinte de novo. Banco sem o Zorvin (um cliente novo, a bancada,
a 51l-bis) segue como sempre seguiu.

**A senha à parte (`DATABASE_PASSWORD`).** O endereço da Supabase vem com
`[YOUR-PASSWORD]`, e trocar à mão tem uma armadilha que ninguém vê: senha com
`@`, `#`, `/` ou `?` precisa ir **codificada** dentro de um endereço, e crua ela
o parte no lugar errado — o banco diz "senha errada" para a senha certa. A ponte
agora **lê o endereço ela mesma** e passa cada pedaço ao `pg` como valor: quem
separa a senha do servidor é o **último** `@`. A senha crua dentro do endereço
também serve; à parte é o recomendado.

**As frases de quem não é do ramo.** Senha errada (*"é a senha do BANCO, e não a
de entrar no site"*), usuário sem o código do projeto (`Tenant or user not
found`), endereço DIRETO (só IPv6), servidor que não existe, banco que não
existe — cada um vira a frase do que mudar, com o motivo técnico à parte. O
pooler de **transação** (porta 6543) é **recusado antes de tentar**: nele a
trava de sessão se soltaria, e ele "funcionaria" — por isso mesmo não pode ser
tentado. **Nenhuma frase repete o endereço**: ele tem a senha dentro.

**Tentar de novo sozinha** — só no que passa sozinho: a trava presa por outra
ponte (numa publicação há duas vivas, e a que desiste é a que FICA no ar) e o
banco que não respondeu. A espera dobra de 30s até 10 min. **Senha errada não
insiste:** a Supabase bloqueia o endereço de quem erra a senha muitas vezes
seguidas, e insistir trocaria um aviso por um bloqueio.

**A janela do painel — `GET /scripts/estado`**, só para quem administra (`admin`
E `ativo`; a conferência de quem pede falhando vira 502 com a frase, e não "você
não administra"). Devolve a situação (`desligado`, `rodando`, `em_dia`,
`pendentes`, `falhou`, `mudou`, `sem_marco`, `marco_invalido`, `nao_conectou`,
`outra_ponte`, `sem_pg`), a frase, o detalhe técnico, o que entrou nesta subida,
a próxima tentativa e a lista do que está anotado no banco. **Por uma rota da
ponte, e não por `zorvin_saude()`** como estava escrito aqui: os defeitos mais
prováveis — senha, endereço — acontecem antes de a ponte chegar ao banco, e o
banco não tem como contar o que nunca chegou a ele. **O desfecho só vai para a
janela depois de a tabela ser relida**: publicado antes, "em dia" sairia ao lado
da lista de antes da rodada, sem o script que acabou de entrar.

**A conferência de cada script fica guardada** (`conferencia`, jsonb, a coluna
nova ao lado de `origem`): é a última linha dele, o `select` que respondia "deu
certo?" no editor da Supabase. Agora ninguém vê o script rodar, então a ponte
guarda a resposta e marca `false`, "NÃO…" e "rode o script…" — a convenção desta
pasta, escrita no LEIA-ME. Contagem e nome não pesam.

**E `SCRIPTS_AUTOMATICOS` escrito errado** ("aplica") vale como `conferir`, que
é o seguro — e a frase diz que foi isso, em vez de deixar a pessoa achando que
ligou.

Prova: seção 51, de 51m a 51z, mais 51h e 51i conferindo a janela — a seção foi
a **94 conferências**, com **21 sabotagens e 21 pegas**, todas limpas (nenhuma
"pegou" estourando a prova). Duas lições da bancada: o papel do banco com a
senha cheia de símbolos é **sorteado por rodada** — papel é do servidor inteiro,
e com nome fixo as sabotagens em paralelo brigavam pelo mesmo `alter role` e a
prova estourava com *"tuple concurrently updated"*, falando de outro assunto; e
a primeira rodada de sabotagens reprovou, de passagem, uma cena que a sabotagem
nem tocava (51w) — era um descompasso de verdade: a próxima tentativa era
apagada DEPOIS de a rodada voltar, e quem perguntasse no meio lia "em dia" ao
lado de uma tentativa marcada. Hoje ela se apaga no começo da rodada. Uma variável
própria para a bancada: `SCRIPTS_TENTAR_DE_NOVO_MS` (a primeira espera).

### Ligado em produção (08/10) — e o marco que eu ia dar errado

**Antes de pôr o marco, ele foi MEDIDO.** Eu vinha afirmando que de 001 a 020
tinham sido colados à mão — e uma consulta só de leitura, que procura no banco
o que cada script deixa (uma coluna, uma tabela, uma função, o gatilho),
respondeu que **o 001 e o 002 nunca tinham sido colados**. Os dois nasceram em
14/09 para quem compra sem Vantoro, e nenhum pedido de SQL ao Rodrigo os
incluiu. Com `SCRIPTS_RODADOS_A_MAO=020` sem a conferência, os dois ficariam
anotados como aplicados sem estar no banco — e nunca mais rodariam, calados.

**Os dois foram colados à mão antes do marco**, num bloco só com a conferência
no fim (dois `true`). No escritório eles não mudam nada para a equipe: o 002 é
uma coluna que só o caminho sem Vantoro usa, e o gatilho do 001 cria a linha
de `usuarios` que a entrada com Vantoro sobrescreve logo depois — conferido no
código (`upsert(..., { onConflict: 'id' })` em `/auth/login`) e num Postgres
de teste, rodando o bloco duas vezes.

Depois, na Render: `DATABASE_URL` (Session pooler, com `[YOUR-PASSWORD]`),
`DATABASE_PASSWORD`, `SCRIPTS_RODADOS_A_MAO=020` e `SCRIPTS_AUTOMATICOS=aplicar`.
A primeira subida, às 15:53, disse na aba do painel: **"Em dia"** e **"20
scripts colados à mão antes de a ponte aplicar sozinha (001 a 020)"**.
`SCRIPTS_RODADOS_A_MAO` ficou na Render: com histórico ela é ignorada.

**A régua que fica: o marco é uma afirmação sobre o banco, e afirmação sobre o
banco se MEDE antes de virar configuração.** A consulta custou uma colada; o
palpite custaria dois scripts sumidos sem nenhum aviso — a armadilha nº 2 com
outra roupa, no lugar onde ninguém olharia de novo.

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

### O REPASSE, e a lista em ordem alfabética (script 025, 14/10)

Pedido do Rodrigo: *"No 'Já tratei' crie a opção 'REPASSE'. E deixe tudo em
ordem alfabética."* `sql/automaticos/025-o-repasse-e-a-ordem-alfabetica.sql`.

**Quem mantém a ordem é o banco, e nenhuma tela mudou.** A lista aparece em
quatro lugares do painel (a janela do "Já tratei", a administração, o
histórico do cliente e o relatório), e os quatro já liam
`zorvin_assuntos.ordem`. `zorvin_ordenar_assuntos()` refaz as posições pela
ordem alfabética, e um gatilho de instrução a chama quando um assunto
**nasce** ou **muda de nome**: o assunto criado amanhã pela tela vai sozinho
para o lugar dele. Ordenar em cada tela seria a mesma regra escrita quatro
vezes.

**`ordem` deixou de ser a ordem de criação** e passou a ser a posição
alfabética — a tela nunca ofereceu mudá-la à mão. O painel continua gravando
`ordem` = maior + 1 ao criar, e o gatilho conserta na mesma instrução.
**Ao escrever um "mudar a ordem à mão" na tela, este gatilho tem de sair
antes**, senão ele desfaz cada escolha no clique seguinte.

~~**"Tudo" inclui o OUTROS**, que ficou entre DOCUMENTOS JG e REPASSE.~~
**Mudou no mesmo dia, a pedido do Rodrigo: o OUTROS fica sempre no fim** —
ver "O OUTROS sempre no fim (script 026)", logo abaixo. O que continua valendo
daquele raciocínio é a outra metade: a regra não podia ficar presa ao nome
"OUTROS", e por isso o 026 é uma marca.

**A chave ignora acento e caixa** (`zorvin_chave_do_assunto`: `translate`
primeiro, `lower` depois — num banco de collation "C", `lower` não baixa letra
acentuada) e é comparada em `collate "C"`, para a ordem não depender da
collation que a Supabase escolheu. Sem ela, byte a byte, "ÁGUA" viria depois
de "ZELADORIA" e "abertura" depois de "BLINDAGEM". Ativos e desativados entram
na mesma conta.

**`security invoker`, com uma trava de transação.** Quem cria ou renomeia é
quem administra (as políticas do 005), e é com essa permissão que as posições
são refeitas. A trava põe em fila duas renumerações ao mesmo tempo — sem ela,
dois assuntos criados no mesmo segundo ficam com o mesmo número, cada
renumeração calculada sem ver o outro. **Só quem saiu do lugar é regravado.**

**O REPASSE só nasce na rodada que cria a função** (regra 5 do LEIA-ME):
rodar a pasta de novo depois de o escritório tirá-lo de uso não o traz de
volta, e a conferência diz isso sem acusar defeito — faltar só é defeito na
primeira rodada. Um REPASSE já ativo, criado à mão, é aproveitado.

Prova: seção 64, num Postgres de verdade, sobre o 005 e o 009 aplicados a
partir dos próprios arquivos, e não de uma cópia deles. São 28 conferências,
**17 sabotagens e 17 pegas**, todas limpas, rodadas em cópias e lidas uma a
uma. Duas cenas são as únicas que pegam a sabotagem delas:

- a das duas pessoas criando no mesmo segundo pega a que tira a trava;
- a do REPASSE criado à mão pega a que tira a renumeração da instalação. Sem
  assunto novo, o gatilho não dispara, e só a renumeração da instalação põe a
  lista de hoje em ordem.

**O banco da prova é mais fechado que a produção**: ele não tem o EXECUTE que
o Postgres dá a todos por padrão. É assim que se prova que o gatilho funciona
só com as concessões do próprio 025, e que disparar o gatilho não pede EXECUTE
de quem mexeu.

**E uma sabotagem vazou primeiro, por engano meu na prova.** Escrevi o
`revoke` desse banco com `in schema public`. Um `revoke` por esquema só desfaz
um `grant` por esquema: o padrão global continuava valendo, e a sabotagem que
tirava a concessão do 025 passava. Sem o `in schema`, ela é pega por cinco
conferências, com o erro que a tela mostraria ao criar um assunto:
*permission denied for function zorvin_ordenar_assuntos*.

### O OUTROS sempre no fim (script 026, 14/10)

Pedido do Rodrigo, logo depois do 025: *"Deixe o OUTROS sempre no fim"*.
`sql/automaticos/026-o-outros-fica-no-fim.sql`.

**Uma marca, e não o nome**: `zorvin_assuntos.fica_no_fim`, a régua do 009.
Presa ao nome, a regra quebraria no dia em que alguém corrigisse o nome pela
tela — "OUTROS ASSUNTOS" voltaria para o meio. A marca vai junto com o
assunto em qualquer renomeação.

**E não é a marca do "pede descrição"**: a tela deixa ligá-la em qualquer
assunto, e ligar a descrição em ACORDOS não pode mandar ACORDOS para o fim.

**A ordem agora:** primeiro quem não tem a marca, em ordem alfabética (a chave
do 025); depois quem tem, em ordem alfabética entre si. O gatilho dispara
também na troca da marca, e não só do nome. **O 026 é a versão de referência
de `zorvin_ordenar_assuntos()` e do gatilho** (regra 5 do LEIA-ME).

**A marca é ligada no OUTROS só na rodada que cria a coluna**: desligada
depois, rodar a pasta de novo não a religa. E a conferência procura o OUTROS
pelo nome só nessa rodada — numa rodada de novo o nome pode ter mudado pela
tela, com a marca junto, e isso não é defeito.

**Ainda em aberto, e é decisão:** a marca não tem chave na tela. Hoje só o
OUTROS a usa; quem compra o programa e quiser outro assunto no fim precisa de
um botão "fica no fim da lista" ao lado de "pede descrição", na
administração.

Prova: seção 65, no mesmo banco fechado da 64: 21 conferências, **10
sabotagens e 10 pegas**, todas limpas, rodadas em cópias e lidas uma a uma.
Duas delas só existem por causa da diferença entre marca e nome:

- a ordem pelo NOME no lugar da marca é pega pela cena que renomeia o OUTROS;
- a marca ligada em quem PEDE DESCRIÇÃO é pega pela cena em que ACORDOS pede
  descrição antes de o 026 rodar.

### O DÚVIDAS TRATADAS, e as sementes (script 027, 14/10)

Pedido do Rodrigo: *"No 'Já tratei' incluir a opção 'Dúvidas Tratadas'"*.
Primeiro foi sugerido a ele o caminho da tela (Departamentos e acessos →
Assuntos do "Já tratei" → Criar), que fica pronto na hora; ele pediu que
fosse feito por aqui. `sql/automaticos/027-duvidas-tratadas.sql`.

**Em maiúsculas, como os outros** (`DÚVIDAS TRATADAS`), sugestão feita a ele
antes. O lugar não é escolhido no script: o gatilho do 025/026 o põe entre
DOCUMENTOS JG e REPASSE, com o OUTROS no fim.

**A âncora da regra 5 é nova: `zorvin_sementes`.** O 025 semeou o REPASSE
"na rodada que cria a função da ordem"; este não cria nada — o assunto entra
numa tabela que já existe. Sem âncora, rodar a pasta de novo depois de o
escritório tirá-lo de uso ou renomeá-lo o traria de volta. Agora cada linha
plantada assim deixa uma CHAVE (`assunto:duvidas-tratadas`), e a chave
plantada não planta de novo. **O próximo "inclua o assunto X" usa a mesma
tabela** — o LEIA-ME de `sql/automaticos` diz isso na regra 5.

A tabela nasce **com RLS ligada, sem política e sem concessão a `anon` nem a
`authenticated`**, como `zorvin_scripts_aplicados`: nenhuma tela precisa
dela, e apagar uma chave é o jeito de um script plantar de novo.

**O criado à mão é aproveitado pela chave do 025**, que ignora acento e
caixa: "Dúvidas tratadas" ou "DUVIDAS TRATADAS" feitos pela tela antes da
publicação contam como o mesmo assunto. O índice único do 005
(`lower(nome)`) separaria "Ú" de "U" e deixaria nascer um segundo.

Prova: seção 66, num banco que imita a Supabase nas tabelas (tudo concedido
a `authenticated` por padrão) — é nele que se vê se o 027 tira as sementes
do alcance do painel. 16 conferências, **10 sabotagens e 10 pegas**, todas
limpas, rodadas em cópias e lidas uma a uma.

**E uma sabotagem pegou pelo motivo errado na primeira escrita.** "Plantar em
toda rodada" estourava na chave primária das sementes, e a prova reprovava
com o erro em vez de mostrar o assunto voltando. Refeita para não tropeçar
(`on conflict do nothing`), ela é pega pelas cenas do assunto tirado de uso
e do renomeado — que é o defeito de verdade.

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

## O funil de etapas (script 017, 06/10)

Pedido do Rodrigo como segundo passo para CRM, depois do responsável. Decidido
com ele: **um funil por departamento**, as etapas sugeridas (Novo contato → Em
atendimento → Aguardando cliente → Proposta/acordo enviado → Acordo fechado →
Em execução → Encerrado) editáveis na administração, e **o cartão é o
cliente** — que, enquanto o Zorvin não tem ficha própria, é o CONTATO: a
mesma pessoa por dois números são dois cartões, e isso foi dito a ele antes.

`sql/automaticos/017-o-funil-de-etapas.sql`, três tabelas:

| tabela | o que guarda |
|---|---|
| `zorvin_etapas` | as colunas de cada funil (`departamento_id`, `ordem`, `cor`, `ativo`) |
| `zorvin_cartoes` | em que etapa está cada cliente — **um** por (contato, departamento) |
| `zorvin_movimentos` | de qual etapa para qual, quem e quando |

**Etapa não se apaga, desativa-se** — a régua dos assuntos do "Já tratei":
não há política de DELETE. **O histórico é escrito por gatilho**
(`security definer`), e quem entrou só o LÊ: não há como mover sem deixar
rastro, nem escrever rastro falso. **A etapa tem de ser do mesmo
departamento do cartão** — um gatilho confere e recusa com 23514, senão um
cartão do SAC poderia parar numa coluna do SDC e sumir dos dois funis.

**Quem vê um cartão é quem vê as conversas daquele cliente naquele
departamento**: a regra (`zorvin_ve_no_funil`, `security invoker`) pergunta
às próprias `conversas` e herda a permissão de telefones e departamentos que
já existe.

**O cliente novo entra sozinho** na primeira etapa ATIVA, por gatilho em
`conversas` — grupo não entra, telefone sem departamento não entra, e o corpo
vive num `exception when others`: funil quebrado não pode derrubar a conversa
nova (perder mensagem de cliente é o pior desfecho deste sistema). **O que
já existia não entra sozinho**: quem administra traz pela tela, por
`zorvin_funil_trazer(p_departamento, p_dias)`, que devolve quantos entraram.

**A ponte não faz nada com isso**, como no responsável: é banco e painel.

Conferido num Postgres 16 de verdade, 20 cenas: o cliente novo entrando, o
grupo de fora, o cartão nos dois departamentos, o trazer só de quem
administra (e 0 na segunda vez), a atendente vendo só o SAC, o movimento com
quem moveu, a etapa de outro funil recusada, a atendente sem alcançar o SDC
nem escrever movimento, criar ou apagar etapa, o cartão apagado deixando
rastro, a primeira etapa desativada mandando o novo para a seguinte, o funil
quebrado sem derrubar a conversa, reaplicação (a etapa desativada continua
desativada) e banco limpo (a 51l-bis passa). **A conferência do fim CHAMA a
leitura no papel `authenticated`** — a régua do 012.

### O relatório do funil (script 019, 07/10)

`sql/automaticos/019-o-relatorio-do-funil.sql` cria
`zorvin_relatorio_funil(p_desde, p_ate, p_departamento, p_telefone)`: por
departamento e por etapa, quantos cartões estão nela AGORA (com a mediana de
há quanto tempo e o mais parado), e NO PERÍODO quantos entraram, quantos
saíram e quanto tempo ficaram os que saíram (mediana e média). A tela é uma
seção do Painel de números.

**O tempo numa etapa sai dos movimentos**: a saída é o movimento com
`de_etapa` = a etapa, a chegada é o último com `para_etapa` = a etapa ANTES
dela. **Só quem saiu conta** — o "até agora" de quem ficou vai à parte.

**`security invoker`**, como o 010 e o 011, e **só aparecem os departamentos
em que quem chama vê alguma conversa**. Sem o 017 responde
`{"falta": "017"}`. De `advogados` só `departamento_id`, pelo nome — a régua
do 012; **e a conferência do fim chama a função como `authenticated` COM um
telefone**, porque é o caminho com filtro que lê `advogados`: chamada sem
telefone, a sabotagem do `to_jsonb(a)` passava. Entraram também dois índices
em `zorvin_movimentos` para a conta da chegada.

Conferido num Postgres 16 de verdade (as contas batidas à mão: 4 entradas, 3
saídas, mediana de 2 dias de (4, 2, 1) e média 2,33; o cliente que VOLTA a
uma etapa; o período curto; o filtro de telefone; quem não administra só no
departamento que atende; etapa desativada vazia some e com cartão fica;
banco limpo; reaplicação) e **5 sabotagens com 5 pegas**.

## Tarefas e lembretes (script 018, 06/10)

Terceiro passo para CRM, depois do responsável e do funil: o "quando agir de
novo". Decidido com o Rodrigo: **a tarefa é de uma conversa**, quem vê a
conversa vê as tarefas dela (a equipe do telefone), e **só quem recebeu é
avisado** na hora.

`sql/automaticos/018-tarefas-e-lembretes.sql`, uma tabela só,
`zorvin_tarefas`: `conversa_id`, `texto` (1 a 500), `vence_em`, `para_quem`
(`usuarios.id`, `on delete set null`), `criada_por`/`criada_em` e
`feita_em`/`feita_por`.

**Quem criou e quem concluiu são do gatilho** (`zorvin_tarefa_quem`), e não
da tela: `criada_por` é sempre quem entrou, não muda depois, e reabrir limpa
`feita_por`. **Apagar é permitido**, e é decisão: tarefa criada por engano não
é histórico, e "concluída" no lugar de "apagada" contaria como trabalho feito.

**Quem vê é quem vê a conversa**: as políticas perguntam a `conversas` numa
subconsulta, e a regra de acesso de `conversas` vale lá dentro, no papel de
quem pergunta. Nenhuma segunda escrita da permissão.

**O aviso na hora é do PAINEL**, e não do banco nem da ponte — a ponte não
faz nada com isso.

Conferido num Postgres 16 de verdade, 12 cenas (quem criou mesmo mandando
outro; criar e ver só no telefone que atende; concluir e reabrir; quem criou
não muda; apagar só o que vê; texto vazio recusado; pessoa apagada vira sem
dono; conversa apagada leva as tarefas), reaplicação, banco limpo, e **3
sabotagens com 3 pegas** (leitura aberta, `criada_por` da tela, reabrir sem
limpar). A conferência do fim lê a tabela como `authenticated`.

## A resposta automática fora do horário (script 021, 09/10)

Pedido do Rodrigo, o nº 1 da lista de ideias de 08/10: quem escreve à noite,
no fim de semana ou no feriado recebe na hora o texto do departamento
("Recebemos sua mensagem. Respondemos de segunda a sexta, das 8h às 18h").
Decidido com ele: **texto e horário por departamento**, **uma vez por
período fechado** (não a cada mensagem), e **a conversa continua na fila de
espera** — o cliente ainda não foi atendido.

`sql/automaticos/021-a-resposta-fora-do-horario.sql`:

| peça | o quê |
|---|---|
| `zorvin_feriados` | os dias em que o escritório não abre — do escritório inteiro |
| `zorvin_horario_de(semana, fuso, quando)` | a conta: aberto? quando fecha? quando abre? quando fechou? |
| `zorvin_fora_do_horario` | por departamento: ligada, texto, a semana (`seg`…`dom`, `["08:00","18:00"]` ou nulo) e o fuso |
| `zorvin_respostas_automaticas` | o que saiu: texto, status (`enviando`/`enviada`/`erro`), e `ate` |
| `zorvin_responder_fora_do_horario(conversa, id_uazapi)` | a decisão e a reserva da vez, numa transação só |

### Quem decide é o banco, e a ponte só pergunta

Depois de gravar uma mensagem de CLIENTE (não grupo), a ponte chama a função
com a conversa e o id da mensagem; se ela disser que sim, manda o texto por
`/send/text` e anota `enviada` (com o id do WhatsApp) ou `erro` (com o
motivo). A conta do horário, as regras e a reserva moram no banco por dois
motivos: é a MESMA conta que a prévia do painel usa (uma escrita só), e a
reserva precisa ser atômica — duas pontes vivas na publicação, ou a caixa de
entrada reprocessando, perguntam as duas, e só uma manda.

**Não sai quando:** a mensagem tem mais de 30 minutos (importação, reenvio
atrasado); é grupo; a linha está desativada; o departamento não tem a
resposta ligada; está dentro do horário; não há dia aberto em 31 dias; **ou
a equipe está conversando com o cliente** — escreveu depois do fechamento
(quem fez hora extra está atendendo, e "estamos fechados" no meio de uma
conversa viva é constrangimento) ou nos 30 minutos antes da mensagem dele
(script 022, logo abaixo).

**A chave do período é a hora em que o escritório ABRE de novo** (`ate`),
única por conversa: a sexta às 19h e o sábado às 10h têm a mesma (terça 8h,
com a segunda 12/10 feriado), a segunda às 20h outra. É também o que
responde, no registro, "fechado até quando".

### A resposta NÃO entra em `mensagens`, e é a decisão principal

Em `mensagens` ela passaria pelo gatilho feito à mão no começo do projeto (a
prévia, a ordem e as NÃO LIDAS da lista), que não está em arquivo nenhum — a
prévia viraria "Recebemos sua mensagem" no lugar da pergunta do cliente, e
não há como saber se o selo contaria a nossa resposta como mensagem a ler. E
a fila de espera, o painel de números, os avisos e "quem respondeu" leem
`mensagens`. No registro à parte, nada disso muda; o painel junta o registro
à linha do tempo da conversa, como já junta as notas e as mensagens que não
saíram.

**Pelo mesmo motivo ela não passa pela `fila_envio`**: falhando, viraria
bolha vermelha com "Reenviar" e acenderia a faixa vermelha de "mensagem que
não saiu" — alarme sobre um aviso automático, que ninguém tem o que fazer
com ele. Falhando aqui, o registro diz `erro` e o motivo, e só.

**Sem `readchat`**: a fila manda porque quem responde já leu; aqui ninguém
leu, e marcar como lida no aparelho apagaria o sinal de cliente esperando.

**Nasce desligada**, e o 021 semeia os feriados nacionais de 2026 e 2027 só
na rodada que CRIA a tabela (regra 5 do LEIA-ME). Carnaval e Corpus Christi
ficam de fora: são ponto facultativo.

**Sem o script, tudo como antes**: a primeira resposta "a função não existe"
desliga isto até a ponte reiniciar, com uma linha no log. Um tropeço qualquer
do banco NÃO desliga — calaria a resposta por causa de um segundo ruim.

Conferido num Postgres 16 de verdade: **60 conferências** (a conta do
horário com feriado, fuso, UTC, 8h e 18h em ponto, sábado de meio
expediente; o gatilho que recusa em português; cada motivo de não sair; duas
pontes ao mesmo tempo; quem pode o quê, no papel de quem atende) e **14
sabotagens com 14 pegas**. Uma estourou a prova primeiro, em vez de reprovar
com nome — a chamada da decisão passou a ser guardada. Na suíte: seção 58
(a ponte, 28 conferências, **12 sabotagens e 12 pegas**) e seção 59 (a conta
do horário num Postgres de verdade, obrigatória na integração contínua).

### E ela não interrompe uma conversa (script 022, 09/10)

Pedido do Rodrigo no mesmo dia em que ligou e testou: *"se eu estiver
conversando com o contato antes ou após o horário do expediente, a mensagem
automática não pode aparecer"*. O 021 cuidava de metade (quem escreveu
DEPOIS do fechamento); faltava a conversa que vem de ANTES:

| | |
|---|---|
| 17:55 | nós: "Vou conferir e já te digo." |
| 18:00 | o escritório fecha |
| 18:05 | ele: "Obrigado, fico no aguardo" → o 021 respondia "nosso horário é das 8h às 18h…" |

`sql/automaticos/022-a-resposta-nao-interrompe-a-conversa.sql` recria a
decisão com a regra nova: **não sai se a equipe agiu nesta conversa nos 30
minutos antes da mensagem do cliente**, de qualquer lado do fechamento. Pela
regra 5 do LEIA-ME, **o 022 é a versão de referência da decisão** daqui para
a frente.

**Os 30 minutos são `zorvin_carencia_da_espera()`, do 006** — a carência da
fila de espera. É a mesma pergunta ("o cliente ainda está respondendo àquela
conversa?"), e duas réguas para ela divergiriam no primeiro ajuste: a fila
diria que ele não está esperando, e a resposta automática diria a ele que
ninguém está ali. A aba do painel escreve o número lido de lá.

**"A equipe agiu" são duas coisas:** a mensagem nossa em `mensagens` (inclui
quem respondeu pelo celular) e **o pedido que ainda está na `fila_envio`** —
quem apertou Enviar dois segundos antes está conversando, e a mensagem dele
só entra em `mensagens` depois que o WhatsApp aceita. Sem isso, mensagens
que se cruzam dariam a resposta automática logo depois da nossa. **A
agendada que espera a hora não conta** (`agendada_para`, lida por `to_jsonb`
porque nasceu no 013).

**A carência é lida dentro de um bloco protegido**, e não é zelo: sem o 006,
um "function does not exist" que escapasse cairia em `semAFuncao` — e a
PONTE desligaria a resposta automática até reiniciar, achando que o 021 não
existe. Sem a função, valem os mesmos 30 minutos. Pela mesma razão a
conferência lê a carência por `execute`: escrita direto, a chamada seria
resolvida ao preparar o `insert`, e o script inteiro morreria por uma linha
de conferência.

**Motivo próprio no retorno** (`conversa_em_andamento`), separado do
`equipe_respondeu` do 021, para quem investigar saber qual das duas regras
segurou.

**O que continua de fora, e foi dito ao Rodrigo:** o cliente que escreve
PRIMEIRO, fora do horário, recebe a resposta na hora — mesmo com alguém no
escritório que vá responder um minuto depois. O banco não tem como saber
disso. O ajuste é o horário do departamento na tela; esperar uns minutos
antes de mandar seria outra decisão, e é dele.

**E a presença ("estou atendendo") NÃO entrou, de propósito.** O painel pulsa
`atendendo_em` de minuto em minuto enquanto a conversa está aberta, **mesmo
com a aba escondida** — uma aba esquecida aberta numa conversa às 18h
calaria a resposta daquele cliente a noite toda. Mensagem é fato; aba aberta
não é gente.

Conferido num Postgres 16 de verdade: **43 conferências** (a conversa que
atravessa o fechamento; 29 e 31 minutos; a fila que ainda não saiu; a
agendada; o envio que falhou; a carência trocada para 10 minutos; o banco
sem o 006; a base sem a fila; banco limpo; reaplicação; o 021 inteiro de
novo) e **11 sabotagens com 11 pegas**, todas limpas — inclusive a versão
de antes (só o 021), que reproduz o relato.

## A distribuição das conversas novas (script 023, 13/10)

Pedido do Rodrigo, o nº 3 da lista de ideias de 08/10: o cliente novo já
chega com um responsável, em rodízio entre quem atende o departamento.
Decidido com ele: entra no rodízio **quem atende o departamento** (quem vê as
conversas dele), com uma chave *"recebe conversas novas"* por pessoa para
férias e folga; o rodízio é **simples** (cada um na sua vez); e **só a
conversa de cliente novo** — as antigas sem responsável ficam como estão.

`sql/automaticos/023-a-distribuicao-das-conversas-novas.sql`:

| peça | o quê |
|---|---|
| `zorvin_distribuicao` | a chave de cada departamento — nasce desligada |
| `zorvin_rodizio` | a chave de cada pessoa; sem linha, vale o padrão |
| `zorvin_distribuicoes` | quem recebeu qual conversa, e quando — é dele que sai a vez |
| `zorvin_ve_o_telefone(pessoa, telefone)` | a regra de acesso, para uma pessoa |
| `zorvin_distribuir_conversa(conversa, id_uazapi)` | a decisão — só a ponte chama |
| `zorvin_rodizio_pessoas()` | a lista da aba do painel — só quem administra |

### Quem decide é o banco, e a ponte só pergunta

Depois de gravar a mensagem de um CLIENTE (não grupo, não nossa), a ponte
chama `zorvin_distribuir_conversa` — **antes** da resposta fora do horário,
que pode levar segundos falando com o WhatsApp: nessa ordem a conversa
aparece com dono na tela de todo mundo na hora. **A pergunta vai em toda
mensagem de cliente**, e não só na primeira: a conversa é gravada com
`upsert`, e a ponte não sabe se ela acabou de nascer. A resposta de quase
toda mensagem é "já tem responsável", a primeira coisa que o banco confere.

**"Cliente novo" é o banco quem diz**, olhando as mensagens: a que chegou é do
cliente e recente (até 30 minutos — a importação de histórico não distribui
o passado); a primeira da conversa também é recente (o "Oi" seguido de "Bom
dia" é o mesmo cliente novo, e a distribuição que tropeçou no "Oi" acerta no
"Bom dia"); a equipe ainda não agiu nela (nenhuma mensagem nossa, nem do
celular; nenhum item na fila — conversa começada por nós é cliente que nós
procuramos); não é grupo, a linha não está desativada e tem departamento.
**A resposta automática não conta como a equipe ter agido** (ela mora fora de
`mensagens`): o cliente da noite recebe a resposta E um responsável.

### Quatro decisões que o pedido não dizia

1. **Cada departamento liga a sua, e ela nasce desligada** — como a resposta
   fora do horário. Ligada na publicação, daria cliente a quem ninguém
   escolheu; ligada pela tela, quem administra vê antes a lista de quem vai
   receber.
2. **Quem administra começa fora, quem atende começa dentro.** O
   administrador vê todos os telefones POR administrar, e não por atender:
   sem isto o gerente entraria no rodízio de todos os departamentos. A chave
   muda os dois sentidos.
3. **"Na sua vez" é "quem recebeu há mais tempo, naquele departamento"**,
   com quem nunca recebeu primeiro e o empate pelo nome. Acerta sozinho
   quando a equipe muda: quem volta das férias recebe a próxima — com um
   ponteiro de "quem é o próximo", esperaria a volta da lista inteira.
4. **Só recebe quem vê o TELEFONE da conversa**, e não só o departamento:
   entregar uma conversa a quem não consegue abri-la seria o cliente sem
   ninguém, com cara de ter dono.

### O responsável que o Zorvin põe

É o `responsavel_id` do 008 com **`responsavel_por` NULO** — a convenção do
funil, onde `quem` nulo é "O Zorvin". O painel diz *"pela distribuição
automática"* no menu do responsável. **A escolha é feita sob uma trava por
departamento** (`pg_advisory_xact_lock`), **e a gravação exige
`responsavel_id` nulo**: duas pontes vivas na publicação, a caixa de entrada
reprocessando ou dois clientes no mesmo segundo não dão a mesma vez duas
vezes, nem tiram a conversa de quem já a pegou.

### A regra de acesso escrita duas vezes, e conferida contra a de verdade

`zorvin_ve_o_telefone` repete `pode_ver_conversa(telefone)` com a pessoa como
parâmetro — a de verdade lê `auth.uid()`, e quem chama a decisão é a ponte,
que não é ninguém. **A conferência do fim compara as duas**, pessoa por
telefone, fazendo o banco acreditar que é cada pessoa da equipe (o
`auth.uid()` do Supabase lê `request.jwt.claim.sub`). Tem de dar zero
divergências; uma só aparece como *"NÃO — N de M pares…"*, e a faixa vermelha
do painel avisa quem administra. É a régua de
`sql/2026-09-a-permissao-perguntada-uma-vez.sql`: conferir linha por linha em
vez de acreditar em mim.

**Só a ponte chama a decisão** (`revoke` de `authenticated`, e a conferência
diz). A lista da tela recusa (42501) quem não administra — a recusa DITA, e
não uma lista vazia.

### A ponte

`distribuirConversaNova`, em `index.js`. **Nunca segura a mensagem**: ela já
entrou. Sem o script, a primeira resposta "a função não existe" desliga isto
até a ponte reiniciar, com uma linha no log; **um tropeço qualquer NÃO
desliga** — a próxima mensagem do mesmo cliente pergunta de novo. O log diz
para quem a conversa foi e, quando o departamento está ligado e ninguém do
rodízio vê o telefone, diz isso — é a única recusa que é configuração; "já
tem responsável", "desligada" e "a equipe já agiu" são o dia a dia e não
enchem o log.

**O aviso de mensagem nova não mudou** (ele é do painel): enquanto ninguém
responde, todo mundo continua sendo avisado.

**Um caso de borda conhecido, e aceito:** "Nova conversa" no painel grava a
conversa antes de a primeira mensagem sair. Se o cliente escrever nesse
intervalo, sem nada nosso na fila ainda, a conversa vai para o rodízio. É
raro, e o "Assumir" do menu resolve.

### As provas

**Seção 61 — o 023 num Postgres de verdade, obrigatória na integração
contínua** (37 conferências): sobre um esquema do Zorvin com `zorvin_admin` e
`pode_ver_conversa` copiadas dos scripts de `sql/`. **E ela existe porque a
51l-bis não basta:** num banco limpo o 023 sai cedo, por não achar as tabelas
do Zorvin, e o corpo das funções — que é `plpgsql`, conferido só ao rodar —
nunca rodaria na integração contínua. As cenas mais longas, que a semente
desta seção encurtou, rodaram à parte (77 conferências) antes de virar seção.
**16 sabotagens do script, 16 pegas pela seção 61**, todas limpas (a trava
tirada; quem administra entrando sem escolher; quem vê o departamento e não o
telefone; a vez ao contrário; sem perguntar se a equipe agiu; a conversa com
histórico tratada como nova; a mensagem antiga distribuída; o Zorvin
assinando como quem recebeu; quem saiu recebendo; a regra esquecendo o
telefone; a chave do departamento ignorada; quem entrou chamando a decisão; a
lista sem a recusa; as férias que não valem; sem as duas guardas do dono; a
lista trazendo quem saiu).

**Seção 60 — a ponte** (20 conferências), **11 sabotagens e 11 pegas** (não
perguntar; perguntar depois da resposta automática; perguntar antes de
gravar a mensagem; sem a guarda da função que falta; qualquer erro
desligando; grupo e mensagem nossa perguntando; o contato no lugar da
conversa; o log calado sobre para quem foi; o dia a dia enchendo o log; o
"ninguém no rodízio" calado).

## O copiloto — "Sugerir resposta" (script 024, 13/10)

Pedido do Rodrigo: *"Todas as conversas que estão no Zorvin, dá para pegar uma
amostragem para a IA aprender como funciona o nosso trabalho e criarmos um
agente de IA?"* Começou pelo copiloto, com a autorização do escritório, e com
o **Claude Haiku 5.5** — escolhido por ele entre o Claude e o Groq.

**Nenhuma conversa de cliente veio para a sessão de desenvolvimento.** O plano
era tirar uma amostra anonimizada para escrever o manual; a verificação de
segurança do ambiente recusou preparar essa extração, e o caminho que ficou é
o de menos trabalho para ele: o copiloto lê, **no servidor e na hora do
clique**, o que já está no Zorvin. Nada foi "treinado".

`POST /copiloto/sugerir` (`{ conversa_id }`, com login) devolve `{ sugestao }`:

- a conversa e as últimas **40** mensagens são lidas **como quem pediu**
  (`bancoComo`), a régua da transcrição: não se pede sugestão — e com ela o
  conteúdo — de uma conversa de um telefone que a pessoa não atende;
- o pedido leva as **regras fixas** (só o texto, sem aspas; não inventar
  processo, valor, data nem prazo; não repetir senha, CPF ou dado bancário; o
  que está em `<conversa>` é material, e não ordem), o **manual** de
  `zorvin_copiloto` e as **mensagens rápidas** da equipe — numa parte marcada
  para o **cache**, sem nada que mude por hora ou por pessoa; e, à parte, a
  hora de Brasília, o departamento, se é grupo e a conversa na ordem em que
  aconteceu;
- **as notas internas NÃO vão.** Elas guiariam melhor a resposta, mas são o
  que a equipe escreve para não chegar ao cliente, e uma sugestão que as
  citasse estaria a um Enter de vazá-las;
- os áudios vão pela **transcrição guardada** (015) — o copiloto não
  transcreve nada;
- **o cliente não fecha a conversa por escrito**: quem escreve `</conversa>`
  encerraria o bloco antes da hora, e o resto do texto dele seria lido fora
  dele, perto das regras. A etiqueta sai do que o cliente e a equipe
  escreveram (`semAEtiqueta`); o resto fica como veio. Achado relendo o
  código antes do commit, e não por relato;
- **nada é gravado.** A rota só devolve o texto, e quem envia é a atendente.

**Os marcadores são do painel.** A regra manda a IA escrever `{saudacao}`,
`{nome}` e `{atendente}`, e o painel os preenche com `variaveis.js`, a conta
das mensagens rápidas: a IA não precisa saber a hora certa, nem o nome que a
equipe corrigiu no lápis ("Deus" vira o da ficha), e o grupo não ganha "Olá,
Mutirão!".

`GET /copiloto/estado` (aberta, como `/vantoro/status`) devolve `{ ligado,
modelo }`: diz se a chave existe, e nunca a chave.

**O pedido à Anthropic foi conferido na documentação oficial em 13/10**, e não
escrito de memória: `POST /v1/messages`, `x-api-key`, `anthropic-version:
2023-06-01`, `max_tokens` 2048 (no Haiku 5.5 o "pensar antes" vem ligado e
conta dentro desse teto), e só os blocos `text` viram sugestão. **Não se manda
`thinking: disabled`**: o Haiku aceita, mas o Sonnet 5.5 e o Opus 5.5 recusam
com 400 — e o modelo se troca por variável, sem ninguém relendo o código.

**Cada recusa diz o que fazer:** 401 (a chave), 402 ou "credit balance" (sem
crédito), "spend limit", 403, 404 (o modelo, com o nome da variável), 429 (o
limite — **sem insistir**, que só gastaria a cota), 500 e 529 (sobrecarregada —
**uma** segunda tentativa: pedir de novo não tem efeito colateral), 504, a
recusa da própria IA (`stop_reason: refusal`) e a resposta em branco. **Dois
cliques juntos são uma ida** (`sugestoesEmVoo`, por pessoa e conversa).

**Sem o 024, sugere sem o manual**, e o log diz qual script falta. **Com a
tabela e a leitura falhando, não sugere**: sugerir sem as regras que o
escritório escreveu, calado, é a ausência no lugar da falha.

**O log só leva números** — tempo, mensagens lidas, tokens e quanto veio do
cache —, nunca o que o cliente escreveu nem o que a IA sugeriu.

**O custo**, pela tabela oficial de 13/10: o Haiku 5.5 sai a US$ 0,10 por
milhão de tokens de entrada e US$ 0,50 de saída — uns **US$ 5 por mês** para
~300 cliques por dia.

**O script 024** (`zorvin_copiloto`): uma linha só (`check (id)`), o manual
com teto de 8000 caracteres; lê quem entrou, muda quem administra
(`zorvin_admin()`), ninguém apaga nem insere; `atualizado_em` e
`atualizado_por` são do **gatilho**. O modelo inicial é genérico, sem conversa
de ninguém, e **só entra na rodada que cria a tabela** (regra 5): a linha que
sumir volta **vazia**. **A guarda pede `conversas` também** — o 001 e o 002
deixam `usuarios` e `zorvin_admin()` até num banco sem o Zorvin, e foi a
51l-bis que cobrou: o manual nascia ali preso a `usuarios`, e a cena que apaga
`usuarios` parou de rodar.

Provas: seção 62 (a rota, 53 conferências, com um Claude de mentira que guarda
cada pedido) e 63 (o 024 num Postgres de verdade, 18, cada regra tentada no
papel de quem atende). **39 sabotagens e 39 pegas**, todas limpas, rodadas em
cópias. **Uma vazou primeiro, com razão:** semear "por cima" dentro do `if` da
rodada que cria não muda nada — a régua de 25/09. O defeito de verdade é
semear em toda rodada, e esse é pego por duas conferências.

**E a rodada em paralelo atropelou portas.** Com seis cópias ao mesmo tempo, a
porta "livre" que `portaLivre` devolve pode ser tomada por outra cópia antes de
a ponte subir nela — e a prova passa a conversar com a ponte da outra cópia.
Duas pegas trouxeram, além da conferência certa, falhas de assunto alheio
("sem crédito" numa cena que não mandava isso). **Cada pega foi lida**, e a
conferência certa estava em todas; a suíte normal, uma prova de cada vez, não
tem esse atropelo. Pega se lê, e não só se conta.

### O resumo da conversa — "Resumir" (01/11)

Pedido do Rodrigo, da lista de recomendações de 31/10: *"…em seguida pode
continuar com a recomendação 4"* — *"Um botão 'Resumir' que diz em poucas linhas o que o
cliente quer, o que já foi combinado e o que falta. Serve para quem pega a
conversa de uma colega e para o cliente que volta depois de semanas. Usa a
mesma chave do copiloto."*

`POST /copiloto/resumir` (`{ conversa_id }`, com login) devolve
`{ resumo: { quer, combinado, falta }, mensagens, notas, cortou, ate, avisos }`.
A mesma chave, o mesmo modelo e a mesma ida à Anthropic do copiloto
(`ANTHROPIC_API_KEY`, `COPILOTO_MODELO`, `pedirAoClaude`). **Nada é gravado**:
o painel mostra o resumo só para quem pediu. **Nenhum SQL e nenhuma variável
nova.**

**O que muda em relação ao copiloto, e por quê:**

| | copiloto | resumo |
|---|---|---|
| o que lê | as 40 últimas | até 300 mensagens e 60 mil caracteres |
| as notas internas | **não vão** | **vão**, marcadas como da equipe |
| a resposta | texto livre | JSON com três partes (`output_config.format`) |
| o manual que falha | não sugere | resume assim mesmo |

- **As notas vão porque o resumo não vai a cliente nenhum.** No copiloto elas
  ficam de fora porque a sugestão entra na caixa de escrever, a um Enter do
  cliente. O resumo é lido pela equipe, e é nas notas que ela escreve o que
  combinou. Cada nota vai como *"Nota interna da equipe (Ana), o cliente não
  viu: …"*, e a regra diz à IA para não escrever que algo foi dito ao cliente
  se só está numa nota. **A nota apagada não vai** (`apagada_em`, filtrada na
  ponte: pedir a coluna pelo nome num banco sem ela daria 42703).
- **A conversa longa é cortada PELO COMEÇO.** Mensagens e notas viram uma
  linha do tempo só, da mais nova para a mais velha, e o teto de caracteres é
  gasto nessa ordem. A leitura pede **301** mensagens: é a de número 301 que
  diz se a conversa é mais longa do que o que foi lido (lendo 300 cravadas,
  uma conversa de 300 sairia como "cortada"). Cortada, a nota de antes da
  janela também fica de fora, o pedido diz à IA que as mais antigas não
  couberam, e o painel recebe `cortou: true`.
- **O formato, e não texto livre**: o painel desenha as três partes sempre do
  mesmo jeito. O formato da Anthropic não aceita teto de itens nem de tamanho
  (`maxItems`, `maxLength`), e por isso o teto mora na volta
  (`resumoDaResposta`): no máximo **8 itens** por lista, **400 caracteres**
  por item (600 no "quer"), **cada item numa linha só**, e o que não é texto
  sai.
- **Esforço médio, escrito** (`output_config.effort: 'medium'`, que é o padrão
  do Haiku 5.5 — mas o padrão muda de um modelo para outro, e o modelo se
  troca por variável), e **`max_tokens` de 8000**: no Haiku 5.5 o "pensar
  antes" vem ligado e conta dentro do teto.
- **O manual vai junto** (para a IA entender "VENDA LN", "JG"), e a leitura dele
  que falha **não impede o resumo**. No copiloto, o manual tem as regras do que
  dizer ao cliente, e sugerir sem elas seria a ausência no lugar da falha;
  aqui ele só ajuda a entender os nomes.
- **As notas que não vieram são DITAS** (`avisos`), e não caladas: um resumo sem
  o que a equipe combinou nas notas se leria como o caso inteiro. **A tabela
  que falta não é aviso** — o recurso não existe ali.
- **`ate`** é o `criado_em` da mensagem mais nova que entrou no resumo. É por
  ela que o painel conta as mensagens que chegaram depois — pelo relógio do
  banco, e não pelo do computador de quem pediu.
- **Cada resposta estranha vira uma frase**, e nunca um resumo inventado: a
  recusa da IA (`refusal`), a resposta cortada no teto (`max_tokens`), o texto
  que não é o JSON, as três partes vazias. A frase da Anthropic que recusa é a
  do copiloto (`explicarFalhaDaAnthropic`).
- **Só números no log**, como no copiloto. O `JSON.parse` que falha cita o
  começo do texto da IA na mensagem de erro, e por isso o log leva só o nome
  do erro.

**`GET /copiloto/estado` ganhou `resumo: true`.** O painel pode chegar ao ar
antes da ponte — em 14/10 a Render passou um dia sem publicar a ponte —, e o
botão de uma rota que ainda não existe daria 404 a cada clique. A ponte de
antes não manda a chave, e o painel esconde só o "Resumir".

**O custo**, pela tabela de preços da Anthropic (a mesma do copiloto: o Haiku
5.5 sai a US$ 0,10 por milhão de tokens de entrada e US$ 0,50 de saída, até 100
mil tokens por pedido): um resumo da
conversa mais longa (60 mil caracteres, uns 20 mil tokens) sai por uns
**US$ 0,003**. Os 60 mil caracteres também deixam o pedido longe dos 100 mil
tokens, acima dos quais o preço do Haiku 5.5 sobe.

Prova: seção 87, 52 conferências, com um Claude de mentira que devolve o JSON.
**28 sabotagens e 28 pegas**, todas limpas, rodadas em cópias e lidas uma a
uma:

- **as notas:** sem as notas (8 reprovações); lidas com a chave da ponte; a
  apagada indo; sem dizer que o cliente não viu; sem a limpeza da etiqueta
  (`</conversa>` dentro da nota);
- **o pedido:** sem o formato; sem o esforço; o teto padrão; a hora no cache;
  sem o manual;
- **a conversa longa:** sem a de número 301; as mais velhas no lugar das mais
  novas; o teto de caracteres cortando o fim; sem dizer à IA que cortou; a nota
  de antes da janela;
- **a volta:** a recusa ignorada; o corte ignorado; os itens com quebra de
  linha; sem o teto de itens; o resumo vazio virando resumo; o log com o texto
  da IA;
- **o resto:** a falha das notas calada; a tabela que falta avisando; o manual
  que falha impedindo o resumo; o estado sem `resumo: true`; sem juntar os
  cliques; as mensagens lidas com a chave da ponte; o `ate` na mensagem mais
  velha.

**Duas conferências foram apertadas antes das sabotagens**, relendo: a do log
procurava um trecho do meio do texto da IA, e o `JSON.parse` só cita o começo
— a sabotagem que põe a mensagem de erro no log passaria. E a do
`</conversa>` só olhava a mensagem do cliente, e não a nota.

### O assunto do Finalizar — a IA sugere (01/11)

Pedido do Rodrigo, da lista de recomendações de 31/10: *"Siga para a
recomendação 5"* — *"A IA sugere o assunto no Finalizar. A lista já abre com o
assunto provável marcado, e a pessoa só confere. Finalizar fica mais rápido, e
o relatório mais certo."*

`POST /copiloto/assunto` (`{ conversa_id }`, com login) devolve
`{ assuntos: [{ id, nome }], motivo, mensagens, notas, atendimento }`. A mesma
chave, o mesmo modelo e a mesma ida à Anthropic do copiloto. **Nada é gravado
aqui**: quem marca é o painel, e só se a pessoa ainda não mexeu na lista. O que
vai ao banco é o clique da pessoa, com a sugestão junto (script 042, logo
abaixo).

**Medido em 01/11, só contando:** 346 cliques de "Já tratei" nos 14 dias
anteriores (uns 25 por dia), com 1,05 assunto por clique; só 15 dos 346 (4%)
marcaram mais de um. Por isso a regra diz *"quase sempre é um só"*, e o teto
é dois.

**O que muda em relação ao resumo, e por quê:**

| | resumo | assunto |
|---|---|---|
| o que lê | até 300 mensagens | o atendimento de agora (até 60 mensagens), e as 10 de antes dele |
| a resposta | três partes | os assuntos da lista, presos pelo formato, e um porquê |
| esforço | médio | baixo: é uma escolha numa lista curta |
| teto | 8000 | 2048 |

- **O atendimento de agora.** O assunto de um Finalizar é o do protocolo que
  está sendo fechado, e não o da conversa de dois anos. Com o 028, a marca é o
  `aberto_em` do atendimento mais recente da conversa
  (`comecoDoAtendimento`). Do que veio antes vão só as dez últimas, como
  contexto. **A mensagem que abriu o protocolo é do atendimento de agora**
  (`>=`): ela tem a mesma hora do `aberto_em`.
- **A marca na conversa.** A IA lê *"--- Aqui começa o atendimento de agora
  (protocolo X) ---"* antes do primeiro item dele, e só quando há o que ficou
  antes. **O primeiro item do atendimento decide, haja marca ou não.** Na
  primeira escrita, a marca caía depois da primeira mensagem do atendimento
  que é a conversa inteira, e foi a prova que achou.
- **Sem a marca, as quarenta últimas**, como no copiloto: sem o 028 (calado),
  ou com a leitura do atendimento falhando (o log diz). A marca ajuda, e não é
  condição.
- **Os nomes presos à lista.** O formato da resposta leva os nomes dos
  assuntos ativos num `enum`, na ordem da lista: a IA não tem como devolver um
  assunto que não existe. A ordem estável é o que deixa a Anthropic
  reaproveitar o formato já compilado (ele fica guardado 24 horas); trocar a
  lista custa uma compilação a mais na primeira sugestão seguinte.
- **Na volta, conferido de novo** (`sugestaoDeAssuntoDaResposta`): cada nome é
  procurado na lista, **o nome exato primeiro**, e só depois a chave sem acento
  (a régua do 025). Dois assuntos que só diferem no acento podem existir (o
  índice do 005 é por `lower`, que guarda o acento), e a chave sozinha
  escolheria um deles no chute. O que não casa sai, o repetido sai, e são no
  máximo dois. O porquê vai numa linha, até 240 caracteres.
- **Na dúvida, nenhum.** A regra manda devolver a lista vazia quando a conversa
  não diz o assunto (só cumprimento, só agradecimento). É a régua da leitura
  das douradas: marcar o assunto errado é pior do que não marcar, porque quem
  confere com pressa confirma o que já veio marcado.
- **As notas vão**, como no resumo, porque a sugestão não vai a cliente
  nenhum. A apagada não vai, e a de antes da mensagem mais velha lida também
  não.
- **O nome do assunto não fecha a lista por escrito.** No texto que vai à IA,
  `<`, `>` e quebra de linha viram espaço (quem escreve os nomes é quem
  administra, pela tela); o formato leva o nome inteiro.
- **Cada falha diz o que fazer**, e nenhuma vai à Anthropic: sem a lista (005),
  409; a lista que falha, 502 com o código; nenhum assunto ativo, 409; a
  conversa ou as mensagens que falham, 502 com o código. **As notas e o manual
  que falham não impedem** a sugestão, e o log diz.
- **Cada resposta estranha da IA vira uma frase**: a recusa (*"Marque à
  mão"*), o corte no teto, o texto que não é o JSON. Do `JSON.parse` que falha,
  o log leva só o nome do erro: a mensagem dele cita o começo do texto da IA.
- **Dois pedidos juntos são uma ida** (`assuntosEmVoo`, por pessoa e
  conversa): a janela aberta, fechada e aberta de novo antes de a resposta
  chegar.
- **`/copiloto/estado` ganhou `assunto: true`.** A ponte de antes não diz, e a
  janela do Finalizar abre como sempre abriu, sem pedir à IA.
- **O custo**, pela tabela do copiloto (US$ 0,10 por milhão de tokens de
  entrada e US$ 0,50 de saída no Haiku 5.5): o pedido mais longo (30 mil
  caracteres, uns 10 mil tokens) sai por uns US$ 0,001. Com 25 por dia, menos
  de US$ 1 por mês.

#### A sugestão fica gravada (script 042)

`sql/automaticos/042-a-sugestao-do-assunto-fica-gravada.sql` acrescenta
`zorvin_tratamentos.sugestao_ia` (jsonb, opcional): `{"assuntos": [ids],
"marcou": true|false}`, igual em todas as linhas do clique e nula sem
sugestão. `marcou` diz se a janela marcou sozinha ou se a sugestão chegou só
como dica, com a pessoa já marcando. **É o que dá para medir o acerto
depois**: sem isso, uma sugestão que erra muito, confirmada por quem conferiu
com pressa, vira o assunto errado no relatório sem ninguém saber.

- **Uma regra:** objeto, de no máximo 2000 caracteres. Quem grava é a tela de
  quem atende, e a coluna não pode virar depósito de outra coisa.
- **Nenhuma permissão nova.** Conferido no banco do escritório em 01/11: o
  INSERT de `zorvin_tratamentos` é da tabela inteira para `authenticated`, e
  vale para a coluna nova. A conferência pergunta isso ao banco no papel de
  quem atende (`has_column_privilege`).
- **A conferência conta cliques, e não linhas** (`count(distinct (conversa_id,
  quem, quando))`): o clique de dois assuntos são duas linhas.
- **Sem o 042, o painel grava o clique sem a coluna**: a sugestão some do
  registro, e o registro não se perde.

Provas: seção 88 (a rota, 66 conferências, com um Claude de mentira) e seção
89 (o 042 num Postgres de verdade, 15, com o defeito conferido antes: gravar a
coluna antes do 042 dá 42703, que é o caso que o painel contorna).

**50 sabotagens e 50 pegas**, todas limpas, rodadas em cópias e lidas uma a
uma:

- **o estado e quem lê:** o estado sem `assunto: true`; as mensagens lidas com
  a chave da ponte, e o atendimento também; a lista sem o filtro dos ativos, e
  sem a ordem dela;
- **o pedido:** o formato sem o `enum`; o esforço médio; a hora no cache; sem
  o manual; o nome do assunto sem a limpeza; o grupo nunca dito;
- **o atendimento de agora:** o atendimento mais antigo no lugar do mais
  recente; sem as dez de antes, e com todas; a mensagem que abriu o protocolo
  fora dele (`>` no lugar de `>=`); a marca sempre; o laço da primeira escrita
  (a marca depois da primeira mensagem); sem as quarenta;
- **as notas e o teto:** a nota apagada indo; a nota de antes das mensagens
  lidas indo; o teto cortando o fim; as notas contadas como mensagens;
- **a volta da IA:** só a chave sem acento, com o primeiro da lista vencendo e
  com o último; sem conferir contra a lista; sem o teto de dois; sem tirar o
  repetido; o porquê com quebra de linha, e sem teto; a recusa e o corte
  ignorados; o log com o texto da IA;
- **os pedidos juntos:** sem juntar; e sem tirar do mapa (12 reprovações: o
  pedido seguinte recebe a resposta guardada do anterior);
- **as falhas:** a falha da lista virando "não tem lista", e a tabela que
  falta virando falha; a falha das notas impedindo a sugestão, e calada; a
  falha do atendimento derrubando a sugestão; o manual que falha impedindo; a
  falha das mensagens calada; a falha da conversa virando "não achei";
- **o 042:** sem a regra da forma; sem o teto de 2000; a regra e a coluna sem
  a guarda da segunda rodada; a conferência contando linhas; sem a guarda do
  banco limpo; a tabela da conferência depois da guarda; a conferência sem
  perguntar ao banco.

**Duas pegavam com a seção estourando no meio, e a culpa era da prova.** Com a
segunda rodada do 042 recusada, a resposta era o erro, e não a lista, e o
`.find` num objeto derrubava a seção 89 antes de as conferências seguintes
dizerem o nome delas. Hoje os ajudantes conferem que é uma lista (`lista`, a
régua das seções vizinhas), e as duas são pegas por três conferências cada.

**Duas lições desta rodada, as duas de processo:**

- **A sessão foi reiniciada no meio, e o que não estava no GitHub sumiu**: a
  rota inteira e o script, escritos e ainda sem commit. O reinício traz o
  repositório de novo, limpo. **Trabalho em curso vai para o ramo remoto
  cedo**, em commits de rascunho (a PR junta tudo num só ao mesclar).
- **O caractere invisível tem uma causa, e agora se sabe qual.** A ferramenta
  que grava o arquivo recebe o texto em JSON, e no JSON a escrita `\u0300` é o
  próprio caractere de acento: escrito assim, ele chega ao arquivo convertido.
  Foi o que aconteceu de novo aqui, e é a mesma armadilha que o painel já
  registrou duas vezes. **Depois de escrever uma expressão com escapa de
  acento, confira os bytes do arquivo.**

## Aguardando, em aberto e finalizados (script 028, 19/10)

Pedido do Rodrigo: o que o DataCrazy faz nas conversas, *"para facilitar a
organização"* — três abas que separam a lista, e um protocolo por
atendimento. `sql/automaticos/028-aguardando-em-aberto-e-finalizados.sql`.

Decidido com ele: o **"Já tratei" vira o "Finalizar"** (um botão só, com a
mesma checklist, e o relatório continua contando); **o que já existe não muda
de sentido** (*"o que estiver como Já tratei fica como finalizado. Caso o
cliente tenha enviado mensagem após já ter sido finalizado, então a conversa
deve ficar aberta novamente, porém já com a tratativa"*); Aguardando e Em
aberto são **abas separadas**; e o protocolo é **só da equipe**.

**Os nomes das abas na tela mudaram em 20/10**, a pedido do Rodrigo:
"Aguardando" virou **"Novos"** e "Em aberto" virou **"Em Atendimento"**. Os
valores do banco (`conversas.situacao`) continuam `aguardando`, `aberto` e
`finalizado`: trocar o nome é coisa da tela, e trocar o valor seria regravar
cada conversa e mexer nos gatilhos daqui.

### As regras

| a conversa | fica |
|---|---|
| a equipe **nunca agiu** nela (nenhuma mensagem nossa, nem do celular; nenhum "Já tratei" que valha) | **aguardando** |
| a equipe já agiu, e o atendimento de agora não foi fechado | **em aberto** |
| o atendimento de agora foi fechado por um "Já tratei" | **finalizada** |

- **A resposta automática fora do horário não é gente**, e mora fora de
  `mensagens`: não tira ninguém de "aguardando".
- **Só o cliente reabre sozinho.** A mensagem do cliente depois da
  finalização abre um **atendimento novo, com protocolo novo**, e a conversa
  volta para *em aberto* — e não para *aguardando*: "o cliente em si já foi
  tratado". A mensagem da equipe numa finalizada não reabre nada (é o
  "obrigado, até mais" depois de finalizar).
- **A mensagem atrasada com data de antes da finalização não reabre** — a
  régua da fila de espera (005): o que o cliente escreveu antes do "Já
  tratei" está coberto por ele.
- **Finalizar tira da fila de espera**, em toda finalização: o gatilho grava
  `tratada_em` e apaga `esperando_desde`. Antes, o "Já tratei" de uma conversa
  respondida só registrava — e uma finalizada dizendo "esperando há 5 dias"
  seria a aba e a fila dizendo coisas opostas.

### O Reabrir tem dois sentidos, e os dois existem

- **Reabrir, para continuar** — o pedido do DataCrazy. Em aberto, com
  **protocolo novo**; a finalização de antes **continua contando**. A tela
  pede gravando `situacao = 'aberto'` numa finalizada.
- **Desfazer, porque foi engano** — o "Voltar para a fila" de sempre (marcar
  o clique como desfeito). O **mesmo** atendimento volta a ficar aberto, e o
  relatório deixa de contá-lo. Se outro clique sobrou nele (duas pessoas
  finalizaram juntas), continua fechado pelo que sobrou.

**Reabrir para continuar não desfaz o registro de ninguém**, e é decisão: um
"Reabrir" que apagasse do relatório o "Já tratei" de verdade de uma colega,
só porque alguém quis voltar a falar com o cliente, seria trabalho sumindo
calado.

### Quem escreve a situação é o banco

`conversas.situacao` e `conversas.protocolo` ficam na própria conversa — a
lista filtra por elas, e o tempo real já leva a mudança a todo painel —, mas
quem as escreve são os gatilhos: a mensagem que entra
(`zorvin_situacao_da_mensagem`), o clique (`zorvin_situacao_do_clique`,
**antes** de gravá-lo, para ligar o clique ao atendimento em
`zorvin_tratamentos.atendimento_id`) e o clique desfeito
(`zorvin_situacao_desfeita`).

**A guarda** (`zorvin_situacao_guardada`, `before update of situacao,
protocolo`) recusa com 42501 qualquer outra mudança feita pela tela. Passam:
os gatilhos (gravam de dentro de outro gatilho — `pg_trigger_depth() > 1`) e
quem não entrou (`auth.uid()` nulo: a ponte, o editor, a montagem). Ela só
dispara quando a gravação **menciona** as duas colunas: a prévia, as não
lidas e a espera, que mexem na conversa a cada mensagem, nem passam por ali.

`zorvin_atendimentos` é o histórico, um por protocolo (`2026-000123`: o ano
de quando começou, no fuso de São Paulo, e um número que só cresce — **e
nunca é cortado**: `lpad` corta o texto maior que a largura, e o milionésimo
viraria o número de outro). Quem entrou **lê** os das conversas que vê e
**não escreve nenhum** — a tabela nasce aberta pela herança da Supabase, e
tudo é tirado antes de a leitura ser devolvida.

**O número ao lado de cada aba** vem de `zorvin_contar_situacoes(p_telefone)`,
uma pergunta só (`security invoker`: conta o que quem pergunta enxerga). Fica
de fora o que a lista também não mostra — a arquivada e a conversa sem
mensagem —, senão o número diria uma coisa e a lista outra. `arquivada` vem
por `to_jsonb`: a coluna foi criada à mão e não está em script nenhum, e uma
função `sql` que a citasse pelo nome não seria criada num banco sem ela.

**E as não lidas de cada aba vêm na mesma resposta** (`nao_lidas`): a pílula
"Não lidas" do painel filtra a lista DA ABA, e com o número do telefone
inteiro ela diria 10 numa aba em que o filtro mostra 6 — as outras 4 parecem
ter sumido, quando estão na aba ao lado.

**A ponte só faz uma coisa nova:** depois de juntar duas conversas
(`mudarDeConversa`), pede `zorvin_recontar_situacao` para a conversa que
fica. Mudar mensagem de casa é um UPDATE, e o gatilho só vê mensagem que
entra: sem a conta, a finalizada que recebeu da outra uma pergunta do cliente
continuaria nas finalizadas. Sem o 028, a função não existe e nada muda.

### A montagem, e as travas do começo

Na rodada que **cria** a tabela, cada "Já tratei" não desfeito fecha um
atendimento e o que o cliente escreveu depois abre o seguinte; os protocolos
saem numerados **pela data** em que cada atendimento começou. **Rodar de novo
não renumera nada** — protocolo que muda de número deixa de ser protocolo. O
que rodar de novo faz é **consertar** quem ficou fora da regra
(`zorvin_situacao_fora_da_regra`, a mesma pergunta da conferência).

**As travas do começo são a ordem do webhook**: `zorvin_tratamentos` e
`mensagens` primeiro, `conversas` depois. **Medido na sabotagem que as
tira:** a mensagem que chega no meio da instalação trava com ela — o
Postgres derruba uma das duas com `deadlock detected`. Com as travas, o
webhook espera um segundo e entra com o gatilho já valendo.

Medido num banco do tamanho do escritório (2.500 conversas, 100 mil
mensagens): a instalação leva **0,8 s**, e o gatilho custa ~0,08 ms por
mensagem.

### O que isto não faz, ainda

~~A **contabilização** do DataCrazy (relatório por protocolo, tempo até a
primeira resposta, tempo até finalizar). Os campos nascem aqui (`aberto_em`,
`primeira_resposta_em`, `finalizado_em`); a tela, não.~~ **Feita** — ver "A
contabilização dos atendimentos (script 029, 20/10)", logo abaixo.

### As provas

Seção 67, num Postgres de verdade, obrigatória na integração contínua:
**79 conferências, 35 sabotagens e 35 pegas**, todas limpas, rodadas em
cópias e lidas uma a uma. E a 57c-bis e a 57c-ter, da junção: **5 sabotagens
e 5 pegas**.

**Três vazaram primeiro, e as três eram minhas:**

- **A trava da conversa** (`for update`) vazou porque o gatilho da espera
  também trava a mesma linha, por acaso, antes do nosso. A cena das duas
  mensagens ao mesmo tempo desliga o gatilho da espera: quem segura a
  corrida tem de ser a trava do 028, e não um efeito colateral de outro
  script.
- **A finalizada fora da fila estava escrita em dois lugares** — na montagem
  e no conserto do fim —, e um cobria a falta do outro: as duas sabotagens
  vazavam. Ficou uma escrita só (o conserto), e a sabotagem que a tira é
  pega.

**E duas sabotagens pegavam estourando a prova** — uma conferência lia o
segundo atendimento que a sabotagem não deixava existir. Prova que estoura
não diz qual conferência viu o defeito: os acessos passaram a ser guardados.

## A contabilização dos atendimentos (script 029, 20/10)

Pedido do Rodrigo, depois das abas do 028: a "contabilização" do DataCrazy —
quantos atendimentos houve, quanto o cliente esperou pela primeira resposta e
quanto levou até finalizar.
`sql/automaticos/029-a-contabilizacao-dos-atendimentos.sql` cria
`zorvin_relatorio_atendimentos(p_desde, p_ate, p_quem, p_fuso, p_telefone,
p_departamento, p_limite)`. A tela é a seção "Protocolos de atendimento", no
alto do Painel de números (ver o CLAUDE.md do painel).

**Um atendimento é um protocolo, e ele só entra no total quando a equipe
começa**: alguém respondeu, alguém finalizou, ou foi a própria equipe que
abriu (a conversa começada por nós, o Reabrir). É a regra que o Rodrigo
copiou do DataCrazy: *"as mensagens que permanecem com o status de Aguardando
não somam no volume de 'Quantidade Total' até que a interação humana de fato
comece"*. O protocolo que o cliente abriu e em que ninguém mexeu vem à parte,
como **esperando resposta**.

**O cliente que volta é decisão.** A conversa finalizada em que o cliente
escreve de novo vai para "Em Atendimento" (o 028), mas o protocolo novo dela
só entra no total quando alguém responder: contá-lo antes seria contar
trabalho que ainda não aconteceu. É a mensagem que "não teve resposta", nas
palavras dele.

| | o que é |
|---|---|
| total | protocolos abertos no período em que a equipe começou |
| em atendimento | começados e ainda não finalizados |
| finalizados | fechados pelo "Finalizar" — o total é a soma dos dois de cima |
| esperando resposta | abertos pelo cliente e que ninguém tocou — fora do total |
| até a primeira resposta | só nos que o CLIENTE abriu: nos nossos e no Reabrir não houve espera |
| até finalizar | da abertura do protocolo ao "Finalizar" |

**O período é o da abertura, para tudo**: um eixo só faz as contas fecharem.
**O período anterior, do mesmo tamanho, vem só para o total** — comparar
quantos ainda estão em atendimento entre dois meses mediria só que o mês
velho teve mais tempo para ser finalizado. Os tempos vêm em segundos, com
mediana e média.

**Quem deu a primeira resposta** sai da mensagem que o 028 anotou
(`primeira_resposta_em`): `enviado_por_id`; a mandada pelo celular
(`enviado_por` = "WhatsApp", sem id) vira a linha **"Pelo celular"**; a de
antes de ago/2026, sem id, vale pelo nome. As duas colunas vêm por
`to_jsonb(m)`, porque nasceram à mão em `sql/` — e em `mensagens` isso é
seguro: nenhuma coluna dela é fechada (a régua do 012).

**Quem não administra recebe os de que participou** (respondeu primeiro,
finalizou ou reabriu), com o recorte feito aqui; os tempos são de quem fez; o
"esperando resposta" vem nulo, porque ainda não é de ninguém. O "por pessoa"
mostra todo mundo, para comparar. **Sem sessão o recorte continua ligado**:
`v_so_meu` é separado de `v_quem`, e o `auth.uid()` nulo não vira "todo
mundo". `security invoker`, e de `advogados` só `departamento_id`, pelo nome.

**Sem o 028, `{"falta": "028"}`**, e não números zerados — que se leriam como
"ninguém atendeu ninguém". **A conferência chama a função como
`authenticated`**, sem filtro, com um telefone e com um departamento: a régua
do 012 e do 019.

Prova: seção 68, num Postgres de verdade, obrigatória na integração contínua:
**52 conferências**, sobre dez protocolos com as contas feitas à mão (o
celular, o nome antigo, o Reabrir, o cliente que voltou, o SDC que a atendente
não vê) e com a chave da Uazapi **fechada** em `advogados`, como em produção —
é nela que se vê se a função lê a linha inteira do telefone. **23 sabotagens,
22 pegas e uma que vaza com razão**, todas rodadas em cópias e lidas uma a
uma. A que vaza tira a guarda do "sem sessão": sem sessão, a regra de acesso
de `conversas` já não deixa ver nada, e o recorte da função é a segunda
guarda — a régua de 25/09.

**Duas lições da primeira rodada:**

- **a conferência que rodava como dona do banco passava.** A sabotagem que
  tirava a troca de papel vazou, porque nenhuma cena fazia a função quebrar
  SÓ para quem atende. Entrou a cena que tira de `authenticated` a leitura da
  vista `equipe`: a conferência tem de dizer "NÃO — permission denied", e diz;
- **duas sabotagens estouravam a seção** em vez de reprovar pelo nome — um
  campo lido de uma resposta que já tinha falhado, e uma conferência que
  esperava lista e recebeu o erro. Os acessos passaram a ser guardados.

## Quem está esperando demais (script 041, 31/10)

Pedido do Rodrigo, da lista de recomendações de 31/10: *"Pode seguir para a
segunda recomendação"* — um aviso quando um cliente passa de alguns minutos
sem resposta no expediente, e, ao abrir o Zorvin, as conversas de cada pessoa
esperando há 3 dias ou mais. A segunda metade é só do painel (ver o CLAUDE.md
dele); a primeira precisa do banco, porque o expediente mora nele.
`sql/automaticos/041-quem-esta-esperando-demais.sql`.

**Medido em 31/10, só contando**, nos 30 dias anteriores e só nos atendimentos
que o cliente abriu (sem grupos):

| | |
|---|---|
| abertos dentro do expediente | 297 |
| respondidos em até 30 minutos | 57 (19%) |
| mediana até a primeira resposta | 1 h 46 min |
| sem resposta nenhuma | 118 (40%) |

E 596 conversas esperando há 3 dias ou mais: 193 com responsável (17 pessoas,
de 1 a 56 cada) e 403 sem — 315 delas paradas há mais de um mês.

| peça | o quê |
|---|---|
| `zorvin_minutos_no_expediente(semana, fuso, desde, ate)` | quantos minutos de expediente há entre duas horas, dia a dia, pela régua de `zorvin_expediente_do_dia` (021) — que já sabe dos feriados |
| `zorvin_aviso_de_espera` | por departamento: ligado ou não, e depois de quantos minutos (de 5 a 480). **Sem linha, vale o padrão: ligado, 30** |
| `zorvin_clientes_sem_resposta()` | os clientes que abriram um atendimento e esperam a primeira resposta há mais que o limite do departamento, contado só no expediente |

**A lista:** o atendimento de agora (`conversas.protocolo`), aberto pelo
cliente, sem primeira resposta e sem finalização; aberto nos últimos 7 dias
(o pior caso de 30 minutos de expediente: sexta à noite, feriado na segunda);
sem grupo, conversa arquivada nem linha desativada; com o aviso ligado no
departamento. **`security invoker`**: cada um recebe só as conversas que vê.
De `advogados`, só `ativo` e `departamento_id`, pelo nome — a régua do 012.

**A mesma semana da resposta fora do horário.** O expediente de cada
departamento já morava em `zorvin_fora_do_horario.semana` (021), e os quatro
departamentos do escritório têm a sua escrita (medido em 31/10). Uma segunda
escrita do expediente divergiria dela no primeiro feriado. **Sem semana
escrita, conta o relógio inteiro**: calar o aviso por isso seria o cliente
esperando sem ninguém saber. A semana toda fechada é escolha, e vale: nada
soma.

**Quem é avisado é decisão do painel**, pela régua do aviso de mensagem nova:
a conversa com responsável avisa só ele; a sem responsável, todo mundo que a
vê. Por isso a função devolve o `responsavel_id`, e não recorta por ele.

**Ligado desde a publicação, e é decisão.** A resposta fora do horário e a
distribuição nasceram desligadas porque falam com o cliente ou dão trabalho a
alguém sem ninguém ter escolhido. Este aviso só toca para a equipe, e foi
pedido. Quem administra desliga por departamento, na aba Aviso de espera do
painel.

**30 minutos, e não 15 nem 60.** Dos clientes do expediente, 14% tinham
resposta em 15 minutos, 19% em 30 e 24% em 60. Quantos avisos tocam quase não
muda — a maioria espera horas —; o que muda é quando.

**A herança sai inteira da tabela antes de dar só o que a tela usa** (ler,
criar, mudar): `truncate` não passa pela regra de acesso, e quem entrou o
herdaria com a tabela. Ninguém apaga linha: voltar ao padrão é escrever 30.

**O primeiro dia útil com o aviso valendo é terça, 03/11**: segunda, 02/11, é
Finados, que já está entre os feriados do 021.

**A ponte não faz nada com isso.** É banco e painel.

Prova: seção 86, num Postgres de verdade, sobre o 004, 005, 006, 008, 020,
021 e 028 aplicados a partir dos próprios arquivos — 56 conferências: a conta
(feriado, fim de semana, o fuso de Manaus, sem semana, a semana fechada, os
segundos que não arredondam), um cliente por caso na lista, o telefone que a
pessoa não vê, a configuração e quem pode mudá-la, a conferência no papel de
quem atende, e rodar de novo sem desfazer a escolha de ninguém. **28
sabotagens e 28 pegas**, todas limpas, rodadas em cópias e lidas uma a uma.

**Uma vazou primeiro, e a culpa era da prova.** Tirar `anon` da conta dos
minutos passava: a conferência chamava a função como quem não entrou, e a
chamada estourava assim mesmo — na função do 021, que ela usa por dentro e
que já é fechada. Hoje a prova pergunta ao banco quem pode
(`has_function_privilege`), e a conferência do script também. **Para saber
quem alcança uma função, pergunte ao banco, e não chame: a chamada pode
estourar por outro motivo.** E o banco da prova passou a dar `execute` a
`anon` pelo nome em toda função nova, como a Supabase dá (a armadilha nº 5):
sem isso, tirar `anon` do 041 não faria diferença ali, e faria lá.

**E a prova não depende do calendário.** As cenas da lista medem "agora":
elas apagam os feriados e deixam o departamento aberto todo dia, das 00:00 às
23:59. Sem isso, a seção reprovaria em todo feriado nacional.

## Quem não entrou não alcança nada (script 032, 22/10)

Pedido do Rodrigo, depois de ler comigo os avisos de segurança da Supabase:
fechar as funções que até quem não entrou no Zorvin consegue chamar.
`sql/automaticos/032-quem-nao-entrou-nao-alcanca-nada.sql`.

**Medido no banco do escritório, só lendo:**

| | |
|---|---|
| funções com poder de dono (`security definer`) que `anon` chamava | **13** |
| delas, as que fazem alguma coisa quando chamadas pelo nome | 6 — criar um protocolo (`zorvin_atendimento_abre`), gastar um número (`zorvin_proximo_protocolo`), refazer a aba de uma conversa, ler as datas dos atendimentos |
| tabelas abertas para `anon` (ler, gravar, alterar, apagar, esvaziar) | **15**, todas criadas pelos scripts desta pasta |
| política que deixasse `anon` passar | nenhuma — por isso nada vazou |

**A causa das duas é a herança**, a armadilha nº 5 de volta: tudo o que o
`postgres` cria em `public` nasce para `anon`. O arquivo de 09/26 que a
fechava não está valendo, e não dá para saber se não rodou ou se foi
desfeito. **E o 001 já tinha tentado**, só para a função dele: `revoke all …
from public`, com o comentário "ninguém recebe de volta" — e `anon` continuava
lá, porque a Supabase dá a `anon` PELO NOME, e não por `public`.

**O que o 032 faz:**

1. `anon` sai de toda tabela e sequência de `public`;
2. nenhuma função com poder de dono fica para `anon` nem para `public` — e a
   que estava liberada só por `public` é **devolvida** a `authenticated` e
   `service_role` na mesma passada (a régua da armadilha nº 5);
3. as 13 **internas** saem também de `authenticated`: só gatilhos e outras
   funções de dono as chamam. Conferido no banco antes de escrever (`prosrc`
   e `pg_policies`): nenhuma é chamada pelo painel, por política, ou por
   função que roda no papel de quem atende. A ponte continua chamando
   `zorvin_recontar_situacao`;
4. a herança fecha, para o que vier depois.

**Gatilho dispara sem permissão de executar.** O Postgres confere o EXECUTE
ao CRIAR o gatilho, e não ao disparar — por isso tirar as funções de gatilho
de quem atende não muda nada na tela. A prova confere disparando cada um no
papel de quem atende.

**A armadilha que a conferência pegou, na primeira escrita:** tirar `public`
da herança com `in schema public` **não faz nada**. O Postgres dá EXECUTE a
`public` em toda função nova por conta própria, e a herança de um esquema só
ACRESCENTA ao que a geral dá. A função de mentira da conferência continuou
nascendo executável por `anon`. Hoje o `public` sai pela herança geral do
`postgres` (sem `in schema`); `anon` sai pela do esquema, que é onde a
Supabase o pôs.

**A conferência cria uma tabela e uma função de mentira**, dentro da
transação do script, e pergunta quem as alcança — a diferença entre "a regra
diz que não deveria" e "não acontece". E **lê as conversas e chama as funções
do painel no papel de quem atende** (a régua do 012): fechar demais é o outro
jeito de errar isto, e esse aparece na tela de todo mundo.

Prova: seção 73, num Postgres de verdade que imita a herança da Supabase, com
o defeito conferido ANTES do 032 (sem isso a prova aprovaria um banco que
nunca esteve aberto). 48 conferências, **10 sabotagens e 10 pegas**, todas
limpas, rodadas em cópias e lidas uma a uma:

- sem tirar as tabelas;
- sem tirar as sequências;
- as internas ficando para quem entrou;
- tirar `public` sem devolver (o aviso de que algo parou cai para quem atende);
- as internas saindo também da ponte;
- a herança de `public` só no esquema (o engano da primeira escrita);
- sem fechar a herança das tabelas;
- fechar demais: tudo de quem entrou (a leitura das conversas cai);
- só as internas, sem olhar as outras de dono;
- `anon` tirada só das de dono.

**Quatro sabotagens estouraram na primeira rodada**, sem placar: a prova
garante que a ponte passa por cima da regra de acesso (`alter role
service_role bypassrls`), e três cópias fazendo isso ao mesmo tempo se
derrubaram com *"tuple concurrently updated"* — a lição da seção 51. Hoje a
prova só mexe no papel quando falta.

## As mensagens rápidas com anexo (script 034, 23/10)

Pedido do Rodrigo: *"Para as mensagens rápidas, precisa ser possível incluir
vídeos."* `sql/automaticos/034-as-mensagens-rapidas-com-anexo.sql` acrescenta
quatro colunas opcionais a `mensagens_rapidas`: `midia_url`, `midia_tipo`,
`midia_mime` e `midia_nome`. A rápida de sempre continua sendo só texto.

**O arquivo sobe uma vez, ao salvar a rápida**, para `anexos/rapidas/…`.
Usar a rápida põe na fila esse mesmo endereço. Não sobe de novo a cada uso,
pela conta de banda de 21/08 (armadilha nº 6). **A ponte não muda nada**: o
item da fila com `midia_url` sai por `/send/media` como qualquer anexo,
inclusive o segundo caminho em base64.

**Duas regras no banco:**

- o tipo é um dos quatro que a fila conhece (`video`, `imagem`, `documento`,
  `audio`). Um tipo desconhecido viraria uma mensagem que nunca sai;
- endereço e tipo andam juntos. O painel decide pelo tipo como desenhar e como
  mandar, e um endereço sem tipo é uma rápida que ninguém sabe se tem anexo.

**Nenhuma política nova.** Medido no banco do escritório em 23/10:
`rapidas_tudo` vale para quem entrou, em todas as linhas, e a permissão de
`mensagens_rapidas` é da tabela inteira, sem coluna fechada. A conferência
confere as duas coisas no papel de quem atende. **O texto continua `not null`**,
e a rápida só com o vídeo grava `texto = ''`.

**O número era 033 até a hora de enviar.** Outra sessão mesclou antes a
PR #201 (as etiquetas no Controle de atendimento) com o script 033 e a seção
74, e este virou o 034 e a seção 75, sem mudar nada por dentro. **O número
de um script só fica reservado quando chega à `main`.** Antes de abrir a PR,
confira o último número da pasta na `main` mais recente.

Prova: seção 75, num Postgres de verdade, com a tabela como ela é no
escritório: 25 conferências, **9 sabotagens e 9 pegas**, todas limpas, rodadas
em cópias e lidas uma a uma:

- sem a regra do tipo;
- sem a regra que junta endereço e tipo;
- a regra criada sem `if not exists` (a segunda rodada estoura);
- a coluna criada sem `if not exists`;
- sem a guarda do banco limpo;
- o tipo `audio` fora da lista;
- a regra que junta só de um lado;
- o script tirando de quem atende a permissão de gravar;
- uma coluna a menos.

## O que não entrava no histórico (26/10)

Pedido do Rodrigo: *"Veja também se todos os históricos de conversas estão
presentes, se não existem erros referente a isso."* Cruzando a caixa de entrada
com `mensagens` (só números, nomes de campos e horas; o texto das mensagens de
cliente não foi lido), três defeitos, os três daqui:

| o que | quantas, desde setembro | por quê |
|---|---|---|
| mensagem com botões, resposta a um modelo, convite de grupo | 27 recebidas | o texto mora em `content`, e o webhook as descartava como "evento sem texto" |
| a mensagem que a equipe mandou e que saiu DEPOIS do nosso prazo | 9 enviadas | o item virava erro, e o eco que provava a entrega era jogado fora |
| a limpeza da caixa de entrada | — | nunca rodava; quando rodou, de surpresa, levou a cópia das 34 acima que não existiam em `mensagens` |

O resto bate: os 402 eventos de reação, os 103 avisos de álbum, as 140 respostas
automáticas (que moram no registro do 021, de propósito) e as 299 edições não
são mensagens novas, e não faltam.

### As três mensagens que sumiam

`textoDoQueNaoEAnexo` ganhou três desvios, com os nomes de campo MEDIDOS no
evento cru (e `m.text` vazio nas 27):

| messageType | quantas | a bolha |
|---|---|---|
| `ButtonsMessage` | 21, de 7 conversas | o `contentText` e, embaixo, `Opções: “Pagar agora” · “Falar com atendente”` (os `buttons[].buttonText.displayText`) |
| `TemplateButtonReplyMessage` | 5 (2 nossas) | o `selectedDisplayText`, a palavra que a pessoa tocou — como a resposta de botão que já existia |
| `GroupInviteMessage` | 1 (nossa) | `👥 Convite para o grupo “…”` e a `caption` |

- **A resposta a um modelo vem ANTES do desvio do modelo**, e era por isso que
  se perdia: o nome contém "template", caía ali, e `textoDoModelo` não achava
  corpo de modelo nenhum — não há: é uma resposta.
- **O convite não leva link.** O `inviteCode` desta mensagem é o do convite que
  expira, e não o código de um `chat.whatsapp.com`; escrever o link seria
  inventar um endereço.
- **O botão sem texto diz quem tocou** (`fraseDoBotaoSemTexto`): 2 das 5
  respostas a modelo eram do celular do escritório, e "o contato respondeu"
  diria o contrário.
- **Os três deixam de ser "tipo desconhecido"** (`button`, `template`,
  `invite`) — o alerta de 800 caracteres a cada um seria ruído.

### O eco do envio que "falhou"

O eco (`wasSentByApi`) era ignorado sem pergunta: o envio grava a linha com o id
que a Uazapi devolve, e o eco seria repetição. Mas quando a resposta da Uazapi
se perde, o envio nunca soube o id — e o eco é a única notícia de que a
mensagem saiu. Medido nas 9:

- **seis acabaram em tempo limite** e saíram 56 a 104 segundos depois de o item
  entrar na fila. Três foram reenviadas (o cliente recebeu duas vezes) e três
  dispensadas (o cliente recebeu, a conversa não mostra);
- **três saíram na primeira tentativa E na segunda** (`tentativas` = 2): a
  conversa só mostra a segunda.

Agora `conferirEcoDoEnvio` pergunta antes de ignorar. **O eco cujo id não está
na conversa procura o item da fila que o mandou**: a mesma conversa, o mesmo
tipo, o mesmo texto, e o eco até 30 minutos depois de o item sair (a última
tentativa, a criação ou a hora marcada da agendada, qualquer uma). Achando:

| o item | o que acontece |
|---|---|
| erro, dispensado, ou pendente já tentado (esperando a próxima tentativa) | vira `enviada`, a mensagem entra com o id e a hora do eco, e a nova tentativa não acontece |
| saindo agora (o pedido à Uazapi não voltou) | o eco fica **anotado** na memória; quando o envio desistir, confere a anotação antes de virar erro ou tentar de novo |
| enviado depois de mais de uma tentativa | ganha a linha da anterior: o cliente recebeu as duas, e a conversa passa a dizer isso |

**Quatro cuidados, e cada um tem cena na prova:**

- **o que está saindo vem primeiro**: "Reenviar" cria um item novo com o mesmo
  texto e dispensa o antigo; o eco que chega com o novo no ar é do novo;
- **o pendente nunca tentado não é dono de eco nenhum** (a agendada de amanhã
  com o mesmo texto);
- **a edição não é mensagem nova**: o eco dela aponta a original (`edited`);
- **a gravação confere o estado de onde sai** (`.eq('status', …)`): se a nova
  tentativa já começou, zero linhas, e nada é gravado.

**E o item confirmado é confirmado mesmo com o histórico recusando a linha.**
`confirmarPeloEco` responde três coisas, e não uma: `saiu` (o item virou
`enviada`), `entrou` (a linha entrou no histórico) e `falhou` (o banco recusou
uma das duas gravações). Na primeira escrita ela respondia só "entrou?", e eu
achei relendo o código antes do commit: com o histórico recusando a linha (uma
coluna que falta, uma restrição), o envio que desistia via "não confirmado" e
seguia para o caminho da falha — o item virava erro por cima do `enviada`, e
uma falha que insiste mandaria a mensagem de novo. Quem decide a desistência
é `saiu`. A recusa do histórico fica dita no log e em `erro_detalhe`, por
`gravarEnviadaNoHistorico`, como no envio de sempre.

**A mensagem que nasce do eco é igual à do envio**: a escrita é uma só,
`gravarEnviadaNoHistorico` — quem mandou, o id de quem mandou, o nome do
arquivo, a citação. O aviso de audiência que o Vantoro ouviu como falha é
confirmado.

**A frase do tempo limite manda esperar**: *"…a mensagem pode ter saído assim
mesmo. Espere um ou dois minutos: se ela saiu, esta bolha some e a mensagem
aparece como enviada. Só reenvie se continuar vermelha."* Era *"toque em
reenviar daqui a pouco"*, e foi essa frase que fez três clientes receberem duas
vezes.

**O que não se cobre:** a anotação mora na memória. Se a ponte cair entre o eco
e a desistência, ou se o eco for tratado pela outra ponte nos segundos de uma
publicação, o item fica como ficaria antes. E o item preso em `enviando` por
cinco minutos continua voltando para a fila sem perguntar pelo eco.

### A limpeza da caixa de entrada nunca rodava

`terminarOsPendentes` lia os pendentes e, sem nenhum, **voltava** — e a limpeza
de hora em hora morava depois dessa volta. Medido em 26/10: **64.713 eventos,
108 MB, o mais antigo de 08/09**, para uma limpeza de sete dias.

**Ela rodou uma vez, em 26/10 às 16h25** (`/rpc/limpar_eventos_recebidos` nos
registros do Supabase): uma foto que chegou às 16h24 ficou mais de um minuto
pendente, a volta seguinte passou dali, e a limpeza apagou 56 mil eventos de uma
vez — entre eles a cópia de 25 das 27 recebidas e das 9 enviadas, que o resgate
desta entrega ia devolver às conversas.

**E é provável que a demora da foto tenha sido culpa da medição.** Naquele
minuto rodavam aqui consultas pesadas na caixa de entrada (varrer os 64 mil
eventos com subconsultas, duas delas passaram de 60 segundos). Uma consulta de
leitura não trava ninguém, mas ocupa o banco — e o webhook que demora vira
pendente. **A régua que fica: medir em produção com consultas pequenas, uma
pergunta de cada vez. Uma consulta que passa de 60 segundos não é só lenta:
ela atrasa o webhook do escritório.**

Hoje a limpeza roda **de hora em hora, haja ou não pendente**, e **a primeira
espera uma hora depois de subir** — o resgate lê a caixa dois minutos depois da
subida, e o que ele procura é o que a limpeza apagaria. `CAIXA_LIMPEZA_MS` é
opcional, para a bancada. O aviso dos eventos que desistiram continua logo
depois da volta que os tentou.

~~**Ainda em aberto, e é decisão do Rodrigo:** sete dias é o prazo para resgatar
o que a ponte não souber ler. Trinta dariam mais folga (uns 40 mil eventos,
70 MB), e guardariam por mais tempo uma segunda cópia do que o cliente escreveu.~~
**Decidido em 27/10: trinta dias** — ver logo abaixo.

### A cópia passou a durar 30 dias (script 035, 27/10)

Decidido pelo Rodrigo em 27/10, depois de ler a conta em linguagem simples.
`sql/automaticos/035-a-caixa-de-entrada-guarda-30-dias.sql` recria
`limpar_eventos_recebidos()` com `interval '30 days'`. A razão: a cópia é o
único jeito de devolver às conversas uma mensagem que a ponte não soube ler, e
o defeito de 26/10 foi achado semanas depois. Com 7 dias, só 2 das 27 voltaram.

**O que custa, medido em 27/10:** a tabela vai de uns 10 mil para uns 40 mil
eventos. Ela já ocupa 108 MB no disco, porque o Postgres não devolve ao disco o
espaço da limpeza de 26/10 (guarda para reaproveitar), e o banco inteiro tem
208 MB. A segunda cópia do que os clientes escrevem fica guardada mais tempo; a
primeira, a conversa, já fica para sempre.

**O que não mudou, e a prova confere cada um:**

- os pendentes nunca saem;
- a conta é pelo `processado_em`: o evento que chegou há 35 dias e foi
  processado há 29 fica;
- poder de dono, `search_path` fixo e só para a ponte. `create or replace`
  guarda as permissões da função que já existe, e a que tivesse sumido nasceria
  com as da herança — por isso o script as diz de novo;
- a ponte chama do mesmo jeito: o `index.js` não mudou.

**A guarda é obrigatória aqui:** a função é `language sql`, e o Postgres
confere o corpo dela ao criar. Num banco sem `eventos_recebidos` (o da
51l-bis), o `create` estouraria.

Prova: seção 80, num Postgres de verdade, sobre o script de setembro que criou
a caixa, com o 035 por cima: 31 conferências, **12 sabotagens e 12 pegas**,
todas limpas, rodadas em cópias e lidas uma a uma:

- os 7 dias de sempre;
- apagar também os pendentes;
- a conta pela chegada, e não pelo processamento;
- sem o poder de dono;
- sem o `search_path`;
- sem tirar de `public`;
- sem tirar de `anon`, e sem tirar de `authenticated`;
- sem dar à ponte;
- sem a guarda do banco limpo;
- a tabela da conferência criada depois da guarda;
- e a conferência que diz "true" com os 7 dias de volta: quem pega é a conta
  dos eventos que ficam, e não a conferência.

**As de `anon` e `authenticated` só são pegas na cena com a herança da
Supabase.** No banco de prova as funções nascem para `public`, e tirar
`public` já bastaria; na Supabase os dois recebem pelo NOME (a armadilha nº 5).
Sem essa cena, as duas sabotagens vazariam.

### O resgate do histórico, uma vez só

Na subida, dois minutos depois (`RESGATE_DO_HISTORICO_MS`, opcional),
`resgatarOHistorico` devolve às conversas o que está na caixa e não entrou:

1. **as recebidas** dos três tipos, lidas com as MESMAS funções do webhook
   (`textoDoQueNaoEAnexo`, `extrairResposta`, `horarioDeQuemEnviou`), na conversa
   que o webhook criou antes de descartá-las. Nada de contato nem conversa novos:
   não achando, a conversa foi juntada ou apagada, e ele conta e segue;
2. **os ecos sem mensagem** que casam com um item da fila pela régua acima.
   Primeiro só o id, a marca de edição e o tipo de cada eco (caminho de JSON no
   `select`); o corpo inteiro só dos que faltam. As respostas automáticas saem
   antes, pelo registro do 021;
3. **a conversa volta ao lugar.** O gatilho do banco põe toda mensagem que entra
   como a última — prévia, hora e +1 nas não lidas. A resgatada mais velha que a
   última mensagem devolve a prévia e a hora de antes (só se ainda for o valor
   que o gatilho pôs: uma mensagem nova no meio vale); as não lidas voltam ao que
   eram, com a gravação conferindo o valor de agora; e a espera e a aba são
   recontadas (`zorvin_recontar_espera`, `zorvin_recontar_situacao`).

**Uma vez só, por causa do custo:** procurar um tipo dentro do JSON é ler a
caixa inteira — **1,2 segundo** no banco do escritório, com 64 mil eventos — e a
ponte sobe dezenas de vezes por dia. Terminado sem falha, a chave
`ponte:resgate-do-historico-26-10` em `zorvin_sementes` (o 027) diz que ele
rodou. **Sem a tabela, ele não roda**, e diz por quê: sem como lembrar, a
varredura seria de toda subida.

**A recusa do banco é falha, nas duas metades:** a recebida que o banco recusa,
e o eco cujo item virou `enviada` com a linha recusada pelo histórico. A chave
não é anotada, e a próxima subida confere de novo. Zero linhas na gravação do
item não é falha: alguém mexeu nele no meio (reenviou, ou o eco ao vivo chegou
antes), e não há o que resgatar.

**O que ele ainda tem para devolver:** depois da limpeza de 26/10, só 2 das 27
recebidas continuam na caixa (21/10 e 24/10), e nenhuma das 9 enviadas. A de
21/10 sai do prazo de sete dias em **28/10 às 08h17 (Brasília)**: publicada
depois disso, a ponte já não a encontra. As outras continuam no WhatsApp dos
aparelhos.

**O painel tem de estar no ar ANTES**: a guarda que não toca o aviso para
mensagem de mais de um dia mora nele (`ehHistoricoChegando`, PR do painel de
26/10). Com o painel de antes, cada recebida resgatada tocaria o som.

**E isto se encaixa com a resposta do cliente ao aviso (a #203, do mesmo
dia).** O aviso de audiência confirmado pelo eco vira `enviada`, com o
`enviado_em` do eco e a linha no histórico, e é por esse status e essa hora que
a rodada das respostas o encontra: o "ok" do cliente a um aviso que tinha dado
tempo limite passa a chegar ao Vantoro. E o que o resgate devolve tem a data de
quando foi escrito, fora das 48 horas que aquela rodada relê.

Prova: seção 77, **73 conferências**, com o gatilho do banco imitado na bancada
(`aoGravar`): sem a imitação, a devolução da prévia e das não lidas não teria o
que desfazer. A bancada aprendeu o caminho de JSON nos filtros e no `select`
(`valorDoCaminho`): sem isso, a leitura da caixa por tipo devolvia lista vazia, e
a prova mediria a bancada.

**26 sabotagens, 25 pegas e uma que vaza com razão**, todas rodadas em cópias e
lidas uma a uma:

- **os três tipos:** sem a mensagem com botões; a resposta a um modelo de volta
  ao desvio do modelo; sem o convite; o botão sem texto sempre "do contato"; as
  opções fora do texto;
- **o eco:** ignorado como antes (13 reprovações); a desistência sem a anotação;
  a desistência conferindo a linha, e não o item; sem a janela de tempo; sem dar
  a vez ao que está saindo; o pendente nunca tentado como dono do eco; a edição
  confirmando; a frase antiga do tempo limite;
- **o resgate:** sem devolver a conversa ao lugar; as não lidas que não voltam;
  sem recontar; sem anotar a chave; sem conferir a chave; sem os ecos; sem a
  guarda do que já está (a não lida sai a mais); a conversa que desce na lista;
  o convite sem o rótulo do celular; a recusa do eco sem contar como falha;
- **a limpeza:** de volta depois do "não há pendente"; a primeira na primeira
  volta;
- **e a que vaza:** o resgate sem filtrar as respostas automáticas. O eco de uma
  automática não acha item na fila (elas não passam por lá) e é pulado do mesmo
  jeito: o filtro é a segunda guarda, e poupa ler o corpo delas — a régua de
  25/09.

**Duas conferências minhas mediam antes da hora, e a rodada de sabotagens
mostrou.** "O resgate anota que rodou" reprovou em duas sabotagens que nem mexem
na chave: a cena acordava com a frase do registro, e a chave é gravada DEPOIS
dela — numa máquina ocupada (três cópias ao mesmo tempo), às vezes ainda não
tinha chegado. E as cenas do eco acordavam com o item virando `enviada`, que é a
primeira de duas gravações: liam o histórico antes da segunda. Hoje cada uma
espera o que confere, com teto. **Na integração contínua isso seria um X
vermelho de vez em quando, sem defeito nenhum.**

**E um nome repetido, achado pela prova:** escrevi um `lerEmPaginas` para o
resgate, e já existia outro com o mesmo nome, mais abaixo no arquivo. Função
declarada duas vezes vale a ÚLTIMA, sem aviso nenhum: o resgate chamava a outra,
com outra forma de resposta, e quebrava com "is not iterable". Hoje ele usa a
que existia. **Antes de criar um ajudante, procure o nome no arquivo.**

## A auditoria de 07/10

Varredura inteira da ponte e dos scripts, cada achado conferido antes de
mexer (a do painel está no CLAUDE.md dele). O que mudou aqui:

| o que acontecia | agora |
|---|---|
| a busca do telefone falhando no meio do webhook fazia `return` — com o evento já guardado e o "OK" dado, a caixa o marcava como resolvido e **a mensagem do cliente se perdia** | SOBE (`throw`), a regra 2 da caixa; o aviso "MENSAGEM DE CLIENTE PERDIDA" só sai quando não há caixa (aí a perda é de verdade) |
| edição e "apagar para todos" liam o corpo da resposta da Uazapi **duas vezes** — a segunda dava `null`, e a recusa nunca era vista | o corpo é lido uma vez (`corpoDaResposta`); a troca do `id_uazapi` na edição **fica desligada** até ser medida com resposta de verdade — com o corpo lido duas vezes ela nunca tinha rodado |
| CORS sem `DELETE`: "Tirar este número" da ficha morria no navegador | liberado |
| desligar "Conta ativa" (sem Vantoro) não tirava acesso nenhum | `aplicarPermissoes` tira todas as linhas de quem está desativado, e o Auth bloqueia a entrada (`ban_duration`); reativar devolve |
| juntar conversas apagava (cascade) as tarefas e o "Já tratei" da que sai | mudam de conversa junto |
| a mídia que falhava por URL era reenviada em base64 também em 5xx e 429 — o cliente podia receber o arquivo duas vezes | só no 4xx, a régua da fila |
| a classificação semanal apagava o vínculo com o Vantoro feito à mão | só grava vínculo quando o Vantoro acha alguém |
| um tropeço ao ler a conversa no envio virava erro definitivo "cadastro" | tenta de novo mais tarde |
| sem `trust proxy`, o freio da entrada era só por login | um salto de proxy (a Render) |
| `/permissoes/diagnostico` aceitava administradora desativada | exige `admin` e `ativo` |
| um "entregue" atrasado rebaixava "lida" | nunca rebaixa (duas gravações: `neq` deixa o nulo de fora no Postgres) |
| `/etiqueta/contato` e `/contato/foto` agiam sobre qualquer contato | conferem, lendo como quem pediu (`alcancaConversa`), que a pessoa vê alguma conversa dele |

**E o script 020** (`sql/automaticos/020-a-auditoria-do-banco.sql`), com
quatro consertos conferidos num Postgres 16 — os oito cenários reproduzem o
defeito sem ele e passam com ele:

- **a agendada só se edita antes da hora**: as políticas de UPDATE de
  `fila_envio` se somam por "OU", e a do cancelar (que não olha a hora)
  deixava a do editar valer depois da hora — e deixava um item com erro
  voltar a `pendente`. Um gatilho, que enxerga a linha velha, recusa (42501)
  quando é gente do painel; a ponte não passa por ele;
- **o "Já tratei" só na conversa que a pessoa vê, e assinado por ela**: criar
  e desfazer eram `true`, e `quem` vinha da tela. A leitura continua aberta
  (decisão do 005, para o histórico do cliente);
- **o gatilho da espera nunca derruba a mensagem**: a carência era lida na
  declaração das variáveis, que o `exception` não protege. Este script é,
  daqui para a frente, a versão de referência do gatilho;
- **`tratada_em` no relógio do banco**, e não no do computador de quem clicou.

**O LEIA-ME ganhou a regra 5:** "rode de novo sem medo" vale para a pasta
inteira, na ordem — rodar o 004 sozinho depois do 006 desfaz a espera.

**Ficou de fora, de propósito:** a reação e o envio para grupo com `@g.us`
(depende de como a Uazapi responde — medir com um grupo de verdade); os
avisos de audiência sem as variantes do nono dígito (feito em 27/10: ver "O
aviso de audiência vai para o contato que já existe"); o `/anexos/resgatar`
pedindo mais de 1000 linhas.

Prova: seção 57 (10 conferências) e a seção da busca do advogado refeita em
duas cenas (com e sem a caixa), **5 sabotagens e 5 pegas**.

## A auditoria de 27/10 (28/10)

Pedido do Rodrigo: *"Faça uma auditoria completa, analise todos os arquivos,
encontre possíveis erros, faça os ajustes necessários, me dê sugestões de
melhorias"*. Sete leituras em paralelo (o painel em três pedaços, os
componentes, a ponte em dois e os scripts SQL), e **cada achado conferido no
código, e quando possível medido no banco, antes de mexer**. A lista inteira
está na PR; aqui fica o que mudou na ponte, e por quê. A do painel está no
CLAUDE.md dele.

### Os avisos de audiência: um tropeço não é o desfecho

O Vantoro tira um aviso da lista de pendentes quando ouve `/enviado` ou
`/erro` — **e lá o ERRO é o fim**: o aviso não volta para a fila. Três coisas
erravam isso:

| o que acontecia | agora |
|---|---|
| um tropeço do banco no meio do caminho (ler os telefones, achar o contato, abrir a conversa, gravar na fila) virava `/erro`: o cliente ficava sem saber da audiência por causa de um segundo ruim | **adia** (`adiarAviso`): o aviso continua pendente lá, e a rodada seguinte (5 min) tenta de novo. `/erro` fica para o que não muda sozinho: o cliente sem número, o telefone que o Zorvin não tem, a linha desativada |
| `/enviado` e `/erro` eram mandados sem olhar a resposta: o Vantoro que tossia na confirmação deixava o aviso pendente para sempre — e a ponte tentava enfileirá-lo de novo a cada 5 minutos, o banco recusava (`23505`, o índice único de `aviso_vantoro_id`) e o log ganhava uma linha de "duplicate key" por rodada | **a lista de pendentes reconcilia** (`reconferirAvisoNaFila`): o aviso que já está na fila tem o desfecho dito de novo — saiu, `/enviado`; falhou, foi dispensado ou cancelado, `/erro` com o motivo. O que ainda está saindo fica quieto. A confirmação só diz "confirmado" no 2xx (`confirmarAvisoNoVantoro`) |
| `numeroComPais` lia "começa com 55" como "já tem o país" — e **55 é o DDD de Santa Maria** e do centro do RS: o celular (55) 99999-8888 virava um número que não existe | pelo **tamanho**: 10 ou 11 dígitos ganham o 55; 12 ou 13 já o têm |

**O cliente não recebe duas vezes** em nenhum desses caminhos: reconferir
não põe nada na fila de novo, e a confirmação repetida é só uma chamada ao
Vantoro (`marcar_enviado` lá aceita vir depois).

### A linha do aviso é marcada como automática (script 037)

`sql/automaticos/037-o-aviso-automatico-nao-e-atendimento.sql`. O aviso entra
em `mensagens` como mensagem do escritório (`origem = 'advogado'`, sem autor),
e toda conta que pergunta *"a equipe já agiu?"* o lia como gente respondendo:

- **a fila de espera** (004–006, 020): o cliente que tinha perguntado algo
  saía da fila quando o aviso saía, sem ninguém ter respondido;
- **a situação e o protocolo** (028): o aviso virava a primeira resposta do
  atendimento e tirava a conversa de "Novos";
- por tabela, **a contabilização** (029): o tempo até a primeira resposta era
  o do aviso.

**Medido em 28/10, só contando:** 38 avisos desde 13/08, em 14 conversas; uma
conversa fora da fila só por causa do aviso; 6 protocolos com um aviso como
primeira resposta. E um protocolo foi **aberto** por um aviso — já está
finalizado, e o 037 não mexe nele: protocolo que muda de número deixa de ser
protocolo. **Dos 6, 3 continuam abertos, e os 3 já têm resposta de gente
depois do aviso**: nenhuma conversa muda de aba com o 037. O que muda é o
tempo até a primeira resposta na contabilização, e a conversa que volta para
a fila de espera.

O 037 cria `mensagens.automatica` (padrão falso), marca as linhas que já
existem pelo item da fila que as mandou (mesma conversa, mesmo texto, sem
autor, até 10 minutos da hora do envio), tira a mensagem automática das
contas de "a equipe agiu" (o gatilho da espera, a recontagem e as cinco
funções da situação — **são as versões de referência daqui para a frente**,
regra 5 do LEIA-ME), corrige a primeira resposta dos 6 protocolos e reconta
as conversas com aviso. **A ponte marca a linha nova ao gravá-la**
(`gravarEnviadaNoHistorico`: `automatica = true` quando o item tem
`aviso_vantoro_id`).

**O que não muda, e é decisão:** a origem continua `'advogado'` — a bolha, o
lado dela, a resposta do cliente ao aviso (26/10) e o Controle de atendimento
do Vantoro leem a origem, e o aviso continua sendo do escritório; a resposta
fora do horário (022) continua contando o aviso como conversa em andamento
(responder "estamos fechados" ao "ok, ciente" seria pior do que calar); e a
distribuição (023) continua sem distribuir quem responde a um aviso — é
cliente que o escritório procurou, e não um lead. **A conversa que só tem o
aviso** fica em "Em Atendimento", sem protocolo; quando o cliente responde, o
protocolo é dele e ela vai para "Novos".

### Quem é desligado no Vantoro sai do Zorvin

O Vantoro lista em `/usuarios` só quem tem acesso ativo — quem foi desligado
**some da lista**. E a rodada das permissões só percorria a lista: quem sumiu
nunca era visitado, continuava com as permissões, e a sessão do Zorvin se
renova sozinha. **O Vantoro recusa a senha de quem saiu; a sessão aberta,
não.**

Hoje, ao fim da rodada (`desligarQuemSaiuDoVantoro`), quem estava ativo no
Zorvin e não está na lista é **desligado**: `ativo` falso (a marca que as
regras do banco e a distribuição já leem), as permissões saem, e a conta é
**bloqueada no Auth** (`ban_duration`) — sem isso a sessão aberta continuaria
se renovando. **Quem volta à lista, volta**: ativa e desbloqueada, e com as
permissões na rodada seguinte; entrando antes disso, a própria entrada tira o
bloqueio (`/auth/login` lê como a pessoa estava antes de espelhá-la).

**A trava:** lista vazia, ou mais de `max(3, 20%)` das contas ativas sumindo
de uma vez, **não desliga ninguém**, e o log diz uma vez. Isso é o Vantoro
respondendo errado (outro endereço, um defeito lá), e não meio escritório
demitido no mesmo minuto — desligar por engano é a equipe inteira sem entrar.

**Medido em 28/10, antes de publicar** (impressões digitais md5 do login e do
e-mail nos dois bancos, sem ler nome de ninguém): **as 23 contas do Zorvin
casam, todas, com alguém ativo no Vantoro.** A primeira rodada depois da
publicação não desliga ninguém. **Só vale com Vantoro**: sem
`VANTORO_API_URL`, a rodada nem começa.

Duas variáveis **opcionais**, para a bancada encurtar a rodada:
`PERMISSOES_INTERVALO_MS` (padrão 3 min) e `PERMISSOES_PRIMEIRA_MS` (a
primeira, 20 s depois de subir).

### As senhas saem do histórico de alterações (script 038)

O histórico de alterações do cadastro (`alteracoes`, `tipo = 'cadastro'`)
guardava o "de → para" de cada campo da ficha — **a Senha SERASA e a Senha GOV
inclusive, por extenso**, numa tabela que quem entrou lê. **Medido: 59
linhas.** `sql/automaticos/038-as-senhas-fora-do-historico.sql` esconde as que
existem (`••••••`) e põe um gatilho que esconde as que chegam, de quem quer que
as escreva; **a ponte também esconde ao gravar** (`registrarEdicaoDeCadastro`).
A linha fica — quem trocou, e quando —, e a conta de "mudou?" é feita com o
valor de verdade, antes de esconder.

**Desfeito em 29/10, a pedido do Rodrigo**: a premissa estava errada, e na
ficha todo mundo do Zorvin já vê as senhas. Ver "As senhas voltam ao histórico
(script 039, 29/10)", logo abaixo desta seção.

### E o resto

| o que acontecia | agora |
|---|---|
| o item preso em "enviando" voltava à fila depois de 5 minutos — **mesmo com o eco do WhatsApp provando que saiu** (a ponte caiu no meio do envio, e a nova anotou o eco): o cliente recebia duas vezes | a recuperação confere a anotação do eco (`tirarEcoDoQueEstaSaindo`) e confirma pelo eco; só volta para a fila o que não tem eco |
| o eco do envio procurava o item entre os **50 mais antigos** dos dois dias: numa conversa de muito vaivém, o item de agora ficava de fora | os 50 **mais recentes**, e o mais perto da hora do eco primeiro (`distanciaDoEco`) — dois "ok" na janela, o dono é o que saiu mais perto |
| juntar conversas recontava a situação e não a **espera**: a pergunta sem resposta que veio da outra conversa ficava fora da fila | `zorvin_recontar_espera` antes da situação (na ordem contrária, a espera recontada depois poria a finalizada de volta na fila) |
| um "usuário" de megas ia inteiro para o log, para a memória do freio e para o Vantoro | 400 acima de 200 caracteres de login ou 500 de senha, antes do log |
| o copiloto: o nome do arquivo ia sem `semAEtiqueta` (um `</conversa>` no nome fecharia o bloco), e o aviso chegava ao modelo como "Equipe" | as duas consertadas: o nome passa pela mesma limpeza do texto, e o aviso é dito "Aviso automático do escritório" |

### O que ficou como sugestão, e por quê

- **juntar conversas apaga em cascata** os protocolos, as respostas
  automáticas e as distribuições da conversa que sai — o 036 decidiu igual, e a
  rota não tem botão no painel; mudar é decisão;
- **a classificação semanal** troca o vínculo escolhido à mão quando o Vantoro
  acha outra pessoa pelo número;
- `/transcrever` baixa o áudio inteiro, de qualquer tamanho;
- `contatoDoAviso` desempata pela última atividade, que conta os próprios
  avisos;
- o "desligado até reiniciar" de um recurso pode ser decidido no meio da
  rodada de scripts que o cria;
- `/importar-historico` grava o endereço temporário da Uazapi quando o download
  falha; `juntarConversasDoGrupo` roda em toda mensagem de grupo;
  `fetchComTimeout` só cobre os cabeçalhos; a resposta automática acima de 30
  segundos vira "não saiu";
- nos scripts: a finalizada pode voltar para a fila com uma mensagem atrasada
  ou importada (o 028 só grava `tratada_em` quando havia espera); o banco
  aceita um `quando` escrito por quem grava o "Já tratei" (o painel não manda,
  e o 020 só força o `quem`); e, sem Vantoro, duas primeiras contas criadas no
  mesmo instante nascem as duas administradoras (o 001).

### A bancada

`falso-supabase.mjs` aprendeu `mensagens.automatica` e `fila_envio.erro_detalhe`
(a bancada recusa a coluna que não conhece, como o banco); o Vantoro de mentira
ganhou `pendentesAteODesfecho` (a lista guarda o aviso até ouvir `/enviado` ou
`/erro`, como o de verdade), `desfechosQueFalham` (um 500 de verdade na
confirmação) e `ficha` (o `GET /clientes/:id`).

**E uma conferência minha estava errada, e a prova mostrou.** Na cena da
junção, a pessoa que pedia não era administradora ali (os ids da cena são
UUID, e as contas de mentira de sempre, não), e a ponte recusou com razão. A
conferência reprovava dizendo "a junção não reconta", sobre uma junção que nem
aconteceu. Hoje ela diz também o status da resposta.

Provas: seção 82 (o 037 e o 038 num Postgres de verdade, **com o defeito
conferido antes do conserto**, 28 conferências) e seção 83 (a ponte, 45
conferências). **28 sabotagens, 27 pegas e uma que vaza com razão**, todas
rodadas em cópias e lidas uma a uma:

- **os avisos:** o tropeço nos telefones e a conversa que falha virando
  `/erro`; sem reconferir o que já está na fila (8 reprovações); a confirmação
  sem conferir a resposta; o DDD 55 lido como o país; a linha do aviso sem a
  marca;
- **quem sai do Vantoro:** quem sai fica; o desligamento sem bloquear a
  entrada; quem volta não volta; sem a trava; a entrada que não tira o
  bloqueio;
- **o resto:** a senha por extenso no histórico; o preso com eco saindo de
  novo; o eco entre os mais antigos; o eco sem o mais perto; a junção sem
  recontar a espera; o login gigante; o nome do arquivo sem `semAEtiqueta`; o
  aviso dito como "Equipe";
- **o 037 e o 038:** sem marcar as que existem; o gatilho da espera e as
  funções da situação sem a guarda; a primeira resposta não corrigida; sem
  recontar a espera; a recontagem contando o aviso; sem o gatilho das senhas;
  sem esconder as que existem;
- **e a que vaza:** calar o `23505` em vez de reconferir. A cópia recusada é a
  outra ponte enfileirando o mesmo aviso no mesmo segundo: o item acabou de
  entrar, não há desfecho a dizer, e a conferência do começo do laço o pega na
  rodada seguinte. O trecho foi SIMPLIFICADO para o `continue` — a régua de
  25/09, *sabotagem que o resto do sistema conserta sozinho não prova nada*.

**E uma vazou primeiro, e a culpa era da cena:** tirar a ordem "o mais perto
do eco primeiro" passava, porque a cena só tinha UM item com o texto do eco.
Entrou o caso que a ordem existe para separar: dois "pode ser amanhã?" na
janela, e o mais novo pela criação não é o que saiu mais perto da hora do eco
(o mais velho foi tentado de novo há um minuto e meio). Hoje ela é pega.

**E a cena de quem sai do Vantoro conferia antes da hora (31/10).** Ela
esperava o `ativo` virar falso e já conferia as permissões, o bloqueio e o
registro. Só que a ponte faz as quatro coisas uma depois da outra, e o
registro é a última. Na integração contínua da PR da transcrição ela
reprovou três conferências sem defeito nenhum. Reproduzido aqui com 400 ms
de atraso entre a primeira e a segunda gravação: as mesmas três, e uma
quarta na volta, onde o `ativo` também vem antes do desbloqueio. Hoje as
duas esperas aguardam a linha do registro. Cinco sabotagens e cinco pegas
com a espera nova: quem sai fica, sem tirar as permissões, sem bloquear,
quem volta não volta, volta sem desbloquear. É a régua de 26/10 outra vez:
**espere a ÚLTIMA coisa que o código faz, e não a primeira.**

## As senhas voltam ao histórico (script 039, 29/10)

Pedido do Rodrigo, logo depois do merge da auditoria: *"As senhas do SERASA e
GOV precisam aparecer, todos os usuários precisam saber qual é a senha."*

**O 038 partia de uma premissa errada, e ela foi medida depois.** A auditoria
supôs que parte da equipe não via as senhas na ficha e as lia pelo histórico.
No Vantoro, quem decide se as senhas vêm é a CHAVE com que se pergunta
(`ChaveDaAPI.ve_segredos`; o token do ambiente vê tudo), e não a pessoa.
**Medido no banco do Vantoro em 29/10:** as duas chaves nomeadas (Andon e
Midório) veem os segredos, e a ponte usa o token do ambiente. **Na ficha, todo
mundo do Zorvin vê as duas senhas.** Esconder no histórico não protegia nada:
só apagava o que a equipe precisa ler.

**O 039 tira o gatilho e a função do 038**, e a ponte voltou a gravar o "de →
para" da senha como o de qualquer campo (`registrarEdicaoDeCadastro`, igual a
antes da auditoria). **O 038 não foi editado** — script aplicado não se edita
(regra 3). **E o 038 não se roda de novo à mão**: quem rodar a pasta inteira,
na ordem, esconde de novo as senhas que existirem.

### O que se perdeu, e a culpa é desta casa

**O 038 rodou às 01:02 UTC de 29/10 (22h02 de Brasília), dois minutos depois
do merge**, e trocou por "••••••" o valor de **62 linhas**. A mensagem do
Rodrigo chegou depois disso, e uma cópia de `alteracoes` tirada às 01:04
(`zorvin_copia_alteracoes_2810`, com RLS e sem acesso de quem entra) já veio
com o "••••••". Ela não serve para nada, e sai na próxima conversa com o
conector do Supabase.

**O valor de antes não está em lugar nenhum deste banco.** O `UPDATE` grava por
cima. A versão velha da linha continua no disco até o próximo `VACUUM`
(medido: 61 linhas mortas, nenhum `VACUUM` ainda), mas só o superusuário a lê
(`pageinspect`, `pg_walinspect`), e o papel do conector (`postgres`) não é
superusuário.

**As senhas ATUAIS de cada cliente continuam inteiras no Vantoro**, que é onde
elas moram. O que sumiu foi o registro das senhas de antes de cada troca.

**O caminho para recuperar é o backup diário do Supabase** (plano Pro, 7 dias,
backup físico): "Restore to a New Project" com o backup de 28/10 cria um
projeto separado, de onde as linhas podem voltar sem que o valor passe aberto
por ninguém (cifrado com `pgcrypto` na ida e decifrado no banco do escritório).
O projeto novo custa enquanto existir, então é decisão do Rodrigo.

**A lição que fica:** o merge publica sozinho, e o script roda na subida. **Um
script que reescreve dado de produção sem volta pede a pergunta ANTES do
merge**, e não depois. A decisão de esconder foi minha, numa auditoria, sem
perguntar se a equipe precisava ler aquilo.

### As provas

Seção 82 (82g: o 039 tira o gatilho e a função, a senha nova é gravada como
veio, e as linhas já escondidas são contadas) e seção 83 (83i invertida: a
senha vai para o histórico com o "de → para" de verdade). **4 sabotagens e 4
pegas**, rodadas em cópias e lidas uma a uma:

- o 039 sem tirar o gatilho (a função não sai, e o script para);
- o 039 sem tirar a função;
- a ponte escondendo a senha de novo (3 reprovações);
- o 039 sem a guarda do banco limpo (a 51l-bis diz qual script e o erro).

**A última precisou ser rodada sozinha.** Com duas sabotagens ao mesmo tempo,
a cena 51c reprovou ("a tabela existe no Postgres") e a prova estourou na linha
seguinte, antes de chegar à 51l-bis. A 51c confere 400 ms depois da primeira
linha da rodada, como a 51l-bis conferia até 27/10, e sob carga a rodada dos
dois scripts dela não terminou a tempo. Sozinha, a sabotagem foi pega pela
conferência certa. **A 51c tem o mesmo defeito que a 51l-bis tinha**, e não foi
mexida aqui.

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

~~**Fato lateral medido no mesmo dia:** `zorvin_scripts_aplicados` **não existe**
no banco do escritório, ou seja, `DATABASE_URL` não está no Render e a ponte
**nunca aplicou script sozinha**. Tudo o que está lá foi colado à mão. A
automação de `sql/automaticos/` está escrita, provada e desligada em produção —
enquanto for assim, todo script novo é um pedido ao Rodrigo, e vale o que está
escrito acima.~~ **LIGADA EM 08/10** — ver "Ligado em produção", em "Os
scripts que se aplicam sozinhos". Daqui para a frente:

- **script novo de banco NÃO vai para o chat.** Ele entra em
  `sql/automaticos/` com o próximo número, e a ponte o aplica na publicação
  que vem com o merge. Mandar o mesmo SQL para o Rodrigo colar seria rodá-lo
  duas vezes — e um script que não aguente a segunda rodada quebraria ali;
- **o pedido ao Rodrigo passa a ser CONFERIR**, em Departamentos e acessos →
  **Atualizações do banco**: o script novo aparece com o selo "nesta subida" e
  com a conferência dele (a última linha) sem nada pintado de vermelho. Se
  falhar, a faixa vermelha do painel avisa quem administra sozinha;
- **as quatro regras acima continuam valendo** para o SQL que ainda vai para o
  chat — a consulta só de leitura, para medir alguma coisa, como a que
  conferiu de 001 a 020 antes do marco.

**E o SQL pelo conector do Supabase roda sem pedir permissão a ele (26/10).**
Nas palavras dele: *"Sempre que for para executar o SQL, não precisa me pedir
permissão, pode sempre fazer."* **E de novo em 01/11, pedindo que ficasse
guardado:** *"salva aí na sua memória: sempre que precisar rodar alguma
consulta no banco de dados, não precisa ficar pedindo permissão. Só faz!"*
Vale para consultar e para corrigir dados, e também para não avisar antes:
roda-se, e conta-se depois o que foi feito, quando fizer diferença. Foi o que
aconteceu no mesmo dia: o assunto "SEM RETORNO DO CLIENTE" foi criado direto
em `zorvin_assuntos` (dado, e não estrutura — é o que a tela de assuntos
faz), com a lista conferida antes e depois. O que a autorização não muda:

- **mudança de estrutura** (tabela, coluna, regra) continua indo por
  `sql/automaticos/`. Não é por falta de permissão: é o que mantém o banco e o
  código dizendo a mesma coisa, e o que passa pelas provas antes de chegar ao
  escritório;
- **correção de dados** (mudar ou apagar linhas) se faz quando o pedido dele
  precisa, olhando antes o que vai mudar e contando a ele depois exatamente o
  que mudou;
- **consulta pequena, uma pergunta de cada vez**: a pesada atrasa o webhook
  (ver a limpeza da caixa de 26/10, às 16h25).

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

### E o banco de teste deixou de vir do Docker Hub (13/10)

Em 09/10 a PR do script 022 ficou vermelha duas vezes **sem rodar prova
nenhuma**. O passo que sobe o Postgres de teste não conseguiu baixar
`postgres:16` do Docker Hub: primeiro `toomanyrequests` (o limite de downloads
de quem não tem conta), depois o Docker Hub sem responder. A suíte inteira
passava aqui.

Hoje a imagem vem do espelho público da Amazon
(`public.ecr.aws/docker/library/postgres:16`). É a mesma imagem oficial, e a
troca foi decidida com o Rodrigo. **O espelho também tem limite** para quem
baixa sem conta: medido daqui em 13/10, ele respondeu `Data limit exceeded`.
Se isso aparecer na integração contínua, o passo seguinte é o Postgres que já
vem instalado na máquina do GitHub, que não baixa nada.

A lição é a de 25/09 com outra roupa: **antes de procurar defeito no código,
olhe em qual passo o X vermelho parou.**

**Apareceu em 19/10, e o passo seguinte foi dado.** A PR do script 028 ficou
vermelha duas rodadas seguidas, em 11 segundos, com o espelho da Amazon
respondendo `toomanyrequests: Data limit exceeded` às três tentativas de cada
uma. Hoje o banco de teste é o **Postgres que já vem na máquina do GitHub**: o
passo "Ligar o Postgres da máquina" o liga (`systemctl start`), põe a senha e
escreve a versão no registro da rodada. Não baixa nada, e não há limite de
ninguém para esbarrar.

**A máquina ficou escrita (`ubuntu-24.04`, e não `ubuntu-latest`)**, porque a
versão desse Postgres é a do Ubuntu: a 24.04 traz o 16. Com `ubuntu-latest`,
no dia em que o GitHub trocasse a máquina, o banco das provas mudaria de versão
sozinho.

**E ele é o MESMO em que as provas são rodadas à mão** — conferido em 19/10:
Ubuntu 24.04, Postgres 16, `ssl = on` e as regras de entrada de fábrica do
Ubuntu (senha pela rede, `peer` pela porta local). A imagem de antes era outra
coisa (Debian, `ssl = off`). As provas falam com o banco com `sslmode=disable`,
então a diferença do `ssl` não muda nada nelas; a do resto, a suíte inteira
rodada aqui (1095 de 1095) já mostrava.

### O teto da rodada foi de 10 para 20 minutos (27/10)

O teto (`timeout-minutes`, em `provas.yml`) era de 10 minutos, e a suíte
chegava perto dele depressa. Medido nas rodadas do GitHub:

| a rodada | o passo "Rodar as provas" | a rodada inteira |
|---|---|---|
| 22/10, PR do script 031 | 6min50s | 7min05s |
| 26/10, a semanal da `main` | 7min29s | 7min45s |
| 26/10, PR #205 | 8min25s | 8min40s |
| 27/10, PR #206 | 8min28s | 8min42s |

Mais de um minuto e meio em cinco dias, com sete seções novas (da 72 à 78; as
três de 26/10 somaram quase um minuto sozinhas), e sobrava 1min18s. Passando do teto, o GitHub corta a rodada no meio, e o X
vermelho do corte é igual ao de um defeito: foi o que aconteceu no painel em
28/09, com a suíte cortada a segundos do fim.

**Decidido pelo Rodrigo em 27/10: o teto foi para 20.** Não custa nada: os dois
repositórios são públicos, e o GitHub não cobra os minutos de rodada em
repositório público. O teto não muda o que a rodada consome. Ele só decide
quando uma prova travada é derrubada, e vinte minutos ainda a derrubam sem
deixá-la horas de pé.

**Ao acrescentar prova, continue olhando quanto a suíte leva**: o passo "Rodar
as provas" de cada rodada diz.

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

## Qual versão está no ar — e a publicação que não aconteceu (14/10)

Em 14/10 três PRs da ponte (os scripts 025, 026 e 027) foram mesclados à tarde, e
**nenhum foi publicado**. Na Render o serviço não tem um único evento naquele dia.
Rastreadores de status falam de uma pausa nas publicações de serviços gratuitos a
partir de ~20:41 UTC; a página de status da própria Render não abre daqui, então
isso não foi conferido na fonte. Na manhã seguinte o Rodrigo viu a lista do "Já
tratei" na ordem antiga, e a aba **Atualizações do banco** dizia **"Em dia"**.
Ela estava certa para a ponte que estava no ar, que não conhecia script nenhum
depois do 024. Resolveu com **Manual Deploy → Deploy latest commit**.

**Já tinha acontecido em 20/08.** Daquela vez nasceu a linha `versão no ar: commit …`
que a ponte escreve no log ao subir. Nas duas vezes ela dizia a verdade, num lugar
que ninguém abre.

Hoje `GET /scripts/estado` devolve `versao` em toda resposta, também com os scripts
desligados — "qual ponte está no ar?" não depende deles:

| campo | de onde |
|---|---|
| `commit` | `RENDER_GIT_COMMIT`, **inteiro** — é com ele que o painel acha a versão no GitHub |
| `ramo` | `RENDER_GIT_BRANCH` |
| `repositorio` | `RENDER_GIT_REPO_SLUG` |
| `servico` | `RENDER_SERVICE_NAME` — o nome que a frase do Manual Deploy manda abrir |
| `ultimo_script` | o último `.sql` de `sql/automaticos/` (o `LEIA-ME.md` não conta) |

**Fora da Render, as quatro primeiras vêm NULAS.** Nulo quer dizer "não sei"; um
texto vazio o painel leria como uma versão chamada "". E só entram variáveis que a
Render documenta: as outras `RENDER_*` são de uso interno dela e mudam sem aviso.

**Quem compara com o GitHub é o PAINEL, e não a ponte.** O repositório é público e
o GitHub responde a qualquer um, mas limita as perguntas sem senha **por
endereço**. A Render sai para a internet por endereços que muitos serviços
dividem; o navegador do escritório usa um endereço que é só dele. Ver "Qual ponte
está no ar" no CLAUDE.md do painel.

**`ultimo_script` vai junto porque é o número que o Rodrigo confere sozinho**
("conhece as atualizações até a 027"). É ele que mostra que "em dia" quer dizer
em dia com ESTA ponte.

**A lista dos scripts tem uma escrita só** (`nomesDosScripts`): a rodada e o
"último script" saem dela, e duas listas poderiam discordar sobre qual é o último.

Prova: seção 20, agora com 15 conferências e **10 sabotagens, todas pegas** e
lidas uma a uma, rodadas em cópias. Entre elas: a versão fora da janela, o commit
encurtado, o vazio no lugar do nulo, o `LEIA-ME.md` contado como script, a versão
só com os scripts ligados, e a versão indo para quem atende. As cenas sobem **sem**
`DATABASE_URL`, de propósito.

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
- `conversas` — id, advogado_id, contato_id (unique juntos), ultima_mensagem, ultima_atividade, nao_lidas; e, desde o 028, situacao ('aguardando'|'aberto'|'finalizado') e protocolo, escritos só pelos gatilhos
- `mensagens` — id, conversa_id, origem ('contato'|'advogado'), tipo, texto, midia_url, midia_mime, id_uazapi (unique), status
- `zorvin_atendimentos` — um por protocolo (028): quando abriu, por quê, a primeira resposta, quando e quem finalizou
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
   **E ela estava aberta de novo em 22/10** — 15 tabelas e 13 funções com
   poder de dono abertas para `anon`. Fechada pela ponte no script 032, com a
   conferência guardada: ver "Quem não entrou não alcança nada (script 032,
   22/10)".
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
- **Mesclar não pede o OK dele** — dito em 01/11: *"Não fica me pedindo ok,
  sempre que estiver tudo certo é só mesclar, não precisa de permissão para
  isso."* "Tudo certo" quer dizer: as provas verdes no último commit da PR, sem
  conflito com a `main`, e nenhum comentário ou revisão esperando resposta. Com
  PR nos dois repositórios, **a da ponte entra primeiro**. Mesclou, conta-se a
  ele o que entrou no ar.
- **O que continua sendo dele é a decisão sobre o conteúdo**, e não o merge.
  O merge publica sozinho e o script de `sql/automaticos/` roda na subida: um
  script que reescreve dado de produção sem volta pede a pergunta ANTES (ver
  "As senhas voltam ao histórico (script 039, 29/10)"). Com uma pergunta dessas
  em aberto, não está "tudo certo".
- Mesclada a PR, a rodada seguinte é **sempre uma PR nova** (não empilhar em cima da anterior).
- Fluxo por rodada: recomeçar a branch a partir da `main` mais recente
  (`git fetch origin main && git checkout -B <branch> origin/main`), aplicar a mudança,
  commit, push, **abrir uma PR nova**, esperar a prova ficar verde e mesclar.
- Passo a passo (SQL, o que conferir depois de publicar, etc.) vai **no chat**, não na descrição da PR.
