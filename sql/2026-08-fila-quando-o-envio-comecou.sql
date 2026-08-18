-- QUANDO O ENVIO COMEÇOU — uma coluna, contra mensagem enviada duas vezes.
--
-- Rodar no SQL Editor do Supabase. Idempotente.
--
-- A ponte devolve para a fila os itens que ficaram presos em 'enviando' por
-- mais de 5 minutos: é o que salva a mensagem quando o serviço reinicia no meio
-- de um envio. A conta era feita sobre `criado_em` — o momento em que o item
-- foi CRIADO —, e não sobre o momento em que o envio começou.
--
-- A diferença manda a mesma mensagem duas vezes para o cliente. Um item que
-- esperou 6 minutos na fila e acabou de ser reivindicado já se encaixa em
-- "preso há mais de 5 minutos": outro ciclo o devolve para 'pendente' enquanto
-- o primeiro ainda está falando com a Uazapi, e a mensagem sai de novo.
--
-- Dentro de um processo só isso não acontecia (há uma trava em memória). Basta
-- uma segunda instância no ar — o que ocorre em toda publicação, com a nova
-- subindo antes de a antiga sair — para acontecer.
alter table fila_envio add column if not exists enviando_em timestamptz;

comment on column fila_envio.enviando_em is
  'Quando este item foi reivindicado para envio. É por ele que se decide se um item está travado.';

-- Para a varredura de itens travados não percorrer a fila inteira.
create index if not exists fila_envio_enviando
  on fila_envio (enviando_em) where status = 'enviando';
