-- ============================================================
--  PARTE 2 — O ÍNDICE DAS MENSAGENS
--
--  RODE ESTA LINHA SOZINHA, e depois da parte 1.
--
--  POR QUE SEPARADA. Criar índice numa tabela trava as gravações dela
--  enquanto o índice é montado. `mensagens` é a maior tabela do sistema e
--  recebe escrita o tempo todo: é nela que caem as mensagens que os clientes
--  estão mandando agora. Um índice comum poderia travá-la por minutos — e as
--  mensagens que chegassem nesse tempo seriam RECUSADAS. A ponte já respondeu
--  "recebido" para a Uazapi antes de gravar, então ela não reenvia: a mensagem
--  do cliente se perde de vez.
--
--  `concurrently` monta o índice sem travar ninguém. Custa duas passadas pela
--  tabela em vez de uma (demora mais), e é o preço certo.
--
--  E ele NÃO pode rodar dentro de uma transação — é por isso que está sozinho
--  neste arquivo. Se o editor do Supabase reclamar "cannot run inside a
--  transaction block", copie só a linha do `create index` e rode ela.
--
--  ENQUANTO ESTE ÍNDICE NÃO EXISTIR, a busca por nome já funciona (parte 1) e
--  a busca por mensagem funciona porém devagar — ela fica recortada no
--  telefone, que é o que a torna possível, mas ainda lê mensagem por mensagem.
--  Num telefone com muito histórico, pode passar dos 8 segundos e falhar; a
--  tela avisa quando isso acontece, em vez de dizer que não achou nada.
--
--  Seguro rodar de novo.
-- ============================================================

-- O `set` resolve onde o `pg_trgm` foi instalado (no Supabase é `extensions`;
-- noutras bases é `public`), sem qualificar o nome à mão e sem abrir transação
-- — o `concurrently` não pode rodar dentro de uma.
set search_path = public, extensions;

create index concurrently if not exists mensagens_busca_idx
  on public.mensagens using gin (public.zorvin_sem_acento(texto) gin_trgm_ops);

-- Depois, para conferir:
--   select indexname from pg_indexes where indexname = 'mensagens_busca_idx';
