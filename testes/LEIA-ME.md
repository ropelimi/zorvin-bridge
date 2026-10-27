# Testes da ponte

    npm install
    npm test

## Como funciona

A ponte roda **de verdade** — o `index.js` sem nenhuma alteração — contra um
Supabase e uma Uazapi de mentira que falam o mesmo protocolo (PostgREST,
GoTrue, Storage).

Foi de propósito. A alternativa seria trocar o cliente do Supabase por um objeto
falso, e isso obrigaria a mexer no `index.js` só para poder testá-lo — um código
que só é testável depois de alterado não está sendo testado.

`falso-supabase.mjs` sobe os servidores de mentira — Supabase, Uazapi e Vantoro;
`prova.mjs` levanta a ponte apontada para eles, faz as chamadas que o painel e a
Uazapi fariam, e confere o que ficou no banco.

### O falso corta em mil, igual ao de verdade

O PostgREST devolve no máximo 1000 linhas por consulta e **não avisa**: a
resposta chega com mil linhas e cara de resposta inteira. É o defeito que mais
se repetiu neste projeto.

Um falso que devolvesse tudo esconderia justamente esse defeito — o teste
passaria aqui e quebraria em produção, no dia em que a tabela crescesse. Então o
falso também corta em mil. Foi assim que a conferência das permissões encontrou
a pessoa espelhada depois da milésima linha, que nunca recebia permissão nenhuma.

### A rodada de sincronização demora 20 segundos para sair

É o intervalo de verdade, e a prova espera por ele em vez de chamar uma função
exportada só para o teste — isso provaria a função, não o sistema. Por isso a
seção 6 leva cerca de 45 segundos.

## O que ele cobre

| | |
|---|---|
| **webhook** | mensagem recebida vira contato + conversa + mensagem; reenvio da mesma mensagem não duplica |
| **segredo do webhook** | sem `WEBHOOK_TOKEN` tudo passa (e avisa no log); com ele, só passa quem tem o segredo, na URL ou no cabeçalho |
| **fila de envio** | manda para a Uazapi, marca como enviada, devolve o que travou de verdade, e **não** reenvia o que acabou de ser reivindicado |
| **rotas protegidas** | sem login, com sessão inválida, e a importação de histórico sem senha |
| **sessão** | seis chamadas seguidas conferem a sessão uma vez só, e sessão recusada não fica lembrada como recusada |
| **permissões** | a cópia do Vantoro chega a quem está depois da milésima linha; telefone escrito com parênteses e traço encontra o número; "ninguém definiu" não vira "não vê nada"; permissão que não mudou **não é reescrita**; gravação que falha não deixa ninguém sem ver nada; e o custo da rodada não cresce por pessoa |
| **importação de histórico** | traz o passado com a data do passado; a foto vai para o Storage e não fica no link que expira; rodar de novo não duplica **nem mente no número**; banco recusando dá uma frase em português; e importar o passado não apaga o aviso de mensagem por ler |
| **mídia recebida** | a foto vira mensagem e arquivo no Storage; a rota de download que serve é lembrada em vez de reprocurada a cada mídia; o conteúdo do cliente não vai para o log quando dá certo; e download impossível deixa a miniatura, nunca perde a mensagem |
| **motivo do erro** | a falha no envio vira uma frase em português que diz o que fazer, o texto técnico fica guardado à parte, e erro **desconhecido não vira frase genérica** — o texto cru vai para a tela e o log avisa |
| **resposta ao aviso de audiência** | só a resposta logo depois do aviso, a que cita o aviso e a reação do cliente nele vão ao Vantoro — nunca o "ok" dado à equipe, a legenda de foto ou o aviso velho; cada uma vai uma vez; o Vantoro dormindo ou sem a rota não perde a resposta; e o log nunca leva o que o cliente escreveu |
| **a IA lê as douradas** | só a resposta que o Vantoro não entendeu vai ao Claude do copiloto, com o aviso entre etiquetas e a resposta presa às três leituras; a leitura volta ao Vantoro uma vez; sem a chave, ou com um Vantoro que não sabe receber, a IA não é perguntada; a IA que não responde ganha três rodadas; e o log nunca leva o que o cliente escreveu |
| **o aviso no contato que já existe** | o aviso de audiência vai para o contato que já existe na outra forma do nono dígito (com ou sem conversa com a linha), sem mudar o número dele; sem contato, nasce um com o número do cadastro; com as duas formas, vai a conversa mais recente, nos dois sentidos, e o log manda juntar; e o fixo não ganha nono dígito |
| **os duplicados do nono dígito, juntos (036)** | num Postgres de verdade: fica o contato por onde o cliente escreve (nem o mais novo, nem o de atividade mais recente, nem a forma com o nove), com o número que já tinha; as conversas da mesma linha viram uma, sem repetir o aviso gravado nas duas, com as não lidas somadas e a espera recontada; o "Já tratei" da conversa do aviso não vira o do cliente; o funil, a resposta automática, o histórico e o que só o contato que saiu tinha vão junto; o fixo não ganha nono dígito; rodar de novo não muda nada; e o índice que a junção não sabe comparar faz o banco recusar tudo |
