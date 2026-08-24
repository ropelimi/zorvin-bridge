-- A NOTA PASSA A SABER QUANDO FOI EDITADA PELA ÚLTIMA VEZ.
--
-- RODAR NO SUPABASE `zorvin` (o do WhatsApp: conversas, mensagens, contatos,
-- notas, advogados). NÃO é no `vantoro` — lá o banco é do Django, e a coluna
-- equivalente (`Atividade.atualizado_em`) já entrou por migration.
--
-- Rodar INTEIRO no SQL Editor. Idempotente: pode rodar de novo.
--
-- ------------------------------------------------------------------
-- PARA QUE ESTA COLUNA EXISTE
-- ------------------------------------------------------------------
--
-- A nota interna passou a poder ser corrigida DOS DOIS LADOS: na conversa, aqui,
-- e na ficha do cliente, no Vantoro. Quando as duas versões se cruzam — e elas
-- se cruzam, porque a ponte reenvia quando a rede oscila — alguém tem de perder.
-- A regra combinada é: a edição mais nova vence.
--
-- `criado_em` NÃO SERVE para decidir isso: ele marca o nascimento e não se mexe
-- mais. Comparar com ele seria comparar o horário de uma edição com o de um
-- nascimento, e toda correção feita no Vantoro perderia para o primeiro reenvio
-- da nota original — apagando em silêncio o que alguém acabou de escrever.

alter table notas add column if not exists atualizado_em timestamptz;

-- QUEM JÁ EXISTE HERDA O PRÓPRIO NASCIMENTO.
--
-- `now()` para todas diria que o histórico inteiro do escritório foi editado no
-- minuto em que este script rodou — e na primeira comparação com o Vantoro, a
-- versão de lá perderia para uma edição que nunca aconteceu. `criado_em` é a
-- única data verdadeira que existe sobre estas linhas.
update notas set atualizado_em = criado_em where atualizado_em is null;

alter table notas alter column atualizado_em set default now();

comment on column notas.atualizado_em is
  'Quando esta nota mudou pela última vez. É o que decide quem vence quando a '
  'mesma nota é corrigida aqui e no Vantoro: a edição mais nova.';

-- ------------------------------------------------------------------
-- O CARIMBO SE MANTÉM SOZINHO — MAS NÃO ATROPELA O QUE VEM DE FORA
-- ------------------------------------------------------------------
--
-- Deixar cada `update` lembrar de carimbar é deixar para alguém esquecer, e o
-- esquecimento não dá erro: a nota fica com carimbo velho e passa a perder toda
-- comparação, em silêncio. Por isso o gatilho.
--
-- MAS ELE NÃO PODE CARIMBAR SEMPRE. Quando o aviso do Vantoro chega, a ponte
-- grava o carimbo DE LÁ de propósito — é a cópia de uma versão que foi escrita
-- naquele instante, não agora. Um gatilho que pusesse `now()` em toda gravação
-- faria esta linha parecer mais nova do que a versão que ela acabou de copiar,
-- e no próximo aviso ela ganharia dele, desfazendo a cópia. Os dois lados
-- ficariam se reescrevendo.
--
-- Daí a condição: o gatilho só carimba quando QUEM GRAVOU NÃO DISSE NADA sobre
-- o carimbo. Quem diz, manda.
create or replace function notas_carimbar_atualizado_em()
returns trigger
language plpgsql
as $$
begin
  -- `is not distinct from` e não `=`: com nulo dos dois lados, `=` devolve nulo
  -- (que não é verdadeiro), o gatilho não carimbaria, e a nota nasceria sem
  -- carimbo nenhum — justamente o caso que ele existe para cobrir.
  if new.atualizado_em is not distinct from old.atualizado_em then
    new.atualizado_em := now();
  end if;
  return new;
end;
$$;

drop trigger if exists notas_carimbar on notas;
create trigger notas_carimbar
  before update on notas
  for each row
  execute function notas_carimbar_atualizado_em();

-- Índice para "o que mudou desde quando?", que é a pergunta de qualquer
-- reconciliação futura entre os dois sistemas.
create index if not exists notas_atualizado_idx on notas (atualizado_em desc);
