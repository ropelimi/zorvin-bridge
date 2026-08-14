-- NOTA INTERNA QUE SE EDITA E SE APAGA, E UM HISTÓRICO DE QUEM MEXEU NO QUÊ.
--
-- Rodar INTEIRO no SQL Editor do Supabase. Idempotente.
--
-- ------------------------------------------------------------------
-- 1. A NOTA NÃO SOME: ELA FICA MARCADA
-- ------------------------------------------------------------------
--
-- Apagar de verdade é a saída fácil e a errada. A nota interna é onde a equipe
-- escreve o que combinou com o cliente, e uma que desaparece sem deixar rastro
-- vira "eu jurava que tinha anotado". Some do texto, fica a lápide: quem
-- apagou e quando.
--
-- `texto` NÃO é limpo aqui — quem apaga não perde o direito de o escritório
-- saber o que estava escrito, e é o painel que deixa de mostrar. Se um dia for
-- preciso esconder de vez, é uma linha de `update` e uma decisão consciente,
-- não um efeito colateral de clicar na lixeira.

alter table notas add column if not exists autor_id       uuid;
alter table notas add column if not exists editada_em     timestamptz;
alter table notas add column if not exists editada_por    text;
alter table notas add column if not exists apagada_em     timestamptz;
alter table notas add column if not exists apagada_por    text;
alter table notas add column if not exists apagada_por_id uuid;

comment on column notas.apagada_em is
  'Quando foi apagada. Nula = ativa. O texto continua guardado.';

-- ------------------------------------------------------------------
-- 2. O HISTÓRICO DE ALTERAÇÕES
-- ------------------------------------------------------------------
--
-- Uma linha por mexida: quem, quando, em quê, de que valor para que valor.
--
-- SEM CHAVE ESTRANGEIRA para `contatos`, e de propósito. Registro de auditoria
-- que some junto com o que ele auditava não é registro de auditoria — e é
-- justamente quando alguém apaga um cadastro que se quer saber quem foi.

create table if not exists alteracoes (
  id          uuid primary key default gen_random_uuid(),
  -- De quem é a alteração. É por aqui que a tela de histórico junta tudo o que
  -- aconteceu com um cliente, mesmo que tenha sido em conversas diferentes.
  contato_id  uuid,
  conversa_id uuid,
  -- 'cadastro' | 'nota_criada' | 'nota_editada' | 'nota_apagada'
  tipo        text not null,
  -- O que mudou: o nome do campo do cadastro, ou o id da nota.
  alvo        text,
  antes       text,
  depois      text,
  -- O nome de então, e o id que não muda. Os dois, pelo mesmo motivo das
  -- mensagens: o nome é o que se lê, o id é o que se conta.
  autor       text,
  autor_id    uuid,
  criado_em   timestamptz not null default now()
);

create index if not exists alteracoes_contato_idx on alteracoes (contato_id, criado_em desc);
create index if not exists alteracoes_conversa_idx on alteracoes (conversa_id, criado_em desc);

comment on table alteracoes is
  'Histórico de quem mexeu no quê: cadastro do cliente e notas internas.';

alter table alteracoes enable row level security;
alter table notas enable row level security;

-- (o `if` sobre o papel é só para este arquivo poder rodar num Postgres comum,
--  que é onde eu testo antes de mandar; no Supabase ele sempre existe)
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;

  -- LEITURA para quem está dentro. O histórico é do escritório, não de quem
  -- escreveu: a pergunta que ele responde é "quem mexeu nisto?", e ela não se
  -- responde mostrando só as próprias linhas.
  execute 'drop policy if exists alteracoes_leitura on alteracoes';
  execute 'create policy alteracoes_leitura on alteracoes for select to authenticated using (true)';

  -- ESCRITA só acrescenta. Sem update e sem delete: um histórico que se
  -- reescreve não serve para nada, e a ponte grava com a chave de serviço, que
  -- não passa por estas regras.
  execute 'drop policy if exists alteracoes_insercao on alteracoes';
  execute 'create policy alteracoes_insercao on alteracoes for insert to authenticated with check (true)';

  -- As notas passam a ser ALTERÁVEIS pela tela — antes só nasciam. Apagar de
  -- verdade continua fora: a lápide é um `update`, não um `delete`.
  execute 'drop policy if exists notas_atualizacao on notas';
  execute 'create policy notas_atualizacao on notas for update to authenticated using (true) with check (true)';
end;
$$;
