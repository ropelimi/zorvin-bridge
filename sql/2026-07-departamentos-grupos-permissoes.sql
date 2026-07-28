-- ============================================================
--  DEPARTAMENTOS, GRUPOS E PERMISSÕES
--
--  Rode uma vez no Supabase do Zorvin:
--    Dashboard → SQL Editor → New query → cole tudo → Run
--
--  Pode rodar de novo sem medo: tudo é "if not exists" e os dados iniciais
--  usam "on conflict do nothing". Nada é apagado.
--
--  ATENÇÃO — este arquivo TROCA as regras de visibilidade (RLS) das conversas
--  e mensagens. Antes desta mudança, qualquer pessoa que entrasse via
--  autenticada enxergava todas as conversas. Depois, cada pessoa enxerga o
--  que lhe foi concedido. A parte 6 concede a todo mundo, na virada, o mesmo
--  que essa pessoa já enxergava hoje — ninguém perde acesso no dia.
-- ============================================================


-- ------------------------------------------------------------
--  1. DEPARTAMENTOS  —  os telefones nossos, agrupados
--
--  Hoje isto existe como a coluna `advogados.setor`, com dois valores escritos
--  dentro do código do painel ("acordos" e "gestao"). Virar tabela é o que
--  permite criar SAC, Vendas, Interno sem mexer em código.
-- ------------------------------------------------------------
create table if not exists departamentos (
  id          bigint generated always as identity primary key,
  nome        text        not null,
  slug        text        not null unique,
  cor         text        not null default '#7b8794',
  ordem       int         not null default 100,
  ativo       boolean     not null default true,
  criado_em   timestamptz not null default now()
);

-- Cada telefone nosso pertence a um departamento.
alter table advogados add column if not exists departamento_id bigint references departamentos(id);
create index if not exists advogados_departamento_idx on advogados (departamento_id);


-- ------------------------------------------------------------
--  2. GRUPOS  —  os tipos de conversa DENTRO de um departamento
--
--  O problema que eles resolvem: no departamento "Advogados" estão os mesmos
--  telefones para duas conversas de natureza oposta — negociar acordo com o
--  réu e avisar o próprio cliente da audiência. Separar por telefone nunca
--  funcionaria, porque o telefone é o mesmo.
--
--  Quem separa é QUEM ESTÁ DO OUTRO LADO, e o Vantoro já sabe disso: ele
--  classifica cada número em CLIENTE, ACORDO, LEAD, INTERNO ou DESCONHECIDA
--  olhando o cadastro. É a coluna `conversas.frente` que já existe.
--
--  Então o grupo é uma etiqueta com uma REGRA:
--
--    regra = 'frente'  → recebe as conversas cuja classificação do Vantoro
--                        bate com a coluna `frente` deste grupo;
--    regra = 'padrao'  → o balaio do departamento: fica com o que não se
--                        encaixou em nenhum outro grupo dele.
--
--  O NOME é livre e pode ser trocado a qualquer momento: no departamento
--  Advogados, o grupo da frente CLIENTE pode se chamar "Audiências". A regra
--  continua a mesma; muda só o que a equipe lê na tela.
-- ------------------------------------------------------------
create table if not exists grupos (
  id               bigint generated always as identity primary key,
  departamento_id  bigint      not null references departamentos(id) on delete cascade,
  nome             text        not null,
  slug             text        not null,
  cor              text        not null default '#7b8794',
  ordem            int         not null default 100,
  ativo            boolean     not null default true,
  regra            text        not null default 'frente',
  frente           text,
  criado_em        timestamptz not null default now(),
  unique (departamento_id, slug),
  constraint grupo_regra_valida check (regra in ('frente', 'padrao')),
  constraint grupo_frente_valida check (
    (regra = 'frente' and frente in ('CLIENTE','ACORDO','LEAD','INTERNO','DESCONHECIDA'))
    or (regra = 'padrao' and frente is null))
);

-- Um balaio por departamento, e uma frente num grupo só: sem isto a mesma
-- conversa teria dois destinos possíveis e cairia num deles por sorteio.
create unique index if not exists grupos_padrao_unico
  on grupos (departamento_id) where regra = 'padrao';
create unique index if not exists grupos_frente_unica
  on grupos (departamento_id, frente) where regra = 'frente';

-- A conversa aponta para o grupo. Fica repetido de propósito (a frente já
-- está na conversa): é assim que o painel filtra sem cruzar tabela a cada
-- abertura de tela, e é o que a regra de visibilidade consulta.
alter table conversas add column if not exists grupo_id bigint references grupos(id);
-- Alguém moveu a conversa à mão? Então a ponte para de mexer nela. Sem isto, a
-- próxima mensagem devolveria a conversa para o grupo automático e a correção
-- feita por uma pessoa seria desfeita sozinha.
alter table conversas add column if not exists grupo_fixado boolean not null default false;
create index if not exists conversas_grupo_idx on conversas (grupo_id);


-- ------------------------------------------------------------
--  3. USUÁRIOS  —  espelho de quem existe no Vantoro
--
--  A senha NÃO fica aqui: quem confere é o Vantoro. Esta tabela existe para
--  duas coisas: dar um lugar onde pendurar as permissões, e permitir que a
--  tela de permissões mostre nome em vez de um código.
--
--  O `id` é o mesmo do usuário no Auth do Supabase, porque é ele que o
--  `auth.uid()` devolve dentro das regras de visibilidade.
-- ------------------------------------------------------------
create table if not exists usuarios (
  id        uuid        primary key references auth.users(id) on delete cascade,
  login     text        not null unique,
  nome      text        not null default '',
  email     text        not null default '',
  admin     boolean     not null default false,
  ativo     boolean     not null default true,
  visto_em  timestamptz
);


-- ------------------------------------------------------------
--  4. PERMISSÕES  —  três níveis, uma tabela só
--
--  Cada linha é um FILTRO. As colunas preenchidas têm de bater todas; as
--  vazias não restringem nada. Com isso, os três níveis pedidos saem da mesma
--  estrutura, e ainda sobra a combinação:
--
--    departamento_id = Advogados                → tudo do departamento
--    grupo_id        = Audiências               → só as audiências
--    telefone_id     = (número da Dra. Ana)     → só o número dela
--    telefone + grupo                           → só as audiências dela
--
--  As linhas SOMAM: a pessoa enxerga a união de tudo que lhe foi concedido.
--  Escolha deliberada — regra de "negar" exige uma tabela de precedência que
--  todo mundo lê errado na hora de responder "afinal, ela vê ou não vê?".
--  Aqui a resposta é sempre: vê se alguma linha disser que sim.
-- ------------------------------------------------------------
--  O tipo de `telefone_id` é LIDO da tabela `advogados`, não escrito à mão.
--
--  A primeira versão deste arquivo escreveu `bigint` e a execução parou aqui:
--  o `advogados.id` do Zorvin é `uuid`. Tipo chutado não falha discretamente —
--  a chave estrangeira nem chega a ser criada e o arquivo morre no meio.
--  Lendo o tipo do próprio banco, ele vale para os dois formatos, hoje e
--  depois de qualquer migração.
do $$
declare tipo_do_telefone text;
begin
  select format_type(a.atttypid, a.atttypmod) into tipo_do_telefone
    from pg_attribute a
   where a.attrelid = 'public.advogados'::regclass
     and a.attname = 'id' and a.attnum > 0 and not a.attisdropped;
  if tipo_do_telefone is null then
    raise exception 'Não achei a coluna advogados.id — este banco é o do Zorvin?';
  end if;

  execute format($ddl$
    create table if not exists permissoes (
      id               bigint generated always as identity primary key,
      usuario_id       uuid        not null references usuarios(id) on delete cascade,
      departamento_id  bigint      references departamentos(id) on delete cascade,
      grupo_id         bigint      references grupos(id)         on delete cascade,
      telefone_id      %s          references advogados(id)      on delete cascade,
      criado_em        timestamptz not null default now(),
      -- Linha com tudo vazio liberaria tudo sem dizer isso em lugar nenhum.
      constraint permissao_nao_vazia check (
        departamento_id is not null or grupo_id is not null or telefone_id is not null)
    )$ddl$, tipo_do_telefone);
end $$;
create index if not exists permissoes_usuario_idx on permissoes (usuario_id);


-- ------------------------------------------------------------
--  5. DADOS INICIAIS  —  o que existe hoje, virando tabela
-- ------------------------------------------------------------

-- 5.1 Os setores de hoje viram departamentos.
insert into departamentos (nome, slug, cor, ordem)
values ('Central de Acordos', 'acordos', '#c98a2e', 10),
       ('Gestão',             'gestao',  '#8a72c9', 20)
on conflict (slug) do nothing;

-- Todo telefone recebe o departamento que corresponde ao seu setor. Telefone
-- sem setor definido cai em "acordos", que era o padrão de antes.
update advogados a
   set departamento_id = d.id
  from departamentos d
 where a.departamento_id is null
   and d.slug = coalesce(nullif(a.setor, ''), 'acordos');

-- Sobrou algum telefone com um setor que não virou departamento? Cria o
-- departamento com o nome do próprio setor, em vez de deixar o telefone órfão
-- (telefone sem departamento fica invisível para todo mundo que não é admin).
insert into departamentos (nome, slug, ordem)
select distinct initcap(a.setor), a.setor, 90
  from advogados a
 where a.departamento_id is null and coalesce(a.setor,'') <> ''
on conflict (slug) do nothing;

update advogados a
   set departamento_id = d.id
  from departamentos d
 where a.departamento_id is null and d.slug = a.setor;

-- 5.2 Um grupo por frente que REALMENTE aparece em cada departamento, mais o
--     balaio. Criar as cinco frentes em todo departamento encheria a tela de
--     abas vazias; criar só o que existe deixa a tela igual ao trabalho real.
insert into grupos (departamento_id, nome, slug, cor, ordem, regra, frente)
select distinct a.departamento_id,
       case c.frente when 'ACORDO'  then 'Acordos'
                     when 'CLIENTE' then 'Clientes'
                     when 'LEAD'    then 'Vendas'
                     when 'INTERNO' then 'Interno'
                     else 'Sem identificar' end,
       lower(c.frente),
       case c.frente when 'ACORDO'  then '#c98a2e'
                     when 'CLIENTE' then '#2e9e6b'
                     when 'LEAD'    then '#3d7dd6'
                     when 'INTERNO' then '#8a72c9'
                     else '#7b8794' end,
       case c.frente when 'ACORDO' then 10 when 'CLIENTE' then 20
                     when 'LEAD' then 30 when 'INTERNO' then 40 else 50 end,
       'frente', c.frente
  from conversas c
  join advogados a on a.id = c.advogado_id
 where c.frente is not null
   and c.frente in ('CLIENTE','ACORDO','LEAD','INTERNO','DESCONHECIDA')
   and a.departamento_id is not null
on conflict (departamento_id, slug) do nothing;

-- O balaio de cada departamento: conversa que ainda não foi classificada, ou
-- cuja frente não tem grupo aqui, precisa de um lugar — senão ela some da tela
-- de quem tem permissão por grupo, e some sem avisar.
insert into grupos (departamento_id, nome, slug, cor, ordem, regra, frente)
select d.id, 'Outras', 'outras', '#7b8794', 900, 'padrao', null
  from departamentos d
on conflict (departamento_id, slug) do nothing;

-- E todo departamento criado DEPOIS, pela tela, nasce com o seu. Deixar isso
-- por conta da tela seria confiar numa promessa: o dia em que o departamento
-- for criado por outro caminho, as conversas dele ficam sem grupo — e conversa
-- sem grupo é invisível para quem tem permissão por grupo. O banco garante.
create or replace function grupo_padrao_do_departamento() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into grupos (departamento_id, nome, slug, cor, ordem, regra, frente)
  values (new.id, 'Outras', 'outras', '#7b8794', 900, 'padrao', null)
  on conflict (departamento_id, slug) do nothing;
  return new;
end $$;

drop trigger if exists departamento_ganha_balaio on departamentos;
create trigger departamento_ganha_balaio after insert on departamentos
for each row execute function grupo_padrao_do_departamento();

-- 5.3 Cada conversa vai para o grupo que corresponde à sua frente; o que não
--     casar vai para o balaio do departamento dela.
update conversas c
   set grupo_id = g.id
  from advogados a
  join grupos g on g.departamento_id = a.departamento_id and g.regra = 'frente'
 where c.advogado_id = a.id and c.grupo_id is null and g.frente = c.frente;

update conversas c
   set grupo_id = g.id
  from advogados a
  join grupos g on g.departamento_id = a.departamento_id and g.regra = 'padrao'
 where c.advogado_id = a.id and c.grupo_id is null;

-- 5.4 Quem já entra no Zorvin vira linha em `usuarios`. O login sai do
--     metadado quando existe; senão, da parte do e-mail antes do @, que é
--     exatamente o formato dos logins encurtados do Vantoro.
insert into usuarios (id, login, nome, email, admin)
select u.id,
       coalesce(nullif(u.raw_user_meta_data->>'login', ''), split_part(coalesce(u.email,''), '@', 1)),
       coalesce(nullif(u.raw_user_meta_data->>'nome',  ''), ''),
       coalesce(u.email, ''),
       coalesce(u.raw_user_meta_data->>'gestor', '') in ('true', 'True', '1')
  from auth.users u
 where coalesce(u.email, '') <> ''
on conflict (id) do nothing;


-- ------------------------------------------------------------
--  6. A VIRADA SEM PERDER ACESSO
--
--  Todo mundo recebe, agora, exatamente o que já enxergava:
--    · gestor  → `admin = true`, enxerga tudo (era o que o painel fazia);
--    · demais  → o departamento "Central de Acordos", que era o único que
--                apareciam para eles.
--
--  Depois disso você aperta os acessos pela tela, com calma. Enquanto não
--  apertar, o sistema fica exatamente como está hoje — nem melhor, nem pior.
-- ------------------------------------------------------------
--  Uma vez por pessoa, marcada na própria pessoa.
--
--  Condicionar a "quem ainda não tem permissão nenhuma" tem um efeito ruim que
--  só aparece meses depois: se você tirar TODOS os acessos de alguém de
--  propósito e este arquivo for rodado de novo, essa pessoa ganha a Central de
--  Acordos de volta sozinha. Uma decisão sua desfeita por um script é o tipo de
--  coisa que ninguém descobre até dar errado.
--
--  Com a marca na pessoa, a concessão inicial acontece uma vez e nunca mais —
--  independente do que você fizer com os acessos dela depois.
alter table usuarios add column if not exists permissao_inicial_em timestamptz;

insert into permissoes (usuario_id, departamento_id)
select u.id, d.id
  from usuarios u
  cross join departamentos d
 where u.admin = false
   and u.permissao_inicial_em is null
   and d.slug = 'acordos';

-- O admin também é marcado: ele enxerga tudo por ser admin, e se um dia deixar
-- de ser não pode ganhar a Central de Acordos de brinde por causa desta parte.
update usuarios set permissao_inicial_em = now() where permissao_inicial_em is null;


-- ------------------------------------------------------------
--  7. QUEM ENXERGA O QUÊ (RLS)
--
--  Até aqui, "estar autenticado" bastava para ver tudo. A partir daqui vale a
--  tabela `permissoes`. As políticas antigas de LEITURA e ESCRITA em
--  `conversas` e `mensagens` são removidas de propósito: políticas do Postgres
--  se SOMAM, então uma política antiga do tipo "todo autenticado pode ler"
--  anularia por completo as regras abaixo — e anularia em silêncio.
-- ------------------------------------------------------------

-- As duas perguntas ficam em FUNÇÕES, e não escritas dentro de cada política.
--
-- `security definer` não é detalhe: uma política que consulta a tabela
-- `permissoes` diretamente exige que a própria pessoa tenha permissão de ler
-- essa tabela — e aí a regra de visibilidade das permissões passaria a valer
-- dentro da regra de visibilidade das conversas, uma dentro da outra. A
-- função roda com os privilégios de quem a criou e corta esse nó.
create or replace function zorvin_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce((select u.admin and u.ativo from usuarios u where u.id = auth.uid()), false);
$$;
grant execute on function zorvin_admin() to authenticated;

-- Esta pessoa enxerga uma conversa deste telefone, neste grupo?
-- Cada dimensão preenchida na linha de permissão tem de bater; as vazias não
-- restringem. É a regra inteira, num lugar só.
--
-- O tipo do primeiro argumento vem do banco, pelo mesmo motivo da tabela
-- `permissoes` mais acima. E qualquer versão anterior com a assinatura errada
-- é removida antes: `create or replace` com outros tipos não substitui nada —
-- cria uma SEGUNDA função com o mesmo nome, e aí a política passaria a
-- escolher entre duas regras parecidas por resolução de tipo.
-- O bloco usa a marca $visibilidade$ e não o $$ de costume: o corpo dele
-- termina com duas marcas de citação encostadas, e um $$ ali dentro fecharia
-- o bloco no meio da frase.
do $visibilidade$
declare tipo_do_telefone text;
        f record;
begin
  select format_type(a.atttypid, a.atttypmod) into tipo_do_telefone
    from pg_attribute a
   where a.attrelid = 'public.advogados'::regclass
     and a.attname = 'id' and a.attnum > 0 and not a.attisdropped;

  -- `cascade` derruba junto as políticas que usam a função — e elas são
  -- recriadas logo abaixo, neste mesmo arquivo. Sem o cascade, a segunda
  -- execução pararia aqui dizendo que a função está em uso.
  for f in
    select oid::regprocedure as assinatura from pg_proc
     where proname = 'pode_ver_conversa'
       and pronamespace = 'public'::regnamespace
  loop
    execute format('drop function if exists %s cascade', f.assinatura);
  end loop;

  execute format($fn$
    create or replace function pode_ver_conversa(p_telefone_id %s, p_grupo_id bigint)
    returns boolean
    language sql stable security definer set search_path = public, auth as $corpo$
      select zorvin_admin() or exists (
        select 1
          from permissoes p
          join advogados a on a.id = p_telefone_id
         where p.usuario_id = auth.uid()
           and (p.departamento_id is null or p.departamento_id = a.departamento_id)
           and (p.grupo_id        is null or p.grupo_id        = p_grupo_id)
           and (p.telefone_id     is null or p.telefone_id     = p_telefone_id)
      );
    $corpo$
  $fn$, tipo_do_telefone);

  execute format('grant execute on function pode_ver_conversa(%s, bigint) to authenticated',
                 tipo_do_telefone);
end $visibilidade$;

-- O painel lê estas tabelas com a chave pública; sem o GRANT, ele levaria
-- "permission denied" — que numa tela vira uma lista vazia sem explicação.
-- Quem restringe as LINHAS é a RLS logo abaixo; o GRANT só abre a porta.
grant select on departamentos, grupos to authenticated;
grant select, insert, update, delete on departamentos, grupos, usuarios, permissoes to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- Remove as políticas antigas de conversas/mensagens (qualquer nome).
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
      from pg_policies
     where schemaname = 'public' and tablename in ('conversas', 'mensagens')
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

alter table conversas enable row level security;
alter table mensagens enable row level security;

-- LER conversas: admin vê tudo; os demais, o que alguma linha de permissão
-- alcançar. Cada dimensão preenchida na linha tem de bater.
create policy conversas_leitura on conversas for select to authenticated
using (pode_ver_conversa(advogado_id, grupo_id));

-- ESCREVER na conversa (marcar lida, favoritar, arquivar, mover de grupo): só
-- quem pode vê-la. Sem a política de UPDATE, quem não enxerga a conversa ainda
-- poderia alterá-la sabendo o id — a leitura estaria protegida e a escrita não.
create policy conversas_escrita on conversas for update to authenticated
using (pode_ver_conversa(advogado_id, grupo_id))
with check (pode_ver_conversa(advogado_id, grupo_id));

-- Mensagens seguem a conversa: quem não pode abrir a conversa não lê nem
-- escreve o que há dentro dela.
create policy mensagens_leitura on mensagens for select to authenticated
using (exists (select 1 from conversas c where c.id = mensagens.conversa_id));

create policy mensagens_insercao on mensagens for insert to authenticated
with check (exists (select 1 from conversas c where c.id = mensagens.conversa_id));

-- A fila de envio também: mandar mensagem por uma conversa que você não
-- enxerga é falar em nome de um atendimento que não é seu.
-- TODAS as políticas, e não só as de inserir: na segunda vez que este arquivo
-- roda, as políticas criadas por ele mesmo precisam sair antes de serem
-- recriadas. Filtrar por tipo deixava a de leitura para trás e a segunda
-- execução parava no meio com "policy already exists" — pior do que falhar
-- logo, porque metade do arquivo já tinha sido aplicada.
do $$
declare r record;
begin
  for r in select policyname from pg_policies
            where schemaname='public' and tablename='fila_envio'
  loop
    execute format('drop policy if exists %I on public.fila_envio', r.policyname);
  end loop;
end $$;
alter table fila_envio enable row level security;
create policy fila_envio_insercao on fila_envio for insert to authenticated
with check (exists (select 1 from conversas c where c.id = fila_envio.conversa_id));
create policy fila_envio_leitura on fila_envio for select to authenticated
using (exists (select 1 from conversas c where c.id = fila_envio.conversa_id));

-- Os cadastros que a tela precisa ler. Departamentos, grupos e telefones não
-- são segredo — o que é segredo é a conversa. Mostrar a aba "Audiências" vazia
-- para quem não tem acesso é melhor do que a tela não saber montar o menu.
alter table departamentos enable row level security;
alter table grupos        enable row level security;
alter table usuarios      enable row level security;
alter table permissoes    enable row level security;

drop policy if exists departamentos_leitura on departamentos;
create policy departamentos_leitura on departamentos for select to authenticated using (true);
drop policy if exists grupos_leitura on grupos;
create policy grupos_leitura on grupos for select to authenticated using (true);

-- Cada pessoa lê o próprio cadastro; o admin lê e mexe em tudo. Sem a primeira
-- regra, o painel não conseguiria nem descobrir se quem entrou é admin.
drop policy if exists usuarios_leitura on usuarios;
create policy usuarios_leitura on usuarios for select to authenticated
using (id = auth.uid() or zorvin_admin());

drop policy if exists permissoes_leitura on permissoes;
create policy permissoes_leitura on permissoes for select to authenticated
using (usuario_id = auth.uid() or zorvin_admin());

-- SÓ o admin mexe na estrutura e nas permissões. É a regra que impede alguém
-- de se conceder acesso a um departamento pela própria tela.
drop policy if exists departamentos_admin on departamentos;
create policy departamentos_admin on departamentos for all to authenticated
using (zorvin_admin()) with check (zorvin_admin());
drop policy if exists grupos_admin on grupos;
create policy grupos_admin on grupos for all to authenticated
using (zorvin_admin()) with check (zorvin_admin());
drop policy if exists permissoes_admin on permissoes;
create policy permissoes_admin on permissoes for all to authenticated
using (zorvin_admin()) with check (zorvin_admin());
drop policy if exists usuarios_admin on usuarios;
create policy usuarios_admin on usuarios for all to authenticated
using (zorvin_admin()) with check (zorvin_admin());

-- O telefone precisa ser lido pela tela (nome do advogado no topo) e mexido
-- pelo admin (trocar de departamento).
alter table advogados enable row level security;
drop policy if exists advogados_leitura on advogados;
create policy advogados_leitura on advogados for select to authenticated using (true);
drop policy if exists advogados_admin on advogados;
create policy advogados_admin on advogados for all to authenticated
using (zorvin_admin()) with check (zorvin_admin());


-- ------------------------------------------------------------
--  8. CONFERÊNCIA — rode depois e olhe os números
-- ------------------------------------------------------------
--  select d.nome as departamento, g.nome as grupo, count(c.id) as conversas
--    from departamentos d
--    left join grupos g on g.departamento_id = d.id
--    left join conversas c on c.grupo_id = g.id
--   group by d.nome, g.nome, d.ordem, g.ordem
--   order by d.ordem, g.ordem;
--
--  select u.login, u.admin, count(p.id) as permissoes
--    from usuarios u left join permissoes p on p.usuario_id = u.id
--   group by u.login, u.admin order by u.login;
--
--  -- Nenhuma conversa pode ficar sem grupo:
--  select count(*) as conversas_sem_grupo from conversas where grupo_id is null;
