-- ============================================================
--  A MENSAGEM AGENDADA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 02/10: poder AGENDAR mensagem — texto e anexo. A
--  mensagem sai na hora marcada mesmo que o cliente escreva antes, e qualquer
--  pessoa da equipe pode cancelar enquanto ela não saiu.
--
--  NÃO É UMA TABELA NOVA. A mensagem agendada é um item da `fila_envio` como
--  qualquer outro, com a hora marcada ao lado. Uma tabela à parte precisaria
--  de um segundo caminho de envio — e a fila já sabe mandar texto, imagem,
--  áudio, documento e figurinha, já insiste quando a Uazapi tosse e já avisa
--  quando para. Duas filas divergiriam no primeiro conserto.
--
--    agendada_para   a hora marcada. Nulo = mensagem comum, sai agora.
--    cancelada_em    quando alguém cancelou
--    cancelada_por   quem cancelou (usuarios.id)
--
--  O PAINEL GRAVA A HORA EM DOIS LUGARES: aqui e em `tentar_em`, que a ponte
--  já lê para a retentativa. Assim a leitura de sempre já deixa a agendada de
--  fora, e o aviso de "fila parada" do `zorvin_saude()` também — ele só conta
--  item cujo `tentar_em` passou. A ponte tem a sua guarda própria por cima,
--  pela `agendada_para`: mensagem que sai antes da hora não tem desfazer.
--
--  CANCELAR é virar o item para 'cancelada', e só isso. A política nova deixa
--  fazer exatamente essa passagem — de agendada e pendente para cancelada — e
--  nenhuma outra: não deixa cancelar mensagem comum (que sai em segundos e
--  cujo "cancelar" seria uma corrida perdida), nem devolver um item à fila por
--  fora. Cancelar e a ponte pegar o item na mesma hora é uma corrida que se
--  resolve sozinha: as duas gravações exigem `status = 'pendente'`, e só a
--  primeira acha a linha assim.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO, NADA MUDA
--
--  O painel não oferece agendar, e a ponte avisa uma vez no log e segue.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`fila_envio`, `conversas`) — o banco do escritório
-- ============================================================

-- A GUARDA EXISTE POR CAUSA DA PROVA 51l-bis, que aplica esta pasta num banco
-- LIMPO. Sem a fila não há onde pôr a coluna, e o certo é desistir em silêncio.
do $agenda$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estoura num banco limpo.
  drop table if exists zorvin_conferencia_013;
  create temp table zorvin_conferencia_013 (item text, resposta text);

  if to_regclass('public.fila_envio') is null
     or to_regclass('public.conversas') is null then
    insert into zorvin_conferencia_013
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem a fila de envio — script 013 não fez nada.';
    return;
  end if;

  execute 'alter table public.fila_envio add column if not exists agendada_para timestamptz';
  execute 'alter table public.fila_envio add column if not exists cancelada_em timestamptz';
  execute 'alter table public.fila_envio add column if not exists cancelada_por uuid';
  -- A DA RETENTATIVA, caso o script de 09/2026 nunca tenha rodado: o painel
  -- grava a hora marcada nela também, e sem ela a gravação inteira morreria.
  execute 'alter table public.fila_envio add column if not exists tentar_em timestamptz';

  execute $c$comment on column public.fila_envio.agendada_para is
    'A hora marcada de uma mensagem AGENDADA. Nulo = mensagem comum. A ponte '
    'não a envia antes desta hora; cancelar é virar o status para cancelada.'$c$;

  -- O PAINEL PERGUNTA, POR CONVERSA, "o que está agendado aqui?". Só as
  -- agendadas que ainda não saíram entram no índice — são um punhado.
  execute 'create index if not exists fila_agendadas_da_conversa
             on public.fila_envio (conversa_id, agendada_para)
             where status = ''pendente'' and agendada_para is not null';

  -- CANCELAR: de agendada e pendente para cancelada, e nada mais. Recriada
  -- a cada rodada, para o script poder rodar de novo.
  execute 'drop policy if exists fila_envio_cancelar_agendada on public.fila_envio';
  execute 'create policy fila_envio_cancelar_agendada on public.fila_envio
             for update to authenticated
             using (status = ''pendente'' and agendada_para is not null
                    and exists (select 1 from public.conversas c
                                 where c.id = fila_envio.conversa_id))
             with check (status = ''cancelada'' and agendada_para is not null
                    and exists (select 1 from public.conversas c
                                 where c.id = fila_envio.conversa_id))';

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
  --  Supabase só mostra o resultado do último comando.
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_013
  select 'a coluna da hora marcada existe'::text,
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'fila_envio'
                    and column_name = 'agendada_para')::text
  union all
  select 'quem entrou pode agendar (gravar na fila)',
         has_column_privilege('authenticated', 'public.fila_envio', 'agendada_para', 'INSERT')::text
  union all
  select 'quem entrou pode cancelar',
         (has_column_privilege('authenticated', 'public.fila_envio', 'status', 'UPDATE')
          and exists (select 1 from pg_policies
                       where schemaname = 'public' and tablename = 'fila_envio'
                         and policyname = 'fila_envio_cancelar_agendada'))::text
  union all
  -- UMA REGRA DE STATUS QUE NÃO CONHEÇA 'cancelada' recusaria todo cancelamento.
  -- Não há nenhuma no banco do escritório que se saiba — e é por isso mesmo
  -- que se pergunta, em vez de supor.
  select 'o banco aceita o status cancelada',
         (not exists (select 1 from pg_constraint
                       where conrelid = 'public.fila_envio'::regclass and contype = 'c'
                         and pg_get_constraintdef(oid) ilike '%status%'
                         and pg_get_constraintdef(oid) not ilike '%cancelada%'))::text
  union all
  select 'mensagens agendadas esperando agora',
         (select count(*) from public.fila_envio
           where status = 'pendente' and agendada_para is not null)::text;
end $agenda$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_013;
