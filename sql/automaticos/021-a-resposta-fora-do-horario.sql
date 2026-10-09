-- ============================================================
--  A RESPOSTA AUTOMÁTICA FORA DO HORÁRIO
--
--  >>> RODAR NO SUPABASE DO **ZORVIN** (o das conversas). <<<
--  A ponte aplica sozinha ao subir (sql/automaticos). Pode rodar de novo sem
--  medo — na ordem da pasta, como diz a regra 5 do LEIA-ME.
--
--  ------------------------------------------------------------
--  O QUE ISTO ACRESCENTA
--
--  Pedido do Rodrigo em 08/10, o nº 1 da lista de ideias: quem escreve à
--  noite ou no fim de semana recebe na hora algo como "Recebemos sua
--  mensagem. Respondemos de segunda a sexta, das 8h às 18h". Decidido com
--  ele:
--
--    - o texto e o horário são de cada DEPARTAMENTO;
--    - ela NÃO se repete a cada mensagem do cliente: sai uma vez por
--      período fechado (a noite, o fim de semana, o feriado);
--    - a conversa CONTINUA NA FILA DE ESPERA, porque o cliente ainda não foi
--      atendido.
--
--  QUATRO PEÇAS:
--
--    zorvin_feriados               os dias em que o escritório não abre
--    zorvin_horario_de(...)        a conta: está aberto? quando abre? quando
--                                  fechou? — UMA conta, usada pela ponte e
--                                  pela prévia do painel
--    zorvin_fora_do_horario        a configuração de cada departamento
--    zorvin_respostas_automaticas  o que saiu, para a conversa mostrar
--
--  E a função que a ponte chama a cada mensagem de cliente,
--  zorvin_responder_fora_do_horario(conversa, id da mensagem), que decide e
--  já reserva a vez — tudo numa transação só.
--
--  ------------------------------------------------------------
--  A RESPOSTA NÃO ENTRA EM `mensagens`, E ESSA É A DECISÃO PRINCIPAL
--
--  Em `mensagens` ela passaria por um gatilho feito à mão no começo do
--  projeto — o que mantém a prévia, a ordem e as NÃO LIDAS da lista — e que
--  não está em arquivo nenhum. Não dá para saber o que ele faz com uma
--  origem nova: a prévia da lista passaria a ser "Recebemos sua mensagem"
--  no lugar da pergunta do cliente, e talvez o selo de não lidas contasse a
--  nossa resposta como mensagem a ler. E o painel de números, a fila de
--  espera, os avisos de mensagem nova e "quem respondeu" leem `mensagens`.
--
--  Num registro à parte nada disso muda. A conversa mostra a resposta como
--  uma bolha nossa (o painel junta este registro à linha do tempo, como já
--  junta as notas e as mensagens que não saíram), e a espera, a prévia, as
--  não lidas e os números continuam falando só do cliente e da equipe.
--
--  ------------------------------------------------------------
--  QUANDO ELA SAI — tudo isto é conferido aqui, e não na ponte:
--
--    - a mensagem é DO CLIENTE e é RECENTE (até 30 minutos): a importação de
--      histórico e o reenvio atrasado da Uazapi não respondem o passado;
--    - não é grupo, a linha não está desativada, e o departamento da linha
--      tem a resposta LIGADA, com texto;
--    - o cliente escreveu FORA do horário (dia da semana sem expediente,
--      fora da faixa, ou feriado);
--    - ninguém da equipe escreveu nesta conversa depois que o escritório
--      fechou — quem fez hora extra está atendendo, e "estamos fechados" no
--      meio de uma conversa viva é constrangimento;
--    - e ainda não saiu nenhuma neste período fechado. A chave do período é
--      a hora em que o escritório ABRE de novo (`ate`), única por conversa:
--      a sexta à noite e o sábado de manhã têm a mesma, a segunda à noite
--      outra. Duas pontes vivas na publicação, ou a caixa de entrada
--      reprocessando, esbarram na mesma chave e só uma manda.
--
--  ------------------------------------------------------------
--  ENQUANTO ESTE ARQUIVO NÃO FOR RODADO
--
--  A ponte descobre sozinha que a função não existe, avisa uma vez no log e
--  segue como antes. O painel não mostra a configuração.
--
--  DEPENDE DE JÁ TER RODADO
--    as tabelas do Zorvin (`conversas`, `mensagens`, `contatos`, `advogados`,
--    `departamentos`) e `zorvin_admin()`. Num banco limpo, só os feriados e a
--    conta do horário nascem — e é isso que a prova da ponte confere.
-- ============================================================

do $fora$
declare
  v_feriados_novos boolean := to_regclass('public.zorvin_feriados') is null;
begin
  -- A TABELA DA CONFERÊNCIA NASCE ANTES DE TUDO — a lição do 006 e do 007.
  drop table if exists zorvin_conferencia_021;
  create temp table zorvin_conferencia_021 (item text, resposta text);

  -- ----------------------------------------------------------
  --  OS FERIADOS — do escritório inteiro, e não de cada departamento: no
  --  dia em que o escritório fecha, fecha para todos.
  --
  --  Nasce fora da guarda, como a conta do horário logo abaixo: as duas não
  --  dependem de nenhuma tabela do Zorvin, e é assim que a prova da ponte as
  --  confere num banco limpo.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_feriados (
      dia        date primary key,
      nome       text not null default '' check (length(nome) <= 80),
      criado_em  timestamptz not null default now()
    )
  $x$;
  execute $x$
    comment on table public.zorvin_feriados is
      'Os dias em que o escritório não abre. A resposta automática fora do '
      'horário conta estes dias como fechados, em todos os departamentos.'
  $x$;

  -- OS FERIADOS NACIONAIS SÓ ENTRAM NA RODADA QUE CRIA A TABELA — a regra 5
  -- do LEIA-ME. Rodar de novo não pode devolver um feriado que alguém tirou
  -- pela tela. Carnaval e Corpus Christi ficam de fora: são ponto
  -- facultativo, e quem fecha nesses dias acrescenta.
  if v_feriados_novos then
    insert into public.zorvin_feriados (dia, nome) values
      ('2026-10-12', 'Nossa Senhora Aparecida'),
      ('2026-11-02', 'Finados'),
      ('2026-11-15', 'Proclamação da República'),
      ('2026-11-20', 'Consciência Negra'),
      ('2026-12-25', 'Natal'),
      ('2027-01-01', 'Confraternização Universal'),
      ('2027-03-26', 'Sexta-feira Santa'),
      ('2027-04-21', 'Tiradentes'),
      ('2027-05-01', 'Dia do Trabalho'),
      ('2027-09-07', 'Independência'),
      ('2027-10-12', 'Nossa Senhora Aparecida'),
      ('2027-11-02', 'Finados'),
      ('2027-11-15', 'Proclamação da República'),
      ('2027-11-20', 'Consciência Negra'),
      ('2027-12-25', 'Natal')
    on conflict (dia) do nothing;
  end if;

  execute 'alter table public.zorvin_feriados enable row level security';
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'drop policy if exists zorvin_feriados_leitura on public.zorvin_feriados';
    execute 'create policy zorvin_feriados_leitura on public.zorvin_feriados
               for select to authenticated using (true)';
    execute 'grant select on public.zorvin_feriados to authenticated';
  end if;

  -- ----------------------------------------------------------
  --  O EXPEDIENTE DE UM DIA: [abre, fecha], ou nulo quando o escritório não
  --  abre nele (dia sem faixa, ou feriado).
  --
  --  A semana é um objeto com as chaves seg…dom, e cada uma é nula (fechado)
  --  ou ["08:00", "18:00"]. Uma faixa que não se lê, ou que fecha antes de
  --  abrir, conta como FECHADO, e não como erro: a prévia do painel chama
  --  esta conta com o que a pessoa ainda está digitando, e quem guarda já
  --  confere a semana inteira antes de gravar.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_expediente_do_dia(p_semana jsonb, p_dia date)
    returns time[] language plpgsql stable set search_path = public as $f$
    declare
      v_faixa jsonb;
      v_abre  time;
      v_fecha time;
    begin
      if p_semana is null or jsonb_typeof(p_semana) <> 'object' or p_dia is null then
        return null;
      end if;
      if exists (select 1 from public.zorvin_feriados where dia = p_dia) then
        return null;
      end if;
      v_faixa := p_semana -> (array['seg','ter','qua','qui','sex','sab','dom'])
                                [extract(isodow from p_dia)::int];
      if v_faixa is null or jsonb_typeof(v_faixa) <> 'array'
         or jsonb_array_length(v_faixa) <> 2 then
        return null;
      end if;
      begin
        v_abre := (v_faixa ->> 0)::time;
        v_fecha := (v_faixa ->> 1)::time;
      exception when others then
        return null;
      end;
      if v_abre is null or v_fecha is null or v_abre >= v_fecha then
        return null;
      end if;
      return array[v_abre, v_fecha];
    end
    $f$
  $x$;

  -- ----------------------------------------------------------
  --  A CONTA DO HORÁRIO, numa função só. Devolve:
  --
  --    aberto     está no expediente agora?
  --    fecha_em   (aberto) quando fecha hoje
  --    abre_em    (fechado) quando abre de novo — a chave do período
  --    fechou_em  (fechado) quando fechou pela última vez
  --
  --  A hora vale NO FUSO do departamento: a ponte roda em UTC na Render, e
  --  "18h" sem fuso seria 15h em Brasília.
  --
  --  Procura até 31 dias para cada lado. Uma semana sem nenhum dia aberto
  --  devolve abre_em nulo — e aí a resposta não sai, porque não haveria o
  --  que prometer ao cliente.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_horario_de(
      p_semana jsonb, p_fuso text default 'America/Sao_Paulo', p_quando timestamptz default now())
    returns jsonb language plpgsql stable set search_path = public as $f$
    declare
      v_fuso  text := coalesce(nullif(btrim(p_fuso), ''), 'America/Sao_Paulo');
      v_local timestamp;
      v_hoje  date;
      v_agora time;
      v_faixa time[];
      v_dia   date;
      i       int;
      v_abre_em   timestamptz;
      v_fechou_em timestamptz;
    begin
      v_local := coalesce(p_quando, now()) at time zone v_fuso;
      v_hoje := v_local::date;
      v_agora := v_local::time;

      v_faixa := public.zorvin_expediente_do_dia(p_semana, v_hoje);
      if v_faixa is not null and v_agora >= v_faixa[1] and v_agora < v_faixa[2] then
        return jsonb_build_object(
          'aberto', true,
          'fecha_em', (v_hoje + v_faixa[2]) at time zone v_fuso,
          'abre_em', null, 'fechou_em', null);
      end if;

      for i in 0..31 loop
        v_dia := v_hoje + i;
        v_faixa := public.zorvin_expediente_do_dia(p_semana, v_dia);
        if v_faixa is not null and (i > 0 or v_agora < v_faixa[1]) then
          v_abre_em := (v_dia + v_faixa[1]) at time zone v_fuso;
          exit;
        end if;
      end loop;

      for i in 0..31 loop
        v_dia := v_hoje - i;
        v_faixa := public.zorvin_expediente_do_dia(p_semana, v_dia);
        if v_faixa is not null and (i > 0 or v_agora >= v_faixa[2]) then
          v_fechou_em := (v_dia + v_faixa[2]) at time zone v_fuso;
          exit;
        end if;
      end loop;

      return jsonb_build_object('aberto', false, 'fecha_em', null,
                                'abre_em', v_abre_em, 'fechou_em', v_fechou_em);
    end
    $f$
  $x$;
  -- A CONTA É DE QUEM ENTROU, e não de qualquer um: toda função nasce
  -- executável por `public` — que inclui `anon` (armadilha nº 5 da ponte).
  execute 'revoke all on function public.zorvin_expediente_do_dia(jsonb, date) from public';
  execute 'revoke all on function public.zorvin_horario_de(jsonb, text, timestamptz) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_expediente_do_dia(jsonb, date) from anon';
    execute 'revoke all on function public.zorvin_horario_de(jsonb, text, timestamptz) from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.zorvin_expediente_do_dia(jsonb, date) to authenticated';
    execute 'grant execute on function public.zorvin_horario_de(jsonb, text, timestamptz) to authenticated';
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_expediente_do_dia(jsonb, date) to service_role';
    execute 'grant execute on function public.zorvin_horario_de(jsonb, text, timestamptz) to service_role';
  end if;

  insert into zorvin_conferencia_021
  select 'os feriados existem', (to_regclass('public.zorvin_feriados') is not null)::text
  union all
  select 'a conta do horário existe',
         (to_regprocedure('public.zorvin_horario_de(jsonb,text,timestamptz)') is not null)::text;

  -- ----------------------------------------------------------
  --  A GUARDA: num banco limpo (a prova 51l-bis, ou um cliente novo) não há
  --  conversa, departamento nem administrador, e o resto não tem onde morar.
  -- ----------------------------------------------------------
  if to_regclass('public.conversas') is null or to_regclass('public.mensagens') is null
     or to_regclass('public.contatos') is null or to_regclass('public.advogados') is null
     or to_regclass('public.departamentos') is null
     or to_regprocedure('public.zorvin_admin()') is null then
    insert into zorvin_conferencia_021
      values ('sem as tabelas do Zorvin', 'só os feriados e a conta do horário');
    raise notice 'Zorvin: sem as tabelas do Zorvin — o script 021 criou só os feriados e a conta do horário.';
    return;
  end if;

  -- QUEM ADMINISTRA MEXE NOS FERIADOS. Aqui, e não lá em cima, porque
  -- `zorvin_admin()` é do Zorvin.
  execute 'drop policy if exists zorvin_feriados_criar on public.zorvin_feriados';
  execute 'create policy zorvin_feriados_criar on public.zorvin_feriados
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_feriados_editar on public.zorvin_feriados';
  execute 'create policy zorvin_feriados_editar on public.zorvin_feriados
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_feriados_apagar on public.zorvin_feriados';
  execute 'create policy zorvin_feriados_apagar on public.zorvin_feriados
             for delete to authenticated using (public.zorvin_admin())';
  execute 'grant insert, update, delete on public.zorvin_feriados to authenticated';

  -- ----------------------------------------------------------
  --  A CONFIGURAÇÃO DE CADA DEPARTAMENTO
  --
  --  Nasce DESLIGADA. Ligar é decisão de quem administra, departamento por
  --  departamento: uma resposta que começasse a sair sozinha na publicação
  --  falaria com cliente sem ninguém ter escrito o que ela diz.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_fora_do_horario (
      departamento_id bigint primary key references public.departamentos(id) on delete cascade,
      ligada          boolean not null default false,
      texto           text not null default '' check (length(texto) <= 1000),
      semana          jsonb not null default
        '{"seg":["08:00","18:00"],"ter":["08:00","18:00"],"qua":["08:00","18:00"],
          "qui":["08:00","18:00"],"sex":["08:00","18:00"],"sab":null,"dom":null}'::jsonb,
      fuso            text not null default 'America/Sao_Paulo',
      atualizada_em   timestamptz not null default now(),
      atualizada_por  uuid
    )
  $x$;
  execute $x$
    comment on table public.zorvin_fora_do_horario is
      'A resposta automática fora do horário de cada departamento: ligada ou '
      'não, o texto, o expediente da semana e o fuso. Quem administra muda; '
      'quem entrou lê.'
  $x$;

  -- O GATILHO CONFERE ANTES DE GRAVAR, e diz o que está errado em português.
  -- A semana gravada fica sempre com as sete chaves — quem lê não precisa
  -- adivinhar o que quer dizer uma chave ausente.
  execute $x$
    create or replace function public.zorvin_fora_do_horario_confere()
    returns trigger language plpgsql set search_path = public as $f$
    declare
      v_dias constant text[] := array['seg','ter','qua','qui','sex','sab','dom'];
      v_nomes constant text[] := array['segunda','terça','quarta','quinta','sexta','sábado','domingo'];
      v_limpa jsonb := '{}'::jsonb;
      v_faixa jsonb;
      v_chave text;
      v_abre  time;
      v_fecha time;
      v_abertos int := 0;
      i int;
    begin
      new.texto := coalesce(new.texto, '');
      new.fuso := coalesce(nullif(btrim(new.fuso), ''), 'America/Sao_Paulo');
      begin
        perform now() at time zone new.fuso;
      exception when others then
        raise exception using errcode = '23514',
          message = format('Fuso horário desconhecido: %s.', new.fuso);
      end;

      if new.semana is null or jsonb_typeof(new.semana) <> 'object' then
        raise exception using errcode = '23514',
          message = 'O horário da semana precisa dizer, dia a dia, quando abre e quando fecha.';
      end if;
      for v_chave in select jsonb_object_keys(new.semana) loop
        if not v_chave = any (v_dias) then
          raise exception using errcode = '23514',
            message = format('Dia da semana desconhecido no horário: %s.', v_chave);
        end if;
      end loop;
      for i in 1..7 loop
        v_faixa := new.semana -> v_dias[i];
        if v_faixa is null or jsonb_typeof(v_faixa) = 'null' then
          v_limpa := v_limpa || jsonb_build_object(v_dias[i], null);
          continue;
        end if;
        begin
          if jsonb_typeof(v_faixa) <> 'array' or jsonb_array_length(v_faixa) <> 2 then
            raise exception 'forma';
          end if;
          v_abre := (v_faixa ->> 0)::time;
          v_fecha := (v_faixa ->> 1)::time;
        exception when others then
          raise exception using errcode = '23514',
            message = format('O horário de %s não se lê: escreva a hora de abrir e a de fechar.',
                             v_nomes[i]);
        end;
        if v_abre is null or v_fecha is null or v_abre >= v_fecha then
          raise exception using errcode = '23514',
            message = format('Em %s a hora de fechar precisa ser depois da de abrir.', v_nomes[i]);
        end if;
        v_limpa := v_limpa || jsonb_build_object(v_dias[i],
                     jsonb_build_array(to_char(v_abre, 'HH24:MI'), to_char(v_fecha, 'HH24:MI')));
        v_abertos := v_abertos + 1;
      end loop;
      new.semana := v_limpa;

      -- LIGADA SEM TEXTO OU SEM NENHUM DIA ABERTO não é uma resposta: o
      -- cliente receberia uma mensagem vazia, ou "voltamos" sem quando.
      if new.ligada and btrim(new.texto) = '' then
        raise exception using errcode = '23514',
          message = 'Para ligar a resposta automática, escreva o texto que o cliente vai receber.';
      end if;
      if new.ligada and v_abertos = 0 then
        raise exception using errcode = '23514',
          message = 'Para ligar a resposta automática, abra pelo menos um dia da semana.';
      end if;

      new.atualizada_em := now();
      new.atualizada_por := coalesce(auth.uid(), new.atualizada_por);
      return new;
    end
    $f$
  $x$;
  execute 'drop trigger if exists zorvin_fora_do_horario_confere on public.zorvin_fora_do_horario';
  execute 'create trigger zorvin_fora_do_horario_confere
             before insert or update on public.zorvin_fora_do_horario
             for each row execute function public.zorvin_fora_do_horario_confere()';

  execute 'alter table public.zorvin_fora_do_horario enable row level security';
  execute 'drop policy if exists zorvin_fora_do_horario_leitura on public.zorvin_fora_do_horario';
  execute 'create policy zorvin_fora_do_horario_leitura on public.zorvin_fora_do_horario
             for select to authenticated using (true)';
  execute 'drop policy if exists zorvin_fora_do_horario_criar on public.zorvin_fora_do_horario';
  execute 'create policy zorvin_fora_do_horario_criar on public.zorvin_fora_do_horario
             for insert to authenticated with check (public.zorvin_admin())';
  execute 'drop policy if exists zorvin_fora_do_horario_editar on public.zorvin_fora_do_horario';
  execute 'create policy zorvin_fora_do_horario_editar on public.zorvin_fora_do_horario
             for update to authenticated
             using (public.zorvin_admin()) with check (public.zorvin_admin())';
  execute 'grant select, insert, update on public.zorvin_fora_do_horario to authenticated';

  -- ----------------------------------------------------------
  --  O QUE SAIU — uma linha por resposta, para a conversa mostrar
  --
  --  `ate` é a hora em que o escritório abre de novo: a chave do período
  --  fechado, ÚNICA por conversa. `texto` é o que foi mandado, guardado: a
  --  configuração muda depois, e a conversa tem de mostrar o que o cliente
  --  recebeu.
  --
  --  Quem escreve aqui é a ponte (`service_role`) e a função logo abaixo.
  --  Quem entrou só LÊ, e só das conversas que vê.
  -- ----------------------------------------------------------
  execute $x$
    create table if not exists public.zorvin_respostas_automaticas (
      id                 uuid primary key default gen_random_uuid(),
      conversa_id        uuid not null references public.conversas(id) on delete cascade,
      id_uazapi_cliente  text,
      ate                timestamptz not null,
      texto              text not null,
      status             text not null default 'enviando'
                           check (status in ('enviando', 'enviada', 'erro')),
      id_uazapi          text,
      erro               text,
      criada_em          timestamptz not null default now(),
      enviada_em         timestamptz,
      unique (conversa_id, ate)
    )
  $x$;
  execute $x$
    comment on table public.zorvin_respostas_automaticas is
      'Cada resposta automática fora do horário: o texto que saiu, para qual '
      'conversa, e até quando o escritório estava fechado (uma por período). '
      'Não entra em mensagens: a espera, a prévia e as não lidas não mudam.'
  $x$;
  execute 'alter table public.zorvin_respostas_automaticas enable row level security';
  execute 'drop policy if exists zorvin_respostas_automaticas_leitura on public.zorvin_respostas_automaticas';
  execute 'create policy zorvin_respostas_automaticas_leitura on public.zorvin_respostas_automaticas
             for select to authenticated
             using (exists (select 1 from public.conversas c where c.id = conversa_id))';
  execute 'grant select on public.zorvin_respostas_automaticas to authenticated';
  execute 'revoke insert, update, delete on public.zorvin_respostas_automaticas from authenticated';

  -- ----------------------------------------------------------
  --  A DECISÃO, E A RESERVA DA VEZ — chamada pela ponte a cada mensagem de
  --  cliente que chega pelo WhatsApp.
  --
  --  Devolve {responde: true, id, texto, ate} quando a resposta deve sair,
  --  com a linha do registro JÁ CRIADA (status 'enviando'); e {responde:
  --  false, motivo} quando não — o motivo é para o log da ponte, e é o que
  --  responde "por que este cliente não recebeu?".
  --
  --  `security definer` e executável SÓ pela ponte: quem entrou no painel não
  --  tem por que mandar mensagem ao cliente por aqui.
  -- ----------------------------------------------------------
  execute $x$
    create or replace function public.zorvin_responder_fora_do_horario(
      p_conversa uuid, p_id_uazapi text)
    returns jsonb language plpgsql security definer set search_path = public as $f$
    declare
      v_msg     record;
      v_conv    record;
      v_cfg     public.zorvin_fora_do_horario;
      v_horario jsonb;
      v_ate     timestamptz;
      v_fechou  timestamptz;
      v_id      uuid;
    begin
      select m.origem, m.criado_em into v_msg
        from public.mensagens m
       where m.conversa_id = p_conversa and m.id_uazapi = p_id_uazapi
       limit 1;
      if not found then
        return jsonb_build_object('responde', false, 'motivo', 'mensagem_nao_achada');
      end if;
      if v_msg.origem is distinct from 'contato' then
        return jsonb_build_object('responde', false, 'motivo', 'nao_e_do_cliente');
      end if;
      -- O PASSADO NÃO SE RESPONDE: importação de histórico, reenvio atrasado.
      if v_msg.criado_em < now() - interval '30 minutes' then
        return jsonb_build_object('responde', false, 'motivo', 'mensagem_antiga');
      end if;

      -- `a.ativo` PELO NOME, e nunca `to_jsonb(a)`: `advogados` guarda a
      -- chave da Uazapi em colunas fechadas (a régua do 012). SÓ O `false`
      -- EXPLÍCITO desativa — a régua da fila de envio.
      select c.id, ct.numero, a.departamento_id,
             coalesce(a.ativo = false, false) as desativada
        into v_conv
        from public.conversas c
        join public.contatos ct on ct.id = c.contato_id
        join public.advogados a on a.id = c.advogado_id
       where c.id = p_conversa;
      if not found then
        return jsonb_build_object('responde', false, 'motivo', 'conversa_nao_achada');
      end if;
      if v_conv.numero like 'grupo:%' then
        return jsonb_build_object('responde', false, 'motivo', 'grupo');
      end if;
      if v_conv.desativada then
        return jsonb_build_object('responde', false, 'motivo', 'linha_desativada');
      end if;
      if v_conv.departamento_id is null then
        return jsonb_build_object('responde', false, 'motivo', 'sem_departamento');
      end if;

      select * into v_cfg from public.zorvin_fora_do_horario
       where departamento_id = v_conv.departamento_id;
      if not found or not v_cfg.ligada or btrim(v_cfg.texto) = '' then
        return jsonb_build_object('responde', false, 'motivo', 'desligada');
      end if;

      v_horario := public.zorvin_horario_de(v_cfg.semana, v_cfg.fuso, v_msg.criado_em);
      if (v_horario ->> 'aberto')::boolean then
        return jsonb_build_object('responde', false, 'motivo', 'no_horario');
      end if;
      v_ate := (v_horario ->> 'abre_em')::timestamptz;
      v_fechou := (v_horario ->> 'fechou_em')::timestamptz;
      if v_ate is null then
        return jsonb_build_object('responde', false, 'motivo', 'sem_dia_aberto');
      end if;

      -- ALGUÉM DA EQUIPE JÁ ESCREVEU DEPOIS DO FECHAMENTO: a conversa está
      -- sendo atendida. Inclui quem respondeu pelo celular, que também é
      -- `advogado`. Sem fechamento conhecido, as últimas 12 horas.
      if exists (select 1 from public.mensagens m
                  where m.conversa_id = p_conversa and m.origem = 'advogado'
                    and m.criado_em >= coalesce(v_fechou, v_msg.criado_em - interval '12 hours')) then
        return jsonb_build_object('responde', false, 'motivo', 'equipe_respondeu');
      end if;

      -- A RESERVA DA VEZ: uma por período fechado e por conversa. Quem chega
      -- depois esbarra na chave e não manda.
      insert into public.zorvin_respostas_automaticas
             (conversa_id, id_uazapi_cliente, ate, texto)
      values (p_conversa, p_id_uazapi, v_ate, v_cfg.texto)
      on conflict (conversa_id, ate) do nothing
      returning id into v_id;
      if v_id is null then
        return jsonb_build_object('responde', false, 'motivo', 'ja_respondida');
      end if;
      return jsonb_build_object('responde', true, 'id', v_id, 'texto', v_cfg.texto, 'ate', v_ate);
    end
    $f$
  $x$;
  execute 'revoke all on function public.zorvin_responder_fora_do_horario(uuid, text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.zorvin_responder_fora_do_horario(uuid, text) from anon';
  end if;
  execute 'revoke all on function public.zorvin_responder_fora_do_horario(uuid, text) from authenticated';
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    execute 'grant execute on function public.zorvin_responder_fora_do_horario(uuid, text) to service_role';
    execute 'grant select, update on public.zorvin_respostas_automaticas to service_role';
    execute 'grant select on public.zorvin_fora_do_horario, public.zorvin_feriados to service_role';
  end if;

  insert into zorvin_conferencia_021
  select 'a configuração por departamento existe',
         (to_regclass('public.zorvin_fora_do_horario') is not null)::text
  union all
  select 'o registro das respostas existe',
         (to_regclass('public.zorvin_respostas_automaticas') is not null)::text
  union all
  select 'só a ponte manda a resposta (quem entrou não chama a função)',
         (not has_function_privilege('authenticated',
            'public.zorvin_responder_fora_do_horario(uuid,text)', 'execute'))::text
  union all
  select 'departamentos com a resposta ligada',
         (select count(*) from public.zorvin_fora_do_horario where ligada)::text
  union all
  select 'feriados de hoje em diante',
         (select count(*) from public.zorvin_feriados where dia >= current_date)::text;
end
$fora$;

-- ----------------------------------------------------------
--  A CONFERÊNCIA NO PAPEL DE QUEM ATENDE — a régua do 012: quem entrou tem
--  de ler a configuração, os feriados e o registro, e fazer a conta do
--  horário, sem "permission denied". A troca de papel volta atrás sozinha.
-- ----------------------------------------------------------
do $conf$
declare
  v_resposta text;
begin
  if to_regclass('public.zorvin_respostas_automaticas') is null
     or not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  begin
    perform set_config('role', 'authenticated', true);
    perform count(*) from public.zorvin_fora_do_horario;
    perform count(*) from public.zorvin_feriados;
    perform count(*) from public.zorvin_respostas_automaticas;
    perform public.zorvin_horario_de('{"seg":["08:00","18:00"]}'::jsonb, 'America/Sao_Paulo', now());
    v_resposta := 'true';
    execute 'reset role';
  exception when others then
    v_resposta := 'NÃO — ' || sqlerrm || ' (código ' || sqlstate || ')';
  end;
  insert into zorvin_conferencia_021
    values ('quem entrou lê a configuração e faz a conta do horário', v_resposta);
end
$conf$;

-- A RESPOSTA DE "DEU CERTO?", na última linha, que é a que o editor mostra.
select * from zorvin_conferencia_021;
