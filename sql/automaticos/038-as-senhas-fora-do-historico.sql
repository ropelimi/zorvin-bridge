-- ------------------------------------------------------------
--  038. AS SENHAS NÃO FICAM NO HISTÓRICO DE ALTERAÇÕES (28/10)
--
--  Auditoria de 27/10. Trocar a Senha SERASA ou a Senha GOV na ficha do
--  cliente deixava em `alteracoes` uma linha com a senha de antes e a de
--  depois, por extenso. A leitura de `alteracoes` é aberta a todo mundo que
--  entrou — é ela que mostra o "de → para" no histórico do cliente —, então
--  quem o Vantoro NÃO deixa ver as senhas as lia ali, uma por uma.
--
--  MEDIDO em 28/10, só contando, sem ler valor nenhum: 59 linhas (40 da Senha
--  GOV e 19 da Senha SERASA), de 26/08 a 27/10.
--
--  O QUE FAZ:
--    1. nas linhas que existem, a senha vira "••••••". A linha fica: quem
--       trocou, e quando, continua sendo resposta — o que some é o valor;
--    2. um gatilho faz o mesmo com toda linha nova, de quem quer que venha.
--       A ponte já não manda a senha (`registrarEdicaoDeCadastro`), mas nos
--       segundos de uma publicação a ponte de antes continua no ar, e a regra
--       mora no banco para não depender de quem escreve.
--
--  É SENHA todo campo do cadastro cujo nome tem "senha" — o da SERASA, o do
--  GOV e o próximo que o Vantoro ganhar. O vazio continua vazio: "(vazio) →
--  ••••••" é a senha cadastrada pela primeira vez, e essa diferença importa.
--
--  Rodável de novo. Num banco sem a tabela, sai cedo.
-- ------------------------------------------------------------

create temporary table zorvin_conferencia_038 (item text, resposta text) on commit drop;

do $senhas$
declare
  v_escondidas int := 0;
begin
  if to_regclass('public.alteracoes') is null then
    insert into zorvin_conferencia_038 values
      ('as senhas fora do histórico', 'nada a fazer — este banco não tem o histórico de alterações');
    return;
  end if;

  execute $x$
    create or replace function public.zorvin_senha_fora_do_historico()
    returns trigger language plpgsql set search_path = public as $f$
    begin
      if new.tipo = 'cadastro' and coalesce(new.alvo, '') ~* 'senha' then
        if coalesce(new.antes, '') <> '' then new.antes := '••••••'; end if;
        if coalesce(new.depois, '') <> '' then new.depois := '••••••'; end if;
      end if;
      return new;
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_senha_fora_do_historico() from public';
  execute 'drop trigger if exists zorvin_senha_fora_do_historico on public.alteracoes';
  execute 'create trigger zorvin_senha_fora_do_historico
             before insert or update on public.alteracoes
             for each row execute function public.zorvin_senha_fora_do_historico()';

  -- AS QUE JÁ ESTÃO LÁ. O gatilho de cima as esconde de novo ao gravar; o
  -- `case` daqui é o que diz qual linha muda, para a conta não contar à toa.
  update public.alteracoes
     set antes  = case when coalesce(antes, '') <> '' then '••••••' else antes end,
         depois = case when coalesce(depois, '') <> '' then '••••••' else depois end
   where tipo = 'cadastro' and coalesce(alvo, '') ~* 'senha'
     and (coalesce(antes, '') not in ('', '••••••') or coalesce(depois, '') not in ('', '••••••'));
  get diagnostics v_escondidas = row_count;

  insert into zorvin_conferencia_038 values
    ('linhas com senha escondidas agora', v_escondidas::text);
  insert into zorvin_conferencia_038
  select 'nenhuma senha por extenso no histórico',
         (not exists (select 1 from public.alteracoes
                       where tipo = 'cadastro' and coalesce(alvo, '') ~* 'senha'
                         and (coalesce(antes, '') not in ('', '••••••')
                              or coalesce(depois, '') not in ('', '••••••'))))::text;
  insert into zorvin_conferencia_038 values
    ('o gatilho que esconde a senha',
     exists (select 1 from pg_trigger where tgname = 'zorvin_senha_fora_do_historico')::text);
end $senhas$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_038;
