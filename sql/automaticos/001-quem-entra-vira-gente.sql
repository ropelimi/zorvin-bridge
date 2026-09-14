-- ============================================================
--  QUEM ENTRA VIRA GENTE — a linha da pessoa nasce junto com a conta
--
--  ESTE É O PRIMEIRO SCRIPT QUE A PONTE APLICA SOZINHA. Não precisa ser colado
--  em lugar nenhum: basta publicar a ponte com `DATABASE_URL` configurada e
--  `SCRIPTS_AUTOMATICOS=aplicar`.
--
--  ------------------------------------------------------------
--  O QUE ELE CONSERTA
--
--  Entrar no Zorvin é duas coisas: ter conta no Auth do Supabase (é ela que
--  confere a senha) e ter uma linha em `usuarios` (é ela que diz QUEM a pessoa
--  é — o nome que assina a bolha, se ela administra, o que ela pode ver).
--
--  Até hoje quem criava a segunda era a PONTE, no login, com o que o Vantoro
--  respondia. Num escritório que não tem Vantoro esse caminho não existe: a
--  pessoa entra com e-mail e senha, chega ao painel, e o painel não sabe quem
--  ela é. O nome não assina nada, ela não administra nada, e a tela não diz o
--  porquê — porque para ela não há nada errado, só não há ninguém ali.
--
--  Agora a linha nasce junto com a conta, por gatilho.
--
--  ------------------------------------------------------------
--  O PRIMEIRO A ENTRAR ADMINISTRA — e é a única saída honesta
--
--  Quem administra sai de `usuarios.admin`, e quem escrevia esse campo era o
--  Vantoro. Sem ele, ninguém seria administrador NUNCA: as telas de
--  departamentos e permissões ficariam trancadas para todo mundo, inclusive
--  para o dono do sistema, e não haveria como destrancar por dentro.
--
--  Então a PRIMEIRA conta do banco nasce administradora. É a instalação nova,
--  e é sempre de quem está instalando. Da segunda em diante, ninguém nasce
--  administrador — quem já é promove.
--
--  Num banco que já tem gente (o do escritório, por exemplo), `usuarios` não
--  está vazia e nada disto acontece: toda conta nova nasce sem poder nenhum,
--  como já nascia.
--
--  ------------------------------------------------------------
--  O GATILHO NUNCA DERRUBA A CRIAÇÃO DA CONTA
--
--  Esta é a parte que exige cuidado, e o motivo é concreto: no caminho COM
--  Vantoro, é a ponte que cria a conta no Auth (`createUser`) na primeira
--  entrada da vida de alguém. Um gatilho que estoure ali faz a criação inteira
--  falhar — e o sintoma seria "fulano não consegue entrar de jeito nenhum", no
--  dia em que fulano foi contratado.
--
--  Por isso o corpo inteiro vive dentro de um `exception when others`: dando
--  qualquer problema, ele desiste em silêncio e a conta é criada assim mesmo.
--  A pessoa entra sem linha em `usuarios` — que é exatamente a situação de
--  antes deste script, e não uma pior.
--
--  ------------------------------------------------------------
--  E ELE NÃO ATRAPALHA O CAMINHO COM VANTORO
--
--  Lá a ponte continua fazendo o `upsert` que sempre fez, logo depois da
--  criação, com o nome e o `admin` que o Vantoro respondeu. O que o gatilho
--  escreveu é substituído por aquilo. O `on conflict do nothing` aqui existe
--  para a ordem inversa: se a linha já existir, este script não tem nada a
--  dizer sobre ela.
--
--  ------------------------------------------------------------
--  CONFERÊNCIA (depois de aplicado)
--
--    select tgname, tgrelid::regclass
--      from pg_trigger where tgname = 'zorvin_usuario_novo';
--    -- deve devolver uma linha, em auth.users
--
--  DESFAZER
--
--    drop trigger if exists zorvin_usuario_novo on auth.users;
--    drop function if exists public.zorvin_usuario_novo();
-- ============================================================

create or replace function public.zorvin_usuario_novo()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  ninguem_ainda boolean;
  apelido text;
begin
  apelido := split_part(coalesce(new.email, ''), '@', 1);

  -- "É o primeiro?" é lido DENTRO da transação que cria a conta, então duas
  -- contas criadas ao mesmo tempo não viram dois administradores por engano:
  -- a segunda enxerga a linha da primeira ou espera por ela.
  select not exists (select 1 from public.usuarios) into ninguem_ainda;

  insert into public.usuarios (id, login, nome, email, admin, ativo, visto_em)
  values (
    new.id,
    apelido,
    coalesce(nullif(new.raw_user_meta_data ->> 'nome', ''), apelido),
    lower(coalesce(new.email, '')),
    ninguem_ainda,
    true,
    now()
  )
  on conflict (id) do nothing;

  return new;
exception when others then
  -- DESISTIR EM SILÊNCIO É O CERTO AQUI, e só aqui. Estourar faria a criação
  -- da conta falhar junto, e aí ninguém entra — em troca de um campo de nome.
  -- Fica no log do banco para quem for investigar.
  raise warning 'zorvin_usuario_novo não escreveu a linha de % (%)', new.id, sqlerrm;
  return new;
end;
$$;

-- Armadilha nº 5 do CLAUDE.md: toda função nasce executável por `public`, que
-- inclui `anon`. Esta é `security definer` e ESCREVE em `usuarios`. Ninguém
-- precisa chamá-la pelo nome — ela vive dentro do gatilho —, então ninguém
-- recebe de volta.
revoke all on function public.zorvin_usuario_novo() from public;

drop trigger if exists zorvin_usuario_novo on auth.users;
create trigger zorvin_usuario_novo
  after insert on auth.users
  for each row execute function public.zorvin_usuario_novo();
