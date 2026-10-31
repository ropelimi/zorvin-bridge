-- ============================================================
--  QUEM ESTÁ ESPERANDO DEMAIS (31/10)
--
--  A ponte aplica sozinha. Pode rodar de novo sem medo — com a pasta inteira,
--  na ordem (regra 5 do LEIA-ME).
--
--  ------------------------------------------------------------
--  POR QUE EXISTE
--
--  Pedido do Rodrigo, da lista de recomendações de 31/10: um aviso quando um
--  cliente passa de alguns minutos sem resposta no expediente. MEDIDO em
--  31/10, nos 30 dias anteriores, só nos atendimentos que o CLIENTE abriu
--  (sem grupos):
--
--    abertos dentro do expediente         297
--    respondidos em até 30 minutos         57   (19%)
--    mediana até a primeira resposta      1 h 46 min
--    sem resposta nenhuma                 118   (40%)
--
--  O painel não tinha como dizer "este cliente espera há 40 minutos": a
--  espera só aparecia em dias ("esperando há 3 dias"), e o aviso de mensagem
--  nova toca uma vez, na chegada — e depois disso ninguém mais é lembrado.
--
--  ------------------------------------------------------------
--  O QUE ESTE SCRIPT FAZ
--
--    1. `zorvin_minutos_no_expediente(semana, fuso, desde, ate)` — quantos
--       minutos de EXPEDIENTE há entre duas horas, dia a dia, pela régua de
--       `zorvin_expediente_do_dia` (021), que já sabe dos feriados. É a mesma
--       semana que decide a resposta fora do horário: duas escritas do
--       expediente divergiriam no primeiro feriado.
--    2. `zorvin_aviso_de_espera` — por departamento, se o aviso está ligado e
--       depois de quantos minutos de expediente. SEM LINHA, VALE O PADRÃO:
--       ligado, 30 minutos.
--    3. `zorvin_clientes_sem_resposta()` — os clientes que abriram um
--       atendimento e esperam a primeira resposta há mais do que o limite do
--       departamento, contado só no expediente. `security invoker`: cada um
--       recebe só as conversas que vê.
--
--  QUEM É AVISADO é decisão do PAINEL, e é a régua do aviso de mensagem nova
--  (ver o CLAUDE.md dele): a conversa com responsável avisa só ele; a sem
--  responsável avisa todo mundo que a vê. Por isso a função devolve o
--  `responsavel_id`, e não recorta por ele.
--
--  LIGADO DESDE A PUBLICAÇÃO, e é decisão. A resposta fora do horário e a
--  distribuição nasceram desligadas porque falam com o cliente ou dão
--  trabalho a alguém sem ninguém ter escolhido. Este aviso só toca para a
--  equipe, e foi pedido. Quem administra desliga por departamento.
--
--  30 MINUTOS, e não 15 nem 60. Medido: dos clientes do expediente, 14% já
--  tinham resposta em 15 minutos, 19% em 30 e 24% em 60. Quantos avisos
--  tocam quase não muda — a maioria espera horas —; o que muda é quando.
--  Trinta dá à equipe tempo de responder sem precisar do aviso, e ainda chega
--  antes de a espera virar hora. Quem administra troca na aba Aviso de
--  espera, de 5 a 480 minutos.
-- ============================================================

do $quem_espera$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada só depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_041;
  create temp table zorvin_conferencia_041 (item text, resposta text);

  -- A CONTA DO EXPEDIENTE É DO 021, e ele a cria até num banco sem o Zorvin.
  if to_regprocedure('public.zorvin_expediente_do_dia(jsonb,date)') is null then
    insert into zorvin_conferencia_041 values ('a conta do expediente', 'rode o script 021 antes');
    raise notice 'Zorvin: sem a conta do expediente (021) — script 041 não fez nada.';
    return;
  end if;

  -- ----------------------------------------------------------
  --  1. QUANTOS MINUTOS DE EXPEDIENTE HÁ ENTRE DUAS HORAS
  --
  --  Dia a dia, de `desde` a `ate`, no fuso do departamento: em cada dia,
  --  quanto do intervalo cai dentro da faixa daquele dia. Feriado e dia
  --  fechado não têm faixa, e não somam nada.
  --
  --  SEM SEMANA, O RELÓGIO INTEIRO. O departamento que nunca abriu a aba Fora
  --  do horário não tem expediente escrito, e calar o aviso por isso seria o
  --  cliente esperando sem ninguém saber. Já a semana com todos os dias
  --  fechados é uma escolha, e vale: nada soma.
  --
  --  O FUSO NÃO É CONFERIDO AQUI: o gatilho de `zorvin_fora_do_horario` (021)
  --  recusa o fuso desconhecido antes de gravar. Conferir a cada chamada
  --  (`pg_timezone_names`) custaria milissegundos por cliente, numa função que
  --  o painel chama de minuto em minuto.
  --
  --  O TETO DE 62 DIAS é só para a conta nunca virar um laço comprido: quem
  --  chama olha uma semana.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_minutos_no_expediente(
      p_semana jsonb, p_fuso text, p_desde timestamptz, p_ate timestamptz default now())
    returns integer language plpgsql stable set search_path = public as $f$
    declare
      v_fuso  text := coalesce(nullif(btrim(p_fuso), ''), 'America/Sao_Paulo');
      v_ate   timestamptz := coalesce(p_ate, now());
      v_dia   date;
      v_fim   date;
      v_faixa time[];
      v_abre  timestamptz;
      v_fecha timestamptz;
      v_seg   numeric := 0;
    begin
      if p_desde is null or p_desde >= v_ate then
        return 0;
      end if;
      if p_semana is null or jsonb_typeof(p_semana) <> 'object' then
        return floor(extract(epoch from v_ate - p_desde) / 60)::int;
      end if;
      v_dia := (p_desde at time zone v_fuso)::date;
      v_fim := (v_ate at time zone v_fuso)::date;
      if v_fim - v_dia > 62 then
        v_dia := v_fim - 62;
      end if;
      while v_dia <= v_fim loop
        v_faixa := public.zorvin_expediente_do_dia(p_semana, v_dia);
        if v_faixa is not null then
          v_abre := (v_dia + v_faixa[1]) at time zone v_fuso;
          v_fecha := (v_dia + v_faixa[2]) at time zone v_fuso;
          v_seg := v_seg + greatest(0, extract(epoch from least(v_ate, v_fecha) - greatest(p_desde, v_abre)));
        end if;
        v_dia := v_dia + 1;
      end loop;
      return floor(v_seg / 60)::int;
    end
    $f$
  $x$;
  -- A CONTA É DE QUEM ENTROU, e não de qualquer um: toda função nasce
  -- executável por `public`, que inclui `anon` (armadilha nº 5 da ponte). Quem
  -- atende precisa dela, porque a lista do item 3 roda no papel de quem pede.
  execute 'revoke all on function public.zorvin_minutos_no_expediente(jsonb, text, timestamptz, timestamptz) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_minutos_no_expediente(jsonb, text, timestamptz, timestamptz) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_minutos_no_expediente(jsonb, text, timestamptz, timestamptz) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_minutos_no_expediente(jsonb, text, timestamptz, timestamptz) to service_role';
  end if;

  insert into zorvin_conferencia_041
  select 'a conta dos minutos de expediente existe',
         (to_regprocedure('public.zorvin_minutos_no_expediente(jsonb,text,timestamptz,timestamptz)') is not null)::text;

  -- ----------------------------------------------------------
  --  A GUARDA: num banco limpo (a prova 51l-bis, ou um cliente novo) não há
  --  conversa, departamento nem atendimento, e o resto não tem onde morar.
  -- ----------------------------------------------------------
  if to_regclass('public.conversas') is null or to_regclass('public.contatos') is null
     or to_regclass('public.advogados') is null or to_regclass('public.departamentos') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_041 values ('sem as tabelas do Zorvin', 'só a conta dos minutos de expediente');
    raise notice 'Zorvin: sem as tabelas do Zorvin — o script 041 criou só a conta dos minutos de expediente.';
    return;
  end if;
  if to_regclass('public.zorvin_atendimentos') is null then
    insert into zorvin_conferencia_041 values ('os atendimentos (028)', 'rode o script 028 antes');
    return;
  end if;
  if to_regclass('public.zorvin_fora_do_horario') is null then
    insert into zorvin_conferencia_041 values ('o expediente dos departamentos (021)', 'rode o script 021 antes');
    return;
  end if;

  -- ----------------------------------------------------------
  --  2. A CONFIGURAÇÃO DE CADA DEPARTAMENTO
  --
  --  SEM LINHA, VALE O PADRÃO (ligado, 30 minutos), a régua do rodízio do
  --  023: o departamento criado amanhã já nasce avisando, sem ninguém lembrar
  --  de vir aqui. A linha só nasce quando quem administra muda alguma coisa.
  --
  --  DE 5 A 480 MINUTOS: menos de 5 é o aviso tocando junto com a mensagem
  --  nova, que já toca; mais de 8 horas é um dia inteiro de expediente, e
  --  aí o cliente já está na fila de "esperando há N dias".
  --
  --  LÊ QUEM ENTROU, MUDA QUEM ADMINISTRA, NINGUÉM APAGA. A tela só liga,
  --  desliga e troca o número; "voltar ao padrão" é escrever 30. E a herança
  --  da Supabase sai inteira antes de dar só o que a tela usa: `truncate` não
  --  passa pela regra de acesso, e quem entrou o herdaria com a tabela.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_aviso_de_espera (
      departamento_id bigint primary key references public.departamentos(id) on delete cascade,
      ligado          boolean not null default true,
      minutos         integer not null default 30 check (minutos between 5 and 480)
    )
  $x$;
  execute $x$
    comment on table public.zorvin_aviso_de_espera is
      'O aviso de cliente sem resposta, por departamento: ligado ou não, e depois de quantos '
      'minutos de expediente. Sem linha, vale o padrão: ligado, 30 minutos. Quem '
      'administra muda; quem entrou lê.'
  $x$;
  execute 'alter table public.zorvin_aviso_de_espera enable row level security';
  execute 'drop policy if exists zorvin_aviso_de_espera_leitura on public.zorvin_aviso_de_espera';
  execute 'create policy zorvin_aviso_de_espera_leitura on public.zorvin_aviso_de_espera
             for select to authenticated using (true)';
  execute 'drop policy if exists zorvin_aviso_de_espera_criar on public.zorvin_aviso_de_espera';
  execute 'create policy zorvin_aviso_de_espera_criar on public.zorvin_aviso_de_espera
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_aviso_de_espera_editar on public.zorvin_aviso_de_espera';
  execute 'create policy zorvin_aviso_de_espera_editar on public.zorvin_aviso_de_espera
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on public.zorvin_aviso_de_espera from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on public.zorvin_aviso_de_espera from authenticated';
    execute 'grant select, insert, update on public.zorvin_aviso_de_espera to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant all on public.zorvin_aviso_de_espera to service_role';
  end if;

  insert into zorvin_conferencia_041
  select 'a configuração do aviso existe', (to_regclass('public.zorvin_aviso_de_espera') is not null)::text;

  -- ----------------------------------------------------------
  --  3. OS CLIENTES QUE ESPERAM A PRIMEIRA RESPOSTA DEMAIS
  --
  --    - O ATENDIMENTO DE AGORA (`conversas.protocolo`), aberto pelo CLIENTE
  --      (`origem = 'cliente'`), sem primeira resposta e sem finalização. A
  --      conversa começada pela equipe já nasce respondida, e o Reabrir não
  --      tem um cliente esperando: foi a equipe que voltou a ela;
  --    - aberto nos ÚLTIMOS SETE DIAS: é quanto uma espera de 30 minutos de
  --      expediente leva, no pior caso (sexta à noite, feriado na segunda). O
  --      que espera há mais do que isso está na fila de "esperando há N
  --      dias", e contar o expediente de cada um, a cada minuto, por pessoa
  --      com o Zorvin aberto, seria trabalho à toa;
  --    - sem grupo, sem conversa arquivada e sem telefone desativado: a régua
  --      da lista de conversas e do relatório por responsável (011, 012);
  --    - com o aviso ligado no departamento, e acima do limite dele.
  --
  --  `security invoker`: a regra de acesso de `conversas` vale lá dentro, no
  --  papel de quem pergunta. Ninguém lê por aqui a conversa de um telefone que
  --  não atende.
  --
  --  DE `advogados`, SÓ `ativo` E `departamento_id`, PELO NOME — nunca
  --  `to_jsonb(a)`: em `advogados` quem entrou não lê a chave da Uazapi, e
  --  `to_jsonb` de uma linha lê todas as colunas (o defeito do 011). De
  --  `conversas` e `contatos` não há coluna fechada, e `to_jsonb` deixa a
  --  função de pé num banco sem as colunas que vieram à mão (`arquivada`, o
  --  responsável do 008, os nomes do cadastro).
  --
  --  O CONTATO VAI INTEIRO, para o painel escrever o nome pela mesma régua da
  --  lista (`nomeDoContato`): a ficha, o nome que a equipe deu, o do WhatsApp.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_clientes_sem_resposta()
    returns table (
      conversa_id     uuid,
      advogado_id     uuid,
      departamento_id bigint,
      protocolo       text,
      aberto_em       timestamptz,
      responsavel_id  uuid,
      minutos         integer,
      limite          integer,
      contato         jsonb
    )
    language sql stable security invoker set search_path = public as $f$
      select c.id, c.advogado_id, a.departamento_id, z.protocolo, z.aberto_em,
             (to_jsonb(c) ->> 'responsavel_id')::uuid,
             m.minutos, coalesce(v.minutos, 30), to_jsonb(ct)
        from public.zorvin_atendimentos z
        join public.conversas c on c.id = z.conversa_id and c.protocolo = z.protocolo
        join public.advogados a on a.id = c.advogado_id
        join public.contatos ct on ct.id = c.contato_id
        left join public.zorvin_aviso_de_espera v on v.departamento_id = a.departamento_id
        left join public.zorvin_fora_do_horario f on f.departamento_id = a.departamento_id
        cross join lateral (
          select public.zorvin_minutos_no_expediente(f.semana, f.fuso, z.aberto_em, now()) as minutos
        ) m
       where z.origem = 'cliente'
         and z.primeira_resposta_em is null
         and z.finalizado_em is null
         and z.aberto_em > now() - interval '7 days'
         and coalesce(v.ligado, true)
         and a.ativo is distinct from false
         and not coalesce((to_jsonb(c) ->> 'arquivada')::boolean, false)
         and ct.numero not like 'grupo:%'
         and m.minutos >= coalesce(v.minutos, 30)
       order by m.minutos desc, z.aberto_em
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_clientes_sem_resposta() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_clientes_sem_resposta() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_clientes_sem_resposta() to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_clientes_sem_resposta() to service_role';
  end if;

  insert into zorvin_conferencia_041
  select 'a lista dos clientes sem resposta existe',
         (to_regprocedure('public.zorvin_clientes_sem_resposta()') is not null)::text;
end
$quem_espera$;

-- ------------------------------------------------------------
--  A CONFERÊNCIA DE QUEM USA: a conta numa semana conhecida, e a lista e a
--  configuração CHAMADAS NO PAPEL DE QUEM ATENDE — a régua do 012. Perguntar
--  só se a função existe passaria com ela quebrada para todo mundo.
-- ------------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regprocedure('public.zorvin_minutos_no_expediente(jsonb,text,timestamptz,timestamptz)') is null then
    return;
  end if;

  -- Segunda 26/10/2026, das 7h às 9h em Brasília, numa semana das 8h às 18h:
  -- uma hora de expediente. Numa segunda sem feriado, para a resposta não
  -- depender do calendário.
  insert into zorvin_conferencia_041
  select 'a conta: das 7h às 9h de uma segunda, com expediente às 8h, dá 60 minutos',
         (public.zorvin_minutos_no_expediente(
            '{"seg":["08:00","18:00"]}'::jsonb, 'America/Sao_Paulo',
            '2026-10-26 07:00:00-03'::timestamptz, '2026-10-26 09:00:00-03'::timestamptz) = 60)::text;

  if to_regprocedure('public.zorvin_clientes_sem_resposta()') is null then
    return;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  insert into zorvin_conferencia_041
  select 'quem entrou pode pedir a lista',
         has_function_privilege('authenticated', 'public.zorvin_clientes_sem_resposta()', 'execute')::text;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    insert into zorvin_conferencia_041
    select 'quem não entrou não alcança a conta, a lista nem a configuração',
           (not has_function_privilege('anon', 'public.zorvin_minutos_no_expediente(jsonb,text,timestamptz,timestamptz)', 'execute')
            and not has_function_privilege('anon', 'public.zorvin_clientes_sem_resposta()', 'execute')
            and not has_table_privilege('anon', 'public.zorvin_aviso_de_espera', 'select'))::text;
  end if;

  begin
    perform set_config('role', 'authenticated', true);
    perform * from public.zorvin_clientes_sem_resposta();
    perform * from public.zorvin_aviso_de_espera;
    v_resposta := 'sim';
    execute 'reset role';
  exception when others then
    -- A troca de papel é desfeita junto com o bloco que falhou.
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_041
  values ('a lista e a configuração respondem para quem atende', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_041;
