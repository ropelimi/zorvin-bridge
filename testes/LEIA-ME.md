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
