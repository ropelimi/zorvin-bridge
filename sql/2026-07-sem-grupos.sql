-- ============================================================
--  OS GRUPOS SAEM. A PERMISSÃO PASSA A SER POR DEPARTAMENTO E POR TELEFONE.
--
--  Rode uma vez no Supabase do Zorvin, DEPOIS do
--  2026-07-departamentos-grupos-permissoes.sql:
--    Dashboard → SQL Editor → New query → cole tudo → Run
--
--  Pode rodar de novo sem medo.
-- ============================================================
--
--  POR QUE SAEM
--
--  Os grupos existiam para resolver um problema só: no departamento Advogados,
--  os MESMOS telefones negociavam acordo com o réu e avisavam o cliente da
--  audiência — duas conversas de natureza oposta no mesmo número, e o número
--  não servia para separá-las.
--
--  O aviso de audiência passa a sair de um TELEFONE PRÓPRIO. Com isso o
--  telefone volta a responder a pergunta sozinho, e o grupo perde a razão de
--  existir. Uma dimensão de permissão que não separa mais nada não é neutra:
--  é mais uma caixa para marcar errado, e mais um lugar onde uma conversa some
--  sem ninguém entender por quê.
--
--  O QUE ESTE ARQUIVO FAZ, E O QUE NÃO FAZ
--
--  Faz: a visibilidade passa a olhar só departamento e telefone. As permissões
--  que hoje são POR GRUPO viram permissão do departamento daquele grupo — quem
--  via as audiências dos Advogados passa a ver o departamento Advogados. É mais
--  acesso do que antes, e é uma decisão consciente: o contrário (tirar) deixaria
--  gente sem enxergar conversa no dia seguinte, sem aviso.
--
--  NÃO faz: apagar a tabela `grupos` nem a coluna `conversas.grupo_id`. Elas
--  ficam, sem uso, até o painel parar de citá-las. Apagar coluna que uma tela
--  ainda lê derruba a tela — e o banco não tem como saber que ela parou.
-- ------------------------------------------------------------


-- ------------------------------------------------------------
--  1. QUEM TINHA ACESSO POR GRUPO PASSA A TER PELO DEPARTAMENTO
-- ------------------------------------------------------------
-- Tudo isto só faz sentido enquanto a coluna existir. Na SEGUNDA execução ela
-- já não existe, e o arquivo parava aqui com "column p.grupo_id does not exist"
-- — pior do que falhar logo, porque metade já tinha sido aplicada.
do $migra$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'permissoes'
       and column_name = 'grupo_id')
  then
    raise notice 'permissoes.grupo_id já não existe — nada a migrar.';
    return;
  end if;

  insert into permissoes (usuario_id, departamento_id)
  select distinct p.usuario_id, g.departamento_id
    from permissoes p
    join grupos g on g.id = p.grupo_id
   where p.grupo_id is not null
     and p.departamento_id is null
     and p.telefone_id is null
     -- Não repete o que a pessoa já tem por outro caminho.
     and not exists (
       select 1 from permissoes q
        where q.usuario_id = p.usuario_id
          and q.departamento_id = g.departamento_id
          and q.grupo_id is null and q.telefone_id is null);

  -- Permissão de telefone+grupo vira permissão do telefone: o grupo deixou de
  -- restringir, o telefone continua.
  insert into permissoes (usuario_id, telefone_id)
  select distinct p.usuario_id, p.telefone_id
    from permissoes p
   where p.grupo_id is not null
     and p.telefone_id is not null
     and not exists (
       select 1 from permissoes q
        where q.usuario_id = p.usuario_id
          and q.telefone_id = p.telefone_id
          and q.grupo_id is null and q.departamento_id is null);

  -- Agora as linhas que citam grupo não têm mais o que dizer.
  delete from permissoes where grupo_id is not null;

  -- E a coluna sai da tabela de permissões — esta, sim, pode: quem lê
  -- `permissoes` é a função de visibilidade, que este arquivo reescreve logo
  -- abaixo, e a tela de permissões do Vantoro, que nunca mandou grupo.
  alter table permissoes drop column if exists grupo_id;
end $migra$;


-- ------------------------------------------------------------
--  2. A VISIBILIDADE OLHA SÓ DEPARTAMENTO E TELEFONE
-- ------------------------------------------------------------
-- A assinatura muda (some o segundo argumento), então a versão antiga precisa
-- sair antes — `create or replace` com outros tipos criaria uma SEGUNDA função
-- de mesmo nome. O `cascade` derruba as políticas que a usam; elas são
-- recriadas logo abaixo, neste mesmo arquivo.
drop function if exists pode_ver_conversa(uuid, bigint) cascade;
drop function if exists pode_ver_conversa(bigint, bigint) cascade;

create or replace function pode_ver_conversa(p_telefone_id uuid)
returns boolean
language sql stable security definer set search_path = public, auth as $$
  select zorvin_admin() or exists (
    select 1
      from permissoes p
      join advogados a on a.id = p_telefone_id
     where p.usuario_id = auth.uid()
       and (p.departamento_id is null or p.departamento_id = a.departamento_id)
       and (p.telefone_id     is null or p.telefone_id     = p_telefone_id)
  );
$$;
grant execute on function pode_ver_conversa(uuid) to authenticated;

-- Recria as políticas que o cascade levou. Idênticas às de antes, menos o
-- grupo.
do $limpeza$
declare r record;
begin
  for r in
    select tablename, policyname from pg_policies
     where schemaname = 'public' and tablename in ('conversas', 'mensagens', 'fila_envio')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $limpeza$;

alter table conversas  enable row level security;
alter table mensagens  enable row level security;
alter table fila_envio enable row level security;

create policy conversas_leitura on conversas for select to authenticated
using (pode_ver_conversa(advogado_id));

create policy conversas_escrita on conversas for update to authenticated
using (pode_ver_conversa(advogado_id))
with check (pode_ver_conversa(advogado_id));

create policy mensagens_leitura on mensagens for select to authenticated
using (exists (select 1 from conversas c where c.id = mensagens.conversa_id));

create policy mensagens_insercao on mensagens for insert to authenticated
with check (exists (select 1 from conversas c where c.id = mensagens.conversa_id));

create policy fila_envio_leitura on fila_envio for select to authenticated
using (exists (select 1 from conversas c where c.id = fila_envio.conversa_id));

create policy fila_envio_insercao on fila_envio for insert to authenticated
with check (exists (select 1 from conversas c where c.id = fila_envio.conversa_id));


-- ------------------------------------------------------------
--  3. O GATILHO QUE CRIAVA O "BALAIO" DE CADA DEPARTAMENTO PARA
-- ------------------------------------------------------------
-- Ele existia para nenhuma conversa ficar sem grupo. Sem grupo, não há o que
-- garantir — e um gatilho que cria linha que ninguém lê é lixo que cresce.
drop trigger if exists departamento_ganha_balaio on departamentos;
drop function if exists grupo_padrao_do_departamento();


-- ------------------------------------------------------------
--  4. CONFERÊNCIA — rode depois e olhe os números
-- ------------------------------------------------------------
--  select d.nome as departamento, count(c.id) as conversas
--    from departamentos d
--    left join advogados a on a.departamento_id = d.id
--    left join conversas c on c.advogado_id = a.id
--   group by d.nome, d.ordem order by d.ordem;
--
--  select u.login, u.admin,
--         count(*) filter (where p.departamento_id is not null) as por_departamento,
--         count(*) filter (where p.telefone_id is not null)     as por_telefone
--    from usuarios u left join permissoes p on p.usuario_id = u.id
--   group by u.login, u.admin order by u.login;
--
--  -- Ninguém pode ter ficado sem nada por causa deste arquivo:
--  select count(*) from usuarios u
--   where u.admin = false
--     and not exists (select 1 from permissoes p where p.usuario_id = u.id);
