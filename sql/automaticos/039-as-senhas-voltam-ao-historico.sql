-- ------------------------------------------------------------
--  039. AS SENHAS VOLTAM AO HISTÓRICO DE ALTERAÇÕES (29/10)
--
--  Desfaz o 038. Pedido do Rodrigo, no dia seguinte: *"As senhas do SERASA
--  e GOV precisam aparecer, todos os usuários precisam saber qual é a
--  senha."*
--
--  O 038 partia de uma premissa que não vale neste escritório: a de que
--  algumas pessoas do Zorvin não veem as senhas na ficha e as liam pelo
--  histórico. MEDIDO em 29/10, no banco do Vantoro: quem decide se as senhas
--  vêm é a CHAVE com que a ponte pergunta, e não a pessoa — e a da ponte vê
--  (é o token do ambiente, que vê tudo). Na ficha, todo mundo do Zorvin já vê
--  as duas senhas. Esconder no histórico não protegia nada: só apagava o que
--  a equipe precisa ler.
--
--  O QUE FAZ: tira o gatilho que trocava a senha por "••••••" em toda linha
--  nova, e a função dele. Dali em diante, o "de → para" de uma senha é
--  gravado como o de qualquer outro campo. A ponte já não esconde ao gravar
--  (`registrarEdicaoDeCadastro`).
--
--  O QUE NÃO FAZ: devolver o valor às linhas que o 038 já escondeu. O
--  "••••••" foi gravado por cima, e o valor de antes não está em lugar
--  nenhum deste banco. A conferência diz quantas são. As senhas ATUAIS de
--  cada cliente continuam inteiras no Vantoro, que é onde elas moram.
--
--  O 038 NÃO SE RODA DE NOVO À MÃO: ele esconde as senhas que encontrar. A
--  ponte aplica cada script uma vez só; quem rodar a pasta inteira à mão, na
--  ordem (a regra 5 do LEIA-ME), roda o 038 e logo depois este, e as linhas
--  com senha que já existirem voltam a ser escondidas.
--
--  Rodável de novo. Num banco sem a tabela, sai cedo.
-- ------------------------------------------------------------

create temporary table zorvin_conferencia_039 (item text, resposta text) on commit drop;

do $senhas$
begin
  if to_regclass('public.alteracoes') is null then
    insert into zorvin_conferencia_039 values
      ('as senhas no histórico', 'nada a fazer — este banco não tem o histórico de alterações');
    return;
  end if;

  execute 'drop trigger if exists zorvin_senha_fora_do_historico on public.alteracoes';
  execute 'drop function if exists public.zorvin_senha_fora_do_historico()';

  insert into zorvin_conferencia_039 values
    ('o gatilho que escondia a senha saiu',
     (not exists (select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid
                   where c.relname = 'alteracoes' and t.tgname = 'zorvin_senha_fora_do_historico'))::text);
  insert into zorvin_conferencia_039
  select 'linhas que o 038 escondeu e continuam escondidas',
         count(*)::text
    from public.alteracoes
   where tipo = 'cadastro' and coalesce(alvo, '') ~* 'senha'
     and ('••••••' in (coalesce(antes, ''), coalesce(depois, '')));
end $senhas$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_039;
