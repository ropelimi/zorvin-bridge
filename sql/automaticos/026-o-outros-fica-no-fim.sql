-- ============================================================
--  O OUTROS SEMPRE NO FIM DA LISTA DO "JÁ TRATEI"
--
--  Pedido do Rodrigo em 14/10, logo depois do 025: "Deixe o OUTROS sempre no
--  fim". O 025 pôs a lista inteira em ordem alfabética, com o OUTROS entre
--  DOCUMENTOS JG e REPASSE; agora ela fica em ordem alfabética, e o OUTROS
--  depois de todos.
--
--  ------------------------------------------------------------
--  UMA MARCA, E NÃO O NOME "OUTROS"
--
--  `zorvin_assuntos.fica_no_fim`. A régua é a do 009 (`pede_descricao`):
--  conferir o nome à mão seria uma regra escondida, e ela quebraria no dia
--  em que alguém corrigisse o nome pela tela — "OUTROS ASSUNTOS" voltaria
--  para o meio da lista. A marca vai junto com o assunto em qualquer
--  renomeação.
--
--  E NÃO É A MARCA DO "PEDE DESCRIÇÃO": a tela deixa ligá-la em qualquer
--  assunto, e ligar a descrição em ACORDOS não pode mandar ACORDOS para o
--  fim. São duas perguntas diferentes.
--
--  ------------------------------------------------------------
--  A ORDEM, AGORA
--
--  Primeiro os que não têm a marca, em ordem alfabética (a chave do 025:
--  acento e maiúscula não decidem); depois os que têm, também em ordem
--  alfabética entre si. O gatilho do 025 passa a disparar também quando a
--  marca muda, e não só o nome: ligada ou desligada por SQL, ou um dia por
--  uma tela, a lista se arruma na mesma instrução.
--
--  Este script é a VERSÃO DE REFERÊNCIA de `zorvin_ordenar_assuntos()` e do
--  gatilho daqui para a frente (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  A MARCA SÓ É LIGADA NA RODADA QUE CRIA A COLUNA — regra 5
--
--  No OUTROS em uso. Se depois alguém a desligar, rodar a pasta de novo não
--  a religa.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    005 — a tabela dos assuntos;
--    025 — a ordem alfabética.
--  Sem eles, desiste e diz qual falta.
-- ============================================================

do $nofim$
declare
  v_coluna_nova boolean;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_026;
  create temp table zorvin_conferencia_026 (item text, resposta text);

  if to_regclass('public.zorvin_assuntos') is null then
    insert into zorvin_conferencia_026
      values ('sem a tabela dos assuntos', 'rode o script 005 antes');
    raise notice 'Zorvin: sem zorvin_assuntos — script 026 não fez nada. Rode o 005 antes.';
    return;
  end if;
  if to_regprocedure('public.zorvin_ordenar_assuntos()') is null then
    insert into zorvin_conferencia_026
      values ('sem a ordem alfabética', 'rode o script 025 antes');
    raise notice 'Zorvin: sem zorvin_ordenar_assuntos — script 026 não fez nada. Rode o 025 antes.';
    return;
  end if;

  v_coluna_nova := not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'zorvin_assuntos'
       and column_name = 'fica_no_fim');

  execute 'alter table public.zorvin_assuntos
             add column if not exists fica_no_fim boolean not null default false';
  execute $c$comment on column public.zorvin_assuntos.fica_no_fim is
    'O assunto fica depois de todos na lista do "Já tratei", em vez de no seu '
    'lugar alfabético. Nasce ligada no OUTROS (script 026).'$c$;

  -- A MARCA NO OUTROS, só na rodada que cria a coluna.
  if v_coluna_nova then
    update public.zorvin_assuntos
       set fica_no_fim = true
     where ativo and lower(btrim(nome)) = 'outros';
  end if;

  -- A ORDEM: quem não fica no fim, em ordem alfabética; depois quem fica.
  -- `create or replace` guarda as permissões que o 025 deu; elas são
  -- escritas de novo logo abaixo para este script ser a referência inteira.
  execute $f$
    create or replace function public.zorvin_ordenar_assuntos() returns void
      language plpgsql security invoker set search_path = public as $c$
    begin
      perform pg_advisory_xact_lock(hashtextextended('zorvin_ordenar_assuntos', 0));
      update public.zorvin_assuntos a
         set ordem = x.posicao
        from (select s.id,
                     row_number() over (
                       order by s.fica_no_fim,
                                public.zorvin_chave_do_assunto(s.nome) collate "C",
                                s.nome collate "C", s.id) as posicao
                from public.zorvin_assuntos s) x
       where a.id = x.id
         and a.ordem is distinct from x.posicao;
    end
    $c$
  $f$;
  execute 'revoke all on function public.zorvin_ordenar_assuntos() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_ordenar_assuntos() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_ordenar_assuntos() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_ordenar_assuntos() to service_role';
  end if;

  -- O GATILHO, agora também na troca da marca.
  execute 'drop trigger if exists zorvin_assuntos_em_ordem on public.zorvin_assuntos';
  execute 'create trigger zorvin_assuntos_em_ordem
             after insert or update of nome, fica_no_fim on public.zorvin_assuntos
             for each statement execute function public.zorvin_assuntos_em_ordem()';

  -- A LISTA DE HOJE, de uma vez: a marca acima foi ligada antes do gatilho
  -- novo, e é esta renumeração que leva o OUTROS para o fim.
  perform public.zorvin_ordenar_assuntos();

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele.
  -- ----------------------------------------------------------
  --  A MARCA É PROCURADA PELO NOME SÓ NA RODADA QUE CRIA A COLUNA, que é a
  --  que a liga. Numa rodada de novo o nome pode ter mudado pela tela (e a
  --  marca foi junto), ou a marca pode ter sido desligada de propósito: as
  --  duas coisas são escolha, e nenhuma é defeito.
  insert into zorvin_conferencia_026
  select 'o OUTROS ganhou a marca de ficar no fim',
         case
           when not v_coluna_nova
             then 'a coluna já existia — esta rodada não liga nem desliga a marca'
           when exists (select 1 from public.zorvin_assuntos
                         where ativo and fica_no_fim and lower(btrim(nome)) = 'outros')
             then 'true'
           else 'NÃO — não achei um assunto chamado OUTROS em uso para marcar'
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
$nofim$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_026;
