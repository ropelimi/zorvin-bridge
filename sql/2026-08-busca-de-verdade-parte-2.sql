-- ============================================================
--  PARTE 2 — O ÍNDICE DAS MENSAGENS
--
--  Este índice é SÓ VELOCIDADE. Os dois defeitos relatados — o cliente com
--  acento no nome que não aparecia, e a palavra da conversa que não achava —
--  já estão corrigidos pela parte 1. Sem este índice a busca por mensagem
--  funciona; ela lê mensagem por mensagem dentro do telefone, e num telefone
--  com muito histórico pode ficar lenta ou passar dos 8 segundos da API (e aí
--  a tela avisa, em vez de dizer que não achou nada).
--
--  Ou seja: dá para deixar para depois, com calma. Não há nada quebrado
--  esperando por ele.
--
--  ------------------------------------------------------------
--  POR QUE A VERSÃO ANTERIOR DESTE ARQUIVO NÃO RODOU
--
--  Ela usava `create index concurrently`, que não pode rodar dentro de uma
--  transação — e o editor de SQL do Supabase envolve TUDO numa transação,
--  inclusive uma linha só. Não havia como rodar aquilo ali, e a instrução que
--  acompanhava o arquivo ("rode só a linha do create index") não resolvia.
--
--  E o motivo que eu tinha dado para exigir o `concurrently` estava errado.
--  Eu disse que as mensagens que chegassem durante a criação seriam RECUSADAS
--  e se perderiam. Medido: elas ESPERAM e entram. `create index` bloqueia a
--  gravação, não a rejeita. A mensagem só se perderia se a espera passasse do
--  teto de 8 segundos da API — quer dizer, se a criação do índice demorasse
--  mais do que isso.
--
--  Medido num Postgres 16 com 264 mil mensagens: o índice ficou pronto em
--  3,1 segundos. Cerca de 12 microssegundos por mensagem.
--  ------------------------------------------------------------
-- ============================================================


-- ------------------------------------------------------------
--  PASSO 1 — QUANTO ISSO VAI CUSTAR NESTA BASE
--
--  Rode só isto primeiro e leia a resposta.
-- ------------------------------------------------------------
select count(*)                                   as mensagens,
       round(count(*) * 0.0000116, 1)             as segundos_estimados,
       case when count(*) * 0.0000116 < 5
            then 'Pode ir pelo PASSO 2. Nada se perde.'
            else 'Vá pelo PASSO 3 (conexão direta): a criação passaria perto '
                 || 'do teto de 8 segundos da API.'
       end                                        as o_que_fazer
  from mensagens;


-- ------------------------------------------------------------
--  PASSO 2 — O ÍNDICE, se o passo 1 disse que pode
--
--  Roda no editor do Supabase, normalmente. As mensagens que chegarem durante
--  a criação esperam alguns segundos e entram.
--
--  Ainda assim, prefira um horário de pouco movimento: é o tipo de coisa que
--  não custa nada adiar e custa caro apressar.
-- ------------------------------------------------------------
--  O `gin_trgm_ops` mora onde o `pg_trgm` foi instalado — `extensions` no
--  Supabase, `public` em outras bases. O bloco descobre qual é em vez de
--  obrigar quem roda a escolher entre duas linhas parecidas.
do $$
declare esquema text;
begin
  if to_regclass('public.mensagens_busca_idx') is not null then
    raise notice 'O índice já existe. Nada a fazer.';
    return;
  end if;
  select n.nspname into esquema
    from pg_opclass o join pg_namespace n on n.oid = o.opcnamespace
   where o.opcname = 'gin_trgm_ops'
   limit 1;
  if esquema is null then
    raise exception 'A extensão pg_trgm não está instalada. Rode a parte 1 primeiro.';
  end if;
  execute format(
    'create index mensagens_busca_idx on public.mensagens '
    'using gin (public.zorvin_sem_acento(texto) %I.gin_trgm_ops)', esquema);
  raise notice 'Índice criado.';
end $$;


-- ------------------------------------------------------------
--  PASSO 3 — SÓ SE O PASSO 1 MANDOU (base grande)
--
--  Aí é preciso o `concurrently`, que monta o índice sem travar ninguém — e
--  ele só roda FORA do editor do Supabase, porque o editor abre transação.
--
--  No painel do Supabase: Project Settings → Database → Connection string →
--  aba "PSQL". Copie aquilo, cole num terminal, e rode:
--
--     create index concurrently if not exists mensagens_busca_idx
--       on public.mensagens using gin (public.zorvin_sem_acento(texto) gin_trgm_ops);
--
--  Demora bem mais que os segundos do passo 2 (ele passa duas vezes pela
--  tabela), e é justamente por isso que não trava nada.
--
--  Se o `concurrently` for interrompido no meio, ele deixa um índice INVÁLIDO
--  para trás. Confira e, se for o caso, apague e repita:
--
--     select indexrelid::regclass as indice, indisvalid as valido
--       from pg_index where indexrelid = 'mensagens_busca_idx'::regclass;
--     -- se valido = false:
--     drop index concurrently mensagens_busca_idx;
-- ------------------------------------------------------------


-- ------------------------------------------------------------
--  CONFERÊNCIA — depois de qualquer um dos caminhos
-- ------------------------------------------------------------
select coalesce(
         (select 'índice pronto e válido: ' || i.indisvalid::text
            from pg_index i where i.indexrelid = to_regclass('public.mensagens_busca_idx')),
         'o índice ainda não existe (a busca funciona sem ele, só mais devagar)'
       ) as situacao;
