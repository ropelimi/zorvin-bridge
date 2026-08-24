-- A NOTA INTERNA PASSA A PODER APONTAR PARA UM PROCESSO.
--
-- Rodar INTEIRO no SQL Editor do Supabase. Idempotente: pode rodar de novo.
--
-- ------------------------------------------------------------------
-- POR QUE ESTAS TRÊS COLUNAS
-- ------------------------------------------------------------------
--
-- A equipe escreve a nota dentro da conversa, que é onde ela está quando
-- descobre o que precisa anotar. Mas quem for procurar aquilo meses depois vai
-- à ficha do cliente, ou ao histórico do processo. Então a nota sobe para o
-- Vantoro — e para subir, três coisas precisam ficar guardadas aqui.
--
-- O VÍNCULO COM O CLIENTE NÃO ESTÁ AQUI, e é de propósito: ele já existe pela
-- conversa (`notas.conversa_id` → `conversas.contato_id` → `contatos.
-- vantoro_cliente_id`). Repetir o cliente na nota criaria duas verdades sobre
-- de quem ela é, e no dia em que divergissem não haveria como saber qual vale.
--
-- O PROCESSO É OPCIONAL. Uma nota pode ser sobre o cliente ("mudou de
-- telefone", "vai viajar em março") e não sobre ação nenhuma — essa é a nota
-- geral, e é o caso comum. O processo existe para facilitar achar a informação
-- depois, não para classificar tudo.

alter table notas add column if not exists processo_id          bigint;
alter table notas add column if not exists processo_numero      text;
alter table notas add column if not exists vantoro_atividade_id bigint;

comment on column notas.processo_id is
  'Id do processo no Vantoro. Nulo = nota geral do cliente, que é o caso comum.';

-- O NÚMERO GUARDADO JUNTO, e não só o id.
--
-- Sem ele, desenhar a nota na conversa exigiria perguntar ao Vantoro qual é o
-- processo de cada uma — uma ida à rede por nota, numa lista que rola. E numa
-- conversa aberta com o Vantoro fora do ar, as notas apareceriam sem dizer de
-- que processo são, que é justamente a informação que elas ganharam.
--
-- É uma cópia, e cópia pode envelhecer: se o número do processo for corrigido
-- no Vantoro, o que está aqui fica velho. Vale a pena mesmo assim — o número
-- do processo praticamente não muda, e o id continua sendo a verdade.
comment on column notas.processo_numero is
  'O número do processo, copiado para a tela não precisar perguntar. O id é a verdade.';

comment on column notas.vantoro_atividade_id is
  'A atividade que esta nota virou no Vantoro. É o outro lado do elo — o Vantoro '
  'guarda o id da nota em `id_externo`, e daqui se guarda o dele.';

-- Índice para a pergunta "quais notas são deste processo?", que a tela do
-- processo vai fazer. Parcial: a maioria das notas é geral, e indexar nulo
-- seria indexar a maioria para nada.
create index if not exists notas_processo_idx
  on notas (processo_id) where processo_id is not null;
