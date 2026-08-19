-- ============================================================
--  O NOME E A FOTO DE HOJE, NO HISTÓRICO INTEIRO
--
--  O relato: alguém troca o nome (ou põe uma foto que não tinha) e só as
--  mensagens NOVAS mudam. As antigas continuam assinadas com o nome velho e
--  sem foto — e, no grupinho de avatares do topo da conversa, a mesma pessoa
--  aparece DUAS vezes: uma com o nome de antes, outra com o de agora.
--
--  A causa é uma decisão antiga, e ela tinha razão de ser: `mensagens`
--  guarda `enviado_por` (texto) e `enviado_por_foto` — o nome e a foto NO
--  MOMENTO do envio. O argumento escrito no SQL de agosto foi: "trocar por um
--  join faria uma mensagem de 2025 aparecer assinada com o nome de 2027".
--
--  Só que na prática é o contrário do que se quer. Ninguém abre uma conversa
--  para saber como o colega se chamava em março; abre para saber COM QUEM
--  está falando. O nome de então vira ruído, e a foto de então vira uma
--  bolinha de iniciais no meio de uma conversa que já tem foto.
--
--  Nada é apagado: `enviado_por` e `enviado_por_foto` continuam gravados na
--  linha, do jeito que sempre estiveram. O que muda é de onde a TELA tira o
--  que desenha — e é por isso que dá para voltar atrás sem perder nada.
--
--  Para a tela poder fazer isso, faltava o essencial: um lugar com o nome e a
--  foto ATUAIS de cada pessoa, que todo mundo possa ler. O nome já estava em
--  `usuarios`; a foto morava só no `user_metadata` da conta de cada um — que
--  ninguém, além do próprio dono, consegue ler. É o que este arquivo resolve.
--
--  Rodar no SQL Editor do Supabase. Seguro rodar de novo.
-- ============================================================

set search_path = public;


-- ------------------------------------------------------------
--  1. A FOTO SAI DE DENTRO DA CONTA
--
--  Ela era gravada em `auth.users.raw_user_meta_data`, e ali só o próprio
--  dono alcança. Por isso cada mensagem carregava uma cópia da foto: era o
--  único jeito de saber a cara de outra pessoa. Daí o defeito — cópia tirada
--  no dia do envio não muda depois.
-- ------------------------------------------------------------
alter table usuarios add column if not exists foto_url text;

comment on column usuarios.foto_url is
  'Foto de perfil ATUAL da pessoa. A cópia que viaja em mensagens.enviado_por_foto '
  'é a do dia do envio e fica onde está; a tela desenha esta.';

-- E o que já existe entra de uma vez, sem esperar cada um trocar a foto de
-- novo. Sem esta parte, o histórico só passaria a ter foto aos poucos, à
-- medida que as pessoas fossem mexendo no perfil — e a maioria não mexeria.
update usuarios u
   set foto_url = a.raw_user_meta_data->>'foto_url'
  from auth.users a
 where a.id = u.id
   and coalesce(a.raw_user_meta_data->>'foto_url', '') <> ''
   and u.foto_url is distinct from a.raw_user_meta_data->>'foto_url';


-- ------------------------------------------------------------
--  2. QUEM PODE LER O QUÊ
--
--  `usuarios` é fechada: cada pessoa lê a PRÓPRIA linha, e quem administra lê
--  todas (política `usuarios_leitura`). Está certo — ali dentro há e-mail,
--  login e quem é administrador.
--
--  Mas para desenhar a conversa a tela precisa do nome e da foto dos COLEGAS,
--  e só disso. Abrir `usuarios` inteira para todo mundo, por causa de duas
--  colunas, seria entregar as outras cinco de brinde.
--
--  Então: uma vista com as três colunas que a tela desenha, e nada mais.
--  `security_invoker = false` de propósito — é o que faz a vista responder
--  pelo dono dela, e não pelas regras de quem pergunta. Sem isso a vista
--  devolveria exatamente o que a política já devolve (a própria linha), que é
--  o mesmo que não existir.
-- ------------------------------------------------------------
drop view if exists equipe;
create view equipe with (security_invoker = false) as
  select id, nome, foto_url from usuarios;

comment on view equipe is
  'Nome e foto atuais de cada pessoa do escritório — e SÓ isso. É o que a tela '
  'usa para assinar as mensagens e desenhar os avatares. Quem sai do '
  'escritório continua aqui: as mensagens dele seguem na conversa e precisam '
  'de nome.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant select on equipe to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  3. TROCAR A PRÓPRIA FOTO
--
--  Uma FUNÇÃO, e não uma política de update em `usuarios`. Uma política do
--  tipo "cada um mexe na própria linha" deixaria a pessoa escrever qualquer
--  coluna da linha dela — inclusive `admin`. Seria dar a chave do cofre para
--  resolver a foto do crachá.
--
--  `security definer` com `where id = auth.uid()`: a função escreve uma
--  coluna, numa linha, a de quem chamou. Não há como pedir outra coisa.
-- ------------------------------------------------------------
create or replace function salvar_minha_foto(p_url text)
returns void
language sql
security definer
set search_path = public
as $$
  update usuarios
     set foto_url = nullif(btrim(p_url), '')
   where id = auth.uid();
$$;

comment on function salvar_minha_foto(text) is
  'Grava a foto de perfil de quem chamou. Só a própria, só essa coluna.';

revoke all on function salvar_minha_foto(text) from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function salvar_minha_foto(text) to authenticated';
  end if;
end $$;


-- ------------------------------------------------------------
--  CONFERÊNCIA — rode e leia
-- ------------------------------------------------------------
select 'a coluna da foto existe' as item,
       exists(select 1 from information_schema.columns
               where table_name = 'usuarios' and column_name = 'foto_url') as ok
union all
select 'a vista da equipe existe',
       exists(select 1 from pg_views where viewname = 'equipe')
union all
select 'a vista responde pelo dono (e não pelas regras de quem pergunta)',
       not coalesce((select 'security_invoker=true' = any(reloptions)
                       from pg_class where relname = 'equipe' and relkind = 'v'), false)
union all
select 'a função de trocar a foto existe',
       to_regprocedure('public.salvar_minha_foto(text)') is not null;

-- Quantas pessoas já ficaram com foto (as que tinham foto na conta):
select count(*) filter (where foto_url is not null) as com_foto,
       count(*)                                    as no_total
  from usuarios;
