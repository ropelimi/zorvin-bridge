-- ============================================================
--  O ASSUNTO "DÚVIDAS TRATADAS" NO "JÁ TRATEI"
--
--  Pedido do Rodrigo em 14/10: "No 'Já tratei' incluir a opção 'Dúvidas
--  Tratadas'". Escrito em maiúsculas, como os outros assuntos da lista — a
--  sugestão foi feita a ele antes, e o nome pode ser corrigido pela tela.
--
--  O LUGAR NA LISTA não é escolhido aqui: o gatilho do 025 e do 026 o põe
--  na ordem alfabética, entre DOCUMENTOS JG e REPASSE, com o OUTROS no fim.
--
--  ------------------------------------------------------------
--  UMA SEMENTE ANOTADA — regra 5 do LEIA-ME
--
--  "Um script que semeia linha só semeia na rodada que CRIA a coluna ou a
--  tabela" — e este não cria nenhuma das duas: o assunto entra numa tabela
--  que já existe. Sem uma âncora, rodar a pasta de novo depois de o
--  escritório tirar o assunto de uso, ou renomeá-lo, o traria de volta.
--
--  A âncora é `zorvin_sementes`: cada linha que um script planta numa tabela
--  que já existia deixa ali uma CHAVE. Plantada uma vez, a chave fica, e
--  nenhuma rodada planta de novo. É a tabela que os próximos pedidos desta
--  forma ("inclua o assunto X") vão usar, em vez de inventar uma âncora cada.
--
--  Ela nasce com RLS ligada e SEM política, como `zorvin_scripts_aplicados`:
--  só a dona do banco e a ponte a alcançam. Nenhuma tela precisa dela.
--
--  ------------------------------------------------------------
--  O QUE JÁ FOI CRIADO À MÃO É APROVEITADO
--
--  Pela chave do 025, que ignora acento e maiúscula: "Dúvidas tratadas" ou
--  "DUVIDAS TRATADAS", criados pela tela antes da publicação, contam como o
--  mesmo assunto — o índice único do 005 (`lower(nome)`) deixaria nascer um
--  segundo, porque ele separa "Ú" de "U".
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    005 — a tabela dos assuntos;
--    025 — a chave e a ordem alfabética;
--    026 — o OUTROS no fim (a conferência confere a ordem inteira).
--  Sem eles, desiste e diz qual falta.
-- ============================================================

do $duvidas$
declare
  v_chave constant text := 'assunto:duvidas-tratadas';
  v_plantada boolean;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_027;
  create temp table zorvin_conferencia_027 (item text, resposta text);

  if to_regclass('public.zorvin_assuntos') is null then
    insert into zorvin_conferencia_027
      values ('sem a tabela dos assuntos', 'rode o script 005 antes');
    raise notice 'Zorvin: sem zorvin_assuntos — script 027 não fez nada. Rode o 005 antes.';
    return;
  end if;
  if to_regprocedure('public.zorvin_chave_do_assunto(text)') is null then
    insert into zorvin_conferencia_027
      values ('sem a ordem alfabética', 'rode o script 025 antes');
    raise notice 'Zorvin: sem zorvin_chave_do_assunto — script 027 não fez nada. Rode o 025 antes.';
    return;
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'zorvin_assuntos'
                    and column_name = 'fica_no_fim') then
    insert into zorvin_conferencia_027
      values ('sem o OUTROS no fim', 'rode o script 026 antes');
    raise notice 'Zorvin: sem zorvin_assuntos.fica_no_fim — script 027 não fez nada. Rode o 026 antes.';
    return;
  end if;

  -- AS SEMENTES — ver o cabeçalho.
  execute $x$
    create table if not exists public.zorvin_sementes (
      chave        text primary key,
      plantada_em  timestamptz not null default now()
    )
  $x$;
  execute $x$
    comment on table public.zorvin_sementes is
      'Cada linha que um script plantou numa tabela que já existia (um assunto '
      'do "Já tratei", por exemplo). Plantada uma vez, a chave fica, e rodar a '
      'pasta de novo não planta de novo — regra 5 do LEIA-ME de sql/automaticos.'
  $x$;
  execute 'alter table public.zorvin_sementes enable row level security';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.zorvin_sementes from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.zorvin_sementes from authenticated';
  end if;

  v_plantada := exists (select 1 from public.zorvin_sementes where chave = v_chave);

  if not v_plantada then
    if not exists (select 1 from public.zorvin_assuntos
                    where ativo
                      and public.zorvin_chave_do_assunto(nome) = 'duvidas tratadas') then
      insert into public.zorvin_assuntos (nome) values ('DÚVIDAS TRATADAS');
    end if;
    insert into public.zorvin_sementes (chave) values (v_chave);
  end if;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele.
  -- ----------------------------------------------------------
  --  FALTAR SÓ É DEFEITO NA RODADA QUE PLANTA. Numa rodada de novo, o
  --  assunto pode ter sido tirado de uso ou renomeado pela tela — escolha do
  --  escritório, e não defeito.
  insert into zorvin_conferencia_027
  select 'o DÚVIDAS TRATADAS está na lista do “Já tratei”',
         case
           when exists (select 1 from public.zorvin_assuntos
                         where ativo
                           and public.zorvin_chave_do_assunto(nome) = 'duvidas tratadas') then 'true'
           when not v_plantada then 'NÃO — o DÚVIDAS TRATADAS não foi criado'
           else 'fora de uso ou renomeado pela tela — rodar de novo não o traz de volta'
         end
  union all
  select 'a lista está em ordem, com o que fica no fim por último',
         (not exists (
            select 1
              from (select s.ordem,
                           row_number() over (
                             order by s.fica_no_fim,
                                      public.zorvin_chave_do_assunto(s.nome) collate "C",
                                      s.nome collate "C", s.id) as posicao
                      from public.zorvin_assuntos s) x
             where x.ordem is distinct from x.posicao))::text
  union all
  select 'os assuntos em uso, na ordem',
         (select string_agg(nome, ', ' order by ordem)
            from public.zorvin_assuntos where ativo);
end
$duvidas$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_027;
