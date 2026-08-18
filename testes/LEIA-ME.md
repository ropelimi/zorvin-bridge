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

`falso-supabase.mjs` sobe os dois servidores; `prova.mjs` levanta a ponte
apontada para eles, faz as chamadas que o painel e a Uazapi fariam, e confere o
que ficou no banco.

## O que ele cobre

| | |
|---|---|
| **webhook** | mensagem recebida vira contato + conversa + mensagem; reenvio da mesma mensagem não duplica |
| **segredo do webhook** | sem `WEBHOOK_TOKEN` tudo passa (e avisa no log); com ele, só passa quem tem o segredo, na URL ou no cabeçalho |
| **fila de envio** | manda para a Uazapi, marca como enviada, devolve o que travou de verdade, e **não** reenvia o que acabou de ser reivindicado |
| **rotas protegidas** | sem login, com sessão inválida, e a importação de histórico sem senha |
| **sessão** | seis chamadas seguidas conferem a sessão uma vez só, e sessão recusada não fica lembrada como recusada |
