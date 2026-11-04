-- ============================================================
--  O NÚMERO DE CADA ABA, POR RESPONSÁVEL
--
--  >>> A PONTE APLICA SOZINHA (sql/automaticos). <<<
--  Pode rodar de novo sem medo — a pasta inteira, na ordem (regra 5).
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 04/11, com a foto do alto da lista: "Excluir a
--  mensagem 'ATENDENDO COMO' e ao lado no número de telefone colocar uma
--  opção de selecionar o responsável pela conversa. Ao selecionar o
--  responsável, aparecer apenas as conversas do responsável, mostrando em
--  'Novos', 'Em atendimento', 'Finalizados' e 'Não lidas' apenas as conversas
--  correspondentes ao responsável selecionado. Precisa ter a possibilidade de
--  selecionar mais de um responsável."
--
--  A LISTA o painel recorta sozinho, pela coluna `responsavel_id` (008). O
--  NÚMERO de cada aba, não: ele vem de `zorvin_contar_situacoes` (028), que
--  conta o telefone inteiro. Com o seletor ligado, o número ao lado de "Em
--  Atendimento" diria 403 sobre uma lista com as 40 conversas da Jenifer.
--
--    zorvin_contar_situacoes(p_telefone, p_responsaveis, p_sem_responsavel)
--
--    - sem `p_responsaveis` (ou com a lista vazia) e sem `p_sem_responsavel`:
--      conta tudo, como antes. É a chamada do painel de antes — só com o
--      telefone —, e ela continua valendo;
--    - com `p_responsaveis`: só as conversas dessas pessoas;
--    - com `p_sem_responsavel`: também as conversas sem responsável (ou só
--      elas, sem `p_responsaveis`).
--
--  AS MESMAS REGRAS DO 028: sem as arquivadas e sem a conversa que nunca teve
--  mensagem — o número é o da lista. E `security invoker`: conta o que quem
--  pergunta enxerga.
--
--  ------------------------------------------------------------
--  A VERSÃO DE ANTES SAI, e não fica ao lado
--
--  `create or replace` com outra lista de argumentos cria uma SEGUNDA função
--  com o mesmo nome. A chamada do painel só com o telefone passaria a ter
--  duas candidatas e morreria com "could not choose the best candidate
--  function" (a lição do 010). Aqui a de um argumento sai e a de três entra
--  na mesma transação — não há instante sem a função —, e a de três, com os
--  dois argumentos novos de padrão, atende a chamada de antes.
--
--  A VERSÃO DE REFERÊNCIA de `zorvin_contar_situacoes` (regra 5 do LEIA-ME)
--  passa a ser esta: rodar o 028 sozinho depois dela poria de volta a de um
--  argumento AO LADO desta, e as duas brigariam pela chamada do painel. Rode
--  a pasta inteira, na ordem.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    o 008 (o responsável) e o 028 (as abas). Sem eles, não faz nada e diz.
-- ============================================================

do $contar$
declare
  -- OS PAPÉIS DA SUPABASE podem não existir num Postgres que não é o dela
  -- (a régua do 030 ao 033): cada permissão para eles pergunta antes.
  v_anon  boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth  boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv   boolean := exists (select 1 from pg_roles where rolname = 'service_role');
  v_resposta text;
  v_diferentes int;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_046;
  create temp table zorvin_conferencia_046 (item text, resposta text);

  if to_regclass('public.conversas') is null
     or to_regclass('public.mensagens') is null
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'conversas'
                       and column_name = 'responsavel_id')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'conversas'
                       and column_name = 'situacao') then
    insert into zorvin_conferencia_046
      values ('sem o responsável (008) ou sem as abas (028)', 'nada a fazer aqui');
    raise notice 'Zorvin: sem o 008 ou sem o 028 — script 046 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. A CONTA, AGORA COM OS RESPONSÁVEIS
  --
  --  "Sem filtro" é a lista vazia E nenhum sem-responsável: as duas metades
  --  ausentes. A lista vazia vale como ausente, e não como "ninguém" — uma
  --  conta de zero em tudo por causa de um `[]` seria a aba dizendo que não
  --  há nada quando ninguém pediu filtro nenhum.
  -- ----------------------------------------------------------
  execute 'drop function if exists public.zorvin_contar_situacoes(uuid)';
  execute $x$
    create or replace function public.zorvin_contar_situacoes(
      p_telefone        uuid,
      p_responsaveis    uuid[]  default null,
      p_sem_responsavel boolean default false)
    returns jsonb language sql stable security invoker set search_path = public as $f$
      select jsonb_build_object(
               'aguardando', count(*) filter (where c.situacao = 'aguardando'),
               'aberto',     count(*) filter (where c.situacao = 'aberto'),
               'finalizado', count(*) filter (where c.situacao = 'finalizado'),
               'nao_lidas',  jsonb_build_object(
                 'aguardando', count(*) filter (where c.situacao = 'aguardando' and coalesce(c.nao_lidas, 0) > 0),
                 'aberto',     count(*) filter (where c.situacao = 'aberto' and coalesce(c.nao_lidas, 0) > 0),
                 'finalizado', count(*) filter (where c.situacao = 'finalizado' and coalesce(c.nao_lidas, 0) > 0)))
        from public.conversas c
       where c.advogado_id = p_telefone
         and not coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false)
         and exists (select 1 from public.mensagens m where m.conversa_id = c.id)
         and (   (coalesce(cardinality(p_responsaveis), 0) = 0 and not coalesce(p_sem_responsavel, false))
              or c.responsavel_id = any(p_responsaveis)
              or (coalesce(p_sem_responsavel, false) and c.responsavel_id is null))
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_contar_situacoes(uuid, uuid[], boolean) from public';
  if v_anon then
    execute 'revoke all on function public.zorvin_contar_situacoes(uuid, uuid[], boolean) from anon';
  end if;
  if v_auth then
    execute 'grant execute on function public.zorvin_contar_situacoes(uuid, uuid[], boolean) to authenticated';
  end if;
  if v_srv then
    execute 'grant execute on function public.zorvin_contar_situacoes(uuid, uuid[], boolean) to service_role';
  end if;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_046
  select 'uma conta só (a de um argumento saiu)',
         (select case when count(*) = 1 then 'true'
                      else 'NÃO — ' || count(*) || ' funções com este nome' end
            from pg_proc
           where proname = 'zorvin_contar_situacoes'
             and pronamespace = 'public'::regnamespace);

  -- AS PARTES SOMAM O TODO, em cada telefone: as conversas de cada
  -- responsável mais as sem responsável têm de dar o número de sempre. É a
  -- conferência de que o recorte não perde nem repete ninguém — sobre os
  -- dados de verdade, e não sobre um exemplo.
  select count(*) into v_diferentes
    from public.advogados a
   where public.zorvin_contar_situacoes(a.id)
         <> public.zorvin_contar_situacoes(
              a.id,
              (select array_agg(distinct c.responsavel_id) from public.conversas c
                where c.advogado_id = a.id and c.responsavel_id is not null),
              true);
  insert into zorvin_conferencia_046 values
    ('as conversas de cada responsável, mais as sem responsável, dão o número de cada aba',
     case when v_diferentes = 0 then 'true'
          else 'NÃO — ' || v_diferentes || ' telefone(s) com a conta diferente' end);

  if v_anon then
    insert into zorvin_conferencia_046 values
      ('quem não entrou não chama a conta',
       (not has_function_privilege('anon', 'public.zorvin_contar_situacoes(uuid, uuid[], boolean)', 'execute'))::text);
  end if;
end
$contar$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua 4 do LEIA-ME: o painel
--  chama a conta como `authenticated`, só com o telefone (como antes) e com
--  os responsáveis. A troca de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regprocedure('public.zorvin_contar_situacoes(uuid, uuid[], boolean)') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    execute 'select public.zorvin_contar_situacoes(p_telefone => null::uuid)';
    execute 'select public.zorvin_contar_situacoes(p_telefone => null::uuid, p_responsaveis => array[gen_random_uuid()], p_sem_responsavel => true)';
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_046 values
    ('quem atende chama a conta, com e sem os responsáveis', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_046;
