-- ------------------------------------------------------------
--  A COLUNA `tipo` PRECISA ACEITAR 'figurinha'
--
--  A conferência mostrou o motivo de a figurinha nunca aparecer no Zorvin:
--
--    CHECK (tipo = ANY (ARRAY['texto','imagem','audio','video','documento','outro']))
--
--  'figurinha' não está na lista. O banco recusa a linha — e recusava dos dois
--  lados: a que o contato manda e a que sai daqui. Por isso a figurinha chegava
--  ao celular do cliente e não existia no histórico: quem envia é a Uazapi,
--  quem guarda é esta tabela, e só a segunda dizia não.
--
--  Zero figurinhas gravadas até hoje. Não há o que corrigir no que já existe;
--  o que passou não foi guardado e não volta. Da próxima em diante, entra.
--
--  A restrição continua existindo, e é bom que continue: ela é o que impede um
--  tipo escrito errado de entrar e virar bolha que a tela não sabe desenhar.
--  Só ganha o valor que faltava.
--
--  O nome da restrição não é fixo entre instalações, então o script procura
--  qualquer CHECK de `mensagens` que fale de `tipo`, derruba e põe a nova no
--  lugar. Rodar de novo não faz mal.
--
--  Rode INTEIRO no SQL Editor do Supabase. É um comando só.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select conname
      from pg_constraint
     where conrelid = 'mensagens'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%tipo%'
  loop
    execute format('alter table mensagens drop constraint %I', r.conname);
  end loop;

  execute $sql$
    alter table mensagens add constraint mensagens_tipo_check
      check (tipo in ('texto','imagem','audio','video','documento','figurinha','outro'))
  $sql$;
end $$;
