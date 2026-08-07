-- ------------------------------------------------------------
--  LIMPA AS PASTILHAS QUE VIERAM COM O ID NO LUGAR DO EMOJI
--
--  A primeira versão da detecção de reação pegou o campo errado do webhook e
--  gravou o ID DA MENSAGEM onde deveria estar o emoji. Na conversa, a bolha
--  passou a exibir uma pastilha escrita "3EB080DB9CFFC33549C426" — e, como um
--  id nunca é vazio, tirar a reação no celular não apagava nada.
--
--  O código já foi consertado e recusa qualquer coisa que não tenha cara de
--  emoji, mas o que já está gravado continua na tela até alguém limpar. É o que
--  este comando faz: apaga SÓ as entradas com mais de 8 caracteres — um emoji,
--  mesmo os compostos como 👨‍👩‍👧 e 🇧🇷, cabe nesse limite; um id do
--  WhatsApp tem 20 e poucos.
--
--  Reações legítimas que estejam na mesma mensagem são preservadas.
--
--  Rode INTEIRO no SQL Editor do Supabase. É um comando só.
-- ------------------------------------------------------------
update mensagens m
   set reacoes = coalesce((
         select jsonb_agg(e)
           from jsonb_array_elements(m.reacoes) e
          where length(e->>'emoji') <= 8
       ), '[]'::jsonb)
 where m.reacoes is not null
   and exists (select 1 from jsonb_array_elements(m.reacoes) e
                where length(e->>'emoji') > 8);
