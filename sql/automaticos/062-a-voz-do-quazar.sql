-- ============================================================
--  A VOZ DO QUAZAR
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 24/11: "no ícone de pergaminho onde temos o resumo da
--  conversa, quero também a possibilidade de darmos voz ao Quazar! Uma opção
--  dele ler o resumo para o usuário. Crie uma voz única, que seja marcante".
--  A voz é desenhada na ElevenLabs (escolha dele), e quem administra ouve três
--  opções no Zorvin e escolhe uma. Esta tabela guarda a escolhida:
--
--    zorvin_quazar_voz   uma linha só: o id da voz na ElevenLabs, o nome, a
--                        descrição com que ela foi desenhada, quem escolheu e
--                        quando
--
--  O ID DA VOZ NÃO É SEGREDO: sem a chave da ElevenLabs (que mora só na
--  Render), ele não serve para nada. Mesmo assim a tabela é só da ponte: o
--  painel pergunta à ponte, e a ponte responde só o que a tela precisa.
--
--  ------------------------------------------------------------
--  QUEM PODE O QUÊ
--
--    - ler e escrever: só a ponte. Ninguém do painel alcança a tabela.
--
--  ------------------------------------------------------------
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin. Sem elas, não faz nada, e diz por quê.
-- ============================================================

do $voz$
declare
  v_anon boolean := exists (select 1 from pg_roles where rolname = 'anon');
  v_auth boolean := exists (select 1 from pg_roles where rolname = 'authenticated');
  v_srv  boolean := exists (select 1 from pg_roles where rolname = 'service_role');
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DA GUARDA — a lição do 006 e do 007:
  -- criada depois, o `select` da última linha estouraria num banco limpo.
  drop table if exists zorvin_conferencia_062;
  create temp table zorvin_conferencia_062 (item text, resposta text);

  if to_regclass('public.usuarios') is null or to_regclass('public.conversas') is null then
    insert into zorvin_conferencia_062 values ('sem as tabelas do Zorvin', 'nada a fazer aqui');
    raise notice 'Zorvin: sem as tabelas do Zorvin — script 062 não fez nada.';
    return;
  end if;

  execute $x$
    create table if not exists public.zorvin_quazar_voz (
      id            boolean primary key default true check (id),
      voz_id        text not null check (length(voz_id) between 1 and 100),
      nome          text not null check (length(nome) between 1 and 100),
      descricao     text check (descricao is null or length(descricao) <= 1000),
      escolhida_em  timestamptz not null default now(),
      escolhida_por uuid references public.usuarios(id) on delete set null
    )$x$;
  execute 'alter table public.zorvin_quazar_voz enable row level security';
  -- A HERANÇA DA SUPABASE dá a tabela nova a quem entrou e a quem não entrou
  -- (a armadilha nº 5): tirada dos dois, e dada só à ponte.
  if v_anon then execute 'revoke all on public.zorvin_quazar_voz from anon'; end if;
  if v_auth then execute 'revoke all on public.zorvin_quazar_voz from authenticated'; end if;
  if v_srv then execute 'grant all on public.zorvin_quazar_voz to service_role'; end if;

  insert into zorvin_conferencia_062 values ('a tabela da voz existe', 'true');
end
$voz$;

-- A CONFERÊNCIA PERGUNTA AO BANCO QUEM ALCANÇA A TABELA (a régua do 041): a
-- leitura feita no papel de quem atende daria zero linhas também numa tabela
-- aberta e vazia.
do $conf$
begin
  if to_regclass('public.zorvin_quazar_voz') is null then return; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    insert into zorvin_conferencia_062 values ('quem entrou não alcança a voz',
      case when not has_table_privilege('authenticated', 'public.zorvin_quazar_voz', 'select, insert, update, delete')
           then 'true' else 'NÃO — quem entrou alcança a tabela' end);
  end if;
  if exists (select 1 from pg_roles where rolname = 'anon') then
    insert into zorvin_conferencia_062 values ('quem não entrou não alcança a voz',
      case when not has_table_privilege('anon', 'public.zorvin_quazar_voz', 'select, insert, update, delete')
           then 'true' else 'NÃO — quem não entrou alcança a tabela' end);
  end if;
  insert into zorvin_conferencia_062 values ('voz escolhida',
    coalesce((select nome || ' (desde ' || to_char(escolhida_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ')'
                from public.zorvin_quazar_voz), 'nenhuma ainda: quem administra escolhe na aba Quazar'));
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_062;
