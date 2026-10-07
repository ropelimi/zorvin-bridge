-- ============================================================
--  A AUDITORIA DO BANCO (07/10)
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  Uma varredura dos scripts 001–019, conferida num Postgres de verdade, achou
--  quatro coisas que valem conserto já. Nenhum script aplicado é editado (a
--  regra da pasta); este as substitui.
--
--  1. A AGENDADA PODIA SER EDITADA DEPOIS DA HORA. As regras de UPDATE de
--     `fila_envio` se somam por "OU": a linha velha só precisa passar no
--     USING de UMA delas, e a nova no WITH CHECK de UMA (qualquer outra).
--     Medido: uma agendada vencida havia 2 minutos passava no USING do
--     cancelar (que não olha a hora) e no WITH CHECK do editar — a edição do
--     script 016 era aceita depois da hora, que era exatamente a corrida com a
--     ponte que ele existia para fechar. E pior: um item com ERRO podia voltar
--     a 'pendente' pela mesma soma — reenviar pelo caminho de fora, e um item
--     que deu tempo esgotado pode ter chegado ao cliente.
--
--     O WITH CHECK não enxerga a linha velha; um GATILHO enxerga. Este recusa
--     (42501) qualquer gravação feita POR QUEM ENTROU NO PAINEL que deixe a
--     linha em 'pendente' sem que ela já fosse uma agendada pendente e no
--     futuro — e ainda no futuro depois. A ponte (chave de serviço, sem
--     `auth.uid()`) não passa por aqui.
--
--  2. O "JÁ TRATEI" ACEITAVA QUALQUER CONVERSA E QUALQUER AUTOR. Criar era
--     `with check (true)`, desfazer era `using (true)`, e `quem` vinha da tela.
--     Medido: quem não vê a conversa B gravou um "Já tratei" nela, assinado com
--     o nome de um colega, e marcou os de B como desfeitos — o relatório e o
--     histórico do cliente passavam a contar trabalho inventado. Agora as duas
--     regras perguntam às próprias `conversas` (a permissão que já existe), e
--     um gatilho escreve `quem` e `desfeito_por` com quem entrou, como o 018
--     faz nas tarefas. A LEITURA continua aberta, e é decisão do 005: o
--     histórico do cliente mostra o que todos os telefones trataram com ele.
--
--  3. O GATILHO DA ESPERA PODIA DERRUBAR A MENSAGEM DO CLIENTE. O corpo dele
--     vive num `exception when others` justamente para nunca estourar — mas a
--     carência era lida na DECLARAÇÃO das variáveis, e o PL/pgSQL não protege
--     a declaração com o `exception` do bloco. Medido: sem permissão na função
--     da carência, o INSERT em `mensagens` morria. A leitura passa para dentro
--     do bloco, e a ponte (`service_role`) ganha a permissão escrita.
--
--  4. `tratada_em` VINHA DO RELÓGIO DO COMPUTADOR de quem clicou. A conta da
--     espera trata como já atendida toda mensagem anterior a ele: com um
--     relógio adiantado, as mensagens que chegassem logo depois do clique
--     ficavam fora da fila. Um gatilho segura `tratada_em` no máximo em
--     `now()` do banco.
--
--  ------------------------------------------------------------
--  O QUE FICOU DE FORA, E POR QUÊ
--
--  - Rodar de novo o 004 ou o 005 DEPOIS do 006 volta as funções da espera
--    para as versões velhas (cada um faz `create or replace` delas). Isto não
--    se conserta editando os velhos: está escrito no LEIA-ME, e este script
--    recria o gatilho na versão certa — rodá-lo de novo desfaz o estrago.
--  - Rodar de novo o 009 traz o "OUTROS" de volta se alguém o renomeou ou
--    desativou. Também no LEIA-ME.
--  - A transcrição pode ser reescrita por quem já pode editar a mensagem.
--    Fechar a coluna exigiria tirar o UPDATE da tabela inteira e devolver
--    coluna por coluna — risco grande para um ganho pequeno.
-- ============================================================

do $auditoria$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DE QUALQUER GUARDA — a lição do 006.
  drop table if exists zorvin_conferencia_020;
  create temp table zorvin_conferencia_020 (item text, resposta text);

  -- ----------------------------------------------------------
  --  1. A AGENDADA SÓ SE EDITA ANTES DA HORA, e nada volta para a fila
  -- ----------------------------------------------------------
  if to_regclass('public.fila_envio') is not null then
    execute $x$
      create or replace function public.zorvin_fila_confere_quem_edita()
      returns trigger language plpgsql set search_path = public as $f$
      begin
        -- A PONTE E O EDITOR DO SUPABASE não têm `auth.uid()`: ficam de fora.
        if auth.uid() is null then return new; end if;
        if new.status = 'pendente' then
          if not (old.status = 'pendente'
                  and old.agendada_para is not null and old.agendada_para > now()
                  and new.agendada_para is not null and new.agendada_para > now()) then
            raise exception 'Esta mensagem não pode mais ser alterada: a hora dela já chegou, ou ela já não está esperando para sair.'
              using errcode = '42501';
          end if;
        end if;
        return new;
      end
      $f$
    $x$;
    execute 'drop trigger if exists zorvin_fila_confere_quem_edita on public.fila_envio';
    execute 'create trigger zorvin_fila_confere_quem_edita
               before update on public.fila_envio
               for each row execute function public.zorvin_fila_confere_quem_edita()';
    insert into zorvin_conferencia_020 values ('a agendada só se edita antes da hora',
      exists (select 1 from pg_trigger where tgname = 'zorvin_fila_confere_quem_edita')::text);
  end if;

  -- ----------------------------------------------------------
  --  2. O "JÁ TRATEI": só na conversa que a pessoa vê, e assinado por ela
  -- ----------------------------------------------------------
  if to_regclass('public.zorvin_tratamentos') is not null
     and to_regclass('public.conversas') is not null then
    execute 'drop policy if exists zorvin_tratamentos_criar on public.zorvin_tratamentos';
    execute 'create policy zorvin_tratamentos_criar on public.zorvin_tratamentos
               for insert to authenticated
               with check (exists (select 1 from public.conversas c
                                    where c.id = zorvin_tratamentos.conversa_id))';
    execute 'drop policy if exists zorvin_tratamentos_desfazer on public.zorvin_tratamentos';
    execute 'create policy zorvin_tratamentos_desfazer on public.zorvin_tratamentos
               for update to authenticated
               using (exists (select 1 from public.conversas c
                               where c.id = zorvin_tratamentos.conversa_id))
               with check (exists (select 1 from public.conversas c
                                    where c.id = zorvin_tratamentos.conversa_id))';

    execute $x$
      create or replace function public.zorvin_tratamento_quem()
      returns trigger language plpgsql set search_path = public as $f$
      begin
        if auth.uid() is null then return new; end if;
        if tg_op = 'INSERT' then
          new.quem := auth.uid();
        elsif new.desfeito_em is not null and old.desfeito_em is null then
          new.desfeito_por := auth.uid();
        elsif new.desfeito_em is not distinct from old.desfeito_em then
          new.desfeito_por := old.desfeito_por;
        end if;
        return new;
      end
      $f$
    $x$;
    execute 'drop trigger if exists zorvin_tratamento_quem on public.zorvin_tratamentos';
    execute 'create trigger zorvin_tratamento_quem
               before insert or update on public.zorvin_tratamentos
               for each row execute function public.zorvin_tratamento_quem()';
    insert into zorvin_conferencia_020 values ('o “Já tratei” é de quem marcou, na conversa que ele vê',
      exists (select 1 from pg_trigger where tgname = 'zorvin_tratamento_quem')::text);
  end if;

  -- ----------------------------------------------------------
  --  3. O GATILHO DA ESPERA NUNCA ESTOURA
  --
  --  O MESMO CORPO DO 006, com uma mudança só: a carência é lida DENTRO do
  --  bloco protegido. Daqui para a frente, esta é a versão de referência.
  -- ----------------------------------------------------------
  if to_regprocedure('public.zorvin_carencia_da_espera()') is not null
     and to_regclass('public.mensagens') is not null
     and to_regclass('public.conversas') is not null then
    execute $x$
      create or replace function public.zorvin_marcar_espera()
      returns trigger
      language plpgsql
      as $fn$
      declare
        nossa     timestamptz;
        carencia  interval;
      begin
        -- DENTRO DO BLOCO, e não na declaração: o `exception` lá de baixo não
        -- protege a declaração das variáveis (auditoria de 07/10).
        carencia := public.zorvin_carencia_da_espera();
        if new.origem = 'contato' then
          if exists (select 1 from public.mensagens m
                      where m.conversa_id = new.conversa_id
                        and m.origem = 'advogado'
                        and m.criado_em >= new.criado_em)
             or exists (select 1 from public.conversas c
                         where c.id = new.conversa_id
                           and c.tratada_em >= new.criado_em) then
            return null;
          end if;

          select greatest(
                   (select max(m.criado_em) from public.mensagens m
                     where m.conversa_id = new.conversa_id
                       and m.origem = 'advogado'),
                   c.tratada_em)
            into nossa
            from public.conversas c
           where c.id = new.conversa_id;

          if nossa is null or new.criado_em > nossa + carencia then
            update public.conversas
               set esperando_desde = case
                     when esperando_desde is null then new.criado_em
                     when nossa is not null
                          and esperando_desde <= nossa + carencia then new.criado_em
                     else least(esperando_desde, new.criado_em)
                   end
             where id = new.conversa_id;
          else
            update public.conversas
               set esperando_desde = coalesce(esperando_desde, new.criado_em)
             where id = new.conversa_id;
          end if;

        elsif new.origem = 'advogado' then
          update public.conversas
             set esperando_desde = null,
                 tratada_em = null
           where id = new.conversa_id
             and coalesce(esperando_desde, tratada_em) <= new.criado_em;
        end if;
        return null;
      exception when others then
        raise warning 'zorvin_espera: %', sqlerrm;
        return null;
      end
      $fn$
    $x$;
    if exists (select 1 from pg_roles where rolname = 'service_role') then
      execute 'grant execute on function public.zorvin_carencia_da_espera() to service_role';
    end if;
    insert into zorvin_conferencia_020 values ('o gatilho da espera nunca derruba a mensagem',
      (position('carencia := public.zorvin_carencia_da_espera()' in
                pg_get_functiondef('public.zorvin_marcar_espera()'::regprocedure)) > 0)::text);
  end if;

  -- ----------------------------------------------------------
  --  4. `tratada_em` NÃO PASSA DO RELÓGIO DO BANCO
  --
  --  Gatilho em `conversas`, que é gravada a toda hora: só age quando
  --  `tratada_em` muda, e o corpo vive num `exception` — gatilho em conversas
  --  que estoura derruba a gravação inteira.
  -- ----------------------------------------------------------
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'conversas'
                and column_name = 'tratada_em') then
    execute $x$
      create or replace function public.zorvin_tratada_no_relogio_do_banco()
      returns trigger language plpgsql set search_path = public as $f$
      begin
        begin
          if new.tratada_em is distinct from old.tratada_em
             and new.tratada_em is not null and new.tratada_em > now() then
            new.tratada_em := now();
          end if;
        exception when others then
          raise warning 'zorvin_tratada_em: %', sqlerrm;
        end;
        return new;
      end
      $f$
    $x$;
    execute 'drop trigger if exists zorvin_tratada_no_relogio_do_banco on public.conversas';
    execute 'create trigger zorvin_tratada_no_relogio_do_banco
               before update of tratada_em on public.conversas
               for each row execute function public.zorvin_tratada_no_relogio_do_banco()';
    insert into zorvin_conferencia_020 values ('o “Já tratei” usa o relógio do banco',
      exists (select 1 from pg_trigger where tgname = 'zorvin_tratada_no_relogio_do_banco')::text);
  end if;

  if not exists (select 1 from zorvin_conferencia_020) then
    insert into zorvin_conferencia_020 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
  end if;
end
$auditoria$;

-- ----------------------------------------------------------
--  E A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua do 012: lê as duas
--  tabelas como `authenticated`. A troca de papel volta atrás sozinha se falhar.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_tratamentos') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_tratamentos;
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_020 values ('quem entrou continua lendo o “Já tratei”', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_020;
