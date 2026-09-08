-- ============================================================
--  A CAIXA DE ENTRADA DO WEBHOOK — o evento existe antes de ser entendido
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  Dashboard → SQL Editor → New query → cole tudo → Run.
--  Pode rodar de novo sem medo.
--
--  ------------------------------------------------------------
--  O QUE ISTO CONSERTA
--
--  Quando o WhatsApp entrega uma mensagem, a Uazapi bate na porta da ponte e
--  espera um "OK". Esse "OK" é uma promessa: dali em diante ela considera a
--  mensagem entregue e nunca mais a manda.
--
--  A ponte respondia "OK" ANTES de gravar. Entre a promessa e a linha no banco
--  há algumas idas à rede — achar o telefone, o contato, a conversa, gravar. Se
--  o processo morresse nesse intervalo (uma publicação, e são várias por
--  semana), a mensagem do cliente sumia: a Uazapi achando que entregou, e aqui
--  nenhum rastro de que ela existiu. Não havia nem como saber qual foi.
--
--  Com esta tabela, o evento cru é gravado ANTES do "OK". A partir daí ele
--  existe. Se o tratamento não terminar, uma rodada de recuperação o encontra
--  pendente e termina o serviço — e a mensagem entra na conversa com atraso, em
--  vez de não entrar.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO, NADA MUDA
--
--  A ponte descobre sozinha que a tabela não existe, avisa uma vez no log e
--  volta a se comportar exatamente como antes. É de propósito: fazer o webhook
--  depender de uma tabela que talvez não exista trocaria uma perda rara por uma
--  parada total — toda mensagem passaria a ser recusada.
--
--  Depois de rodar, a linha no log da ponte que confirma é a ausência do aviso
--  "a tabela eventos_recebidos não existe".
--
--  ------------------------------------------------------------
--  ESTA TABELA GUARDA CONTEÚDO DE CLIENTE
--
--  O `corpo` é o evento inteiro como a Uazapi mandou: texto da mensagem,
--  telefone, nome. Por isso ela nasce com a regra de acesso LIGADA e SEM
--  política nenhuma para quem usa o painel — ninguém logado a alcança. Só a
--  ponte, que usa a chave de serviço e não passa por estas regras.
--
--  E ela se limpa sozinha: o que já foi processado some depois de 7 dias. Uma
--  tabela que só cresce é um problema adiado, e aqui o valor de uma linha
--  acaba no minuto em que ela é processada.
-- ============================================================

create table if not exists public.eventos_recebidos (
  id             bigserial primary key,
  -- O evento como ele chegou. `jsonb` e não `text` para dar para procurar
  -- dentro dele no dia em que alguém perguntar "esta mensagem chegou aqui?".
  corpo          jsonb       not null,
  recebido_em    timestamptz not null default now(),
  -- Quando o tratamento terminou. `null` é o que define "pendente", e é por
  -- ele que a rodada de recuperação procura.
  processado_em  timestamptz,
  -- Quando a última tentativa começou. Serve para investigar, e para separar
  -- "nunca foi tentado" de "está sendo tentado agora".
  processando_em timestamptz,
  tentativas     integer     not null default 0,
  erro           text
);

-- O ÍNDICE É SÓ DOS PENDENTES, e é isso que o torna barato. A tabela vai ter
-- milhares de linhas processadas e um punhado de pendentes; um índice sobre
-- tudo custaria escrita em cada evento para responder uma pergunta que só
-- interessa sobre meia dúzia deles.
create index if not exists eventos_pendentes
  on public.eventos_recebidos (recebido_em)
  where processado_em is null;

comment on table public.eventos_recebidos is
  'O evento cru do webhook, gravado ANTES de a ponte responder "OK" à Uazapi. '
  'É o que permite terminar o tratamento de uma mensagem cujo processamento foi '
  'interrompido (uma publicação, uma queda) em vez de perdê-la.';

-- ------------------------------------------------------------
--  QUEM ALCANÇA: NINGUÉM, ALÉM DA PONTE
--
--  RLS ligada e nenhuma política = nenhuma linha para quem usa o painel. A
--  ponte não é afetada: a chave de serviço não passa por estas regras.
--
--  O `revoke` é o cinto além do suspensório: sem política, o RLS já basta —
--  mas uma política criada sem querer no futuro encontraria a porta fechada
--  também no nível da permissão.
-- ------------------------------------------------------------
alter table public.eventos_recebidos enable row level security;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table public.eventos_recebidos from authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table public.eventos_recebidos from anon';
  end if;
end $$;

-- ------------------------------------------------------------
--  A LIMPEZA
--
--  Uma função, e não um gatilho: gatilho rodaria a cada inserção, e apagar
--  linha velha não é assunto de quem está guardando uma nova.
--
--  Chamada pela ponte de tempos em tempos. Sete dias é o bastante para
--  investigar um relato da semana passada ("essa mensagem chegou?") e curto o
--  bastante para a tabela não virar um arquivo morto.
-- ------------------------------------------------------------
create or replace function public.limpar_eventos_recebidos()
returns integer
language sql
security definer
set search_path = public
as $$
  with apagados as (
    delete from public.eventos_recebidos
     where processado_em is not null
       and processado_em < now() - interval '7 days'
    returning 1
  )
  select count(*)::int from apagados;
$$;

comment on function public.limpar_eventos_recebidos() is
  'Apaga os eventos já processados com mais de 7 dias. Os PENDENTES ficam: '
  'um evento que nunca foi processado é uma mensagem que talvez não tenha '
  'entrado, e apagá-lo seria apagar a única pista dela.';


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'a tabela existe' as item,
       to_regclass('public.eventos_recebidos') is not null as ok
union all
select 'a regra de acesso está ligada',
       coalesce((select relrowsecurity from pg_class where relname = 'eventos_recebidos'), false)
union all
select 'ninguém logado alcança (nenhuma política)',
       not exists (select 1 from pg_policies
                    where schemaname = 'public' and tablename = 'eventos_recebidos')
union all
select 'o índice dos pendentes existe',
       exists (select 1 from pg_indexes
                where schemaname = 'public' and indexname = 'eventos_pendentes')
union all
select 'a limpeza existe',
       to_regprocedure('public.limpar_eventos_recebidos()') is not null;


-- ------------------------------------------------------------
--  DEPOIS DE RODAR
--
--  1. Republique a ponte (ou espere a próxima publicação). Ela descobre a
--     tabela sozinha; o sinal de que ligou é o log PARAR de dizer que a tabela
--     não existe.
--
--  2. Para ver a caixa trabalhando, rode isto de vez em quando:
--
--       select count(*) filter (where processado_em is not null) as terminados,
--              count(*) filter (where processado_em is null)     as pendentes,
--              max(tentativas)                                   as pior_caso
--         from public.eventos_recebidos;
--
--     `pendentes` alto e parado é o sinal de que algo não está sendo tratado —
--     e aí o `erro` de cada linha diz o quê:
--
--       select id, recebido_em, tentativas, erro
--         from public.eventos_recebidos
--        where processado_em is null
--        order by recebido_em desc limit 20;
-- ------------------------------------------------------------
