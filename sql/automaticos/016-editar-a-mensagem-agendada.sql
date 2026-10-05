-- ============================================================
--  EDITAR A MENSAGEM AGENDADA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 05/10: poder EDITAR a mensagem agendada — o texto (ou
--  a legenda do anexo) e a hora. Até aqui a regra do 013 deixava fazer uma
--  coisa só com ela: cancelar.
--
--    editada_em    quando foi editada pela última vez
--    editada_por   quem editou (usuarios.id)
--
--  A REGRA NOVA deixa mexer numa agendada que ainda está PENDENTE e cuja hora
--  AINDA NÃO CHEGOU, e exige que ela continue pendente e com hora no futuro.
--  As duas metades importam:
--
--    - "a hora ainda não chegou" é o que fecha a corrida com a ponte: ela só lê
--      a agendada depois da hora, e a partir da hora a edição é recusada. Não
--      existe instante em que a ponte esteja mandando o texto antigo enquanto
--      alguém grava o novo;
--    - "continua pendente e no futuro" impede de usar a edição para mandar
--      AGORA (hora no passado) ou para tirar a mensagem da fila por fora — o
--      cancelar tem regra própria, e é por ela que se cancela.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  Agendar e cancelar continuam funcionando. O "Editar" é recusado pelo banco,
--  e a tela diz que não deu.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    013 (a mensagem agendada) e 014 (a fila aceita "cancelada")
-- ============================================================

do $editar$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_016;
  create temp table zorvin_conferencia_016 (item text, resposta text);

  if to_regclass('public.fila_envio') is null
     or to_regclass('public.conversas') is null then
    insert into zorvin_conferencia_016
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a fila de envio — script 016 não fez nada.';
    return;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fila_envio'
                    and column_name = 'agendada_para') then
    insert into zorvin_conferencia_016
      values ('FALTA RODAR O 013 ANTES (a mensagem agendada)', 'nada foi feito');
    return;
  end if;

  execute 'alter table public.fila_envio add column if not exists editada_em timestamptz';
  execute 'alter table public.fila_envio add column if not exists editada_por uuid';

  execute 'drop policy if exists fila_envio_editar_agendada on public.fila_envio';
  execute 'create policy fila_envio_editar_agendada on public.fila_envio
             for update to authenticated
             using (status = ''pendente'' and agendada_para is not null
                    and agendada_para > now()
                    and exists (select 1 from public.conversas c
                                 where c.id = fila_envio.conversa_id))
             with check (status = ''pendente'' and agendada_para is not null
                    and agendada_para > now()
                    and exists (select 1 from public.conversas c
                                 where c.id = fila_envio.conversa_id))';

  insert into zorvin_conferencia_016
  select 'quem entrou pode editar a agendada'::text,
         (has_column_privilege('authenticated', 'public.fila_envio', 'texto', 'UPDATE')
          and exists (select 1 from pg_policies
                       where schemaname = 'public' and tablename = 'fila_envio'
                         and policyname = 'fila_envio_editar_agendada'))::text
  union all
  select 'a coluna de quem editou existe',
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fila_envio'
                    and column_name = 'editada_por')::text
  union all
  select 'cancelar continua valendo',
         exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'fila_envio'
                    and policyname = 'fila_envio_cancelar_agendada')::text;
end $editar$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_016;
