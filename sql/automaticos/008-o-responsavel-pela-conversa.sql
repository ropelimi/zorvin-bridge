-- ============================================================
--  O RESPONSÁVEL PELA CONVERSA
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 30/09, como primeiro passo para o Zorvin virar CRM:
--  toda conversa ganha um DONO. Até aqui o banco sabia quem ESCREVEU em cada
--  conversa (`mensagens.enviado_por_id`) e quem está com ela aberta agora
--  (`conversas.atendendo_por`), mas não quem responde por aquele cliente.
--  Sem isso não há "as minhas conversas", não há passar um cliente para outra
--  pessoa, e não há como cobrar de ninguém a fila de ninguém.
--
--  TRÊS COLUNAS, e nenhuma tabela nova:
--
--    responsavel_id   quem é o dono agora (nulo = ninguém ainda)
--    responsavel_em   desde quando
--    responsavel_por  quem pôs ele ali — ele mesmo, ao assumir, ou um colega
--                     que passou a conversa. "Quem me passou isto?" é a
--                     primeira pergunta de quem recebe um cliente no meio.
--
--  UMA COLUNA NA CONVERSA, e não uma tabela de histórico: a tela precisa da
--  resposta de agora em toda linha da lista, e uma segunda tabela seria uma
--  segunda consulta por página. O histórico de quem passou para quem fica
--  para o dia em que alguém pedir o relatório.
--
--  O DONO É PESSOA DO ZORVIN (`usuarios.id`, que é o mesmo id do Auth), e a
--  referência é `on delete set null`: apagada a conta, a conversa volta a
--  "sem responsável" em vez de apontar para ninguém — e aí ela reaparece para
--  quem procura as conversas sem dono.
--
--  A PERMISSÃO NÃO MUDA. Quem já pode editar a conversa (política
--  `conversas_escrita`) pode mudar o dono. É uma ferramenta de equipe: travar
--  "só o dono passa adiante" faria a conversa de quem saiu de férias ficar
--  presa com ele.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`conversas`, `usuarios`) — é o banco do escritório
-- ============================================================

-- A GUARDA EXISTE POR CAUSA DA PROVA 51l-bis, que aplica esta pasta num banco
-- LIMPO. Sem as tabelas do Zorvin não há onde pôr a coluna, e o certo é
-- desistir em silêncio — que também é o certo num cliente novo, cujo banco
-- ainda não tem esquema nenhum.
do $resp$
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estoura num banco limpo.
  drop table if exists zorvin_conferencia_008;
  create temp table zorvin_conferencia_008 (item text, resposta text);

  if to_regclass('public.conversas') is null
     or to_regclass('public.usuarios') is null then
    insert into zorvin_conferencia_008
      values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas de conversas — script 008 não fez nada.';
    return;
  end if;

  execute 'alter table public.conversas add column if not exists responsavel_id uuid';
  execute 'alter table public.conversas add column if not exists responsavel_em timestamptz';
  execute 'alter table public.conversas add column if not exists responsavel_por uuid';

  -- A REFERÊNCIA, uma vez só. `add constraint` não tem `if not exists`, e
  -- rodar o script de novo não pode estourar por causa dela.
  if not exists (select 1 from pg_constraint
                  where conname = 'conversas_responsavel_fk'
                    and conrelid = 'public.conversas'::regclass) then
    execute 'alter table public.conversas
               add constraint conversas_responsavel_fk
               foreign key (responsavel_id) references public.usuarios(id)
               on delete set null';
  end if;

  -- "AS MINHAS CONVERSAS" pergunta por telefone e por dono. Só as linhas que
  -- têm dono entram no índice: a maioria, no começo, não tem.
  execute 'create index if not exists conversas_responsavel_idx
             on public.conversas (advogado_id, responsavel_id)
             where responsavel_id is not null';

  execute $c$comment on column public.conversas.responsavel_id is
    'Quem responde por esta conversa (usuarios.id). Nulo = ninguém ainda. '
    'Assume sozinho quem responde primeiro; muda-se pelo painel.'$c$;

  -- ----------------------------------------------------------
  --  A CONFERÊNCIA VAI DENTRO DO SCRIPT, e é a última linha dele: o editor do
  --  Supabase só mostra o resultado do último comando.
  -- ----------------------------------------------------------
  insert into zorvin_conferencia_008
  select 'a coluna do responsável existe'::text,
         exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'conversas'
                    and column_name = 'responsavel_id')::text
  union all
  select 'quem entrou pode gravá-la',
         has_column_privilege('authenticated', 'public.conversas', 'responsavel_id', 'UPDATE')::text
  union all
  select 'conversas que já têm responsável',
         (select count(*) from public.conversas where responsavel_id is not null)::text;
end $resp$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_008;
