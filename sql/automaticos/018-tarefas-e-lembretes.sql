-- ============================================================
--  TAREFAS E LEMBRETES
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 06/10, como terceiro passo do Zorvin para CRM, depois
--  do responsável e do funil: o "quando agir de novo". "Ligar na quinta para
--  confirmar o acordo", "cobrar o documento em 3 dias" — hoje isso fica na
--  cabeça de quem atende, e o cliente esfria no dia em que ela esquece.
--
--  Decidido com ele:
--
--    - a tarefa é DE UMA CONVERSA, e quem vê a conversa vê as tarefas dela
--      (a equipe do telefone): se a responsável faltar, um colega enxerga o
--      que estava combinado com o cliente e cobre;
--    - ela tem UMA pessoa (`para_quem`), que pode ser quem criou ou um
--      colega, e é só essa pessoa que o painel avisa na hora;
--    - "Minhas tarefas" numa tela própria, mais um filtro na lista.
--
--  UMA TABELA: zorvin_tarefas.
--
--  ------------------------------------------------------------
--  QUEM CRIOU E QUEM CONCLUIU SÃO ESCRITOS PELO BANCO, por gatilho, e não
--  pela tela: a tela não tem como dizer que foi outra pessoa. Concluir é
--  preencher `feita_em`; reabrir é voltar a nulo, e o gatilho limpa
--  `feita_por` junto.
--
--  APAGAR É PERMITIDO, e é decisão: uma tarefa criada por engano não é
--  histórico de ninguém, e "concluída" no lugar de "apagada" contaria como
--  trabalho feito. A tela pergunta antes.
--
--  QUEM VÊ UMA TAREFA É QUEM VÊ A CONVERSA DELA. A regra pergunta às próprias
--  `conversas`, e a regra de acesso de `conversas` vale dentro dela: ninguém
--  enxerga pela tarefa o cliente de um telefone que não atende.
--
--  O AVISO NA HORA É DO PAINEL, e não do banco: é o navegador de quem recebeu
--  a tarefa que toca o som e mostra a notificação. O banco só guarda.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  O painel descobre sozinho que a tabela não existe, e nada das tarefas
--  aparece — nem o botão na conversa, nem a tela, nem o filtro.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`conversas`, `usuarios`) — é o banco do escritório
-- ============================================================

do $tarefas$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_018;
  create temp table zorvin_conferencia_018 (item text, resposta text);

  -- A GUARDA: num banco limpo (a prova 51l-bis, ou um cliente novo) não há
  -- conversa nem gente, e o certo é desistir em silêncio.
  if to_regclass('public.conversas') is null
     or to_regclass('public.usuarios') is null then
    insert into zorvin_conferencia_018
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 018 não fez nada.';
    return;
  end if;

  execute $x$
    create table if not exists public.zorvin_tarefas (
      id           uuid primary key default gen_random_uuid(),
      conversa_id  uuid not null references public.conversas(id) on delete cascade,
      texto        text not null check (length(btrim(texto)) between 1 and 500),
      vence_em     timestamptz not null,
      para_quem    uuid references public.usuarios(id) on delete set null,
      criada_por   uuid,
      criada_em    timestamptz not null default now(),
      feita_em     timestamptz,
      feita_por    uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_tarefas is
      'Tarefas e lembretes de cada conversa: o que fazer, quando, e para '
      'quem. Quem criou e quem concluiu são escritos por gatilho. Quem vê a '
      'conversa vê as tarefas dela.'
  $x$;
  -- AS DUAS PERGUNTAS DA TELA: "as minhas abertas, por hora" e "as desta
  -- conversa". A primeira só olha as abertas — as feitas só crescem.
  execute 'create index if not exists zorvin_tarefas_abertas_por_pessoa
             on public.zorvin_tarefas (para_quem, vence_em) where feita_em is null';
  execute 'create index if not exists zorvin_tarefas_da_conversa
             on public.zorvin_tarefas (conversa_id, vence_em)';

  -- ----------------------------------------------------------
  --  O GATILHO: quem criou e quem concluiu
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_tarefa_quem()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      if tg_op = 'INSERT' then
        new.criada_por := coalesce(auth.uid(), new.criada_por);
        new.criada_em := now();
        if new.feita_em is not null then
          new.feita_por := coalesce(auth.uid(), new.feita_por);
        end if;
      else
        -- QUEM CRIOU E QUANDO NÃO MUDAM: são o registro de onde a tarefa veio.
        new.criada_por := old.criada_por;
        new.criada_em := old.criada_em;
        if new.feita_em is null then
          new.feita_por := null;
        elsif old.feita_em is null then
          new.feita_por := coalesce(auth.uid(), new.feita_por);
        else
          new.feita_por := old.feita_por;
          new.feita_em := old.feita_em;
        end if;
      end if;
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_tarefa_quem on public.zorvin_tarefas';
  execute 'create trigger zorvin_tarefa_quem
             before insert or update on public.zorvin_tarefas
             for each row execute function public.zorvin_tarefa_quem()';

  -- ----------------------------------------------------------
  --  QUEM VÊ — pergunta às próprias conversas
  --
  --  Uma subconsulta em `conversas` dentro da política passa pela regra de
  --  acesso de `conversas` no papel de QUEM PERGUNTA: é a permissão de
  --  telefone e departamento que já existe, sem uma segunda escrita dela.
  -- ----------------------------------------------------------
  execute 'alter table public.zorvin_tarefas enable row level security';
  execute 'drop policy if exists zorvin_tarefas_leitura on public.zorvin_tarefas';
  execute 'create policy zorvin_tarefas_leitura on public.zorvin_tarefas
             for select to authenticated
             using (exists (select 1 from public.conversas c where c.id = conversa_id))';
  execute 'drop policy if exists zorvin_tarefas_criar on public.zorvin_tarefas';
  execute 'create policy zorvin_tarefas_criar on public.zorvin_tarefas
             for insert to authenticated
             with check (exists (select 1 from public.conversas c where c.id = conversa_id))';
  execute 'drop policy if exists zorvin_tarefas_editar on public.zorvin_tarefas';
  execute 'create policy zorvin_tarefas_editar on public.zorvin_tarefas
             for update to authenticated
             using (exists (select 1 from public.conversas c where c.id = conversa_id))
             with check (exists (select 1 from public.conversas c where c.id = conversa_id))';
  execute 'drop policy if exists zorvin_tarefas_apagar on public.zorvin_tarefas';
  execute 'create policy zorvin_tarefas_apagar on public.zorvin_tarefas
             for delete to authenticated
             using (exists (select 1 from public.conversas c where c.id = conversa_id))';
  execute 'grant select, insert, update, delete on public.zorvin_tarefas to authenticated';

  insert into zorvin_conferencia_018
  select 'a tabela das tarefas existe'::text,
         (to_regclass('public.zorvin_tarefas') is not null)::text
  union all
  select 'quem criou e quem concluiu são do banco',
         exists (select 1 from pg_trigger
                  where tgname = 'zorvin_tarefa_quem'
                    and tgrelid = 'public.zorvin_tarefas'::regclass)::text;
end
$tarefas$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua do 012. Lê a tabela como
--  `authenticated`; quem entrou tem de alcançá-la sem "permission denied". A
--  troca de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_tarefas') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_tarefas;
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_018 values ('quem entrou consegue ler as tarefas', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_018;
