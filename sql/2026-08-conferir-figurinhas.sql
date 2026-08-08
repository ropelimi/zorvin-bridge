-- ------------------------------------------------------------
--  CONFERIR AS FIGURINHAS  (consulta — não altera nada)
--
--  A figurinha chega ao celular do contato e não aparece no Zorvin. Isso pode
--  ter duas causas bem diferentes, e o remédio de uma não serve para a outra:
--
--    1. A LINHA NÃO ENTRA NO BANCO. Se a coluna `tipo` tiver uma restrição
--       (CHECK) com a lista de tipos permitidos, 'figurinha' é recusada. A
--       mensagem sai para o WhatsApp e o histórico fica sem ela.
--
--    2. A LINHA ENTRA SEM O ARQUIVO. `midia_url` fica nulo — o download da
--       Uazapi falhou, ou o Storage recusou o .webp. Aí existe registro, mas
--       não existe desenho para mostrar.
--
--  Esta consulta responde às duas. Rode INTEIRA no SQL Editor do Supabase e me
--  mande a tabela que sair; são quatro linhas.
-- ------------------------------------------------------------
select '1. restrições na coluna tipo' as o_que,
       coalesce(string_agg(pg_get_constraintdef(c.oid), '  |  '), 'nenhuma') as resposta
  from pg_constraint c
 where c.conrelid = 'mensagens'::regclass
   and c.contype = 'c'
   and pg_get_constraintdef(c.oid) ilike '%tipo%'
union all
select '2. figurinhas gravadas', count(*)::text from mensagens where tipo = 'figurinha'
union all
select '3. figurinhas sem arquivo', count(*)::text
  from mensagens where tipo = 'figurinha' and midia_url is null
union all
select '4. tipos que existem hoje',
       coalesce(string_agg(distinct tipo, ', '), 'nenhum') from mensagens;
